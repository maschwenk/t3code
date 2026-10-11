import AppKit
import T3Core
import T3Markdown

@MainActor final class Composer: NSTextView {
  var submit: (() -> Void)?
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 36 && event.modifierFlags.contains(.command) {
      submit?()
    } else {
      super.keyDown(with: event)
    }
  }
}

@MainActor
final class ChatWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate,
  NSTextViewDelegate, NSWindowDelegate
{
  let store: ClientStore
  private let sidebar: SidebarView
  private let timeline = NSTableView()
  private let timelineScroll = NSScrollView()
  private let composer = Composer()
  private let heading = NSTextField(labelWithString: "T3 Native")
  private let subtitle = NSTextField(labelWithString: "A native Mac client for T3")
  private let status = NSTextField(labelWithString: "")
  private let errorLabel = NSTextField(wrappingLabelWithString: "")
  private let sendButton = NSButton(title: "Send  ⌘↵", target: nil, action: nil)
  private let stopButton = NSButton(title: "Stop", target: nil, action: nil)
  private let olderButton = NSButton(title: "Load earlier activity", target: nil, action: nil)
  private let modelControls: ComposerControls
  private let requestsPanel: RequestsPanel
  private var rows: [ConversationEntry] = []
  private var expandedWork: [String: Set<String>] = [:]
  private var rendered:
    [String: (row: TimelineRow, markdown: RenderedMarkdown, width: CGFloat, height: CGFloat)] = [:]
  private var renderedThread: String?
  private var lastWidth: CGFloat = 0
  private var outputRequests: Set<String> = []
  private struct ScrollAnchor {
    var id: String?
    var offset: CGFloat
    var followsBottom: Bool
  }

  init(store: ClientStore) {
    self.store = store
    sidebar = SidebarView(store: store)
    modelControls = ComposerControls(store: store)
    requestsPanel = RequestsPanel(store: store)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1220, height: 840),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.title = "T3 Native"
    window.titlebarAppearsTransparent = true
    window.minSize = NSSize(width: 900, height: 640)
    window.setFrameAutosaveName("T3NativeMain")
    window.center()
    super.init(window: window)
    window.delegate = self
    construct()
    store.onChange = { [weak self] in self?.refresh() }
    refresh()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private func construct() {
    guard let window else { return }
    let splitController = NSSplitViewController()
    splitController.splitView.isVertical = true
    splitController.splitView.dividerStyle = .thin
    let left = SurfaceView(sidebar: true)
    let right = SurfaceView()
    let sidebarController = NSViewController()
    sidebarController.view = left
    let contentController = NSViewController()
    contentController.view = right
    let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
    sidebarItem.minimumThickness = 220
    sidebarItem.maximumThickness = 360
    sidebarItem.canCollapse = false
    sidebarItem.holdingPriority = .defaultHigh
    let contentItem = NSSplitViewItem(viewController: contentController)
    contentItem.minimumThickness = 480
    splitController.addSplitViewItem(sidebarItem)
    splitController.addSplitViewItem(contentItem)
    window.contentViewController = splitController
    splitController.splitView.setPosition(285, ofDividerAt: 0)

    let brand = NSTextField(labelWithString: "T3 Code")
    brand.font = .systemFont(ofSize: 16, weight: .semibold)
    let newButton = button("New thread", #selector(newThread))
    newButton.toolTip = "Create a thread in the selected thread’s project, using the same model"
    let connectButton = button("Connect…", #selector(connect))
    let retryButton = button("Reconnect", #selector(retry))
    let controls = NSStackView(views: [connectButton, retryButton])
    controls.spacing = 6
    let leftStack = NSStackView(views: [brand, newButton, sidebar, controls])
    leftStack.orientation = .vertical
    leftStack.alignment = .leading
    leftStack.spacing = 12
    left.addSubview(leftStack)
    pin(leftStack, to: left, inset: 14, top: 46)
    for view in [sidebar, controls] {
      view.widthAnchor.constraint(equalTo: leftStack.widthAnchor).isActive = true
    }

    heading.font = .systemFont(ofSize: 14, weight: .semibold)
    heading.lineBreakMode = .byTruncatingTail
    subtitle.font = .systemFont(ofSize: 12)
    subtitle.textColor = .secondaryLabelColor
    status.font = .systemFont(ofSize: 11)
    status.textColor = .secondaryLabelColor
    errorLabel.font = .systemFont(ofSize: 12)
    errorLabel.textColor = .systemOrange
    olderButton.target = self
    olderButton.action = #selector(older)
    _ = configure(timeline, scroll: timelineScroll)
    timeline.setAccessibilityLabel("Conversation")
    timeline.selectionHighlightStyle = .none
    timeline.intercellSpacing = NSSize(width: 0, height: 4)
    timeline.backgroundColor = .clear
    timelineScroll.contentView.postsBoundsChangedNotifications = true
    NotificationCenter.default.addObserver(
      self, selector: #selector(resized), name: NSView.boundsDidChangeNotification,
      object: timelineScroll.contentView)

    let composerScroll = NSScrollView()
    composerScroll.borderType = .noBorder
    composerScroll.drawsBackground = false
    composerScroll.hasVerticalScroller = true
    composerScroll.documentView = composer
    composer.isRichText = false
    composer.drawsBackground = false
    composer.isAutomaticQuoteSubstitutionEnabled = false
    composer.isAutomaticDashSubstitutionEnabled = false
    composer.font = .systemFont(ofSize: 14)
    composer.textContainerInset = NSSize(width: 10, height: 10)
    composer.isVerticallyResizable = true
    composer.isHorizontallyResizable = false
    composer.autoresizingMask = [.width]
    composer.textContainer?.widthTracksTextView = true
    composer.delegate = self
    composer.setAccessibilityLabel("Message")
    composer.submit = { [weak store] in store?.send() }
    composerScroll.heightAnchor.constraint(equalToConstant: 88).isActive = true
    sendButton.target = self
    sendButton.action = #selector(send)
    sendButton.bezelStyle = .inline
    sendButton.image = NSImage(
      systemSymbolName: "arrow.up.circle.fill", accessibilityDescription: "Send message")
    sendButton.imagePosition = .imageOnly
    sendButton.contentTintColor = .controlAccentColor
    sendButton.setAccessibilityLabel("Send message")
    sendButton.widthAnchor.constraint(equalToConstant: 32).isActive = true
    sendButton.heightAnchor.constraint(equalToConstant: 30).isActive = true
    stopButton.target = self
    stopButton.action = #selector(stop)
    let hint = NSTextField(labelWithString: "⌘ Return to send")
    hint.font = .systemFont(ofSize: 11)
    hint.textColor = .secondaryLabelColor
    let spacer = NSView()
    let bottom = NSStackView(views: [modelControls, spacer, stopButton, sendButton])
    bottom.spacing = 6
    let composerStack = NSStackView(views: [composerScroll, bottom])
    composerStack.orientation = .vertical
    composerStack.alignment = .leading
    composerStack.spacing = 8
    let composerSurface = SurfaceView(raised: true)
    composerSurface.layer?.cornerRadius = 16
    composerSurface.addSubview(composerStack)
    pin(composerStack, to: composerSurface, inset: 10, top: 4)
    composerScroll.widthAnchor.constraint(equalTo: composerStack.widthAnchor).isActive = true
    bottom.widthAnchor.constraint(equalTo: composerStack.widthAnchor).isActive = true
    let header = NSStackView(views: [
      subtitle, NSTextField(labelWithString: "/"), heading, NSView(),
    ])
    header.spacing = 10
    right.addSubview(header)
    header.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      header.leadingAnchor.constraint(equalTo: right.leadingAnchor, constant: 24),
      header.trailingAnchor.constraint(equalTo: right.trailingAnchor, constant: -24),
      header.topAnchor.constraint(equalTo: right.topAnchor, constant: 46),
    ])
    let footer = NSStackView(views: [status, NSView(), hint])
    let stack = NSStackView(views: [
      olderButton, timelineScroll, errorLabel, requestsPanel, composerSurface, footer,
    ])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 9
    right.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    let preferredWidth = stack.widthAnchor.constraint(equalTo: right.widthAnchor, constant: -48)
    preferredWidth.priority = .defaultHigh
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: right.centerXAnchor),
      stack.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 16),
      stack.bottomAnchor.constraint(equalTo: right.bottomAnchor, constant: -16),
      stack.widthAnchor.constraint(lessThanOrEqualToConstant: 820),
      stack.widthAnchor.constraint(lessThanOrEqualTo: right.widthAnchor, constant: -32),
      preferredWidth,
    ])
    for view in [timelineScroll, errorLabel, requestsPanel, composerSurface, footer] {
      view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    timelineScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
    heading.setContentCompressionResistancePriority(.required, for: .vertical)
    composerSurface.setContentCompressionResistancePriority(.required, for: .vertical)
    window.setContentSize(NSSize(width: 1220, height: 840))
    splitController.splitView.setPosition(285, ofDividerAt: 0)
  }

  private func button(_ title: String, _ action: Selector) -> NSButton {
    let button = NSButton(title: title, target: self, action: action)
    button.bezelStyle = .rounded
    return button
  }

  private func pin(_ child: NSView, to parent: NSView, inset: CGFloat, top: CGFloat) {
    child.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
      child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
      child.topAnchor.constraint(equalTo: parent.topAnchor, constant: top),
      child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset),
    ])
  }

  private func configure(_ table: NSTableView, scroll: NSScrollView = NSScrollView())
    -> NSScrollView
  {
    table.headerView = nil
    table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("content")))
    table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
    table.dataSource = self
    table.delegate = self
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.drawsBackground = false
    return scroll
  }

  func refresh() {
    let anchor = scrollAnchor()
    sidebar.refresh()
    let selected = store.selectedThread
    heading.stringValue = selected?.title ?? "T3 Native"
    subtitle.stringValue =
      selected.map {
        store.shell.projects[$0.projectID] ?? store.archives.projects[$0.projectID] ?? "Project"
      } ?? "Connect to an existing T3 server to get started"
    status.stringValue = store.status
    errorLabel.stringValue = store.error ?? store.storageError ?? ""
    errorLabel.isHidden = store.error == nil && store.storageError == nil
    olderButton.isHidden = store.thread?.hasMore != true
    olderButton.isEnabled = store.ready && !store.loadingHistory
    olderButton.title = store.loadingHistory ? "Loading earlier activity…" : "Load earlier activity"
    let draft = store.selectedID.flatMap { store.drafts[$0] } ?? ""
    if composer.string != draft { composer.string = draft }
    updateComposerControls()
    composer.isEditable = selected?.archived != true
    if window?.isKeyWindow == true { store.markVisibleThreadRead() }
    modelControls.refresh()
    requestsPanel.refresh()
    stopButton.isHidden = selected?.activeRunID == nil
    stopButton.isEnabled = store.ready
    window?.contentView?.layoutSubtreeIfNeeded()
    updateRows(conversationEntries(), anchor: anchor)
    let requests = Set(store.commandsInFlight.filter { $0.hasSuffix(":output") })
    if requests != outputRequests {
      outputRequests = requests
      timeline.reloadData(
        forRowIndexes: IndexSet(
          rows.indices.filter { rows[$0].item?.item["outputOmitted"].bool == true }),
        columnIndexes: IndexSet(integer: 0))
    }
  }

  private func conversationEntries() -> [ConversationEntry] {
    ConversationTimeline.entries(
      from: store.thread?.rows ?? [], activeRunID: store.selectedThread?.activeRunID,
      expandedItemIDs: expandedWork[store.selectedID ?? ""] ?? [])
  }

  private func toggleWork(_ group: TimelineWorkGroup) {
    guard let id = store.selectedID else { return }
    if group.expanded {
      expandedWork[id, default: []].subtract(group.entries.map(\.id))
    } else {
      expandedWork[id, default: []].formUnion(group.entries.map(\.id))
    }
    updateRows(conversationEntries(), followsBottom: false)
  }

  private func updateRows(
    _ next: [ConversationEntry], anchor savedAnchor: ScrollAnchor? = nil,
    followsBottom: Bool? = nil
  ) {
    let changedThread = renderedThread != store.selectedID
    guard changedThread || next != rows else {
      if let savedAnchor { restoreScroll(savedAnchor) }
      return
    }
    var anchor = savedAnchor ?? scrollAnchor()
    if let followsBottom { anchor.followsBottom = followsBottom }
    if changedThread { anchor.followsBottom = true }
    let oldCount = rows.count
    let samePrefix = next.count >= rows.count && zip(rows, next).allSatisfy { $0.id == $1.id }
    let changes = IndexSet(next.indices.filter { $0 < oldCount && next[$0] != rows[$0] })
    rows = next
    if let id = anchor.id, !next.contains(where: { $0.id == id }) {
      // Collapsing a group keeps an output row's position at its disclosure header.
      if let group = next.first(where: {
        if case .work(let group) = $0 { return group.entries.contains { $0.id == id } }
        return false
      }) {
        anchor.id = group.id
        anchor.offset = 0
      }
    }
    renderedThread = store.selectedID
    if changedThread || !samePrefix {
      rendered.removeAll(keepingCapacity: true)
      timeline.reloadData()
    } else {
      for index in changes { rendered.removeValue(forKey: rows[index].id) }
      if rows.count > oldCount {
        timeline.insertRows(at: IndexSet(oldCount..<rows.count), withAnimation: [])
      }
      timeline.noteHeightOfRows(withIndexesChanged: changes)
      timeline.reloadData(forRowIndexes: changes, columnIndexes: IndexSet(integer: 0))
    }
    restoreScroll(anchor)
  }

  private func scrollAnchor() -> ScrollAnchor {
    let visible = timeline.visibleRect
    let index = timeline.row(at: NSPoint(x: visible.minX + 1, y: visible.minY + 1))
    return ScrollAnchor(
      id: rows.indices.contains(index) ? rows[index].id : nil,
      offset: rows.indices.contains(index) ? visible.minY - timeline.rect(ofRow: index).minY : 0,
      followsBottom: visible.maxY >= timeline.bounds.maxY - 70)
  }

  private func restoreScroll(_ anchor: ScrollAnchor) {
    timeline.layoutSubtreeIfNeeded()
    let limit = max(0, timeline.bounds.height - timelineScroll.contentView.bounds.height)
    let target: CGFloat
    if anchor.followsBottom {
      target = limit
    } else if let id = anchor.id, let index = rows.firstIndex(where: { $0.id == id }) {
      target = timeline.rect(ofRow: index).minY + anchor.offset
    } else {
      return
    }
    timelineScroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, min(target, limit))))
    timelineScroll.reflectScrolledClipView(timelineScroll.contentView)
  }

  @objc private func resized() {
    let width = timelineScroll.contentSize.width
    guard abs(width - lastWidth) > 1 else { return }
    let anchor = scrollAnchor()
    lastWidth = width
    rendered.removeAll(keepingCapacity: true)
    timeline.noteHeightOfRows(withIndexesChanged: IndexSet(rows.indices))
    timeline.reloadData(forRowIndexes: IndexSet(rows.indices), columnIndexes: IndexSet(integer: 0))
    restoreScroll(anchor)
  }

  private func render(_ row: TimelineRow) -> (RenderedMarkdown, CGFloat) {
    let width = max(120, timeline.bounds.width - 36)
    if let cached = rendered[row.id], cached.row == row, cached.width == width {
      return (cached.markdown, cached.height)
    }
    let markdown: RenderedMarkdown
    if ["user_message", "assistant_message", "reasoning", "proposed_plan"].contains(row.kind) {
      markdown = MarkdownRenderer.render(row.text, width: width)
    } else {
      let font =
        ["command_execution", "dynamic_tool", "file_change"].contains(row.kind)
        ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) : NSFont.systemFont(ofSize: 14)
      markdown = RenderedMarkdown(
        text: NSAttributedString(
          string: row.text,
          attributes: [.font: font, .foregroundColor: NSColor.labelColor]), codeBlocks: [])
    }
    let height = max(65, MarkdownRenderer.height(of: markdown.text, width: width) + 45)
    rendered[row.id] = (row, markdown, width, height)
    return (markdown, height)
  }

  func numberOfRows(in tableView: NSTableView) -> Int {
    rows.count
  }

  func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
    switch rows[row] {
    case .item(let item): render(item).1
    case .work: 36
    }
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int)
    -> NSView?
  {
    if case .work(let group) = rows[index] { return workCell(group) }
    guard case .item(let row) = rows[index] else { return nil }
    let cell = NSView()
    let title = NSTextField(labelWithString: "")
    title.font = .systemFont(ofSize: 11, weight: .semibold)
    title.textColor = .secondaryLabelColor
    title.stringValue =
      row.title + (row.inherited ? " · inherited" : "")
      + (row.failed ? " · failed" : row.streaming ? " · streaming" : "")
    title.textColor =
      row.failed
      ? .systemRed : row.kind == "user_message" ? .controlAccentColor : .secondaryLabelColor
    let (markdown, height) = render(row)
    let body = MessageTextView(
      rendered: markdown, width: max(120, timeline.bounds.width - 36), height: height - 45)
    let copy = ActionButton("") {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(row.text, forType: .string)
    }
    copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy message")
    copy.imagePosition = .imageOnly
    copy.bezelStyle = .inline
    copy.toolTip = "Copy message"
    copy.setAccessibilityLabel("Copy message")
    let header = NSStackView(views: [title, NSView(), copy])
    if row.item["outputOmitted"].bool {
      let busy = store.commandsInFlight.contains(row.id + ":output")
      let output = ActionButton(busy ? "Loading output…" : "Load full output") { [weak store] in
        store?.loadOutput(row)
      }
      output.isEnabled = store.ready && !busy
      output.controlSize = .small
      header.insertArrangedSubview(output, at: 2)
    }
    let stack = NSStackView(views: [header, body])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 6
    cell.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
      stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12),
      stack.topAnchor.constraint(equalTo: cell.topAnchor, constant: 8),
      body.widthAnchor.constraint(equalTo: stack.widthAnchor),
      body.heightAnchor.constraint(equalToConstant: max(20, height - 45)),
      header.widthAnchor.constraint(equalTo: stack.widthAnchor),
    ])
    return cell
  }

  private func workCell(_ group: TimelineWorkGroup) -> NSView {
    let cell = NSView()
    let button = ActionButton(group.summary) { [weak self] in self?.toggleWork(group) }
    button.isBordered = false
    button.alignment = .left
    button.font = .systemFont(ofSize: 12)
    button.contentTintColor = group.active ? .labelColor : .secondaryLabelColor
    button.image = NSImage(
      systemSymbolName: group.expanded ? "chevron.down" : "chevron.right",
      accessibilityDescription: nil)
    button.imagePosition = .imageLeading
    button.cell?.lineBreakMode = .byTruncatingTail
    button.toolTip = group.summary
    button.setAccessibilityLabel(
      (group.expanded ? "Collapse work: " : "Expand work: ") + group.summary)
    cell.addSubview(button)
    button.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      button.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
      button.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12),
      button.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      button.heightAnchor.constraint(equalToConstant: 28),
    ])
    return cell
  }

  func windowDidBecomeKey(_ notification: Notification) { store.markVisibleThreadRead() }
  func textDidChange(_ notification: Notification) {
    if let id = store.selectedID { store.drafts[id] = composer.string }
    updateComposerControls()
  }
  private func updateComposerControls() {
    let sending = store.sending.contains(store.selectedID ?? "")
    sendButton.isEnabled =
      store.canEditThread
      && !composer.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !sending
    sendButton.title = ""
    sendButton.toolTip = sending ? "Sending…" : "Send message (⌘ Return)"
    sendButton.setAccessibilityLabel(sending ? "Sending message" : "Send message")
  }
  @objc private func send() { store.send() }
  @objc private func stop() { store.stop() }
  @objc private func older() { store.loadOlder() }
  @objc private func newThread() { store.newThread() }
  @objc private func retry() { store.retry() }

  @objc func connect() {
    let alert = NSAlert()
    alert.messageText = "Connect to T3"
    alert.informativeText =
      "Use the server address and a pairing token from T3’s Connections settings. Access tokens are stored in your Mac’s Keychain."
    let endpoint = NSTextField(
      string: UserDefaults.standard.string(forKey: "endpoint") ?? "http://127.0.0.1:3773")
    let token = NSSecureTextField()
    token.placeholderString = "Pairing token"
    let pairing = NSButton(checkboxWithTitle: "Exchange a pairing token", target: nil, action: nil)
    pairing.state = .on
    let stack = NSStackView(views: [endpoint, token, pairing])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    stack.frame = NSRect(x: 0, y: 0, width: 430, height: 100)
    endpoint.widthAnchor.constraint(equalToConstant: 430).isActive = true
    token.widthAnchor.constraint(equalToConstant: 430).isActive = true
    alert.accessoryView = stack
    alert.addButton(withTitle: "Connect")
    alert.addButton(withTitle: "Cancel")
    guard let window else { return }
    alert.beginSheetModal(for: window) { [weak self] result in
      guard result == .alertFirstButtonReturn, let self else { return }
      let address = endpoint.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      let credential = token.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      Task { @MainActor in
        do {
          guard let url = URL(string: address) else { throw T3Error("Invalid server address.") }
          let settings =
            pairing.state == .on
            ? try await EnvironmentHTTP.pair(endpoint: url, credential: credential)
            : try ConnectionSettings(endpoint: url, token: credential)
          try Credentials.save(settings)
          store.connect(settings)
        } catch {
          store.error = error.localizedDescription
          refresh()
        }
      }
    }
  }
}
