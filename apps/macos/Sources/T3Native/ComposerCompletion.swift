import AppKit
import T3Core

@MainActor
final class ComposerCompletion: NSObject, NSTableViewDataSource, NSTableViewDelegate,
  NSPopoverDelegate
{
  var onInsert: ((NSRange, String) -> Void)?
  /// Invoked after the command token was removed. The parent opens the picker or changes mode.
  var onLocalCommand: ((String) -> Void)?
  weak var anchorView: NSView?
  /// Optional caret rectangle, in anchorView coordinates. NSTextView anchors compute it automatically.
  var anchorRect: NSRect?
  /// Set only for an older server known to lack workspace-scoped refreshProviders.
  var useGlobalProviderCatalog = false { didSet { cache = nil } }
  var fileReferenceFormat: ComposerMention.FileFormat = .markdownLink
  var skillUsesLiteralPath = false
  /// Older servers may expose bounded folder listings but not indexed path search.
  var useDirectoryListing = false

  private let store: ClientStore
  private var state = ComposerCompletionState()
  private var text = ""
  private var cursor = 0
  private var displayedTicket: ComposerCompletionState.Ticket?
  private var displayedEligibility: LocalEligibility?
  private var items: [ComposerSuggestion] = []
  private var debounce: Task<Void, Never>?
  private var request: Task<Void, Never>?
  private var discoveryRetry: Task<Void, Never>?
  private var discoveryScope: ComposerCompletionScope?
  private var discoveryAttempts = 0
  private var cache: (scope: ComposerCompletionScope, provider: JSON, loaded: Date)?
  private let popover = NSPopover()
  private let table = CompletionTable()
  private let scroll = NSScrollView()
  private let status = NSTextField(labelWithString: "")
  private var programmaticClose = false

  private struct LocalEligibility: Equatable {
    let enabled: Bool
    let planModeEnabled: Bool
    let interactionModeSupported: Bool
  }
  private var localEligibility: LocalEligibility {
    LocalEligibility(
      enabled: onLocalCommand != nil && onInsert != nil,
      planModeEnabled: store.catalog.planModeEnabled,
      interactionModeSupported: store.catalog.provider(for: store.selectedThread?.model ?? .null)?
        .showInteractionMode == true)
  }
  private func slashItems(
    _ providerItems: [ComposerSuggestion], for ticket: ComposerCompletionState.Ticket
  ) -> [ComposerSuggestion] {
    let eligibility = localEligibility
    return ComposerSuggestion.slashItems(
      providerItems: providerItems, mention: ticket.mention,
      localCommandsEnabled: eligibility.enabled, planModeEnabled: eligibility.planModeEnabled,
      interactionModeSupported: eligibility.interactionModeSupported)
  }

  init(store: ClientStore) {
    self.store = store
    super.init()
    let controller = NSViewController()
    controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 250))
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("completion"))
    table.addTableColumn(column)
    table.headerView = nil
    table.rowHeight = 46
    table.intercellSpacing = .zero
    table.style = .plain
    table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
    table.autoresizingMask = [.width]
    table.dataSource = self
    table.delegate = self
    table.target = self
    table.action = #selector(selectClickedItem)
    table.setAccessibilityLabel("Composer suggestions")
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.drawsBackground = false
    status.font = .systemFont(ofSize: 12)
    status.textColor = .secondaryLabelColor
    status.maximumNumberOfLines = 2
    status.lineBreakMode = .byWordWrapping
    controller.view.addSubview(scroll)
    controller.view.addSubview(status)
    popover.contentViewController = controller
    popover.behavior = .semitransient
    popover.animates = false
    popover.delegate = self
  }

  /// Call on edits, selection changes, and store changes. Selection ranges/cursors use UTF-16.
  func refresh(text: String, cursor: Int) {
    self.text = text
    self.cursor = cursor
    let old = state.ticket
    let editor = anchorView as? NSTextView
    let composing = editor?.hasMarkedText() == true || (editor?.selectedRange().length ?? 0) > 0
    state.refresh(text: text, cursor: cursor, scope: composing ? nil : currentScope())
    guard let ticket = state.ticket else {
      debounce?.cancel()
      discoveryRetry?.cancel()
      displayedTicket = nil
      items = []
      hide()
      return
    }
    if old == ticket, displayedTicket == ticket, displayedEligibility == localEligibility {
      present()
      return
    }
    items = slashItems([], for: ticket)
    displayedTicket = items.isEmpty ? nil : ticket
    displayedEligibility = localEligibility
    table.reloadData()
    if !items.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    status.stringValue =
      ticket.mention.kind == .file
      ? "Searching files and folders…" : "Loading provider commands and skills…"
    present()
    schedule(ticket)
  }

  func dismiss() {
    state.dismiss()
    debounce?.cancel()
    discoveryRetry?.cancel()
    items = []
    displayedTicket = nil
    hide()
  }

  /// Return true before the composer's own Return/Tab/send handling when this consumes the key.
  func handleKeyDown(_ event: NSEvent) -> Bool {
    guard popover.isShown, (anchorView as? NSTextView)?.hasMarkedText() != true,
      event.modifierFlags.intersection([.command, .control, .option]).isEmpty
    else { return false }
    if event.keyCode == 53 {
      dismiss()
      return true
    }
    guard !items.isEmpty, let displayedTicket, state.accepts(displayedTicket),
      currentScope() == displayedTicket.scope
    else { return false }
    switch event.keyCode {
    case 125, 126:
      let delta = event.keyCode == 125 ? 1 : -1
      let next = (max(0, table.selectedRow) + delta + items.count) % items.count
      table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
      table.scrollRowToVisible(next)
      return true
    case 36, 76, 48:
      guard onInsert != nil else { return false }
      insertSelected()
      return true
    default: return false
    }
  }

  private func currentScope() -> ComposerCompletionScope? {
    guard store.ready, store.catalogReady, store.canEditThread,
      let location = store.workspaceLocation, let draft = store.composerDraftID,
      let provider = store.catalog.provider(for: store.selectedThread?.model ?? .null),
      provider.available
    else { return nil }
    return ComposerCompletionScope(
      environment: store.environmentKey, session: store.usageSessionID,
      thread: location.threadID, draft: draft, provider: provider.id, root: location.root)
  }

  private func schedule(_ ticket: ComposerCompletionState.Ticket) {
    debounce?.cancel()
    debounce = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
      guard let self, state.accepts(ticket), currentScope() == ticket.scope, request == nil else {
        return
      }
      startRequest(ticket)
    }
  }

  private func startRequest(_ ticket: ComposerCompletionState.Ticket) {
    // One RPC sequence at a time: rapidly typing cannot accumulate server-side searches.
    request = Task { [weak self] in
      guard let self else { return }
      defer {
        request = nil
        if let next = state.ticket, next != ticket { schedule(next) }
      }
      guard state.accepts(ticket), currentScope() == ticket.scope else { return }
      do {
        let results: [ComposerSuggestion]
        var discoveryPending = false
        if ticket.mention.kind == .file {
          guard let location = store.workspaceLocation else { return }
          let result: JSON
          if useDirectoryListing {
            let query = ticket.mention.query
            let directory = query.lastIndex(of: "/").map { String(query[..<$0]) } ?? ""
            result = try await store.workspaceCall(
              "projects.listEntries", at: location,
              fields: ["directoryPath": .string(directory)])
            results = ComposerSuggestion.files(result, limit: 200).filter {
              query.isEmpty || $0.name.localizedStandardContains(query)
            }.prefix(40).map { $0 }
          } else {
            result = try await store.workspaceCall(
              "projects.searchEntries", at: location,
              fields: ["query": .string(ticket.mention.query), "limit": .number(40)])
            results = ComposerSuggestion.files(result)
          }
        } else if ticket.mention.kind == .command, ticket.mention.range.location > 0 {
          results = slashItems([], for: ticket)
        } else {
          let provider = try await providerSnapshot(for: ticket.scope)
          guard state.accepts(ticket), currentScope() == ticket.scope else { return }
          discoveryPending =
            provider["workspaceSnapshots"].array.first {
              $0["cwd"].string == ticket.scope.root
            }?["slashCommandsPending"].bool == true
          let onlyCommand = (text as NSString).replacingCharacters(
            in: ticket.mention.range, with: ""
          )
          .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          let allowCompact =
            onlyCommand && !store.isNewConversation && !store.composerBusy
            && store.execution.activeRunID == nil && store.selectedAttachments.isEmpty
            && store.queuedEdit == nil && store.questionRequest == nil
          let providerItems = ComposerSuggestion.providerItems(
            provider, cwd: ticket.scope.root,
            kind: ticket.mention.kind, query: ticket.mention.query, allowCompact: allowCompact)
          results =
            ticket.mention.kind == .command ? slashItems(providerItems, for: ticket) : providerItems
        }
        guard state.accepts(ticket), currentScope() == ticket.scope else { return }
        items = results
        displayedTicket = ticket
        displayedEligibility = localEligibility
        status.stringValue =
          results.isEmpty
          ? (ticket.mention.kind == .file
            ? "No matching files or folders." : "No matching commands or skills for this provider.")
          : ""
        if ticket.mention.kind == .command, discoveryPending {
          if results.isEmpty { status.stringValue = "Discovering provider commands…" }
          retryDiscovery(ticket)
        }
        table.reloadData()
        if !items.isEmpty {
          table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        present()
      } catch {
        guard state.accepts(ticket), currentScope() == ticket.scope else { return }
        status.stringValue = error.localizedDescription
        items = slashItems([], for: ticket)
        displayedTicket = ticket
        displayedEligibility = localEligibility
        table.reloadData()
        if !items.isEmpty {
          table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        present()
      }
    }
  }

  private func providerSnapshot(for scope: ComposerCompletionScope) async throws -> JSON {
    if discoveryScope != scope {
      discoveryScope = scope
      discoveryAttempts = 0
    }
    if let cache, cache.scope == scope {
      let pending =
        cache.provider["workspaceSnapshots"].array.first {
          $0["cwd"].string == scope.root
        }?["slashCommandsPending"].bool == true
      if Date().timeIntervalSince(cache.loaded) < (pending ? 1 : 20) { return cache.provider }
    }
    let config = try await store.usageCall("server.getConfig", session: scope.session)
    guard currentScope() == scope else { throw CancellationError() }
    guard
      var provider = config["providers"].array.first(where: {
        $0["instanceId"].string == scope.provider
      })
    else {
      return .null
    }
    let workspace = provider["workspaceSnapshots"].array.first { $0["cwd"].string == scope.root }
    if !useGlobalProviderCatalog,
      workspace == nil || workspace?["slashCommandsPending"].bool == true
    {
      let refreshed = try await store.usageCall(
        "server.refreshProviders",
        payload: .object(["instanceId": .string(scope.provider), "cwd": .string(scope.root)]),
        session: scope.session)
      guard currentScope() == scope else { throw CancellationError() }
      provider =
        refreshed["providers"].array.first { $0["instanceId"].string == scope.provider } ?? .null
    }
    guard currentScope() == scope else { throw CancellationError() }
    cache = (scope, provider, Date())
    return provider
  }

  private func retryDiscovery(_ ticket: ComposerCompletionState.Ticket) {
    guard discoveryAttempts < 2 else { return }
    discoveryAttempts += 1
    discoveryRetry?.cancel()
    discoveryRetry = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(1250)) } catch { return }
      guard let self, state.accepts(ticket), currentScope() == ticket.scope, request == nil else {
        return
      }
      startRequest(ticket)
    }
  }

  private func present() {
    guard let anchorView, anchorView.window != nil, state.ticket != nil else { return }
    let height = items.isEmpty ? 52 : CGFloat(min(6, items.count)) * table.rowHeight + 12
    let width = min(500, max(300, anchorView.bounds.width))
    popover.contentSize = NSSize(width: width, height: height)
    scroll.frame = NSRect(x: 6, y: 6, width: width - 12, height: height - 12)
    table.setFrameSize(
      NSSize(width: width - 12, height: max(height - 12, CGFloat(items.count) * table.rowHeight)))
    scroll.isHidden = items.isEmpty
    status.frame = NSRect(x: 14, y: 12, width: width - 28, height: 28)
    status.isHidden = !items.isEmpty
    let rect: NSRect
    if let anchorRect {
      rect = anchorRect
    } else if let editor = anchorView as? NSTextView, let window = editor.window {
      let screenRect = editor.firstRect(
        forCharacterRange: NSRange(location: cursor, length: 0), actualRange: nil)
      rect = editor.convert(window.convertFromScreen(screenRect), from: nil)
    } else {
      rect = anchorView.bounds
    }
    if popover.isShown {
      popover.positioningRect = rect
    } else {
      let responder = anchorView.window?.firstResponder
      popover.show(relativeTo: rect, of: anchorView, preferredEdge: .maxY)
      if let responder { anchorView.window?.makeFirstResponder(responder) }
    }
  }

  private func hide() {
    programmaticClose = true
    popover.performClose(nil)
    programmaticClose = false
  }
  func popoverDidClose(_ notification: Notification) {
    if !programmaticClose {
      state.dismiss()
      debounce?.cancel()
      discoveryRetry?.cancel()
    }
  }

  @objc private func selectClickedItem() { insertSelected() }
  private func insertSelected() {
    guard let ticket = displayedTicket, state.accepts(ticket), currentScope() == ticket.scope,
      items.indices.contains(table.selectedRow), let onInsert
    else { return }
    if let editor = anchorView as? NSTextView,
      editor.string != text || editor.selectedRange() != NSRange(location: cursor, length: 0)
    {
      dismiss()
      return
    }
    let item = items[table.selectedRow]
    let localAction = onLocalCommand
    if item.localCommand != nil,
      !slashItems([], for: ticket).contains(where: { $0.id == item.id })
    {
      return
    }
    let insertion = item.selectionEdit(
      mention: ticket.mention, text: text,
      root: ticket.scope.root, fileFormat: fileReferenceFormat,
      skillUsesLiteralPath: skillUsesLiteralPath)
    let expectedText = (text as NSString).replacingCharacters(
      in: insertion.range, with: insertion.replacement)
    dismiss()
    onInsert(insertion.range, insertion.replacement)
    if let command = item.localCommand {
      // Parent validation may reject the edit; do not perform an action on an unremoved token.
      if let editor = anchorView as? NSTextView, editor.string != expectedText { return }
      guard currentScope() == ticket.scope else { return }
      localAction?(command)
    }
  }

  func numberOfRows(in tableView: NSTableView) -> Int { items.count }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    guard items.indices.contains(row) else { return nil }
    let item = items[row]
    let cell = NSStackView()
    cell.spacing = 10
    cell.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
    let image = NSImageView(
      image: NSImage(
        systemSymbolName: item.kind == .file
          ? (item.isDirectory ? "folder" : "doc") : item.kind == .skill ? "sparkles" : "terminal",
        accessibilityDescription: nil) ?? NSImage())
    image.contentTintColor = .secondaryLabelColor
    image.widthAnchor.constraint(equalToConstant: 18).isActive = true
    let title = NSTextField(labelWithString: item.label)
    title.font = .systemFont(ofSize: 13, weight: .medium)
    title.lineBreakMode = .byTruncatingTail
    let detail = NSTextField(labelWithString: item.detail)
    detail.font = .systemFont(ofSize: 11)
    detail.textColor = .secondaryLabelColor
    detail.lineBreakMode = .byTruncatingMiddle
    let labels = NSStackView(views: [title, detail])
    labels.orientation = .vertical
    labels.alignment = .leading
    labels.spacing = 2
    cell.addArrangedSubview(image)
    cell.addArrangedSubview(labels)
    cell.setAccessibilityLabel(item.label + ", " + item.detail)
    return cell
  }
}

private final class CompletionTable: NSTableView {
  override var acceptsFirstResponder: Bool { false }
}
