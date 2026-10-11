import AppKit
import T3Core

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
  NSTextViewDelegate, NSSearchFieldDelegate
{
  let store: ClientStore
  private let sidebar = NSTableView()
  private let timeline = NSTableView()
  private let timelineScroll = NSScrollView()
  private let search = NSSearchField()
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
  private var threads: [ThreadSummary] = []
  private var rows: [TimelineRow] = []
  private var rendered:
    [String: (row: TimelineRow, text: NSAttributedString, width: CGFloat, height: CGFloat)] = [:]
  private var renderedThread: String?
  private var lastWidth: CGFloat = 0
  private var restoringSelection = false

  init(store: ClientStore) {
    self.store = store
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
    search.placeholderString = "Search threads"
    search.stringValue = Arguments.value("--filter") ?? ""
    search.delegate = self
    let sideScroll = configure(sidebar)
    sidebar.rowHeight = 61
    sidebar.style = .sourceList
    sidebar.setAccessibilityLabel("Threads")
    let connectButton = button("Connect…", #selector(connect))
    let retryButton = button("Reconnect", #selector(retry))
    let controls = NSStackView(views: [connectButton, retryButton])
    controls.spacing = 6
    let leftStack = NSStackView(views: [brand, newButton, search, sideScroll, controls])
    leftStack.orientation = .vertical
    leftStack.alignment = .leading
    leftStack.spacing = 12
    left.addSubview(leftStack)
    pin(leftStack, to: left, inset: 14, top: 46)
    for view in [search, sideScroll, controls] {
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
    let query = search.stringValue
    let nextThreads = store.sortedThreads.filter {
      query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
    }
    if nextThreads != threads {
      threads = nextThreads
      restoringSelection = true
      sidebar.reloadData()
      if let index = threads.firstIndex(where: { $0.id == store.selectedID }) {
        sidebar.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
      }
      restoringSelection = false
    }
    let selected = store.selectedID.flatMap { store.shell.threads[$0] }
    heading.stringValue = selected?.title ?? "T3 Native"
    subtitle.stringValue =
      selected.map {
        store.shell.projects[$0.projectID] ?? "Project"
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
    modelControls.refresh()
    requestsPanel.refresh()
    stopButton.isHidden = selected?.activeRunID == nil
    stopButton.isEnabled = store.ready
    updateRows(
      (store.thread?.rows ?? []).filter {
        $0.kind != "checkpoint" || !$0.item["files"].array.isEmpty
      })
  }

  private func updateRows(_ next: [TimelineRow]) {
    let changedThread = renderedThread != store.selectedID
    guard changedThread || next != rows else { return }
    let wasAtBottom = timeline.visibleRect.maxY >= timeline.bounds.maxY - 70
    let oldCount = rows.count
    let samePrefix = next.count >= rows.count && zip(rows, next).allSatisfy { $0.id == $1.id }
    let changes = IndexSet(next.indices.filter { $0 < oldCount && next[$0] != rows[$0] })
    let oldTop = timeline.row(at: timeline.visibleRect.origin)
    let anchor = rows.indices.contains(oldTop) ? rows[oldTop].id : nil
    rows = next
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
    if (changedThread || wasAtBottom) && !rows.isEmpty {
      timeline.scrollRowToVisible(rows.count - 1)
    } else if !samePrefix, let anchor, let index = rows.firstIndex(where: { $0.id == anchor }) {
      timeline.scrollRowToVisible(index)
    }
  }

  @objc private func resized() {
    let width = timelineScroll.contentSize.width
    guard abs(width - lastWidth) > 1 else { return }
    lastWidth = width
    rendered.removeAll(keepingCapacity: true)
    timeline.noteHeightOfRows(withIndexesChanged: IndexSet(rows.indices))
  }

  private func render(_ row: TimelineRow) -> (NSAttributedString, CGFloat) {
    let width = max(120, timeline.bounds.width - 36)
    if let cached = rendered[row.id], cached.row == row, cached.width == width {
      return (cached.text, cached.height)
    }
    let font =
      row.kind == "command_execution"
      ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) : NSFont.systemFont(ofSize: 14)
    let text = NSMutableAttributedString(
      string: row.text, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
    if ["user_message", "assistant_message", "reasoning", "proposed_plan"].contains(row.kind),
      let markdown = try? AttributedString(
        markdown: row.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
    {
      let rich = NSMutableAttributedString(string: "")
      for run in markdown.runs {
        var runFont = font
        if run.inlinePresentationIntent?.contains(.code) == true {
          runFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
        }
        if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
          runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .boldFontMask)
        }
        if run.inlinePresentationIntent?.contains(.emphasized) == true {
          runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .italicFontMask)
        }
        var attributes: [NSAttributedString.Key: Any] = [
          .font: runFont, .foregroundColor: NSColor.labelColor,
        ]
        if let link = run.link { attributes[.link] = link }
        rich.append(
          NSAttributedString(string: String(markdown[run.range].characters), attributes: attributes)
        )
      }
      text.setAttributedString(rich)
    }
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = 4
    text.addAttribute(
      .paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
    let height =
      ceil(
        text.boundingRect(
          with: NSSize(width: width, height: .greatestFiniteMagnitude),
          options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height) + 49
    rendered[row.id] = (row, text, width, max(65, height))
    return (text, max(65, height))
  }

  func numberOfRows(in tableView: NSTableView) -> Int {
    tableView === sidebar ? threads.count : rows.count
  }

  func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
    tableView === sidebar ? 61 : render(rows[row]).1
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int)
    -> NSView?
  {
    let cell = NSView()
    let title = NSTextField(labelWithString: "")
    let body = NSTextField(wrappingLabelWithString: "")
    title.font = .systemFont(ofSize: 11, weight: .semibold)
    title.textColor = .secondaryLabelColor
    body.font = .systemFont(ofSize: 13)
    if tableView === sidebar {
      let thread = threads[index]
      title.stringValue = store.shell.projects[thread.projectID] ?? "Project"
      body.stringValue = (thread.activeRunID == nil ? "" : "● ") + thread.title
      body.maximumNumberOfLines = 2
      body.lineBreakMode = .byTruncatingTail
    } else {
      let row = rows[index]
      title.stringValue =
        row.title + (row.inherited ? " · inherited" : "") + (row.streaming ? " · streaming" : "")
      title.textColor = row.kind == "user_message" ? .controlAccentColor : .secondaryLabelColor
      body.attributedStringValue = render(row).0
      body.isSelectable = true
      body.allowsEditingTextAttributes = true
      body.maximumNumberOfLines = 0
      body.preferredMaxLayoutWidth = max(120, timeline.bounds.width - 36)
    }
    let stack = NSStackView(views: [title, body])
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
    ])
    return cell
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    guard notification.object as? NSTableView === sidebar, !restoringSelection,
      threads.indices.contains(sidebar.selectedRow)
    else { return }
    store.select(threads[sidebar.selectedRow].id)
  }
  func controlTextDidChange(_ obj: Notification) { refresh() }
  func textDidChange(_ notification: Notification) {
    if let id = store.selectedID { store.drafts[id] = composer.string }
    updateComposerControls()
  }
  private func updateComposerControls() {
    let sending = store.sending.contains(store.selectedID ?? "")
    sendButton.isEnabled =
      store.ready && store.thread?.synchronized == true
      && !composer.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !sending
    sendButton.title = sending ? "Sending…" : "Send  ⌘↵"
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
