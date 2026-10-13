import AppKit
import Combine
import T3Core
import T3Markdown
import UniformTypeIdentifiers

@MainActor private final class ConversationWindow: NSWindow {
  var questionShortcut: ((NSEvent) -> Bool)?
  override func keyDown(with event: NSEvent) {
    if questionShortcut?(event) != true { super.keyDown(with: event) }
  }
}

@MainActor final class Composer: NSTextView {
  var submit: (() -> Void)?
  var editLatestQueued: (() -> Bool)?
  var attach: (([URL], Bool) -> Void)?
  var allowsAttachments = false
  var handleCompletionKey: ((NSEvent) -> Bool)?
  var placeholder = "Ask anything, @tag files/folders, $use skills, or / for commands" {
    didSet { needsDisplay = true }
  }
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    if string.isEmpty {
      (placeholder as NSString).draw(
        in: NSRect(
          x: textContainerInset.width + 5, y: textContainerInset.height, width: bounds.width - 30,
          height: 42),
        withAttributes: [
          .font: font ?? NSFont.systemFont(ofSize: 14),
          .foregroundColor: NSColor.placeholderTextColor,
        ])
    }
  }
  override func paste(_ sender: Any?) {
    if !receiveAttachments(from: .general, preferText: true) { super.paste(sender) }
  }
  private func receiveAttachments(from pasteboard: NSPasteboard, preferText: Bool) -> Bool {
    guard allowsAttachments else { return false }
    if let urls = pasteboard.readObjects(
      forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty
    {
      if preferText, !(pasteboard.string(forType: .string) ?? "").isEmpty,
        !urls.contains(where: {
          ["png", "jpg", "jpeg", "webp", "gif", "heic", "heif", "tiff", "tif"].contains(
            $0.pathExtension.lowercased())
        })
      {
        return false
      }
      attach?(urls, false)
      return true
    }
    if let image = NSImage(pasteboard: pasteboard), let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:])
    {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "t3-paste-" + UUID().uuidString)
      do {
        try FileManager.default.createDirectory(
          at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("Pasted image.png")
        try png.write(to: file, options: .atomic)
        attach?([file], true)
        return true
      } catch { NSSound.beep() }
    }
    return false
  }
  override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
    if allowsAttachments
      && sender.draggingPasteboard.availableType(from: [.fileURL, .png, .tiff]) != nil
    {
      return .copy
    }
    return super.draggingEntered(sender)
  }
  override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
    receiveAttachments(from: sender.draggingPasteboard, preferText: false)
      || super.performDragOperation(sender)
  }
  override func keyDown(with event: NSEvent) {
    if handleCompletionKey?(event) == true { return }
    if event.keyCode == 126 && event.modifierFlags.contains(.option), selectedRange().location == 0,
      editLatestQueued?() == true
    {
      return
    }
    if event.keyCode == 36 && event.modifierFlags.contains(.command)
      && !event.modifierFlags.contains(.shift)
    {
      submit?()
    } else {
      super.keyDown(with: event)
    }
  }
}

@MainActor
final class ChatWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate,
  NSTextViewDelegate, NSWindowDelegate, NSMenuItemValidation
{
  let store: ClientStore
  private let workspace: WorkspacePanel
  private var workspaceItem: NSSplitViewItem?
  private let review: ReviewPanel
  private var reviewItem: NSSplitViewItem?
  private let sidebar: SidebarView
  private var projectPicker: ProjectPicker?
  private var projectSelection: NSPopover?
  private var projectSelectionContext: (session: UUID, draftID: String)?
  private var settingsWindow: NativeSettingsWindow?
  private var reconnecting = false
  private var connectionAttempt = UUID()
  private let preferences = NativePreferences.shared
  private var appearanceObservation: AnyCancellable?
  private var appearanceValues = NativeAppearanceValues()
  private var maximumChatWidth: NSLayoutConstraint?
  private let notifications: NativeNotificationPresenter
  private let usage: UsagePageController
  private let browser: BrowserPanel
  private var browserItem: NSSplitViewItem?
  private var centerItem: NSSplitViewItem?
  private var pageContainer: NSView?
  private var conversationView: NSView?
  private var showingUsage = false
  private var usageThreadID: String?
  private let timeline = NSTableView()
  private let timelineScroll = NSScrollView()
  private let composer = Composer()
  private let completion: ComposerCompletion
  private let contextBanner: NativeContextBanner
  private let header = NSStackView()
  private let conversationStack = NSStackView()
  private let welcome = ConnectionWelcomeView()
  private let newChatHeading = NSStackView()
  private let newChatProject = ComposerPill("Choose project", height: 36, action: {})
  private let withoutProject = ActionButton("or start without a project", action: {})
  private let workspaceControls: DraftWorkspaceControls
  private var conversationTop: NSLayoutConstraint?
  private var conversationBottom: NSLayoutConstraint?
  private var conversationCenter: NSLayoutConstraint?
  private let composerSurface = SurfaceView(raised: true)
  private let heading = NSTextField(labelWithString: "T3 Native")
  private let subtitle = NSTextField(labelWithString: "A native Mac client for T3")
  private let status = NSTextField(labelWithString: "")
  private let errorLabel = NSTextField(wrappingLabelWithString: "")
  private let sendButton = RoundSendButton(title: "Send  ⌘↵", target: nil, action: nil)
  private let planBanner = NSTextField(wrappingLabelWithString: "")
  private let stopButton = NSButton(title: "Stop", target: nil, action: nil)
  private let olderButton = NSButton(title: "Load earlier activity", target: nil, action: nil)
  private let modelControls: ComposerControls
  private let requestsPanel: RequestsPanel
  private let attachmentTray: AttachmentTray
  private let attachmentPreviews = AttachmentPreviews()
  private let queuePanel: QueuePanel
  private let deliveryButton = NSPopUpButton(frame: .zero, pullsDown: true)
  private var deliveryState = ""
  private var renderedDraftID: String?
  private var attachmentConnectionState = ""
  private let attachButton = NSButton(title: "Attach files…", target: nil, action: nil)
  private var sidebarItem: NSSplitViewItem?
  private var sidebarObservation: NSKeyValueObservation?
  private lazy var restoreSidebar = sidebarIcon("Show sidebar (⌘B)", "sidebar.left") {
    [weak self] in self?.toggleSidebar()
  }
  private var didSetSidebarWidth = false
  private let terminal: TerminalPanel
  private var terminalItem: NSSplitViewItem?
  private var rows: [ConversationEntry] = []
  private var expandedWork: [String: Set<String>] = [:]
  private var expandedPlans: [String: Set<String>] = [:]
  private var planLayouts:
    [String: (row: TimelineRow, width: CGFloat, expanded: Bool, layout: PlanCardLayout)] = [:]
  private var planWorkspace: WorkspaceLocation?
  private var planWorkspaceReady = false
  private var planSavePaths: [String: String] = [:]
  private var planSaveSheet: WorkspaceSaveSheet?
  private var notice: String?
  private var noticeReset: Task<Void, Never>?
  private var rendered:
    [String: (row: TimelineRow, markdown: RenderedMarkdown, width: CGFloat, height: CGFloat)] = [:]
  private var renderedThread: String?
  private var renderedWorkspace: WorkspaceLocation?
  private var lastWidth: CGFloat = 0
  private var liveResizing = false
  private var resizeAnchor: ScrollAnchor?
  private var resizeWork: DispatchWorkItem?
  private var applyingResize = false
  private var outputRequests: Set<String> = []
  private struct ScrollAnchor {
    var id: String?
    var offset: CGFloat
    var followsBottom: Bool
  }

  init(store: ClientStore) {
    self.store = store
    notifications = NativeNotificationPresenter(store: store)
    terminal = TerminalPanel(store: store)
    workspace = WorkspacePanel(store: store)
    review = ReviewPanel(store: store)
    sidebar = SidebarView(store: store)
    usage = UsagePageController(store: store)
    browser = BrowserPanel(store: store)
    modelControls = ComposerControls(store: store)
    completion = ComposerCompletion(store: store)
    contextBanner = NativeContextBanner(store: store)
    workspaceControls = DraftWorkspaceControls(store: store)
    requestsPanel = RequestsPanel(store: store)
    attachmentTray = AttachmentTray(store: store, previews: attachmentPreviews)
    queuePanel = QueuePanel(store: store, previews: attachmentPreviews)
    let window = ConversationWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1220, height: 840),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.title = "T3 Native"
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.minSize = NSSize(width: 900, height: 640)
    window.setFrameAutosaveName("T3NativeMain")
    window.center()
    super.init(window: window)
    window.delegate = self
    construct()
    contextBanner.onCompact = { [weak store] in store?.compactContext() }
    installCommands()
    store.onChange = { [weak self] in self?.refresh() }
    store.onShellEvent = { [weak self] event, connection, endpoint in
      self?.notifications.receive(event, connection: connection, endpoint: endpoint)
    }
    notifications.activate()
    notifications.onOpenThread = { [weak self] endpoint, id in
      guard let self else { return }
      let attempt = UUID()
      connectionAttempt = attempt
      let session = store.usageSessionID
      Task { @MainActor [weak self] in
        guard let self else { return }
        let validate: @MainActor () throws -> Void = {
          try Task.checkCancellation()
          guard self.connectionAttempt == attempt, self.store.usageSessionID == session else {
            throw CancellationError()
          }
        }
        do {
          if store.browserEndpoint != endpoint {
            let repository = try await ConnectionRepository(validating: validate)
            try validate()
            guard
              let environment = repository.values.environments.first(where: {
                $0.endpoint == endpoint
              })
            else { return }
            let settings = try await repository.settings(for: environment)
            try validate()
            try repository.select(environment)
            store.connect(settings, selecting: id)
          } else {
            try validate()
            store.select(id)
          }
          showWindow(nil)
          NSApp.activate(ignoringOtherApps: true)
        } catch {
          guard connectionAttempt == attempt, store.usageSessionID == session,
            !(error is CancellationError)
          else { return }
          store.error = error.localizedDescription
          refresh()
        }
      }
    }
    appearanceObservation = preferences.observeChanges { [weak self] _ in
      guard let self, appearanceValues != preferences.appearance else { return }
      applyAppearance()
    }
    applyAppearance()
    refresh()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private var markdownConfiguration: MarkdownConfiguration {
    var config = MarkdownConfiguration.message
    config.fontSize = CGFloat(appearanceValues.interfaceFontSize)
    config.codeFontSize = CGFloat(appearanceValues.codeFontSize)
    config.fontName = appearanceValues.interfaceFont
    config.codeFontName = appearanceValues.codeFont
    config.wrapCode = appearanceValues.wordWrap
    config.wrapTables = appearanceValues.wordWrap
    return config
  }

  private func applyAppearance() {
    let anchor = scrollAnchor()
    appearanceValues = preferences.appearance
    window?.appearance = appearanceValues.appearance.appKitAppearance
    composer.font = appearanceValues.resolvedInterfaceFont
    maximumChatWidth?.constant = appearanceValues.chatWidth.maximumWidth ?? 100_000
    rendered.removeAll(keepingCapacity: true)
    planLayouts.removeAll(keepingCapacity: true)
    window?.contentView?.layoutSubtreeIfNeeded()
    lastWidth = timelineScroll.contentSize.width
    timeline.noteHeightOfRows(withIndexesChanged: IndexSet(rows.indices))
    timeline.reloadData()
    restoreScroll(anchor)
  }

  @objc private func showSettings() {
    completion.dismiss()
    if settingsWindow == nil { settingsWindow = NativeSettingsWindow(store: store) }
    settingsWindow?.showWindow(nil)
    settingsWindow?.window?.makeKeyAndOrderFront(nil)
  }

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
    sidebarItem.minimumThickness = 256
    sidebarItem.maximumThickness = 360
    sidebarItem.preferredThicknessFraction = 256.0 / 1220
    sidebarItem.automaticMaximumThickness = 256
    sidebarItem.canCollapse = true
    self.sidebarItem = sidebarItem
    sidebarObservation = sidebarItem.observe(\.isCollapsed, options: [.initial, .new]) {
      [weak self] _, _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.restoreSidebar.isHidden = self.sidebarItem?.isCollapsed != true
      }
    }
    sidebarItem.holdingPriority = .defaultHigh
    let conversationSplit = NSSplitViewController()
    conversationSplit.splitView.isVertical = false
    conversationSplit.splitView.dividerStyle = .thin
    let conversationItem = NSSplitViewItem(viewController: contentController)
    conversationItem.minimumThickness = 480
    conversationSplit.addSplitViewItem(conversationItem)
    let terminalItem = NSSplitViewItem(viewController: terminal)
    terminalItem.minimumThickness = 180
    terminalItem.canCollapse = true
    terminalItem.isCollapsed = true
    self.terminalItem = terminalItem
    conversationSplit.addSplitViewItem(terminalItem)
    terminal.onClose = { [weak self] in
      self?.terminalItem?.isCollapsed = true
      self?.terminal.refresh(active: false)
      self?.window?.makeFirstResponder(self?.composer)
    }
    terminal.onOpenLink = { [weak self] url, location in self?.openMarkdownLink(url, at: location) }
    let pages = NSViewController()
    pages.view = NSView()
    pages.addChild(conversationSplit)
    pages.addChild(usage)
    pageContainer = pages.view
    pages.view.addSubview(conversationSplit.view)
    pin(conversationSplit.view, to: pages.view, inset: 0, top: 0)
    conversationView = conversationSplit.view
    usage.model.onClose = { [weak self] in self?.showConversation() }
    sidebar.onShowUsage = { [weak self] in self?.showUsage() }
    sidebar.onThreadChosen = { [weak self] in self?.showConversation() }
    sidebar.onNewThread = { [weak self] in self?.newThread() }
    sidebar.onOpenProject = { [weak self] in self?.openProject() }
    sidebar.onToggleSidebar = { [weak self] in self?.toggleSidebar() }
    sidebar.onConnect = { [weak self] in self?.connect() }
    sidebar.onReconnect = { [weak self] in self?.retry() }
    sidebar.onSettings = { [weak self] in self?.showSettings() }
    sidebar.onBrowserSettings = { [weak self] in self?.browserSettings() }
    sidebar.onBack = { [weak self] in self?.showConversation() }
    let contentItem = NSSplitViewItem(viewController: pages)
    contentItem.minimumThickness = 480
    contentItem.canCollapse = true
    centerItem = contentItem
    splitController.addSplitViewItem(sidebarItem)
    splitController.addSplitViewItem(contentItem)
    let workspaceItem = NSSplitViewItem(viewController: workspace)
    workspaceItem.minimumThickness = 420
    workspaceItem.holdingPriority = .defaultHigh
    workspaceItem.canCollapse = true
    workspaceItem.isCollapsed = true
    self.workspaceItem = workspaceItem
    workspace.onClose = { [weak self] in
      self?.workspace.closeEditor()
      self?.workspaceItem?.isCollapsed = true
    }
    splitController.addSplitViewItem(workspaceItem)
    let reviewItem = NSSplitViewItem(viewController: review)
    reviewItem.minimumThickness = 440
    reviewItem.holdingPriority = .defaultHigh
    reviewItem.canCollapse = true
    reviewItem.isCollapsed = true
    self.reviewItem = reviewItem
    review.onClose = { [weak self] in
      self?.reviewItem?.isCollapsed = true
      self?.review.refreshContext(active: false)
      self?.window?.makeFirstResponder(self?.composer)
    }
    review.onOpenFile = { [weak self] url, location in self?.openMarkdownLink(url, at: location) }
    splitController.addSplitViewItem(reviewItem)
    let browserItem = NSSplitViewItem(viewController: browser)
    browserItem.minimumThickness = 420
    browserItem.canCollapse = true
    browserItem.isCollapsed = true
    self.browserItem = browserItem
    browser.onAgentReveal = { [weak self] in
      guard let self, browserItem.isCollapsed, !showingUsage else { return }
      let responder = window.firstResponder
      toggleBrowser()
      window.makeFirstResponder(responder)
    }
    browser.onContextAdded = { [weak self] in
      self?.centerItem?.isCollapsed = false
      self?.window?.makeFirstResponder(self?.composer)
    }
    browser.onClose = { [weak self] in self?.hideBrowser() }
    browser.onExpand = { [weak self] in
      guard let item = self?.centerItem else { return }
      item.isCollapsed.toggle()
    }
    splitController.addSplitViewItem(browserItem)
    window.contentViewController = splitController
    splitController.splitView.setPosition(256, ofDividerAt: 0)

    left.addSubview(sidebar)
    pin(sidebar, to: left, inset: 8, top: 8)

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
    // Message widths already include their gutters; inset table rows would clip the text.
    timeline.style = .plain
    timeline.setAccessibilityLabel("Conversation")
    timeline.selectionHighlightStyle = .none
    timeline.intercellSpacing = NSSize(width: 0, height: 4)
    timeline.backgroundColor = .clear
    timelineScroll.contentView.postsBoundsChangedNotifications = true
    timelineScroll.contentView.postsFrameChangedNotifications = true
    NotificationCenter.default.addObserver(
      self, selector: #selector(resized), name: NSView.boundsDidChangeNotification,
      object: timelineScroll.contentView)
    NotificationCenter.default.addObserver(
      self, selector: #selector(resized), name: NSView.frameDidChangeNotification,
      object: timelineScroll.contentView)

    let composerScroll = NSScrollView()
    composerScroll.borderType = .noBorder
    composerScroll.drawsBackground = false
    composerScroll.hasVerticalScroller = true
    composerScroll.autohidesScrollers = true
    composerScroll.documentView = composer
    composer.isRichText = false
    composer.drawsBackground = false
    composer.isAutomaticQuoteSubstitutionEnabled = false
    composer.isAutomaticDashSubstitutionEnabled = false
    composer.font = .systemFont(ofSize: 14)
    composer.textContainerInset = NSSize(width: 8, height: 12)
    composer.isVerticallyResizable = true
    composer.isHorizontallyResizable = false
    composer.autoresizingMask = [.width]
    composer.textContainer?.widthTracksTextView = true
    composer.delegate = self
    completion.anchorView = composer
    completion.onLocalCommand = { [weak self] command in
      guard let self else { return }
      if command == "model" {
        modelControls.showModels()
      } else if command == "plan" {
        store.setInteractionMode("plan")
      } else if command == "default" {
        store.setInteractionMode("default")
      }
    }
    composer.handleCompletionKey = { [weak completion] in completion?.handleKeyDown($0) ?? false }
    completion.onInsert = { [weak self] range, text in
      guard let self, composer.isEditable, !composer.hasMarkedText(),
        range.location >= 0, NSMaxRange(range) <= (composer.string as NSString).length,
        composer.shouldChangeText(in: range, replacementString: text)
      else { return }
      composer.textStorage?.replaceCharacters(in: range, with: text)
      composer.setSelectedRange(
        NSRange(location: range.location + (text as NSString).length, length: 0))
      composer.didChangeText()
    }
    composer.setAccessibilityLabel("Message")
    composer.submit = { [weak store] in store?.submitComposer() }
    (window as? ConversationWindow)?.questionShortcut = { [weak self, weak requestsPanel] in
      guard self?.showingUsage != true else { return false }
      if let self, let responder = self.window?.firstResponder as? NSView,
        responder.isDescendant(of: self.browser.view)
      {
        return false
      }
      return requestsPanel?.handleNumberKey($0) ?? false
    }
    composer.editLatestQueued = { [weak store] in
      guard let store, store.queuedEdit == nil, !store.queueBusy,
        let message = store.execution.queued.last
      else { return false }
      store.editQueuedMessage(message)
      return true
    }
    composer.attach = { [weak store] urls, temporary in
      store?.addAttachments(urls, deleteSources: temporary)
    }
    composer.registerForDraggedTypes([.fileURL, .png, .tiff])
    attachButton.target = self
    attachButton.action = #selector(attachFiles)
    attachButton.image = NSImage(
      systemSymbolName: "paperclip", accessibilityDescription: "Attach files")
    attachButton.imagePosition = .imageOnly
    attachButton.bezelStyle = .inline
    attachButton.setAccessibilityLabel("Attach files")
    composerScroll.heightAnchor.constraint(equalToConstant: 86).isActive = true
    sendButton.target = self
    sendButton.action = #selector(send)
    sendButton.bezelStyle = .inline
    sendButton.image = NSImage(
      systemSymbolName: "arrow.up.circle.fill", accessibilityDescription: "Send message")
    sendButton.imagePosition = .imageOnly
    sendButton.contentTintColor = .controlAccentColor
    sendButton.setAccessibilityLabel("Send message")
    sendButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true
    sendButton.heightAnchor.constraint(equalToConstant: 36).isActive = true
    deliveryButton.controlSize = .small
    deliveryButton.bezelStyle = .inline
    deliveryButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
    deliveryButton.setAccessibilityLabel("Message delivery")
    stopButton.target = self
    stopButton.action = #selector(stop)
    stopButton.image = NSImage(
      systemSymbolName: "stop.fill", accessibilityDescription: "Stop generation")
    stopButton.imagePosition = .imageOnly
    stopButton.isBordered = false
    stopButton.bezelStyle = .inline
    stopButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
    stopButton.setAccessibilityLabel("Stop generation")
    let hint = NSTextField(labelWithString: "⌘ Return to send")
    hint.font = .systemFont(ofSize: 11)
    hint.textColor = .secondaryLabelColor
    let spacer = NSView()
    let bottom = NSStackView(views: [
      modelControls, spacer, attachButton, stopButton, sendButton, deliveryButton,
    ])
    bottom.spacing = 8
    planBanner.font = .systemFont(ofSize: 12, weight: .medium)
    planBanner.textColor = .secondaryLabelColor
    planBanner.isHidden = true
    let composerStack = NSStackView(views: [planBanner, attachmentTray, composerScroll, bottom])
    composerStack.orientation = .vertical
    composerStack.alignment = .leading
    composerStack.spacing = 8
    composerSurface.layer?.cornerRadius = 22
    composerSurface.addSubview(composerStack)
    pin(composerStack, to: composerSurface, inset: 16, top: 6)
    composerScroll.widthAnchor.constraint(equalTo: composerStack.widthAnchor).isActive = true
    attachmentTray.widthAnchor.constraint(equalTo: composerStack.widthAnchor).isActive = true
    planBanner.widthAnchor.constraint(equalTo: composerStack.widthAnchor).isActive = true
    bottom.widthAnchor.constraint(equalTo: composerStack.widthAnchor).isActive = true
    for view in [
      subtitle, NSTextField(labelWithString: "/"), heading, NSView(),
      button("Files", symbol: "folder", #selector(toggleWorkspace)),
      button("Browser", symbol: "globe", #selector(toggleBrowser)),
    ] { header.addArrangedSubview(view) }
    header.spacing = 10
    right.addSubview(header)
    header.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      header.leadingAnchor.constraint(equalTo: right.leadingAnchor, constant: 24),
      header.trailingAnchor.constraint(equalTo: right.trailingAnchor, constant: -24),
      header.topAnchor.constraint(equalTo: right.topAnchor, constant: 46),
    ])
    let heroTitle = NSTextField(labelWithString: "What should we build in")
    heroTitle.font = .systemFont(ofSize: 24, weight: .medium)
    newChatProject.font = .systemFont(ofSize: 24, weight: .semibold)
    newChatProject.invoke = { [weak self] in self?.chooseExistingProject() }
    newChatProject.setAccessibilityLabel("Choose project for new conversation")
    newChatProject.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true
    let heroLine = NSStackView(views: [heroTitle, newChatProject])
    heroLine.spacing = 6
    withoutProject.isBordered = false
    withoutProject.font = .systemFont(ofSize: 14)
    withoutProject.contentTintColor = .secondaryLabelColor
    withoutProject.invoke = { [weak store] in store?.startWithoutProject() }
    newChatHeading.orientation = .vertical
    newChatHeading.alignment = .centerX
    newChatHeading.spacing = 12
    newChatHeading.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 22, right: 0)
    newChatHeading.addArrangedSubview(heroLine)
    newChatHeading.addArrangedSubview(withoutProject)
    let footer = NSStackView(views: [status, NSView(), hint])
    let stack = conversationStack
    for view in [
      newChatHeading, olderButton, timelineScroll, errorLabel, requestsPanel, queuePanel,
      contextBanner, composerSurface, workspaceControls, footer,
    ] { stack.addArrangedSubview(view) }
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 9
    right.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    let preferredWidth = stack.widthAnchor.constraint(equalTo: right.widthAnchor, constant: -48)
    preferredWidth.priority = .defaultHigh
    conversationTop = stack.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 16)
    conversationBottom = stack.bottomAnchor.constraint(equalTo: right.bottomAnchor, constant: -16)
    conversationCenter = stack.centerYAnchor.constraint(equalTo: right.centerYAnchor, constant: -20)
    maximumChatWidth = stack.widthAnchor.constraint(lessThanOrEqualToConstant: 880)
    NSLayoutConstraint.activate([
      maximumChatWidth!,
      stack.centerXAnchor.constraint(equalTo: right.centerXAnchor),
      conversationTop!, conversationBottom!,
      stack.widthAnchor.constraint(lessThanOrEqualTo: right.widthAnchor, constant: -32),
      preferredWidth,
    ])
    for view in [
      newChatHeading, timelineScroll, errorLabel, requestsPanel, queuePanel, contextBanner,
      composerSurface, workspaceControls, footer,
    ] {
      view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    timelineScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
    welcome.onPrimary = { [weak self] in
      guard let self else { return }
      if store.ready { newThread() } else { retry() }
    }
    welcome.onSecondary = { [weak self] in
      guard let self else { return }
      if store.ready { openProject() } else { connect() }
    }
    right.addSubview(welcome)
    welcome.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      welcome.centerXAnchor.constraint(equalTo: right.centerXAnchor),
      welcome.centerYAnchor.constraint(equalTo: right.centerYAnchor, constant: -24),
      welcome.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
      welcome.widthAnchor.constraint(lessThanOrEqualTo: right.widthAnchor, constant: -64),
    ])
    right.addSubview(restoreSidebar)
    restoreSidebar.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      restoreSidebar.leadingAnchor.constraint(equalTo: right.leadingAnchor, constant: 82),
      restoreSidebar.topAnchor.constraint(equalTo: right.topAnchor, constant: 8),
    ])
    heading.setContentCompressionResistancePriority(.required, for: .vertical)
    composerSurface.setContentCompressionResistancePriority(.required, for: .vertical)
    window.setContentSize(NSSize(width: 1220, height: 840))
    splitController.splitView.setPosition(256, ofDividerAt: 0)
  }

  private func button(_ title: String, symbol: String, _ action: Selector) -> NSButton {
    let button = NSButton(title: title, target: self, action: action)
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    button.imagePosition = .imageLeading
    button.font = .systemFont(ofSize: 12)
    button.bezelStyle = .inline
    button.isBordered = false
    button.contentTintColor = .secondaryLabelColor
    button.toolTip = title
    return button
  }

  private func installCommands() {
    guard let menu = NSApp.mainMenu else { return }
    if let app = menu.items.first?.submenu {
      let settings = app.addItem(
        withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
      settings.target = self
      settings.keyEquivalentModifierMask = .command
    }
    let chat = NSMenu(title: "Chat")
    let view = NSMenu(title: "View")
    for (parent, title, action, key, modifiers) in [
      (chat, "New Thread", #selector(newThread), "n", NSEvent.ModifierFlags.command),
      (chat, "Open Project…", #selector(openProject), "o", [.command]),
      (chat, "New Project…", #selector(newProject), "n", [.command, .shift]),
      (chat, "Choose Model…", #selector(chooseModel), "m", [.command, .shift]),
      (chat, "Search Threads", #selector(searchThreads), "k", [.command]),
      (chat, "Attach Files…", #selector(attachFiles), "a", [.command, .shift]),
      (chat, "Steer Next Queued Message", #selector(steerNextQueued), "\r", [.command, .shift]),
      (chat, "Resume", #selector(resume), "", []),
      (chat, "Enable Plan Mode", #selector(togglePlanModeEnabled), "", []),
      (view, "Toggle Files", #selector(toggleWorkspace), "e", [.command, .shift]),
      (view, "Toggle Changes", #selector(toggleReview), "g", [.command, .shift]),
      (view, "Toggle Terminal", #selector(toggleTerminal), "j", [.command]),
      (view, "Save Workspace File", #selector(saveWorkspaceFile), "s", [.command]),
      (view, "Find in File or Diff", #selector(findWorkspaceFile), "f", [.command]),
      (view, "Toggle Sidebar", #selector(toggleSidebar), "b", [.command]),
      (view, "Usage", #selector(showUsage), "u", [.command, .shift]),
      (view, "Toggle Browser", #selector(toggleBrowser), "b", [.command, .shift]),
      (view, "Browser Address", #selector(browserAddress), "l", [.command]),
      (view, "New Browser Tab", #selector(newBrowserTab), "t", [.command]),
      (view, "Browser Settings…", #selector(browserSettings), "", []),
      (view, "Browser Downloads…", #selector(browserDownloads), "", []),
      (view, "Pause Agent Browser", #selector(toggleAgentBrowser), "", []),
    ] {
      let item = parent.addItem(withTitle: title, action: action, keyEquivalent: key)
      item.keyEquivalentModifierMask = modifiers
      item.target = self
    }
    for submenu in [chat, view] {
      let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
      item.submenu = submenu
      let index = menu.items.firstIndex { $0.submenu === NSApp.windowsMenu } ?? menu.numberOfItems
      menu.insertItem(item, at: index)
    }
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    if menuItem.action == #selector(toggleAgentBrowser) {
      menuItem.title = browser.agentPaused ? "Resume Agent Browser" : "Pause Agent Browser"
      return store.ready
    }
    if menuItem.action == #selector(togglePlanModeEnabled) {
      menuItem.state = store.catalog.planModeEnabled ? .on : .off
      return true
    }
    if menuItem.action == #selector(saveWorkspaceFile) {
      return workspaceItem?.isCollapsed == false && workspace.files.canSave
    }
    if menuItem.action == #selector(findWorkspaceFile) {
      return reviewItem?.isCollapsed == false
        || workspaceItem?.isCollapsed == false && workspace.files.document != nil
    }
    if menuItem.action == #selector(chooseModel) {
      return store.canEditThread && store.catalogReady
    }
    if menuItem.action == #selector(newThread) { return store.canCreateThread }
    if menuItem.action == #selector(openProject) || menuItem.action == #selector(newProject) {
      return store.ready && store.catalogReady && projectPicker == nil
    }
    if menuItem.action == #selector(attachFiles) { return store.canAttach }
    if menuItem.action == #selector(steerNextQueued) {
      return !store.queueBusy && store.execution.canSteer && !store.execution.queued.isEmpty
    }
    if menuItem.action == #selector(resume) {
      return !store.queueBusy && (store.execution.isHeld || store.execution.resumableRunID != nil)
    }
    return true
  }

  @objc private func chooseModel() { modelControls.showModels() }
  @objc private func searchThreads() {
    completion.dismiss()
    sidebarItem?.isCollapsed = false
    sidebar.focusSearch()
  }
  @objc private func togglePlanModeEnabled() {
    store.setPlanModeEnabled(!store.catalog.planModeEnabled)
  }
  @objc private func toggleSidebar() {
    guard let sidebarItem else { return }
    sidebarItem.isCollapsed.toggle()
  }

  @objc private func toggleWorkspace() {
    showConversation()
    hideBrowser()
    guard let workspaceItem else { return }
    workspaceItem.isCollapsed.toggle()
    if workspaceItem.isCollapsed { workspace.closeEditor() }
    if !workspaceItem.isCollapsed {
      reviewItem?.isCollapsed = true
      review.refreshContext(active: false)
      if let window, window.frame.width < 1220 {
        var frame = window.frame
        frame.size.width = 1220
        window.setFrame(frame, display: true)
      }
      workspace.refreshContext()
      workspace.focusSearch()
    }
  }
  @objc private func toggleReview() {
    showConversation()
    hideBrowser()
    guard let reviewItem else { return }
    reviewItem.isCollapsed.toggle()
    if !reviewItem.isCollapsed {
      workspace.closeEditor()
      workspaceItem?.isCollapsed = true
      workspace.refreshContext(active: false)
      if let window, window.frame.width < 1240 {
        var frame = window.frame
        frame.size.width = 1240
        window.setFrame(frame, display: true)
      }
    }
    review.refreshContext(active: !reviewItem.isCollapsed)
    if reviewItem.isCollapsed { window?.makeFirstResponder(composer) } else { review.focus() }
  }
  @objc private func toggleTerminal() {
    showConversation()
    guard let terminalItem else { return }
    terminalItem.isCollapsed.toggle()
    terminal.refresh(active: !terminalItem.isCollapsed)
    if terminalItem.isCollapsed { window?.makeFirstResponder(composer) } else { terminal.focus() }
  }
  @objc private func saveWorkspaceFile() { workspace.saveFile() }
  @objc private func showUsage() {
    guard !showingUsage else { return }
    completion.dismiss()
    showingUsage = true
    hideBrowser()
    usageThreadID = store.selectedID
    workspace.closeEditor()
    workspaceItem?.isCollapsed = true
    reviewItem?.isCollapsed = true
    workspace.refreshContext(active: false)
    review.refreshContext(active: false)
    terminal.refresh(active: false)
    conversationView?.removeFromSuperview()
    if let pageContainer {
      pageContainer.addSubview(usage.view)
      pin(usage.view, to: pageContainer, inset: 0, top: 0)
    }
    sidebar.showUtilityPage(true)
    window?.makeFirstResponder(usage.view)
    usage.model.synchronize(active: true)
  }
  private func showConversation() {
    guard showingUsage else { return }
    showingUsage = false
    usage.view.removeFromSuperview()
    sidebar.showUtilityPage(false)
    if let pageContainer, let conversationView {
      pageContainer.addSubview(conversationView)
      pin(conversationView, to: pageContainer, inset: 0, top: 0)
    }
    usage.model.synchronize(active: false)
    terminal.refresh(active: terminalItem?.isCollapsed == false)
    window?.makeFirstResponder(composer)
  }
  @objc private func toggleBrowser() {
    guard let browserItem else { return }
    if !browserItem.isCollapsed {
      hideBrowser()
      return
    }
    showConversation()
    workspace.closeEditor()
    workspaceItem?.isCollapsed = true
    reviewItem?.isCollapsed = true
    workspace.refreshContext(active: false)
    review.refreshContext(active: false)
    browserItem.isCollapsed = false
    if let window, window.frame.width < 1_240 {
      var frame = window.frame
      frame.size.width = 1_240
      window.setFrame(frame, display: true)
    }
    browser.refresh(active: true)
    browser.focusAddress()
  }
  private func hideBrowser() {
    centerItem?.isCollapsed = false
    browserItem?.isCollapsed = true
    browser.refresh(active: false)
  }
  @objc private func browserAddress() {
    if browserItem?.isCollapsed == true { toggleBrowser() }
    browser.focusAddress()
  }
  @objc private func newBrowserTab() {
    if browserItem?.isCollapsed == true { toggleBrowser() }
    browser.newTab()
  }
  @objc private func toggleAgentBrowser() { browser.toggleAgentControl() }
  @objc private func browserSettings() { browser.showBrowserSettings() }
  @objc private func browserDownloads() { browser.showDownloads() }
  func finishBrowserDownloads() async -> Bool {
    await browser.finishBeforeQuit(window: window)
  }
  func stopBrowserHelper() { browser.stopChromiumHelper() }
  private func openMarkdownLink(_ url: URL, at location: WorkspaceLocation?) {
    if url.isFileURL {
      guard let location, store.workspaceLocation == location else { return }
      if workspaceItem?.isCollapsed == true { toggleWorkspace() }
      workspace.refreshContext()
      workspace.open(url)
    } else if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
      if browser.opensLinksExternally {
        NSWorkspace.shared.open(url)
        return
      }
      if browserItem?.isCollapsed == true { toggleBrowser() }
      browser.open(url.absoluteString, newTab: true)
    } else if url.scheme?.lowercased() == "mailto" {
      NSWorkspace.shared.open(url)
    }
  }
  @objc private func findWorkspaceFile() {
    if reviewItem?.isCollapsed == false { review.find() } else { workspace.findInFile() }
  }
  func finishWorkspaceSaving() async -> Bool { await workspace.finishSaving() }
  var workspaceStorageError: String? { workspace.storageError }

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
    settingsWindow?.refresh()
    notifications.refreshConnection()
    if showingUsage, store.selectedID != usageThreadID { showConversation() }
    usage.model.synchronize(active: showingUsage)
    browser.refresh(active: !showingUsage && browserItem?.isCollapsed == false)
    let anchor = scrollAnchor()
    sidebar.refresh()
    workspace.refreshContext(active: workspaceItem?.isCollapsed == false)
    review.refreshContext(active: reviewItem?.isCollapsed == false)
    terminal.refresh(active: !showingUsage && terminalItem?.isCollapsed == false)
    let selected = store.selectedThread
    let hasConversation = store.selectedID != nil
    header.isHidden = !hasConversation
    conversationStack.isHidden = !hasConversation
    welcome.isHidden = hasConversation
    welcome.refresh(store)
    let newConversation = store.isNewConversation
    newChatHeading.isHidden = !newConversation
    timelineScroll.isHidden = newConversation
    conversationTop?.isActive = !newConversation
    conversationBottom?.isActive = !newConversation
    conversationCenter?.isActive = newConversation
    let project = store.selectedDraft?.project
    newChatProject.title = (project?["title"].string ?? "this project") + "  ⌄"
    newChatProject.toolTip = project?["workspaceRoot"].string
    newChatProject.isEnabled = store.canEditThread && store.catalogReady && !store.composerBusy
    if let context = projectSelectionContext {
      if context.session != store.projectSessionID || context.draftID != store.selectedID
        || !newChatProject.isEnabled
      {
        projectSelection?.performClose(nil)
        projectSelectionContext = nil
      } else {
        (projectSelection?.contentViewController as? ExistingProjectPicker)?.update(
          projects: Array(store.shell.projectDetails.values), selectedID: project?["id"].string)
      }
    }
    withoutProject.isHidden = store.catalog.scratchWorkspaceRoot == nil
    workspaceControls.refresh()
    composer.placeholder =
      newConversation
      ? "Ask for changes, send follow-ups, or attach images"
      : "Ask anything, @tag files/folders, $use skills, or / for commands"
    heading.stringValue = selected?.title ?? "T3 Native"
    subtitle.stringValue =
      selected.map {
        store.shell.projects[$0.projectID] ?? store.archives.projects[$0.projectID] ?? "Project"
      } ?? "Connect to an existing T3 server to get started"
    status.stringValue = notice ?? (store.ready ? "" : store.status)
    errorLabel.stringValue = store.error ?? store.storageError ?? ""
    errorLabel.isHidden = store.error == nil && store.storageError == nil
    olderButton.isHidden = newConversation || store.thread?.hasMore != true
    olderButton.isEnabled = store.ready && !store.loadingHistory
    olderButton.title = store.loadingHistory ? "Loading earlier activity…" : "Load earlier activity"
    let draft = store.composerText
    if composer.string != draft {
      composer.string = draft
      composer.needsDisplay = true
    }
    if renderedDraftID != store.composerDraftID {
      completion.dismiss()
      renderedDraftID = store.composerDraftID
      window?.makeFirstResponder(composer)
    }
    updateComposerControls()
    composer.isEditable =
      selected?.archived != true
      && !(store.queuedEdit != nil && store.sending.contains(store.selectedID ?? ""))
      && store.questionRequest.map { $0.canRespond && !store.questionBusy($0) } != false
      && store.activeQuestionProgress?.question["allowCustomAnswer"] != .bool(false)
    composer.setAccessibilityLabel(
      store.questionRequest == nil ? "Message" : "Answer to the current question")
    refreshCompletion()
    if window?.isKeyWindow == true { store.markVisibleThreadRead() }
    modelControls.refresh()
    contextBanner.refresh()
    requestsPanel.refresh()
    attachmentPreviews.updateEnvironment(store.environmentKey)
    attachmentTray.refresh()
    queuePanel.refresh()
    stopButton.isHidden = store.execution.activeRunID == nil && selected?.activeRunID == nil
    stopButton.isEnabled =
      store.canEditThread && !store.commandsInFlight.contains((store.selectedID ?? "") + ":stop")
    window?.contentView?.layoutSubtreeIfNeeded()
    updateRows(conversationEntries(), anchor: anchor)
    if planWorkspace != store.workspaceLocation || planWorkspaceReady != store.ready {
      planWorkspace = store.workspaceLocation
      planWorkspaceReady = store.ready
      timeline.reloadData(
        forRowIndexes: IndexSet(rows.indices.filter { rows[$0].item?.kind == "proposed_plan" }),
        columnIndexes: IndexSet(integer: 0))
    }
    let connectionState = "\(store.environmentKey):\(store.ready)"
    if connectionState != attachmentConnectionState {
      attachmentConnectionState = connectionState
      timeline.reloadData(
        forRowIndexes: IndexSet(
          rows.indices.filter {
            !(rows[$0].item?.attachments.isEmpty ?? true)
          }), columnIndexes: IndexSet(integer: 0))
    }
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
    let execution = store.execution
    let visible = (store.thread?.rows ?? []).filter {
      $0.inherited || !execution.hidesQueuedMessage($0.item)
    }
    return ConversationTimeline.entries(
      from: visible, activeRunID: store.selectedThread?.activeRunID,
      expandedItemIDs: expandedWork[store.selectedID ?? ""] ?? [],
      checkpoints: store.thread?.checkpoints.items ?? [])
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
    let changedThread = renderedThread != planScope
    let changedWorkspace = renderedWorkspace != store.workspaceLocation
    guard changedThread || changedWorkspace || next != rows else {
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
    renderedThread = planScope
    renderedWorkspace = store.workspaceLocation
    if changedThread || changedWorkspace { resizeAnchor = nil }
    if changedThread || changedWorkspace || !samePrefix {
      rendered.removeAll(keepingCapacity: true)
      planLayouts.removeAll(keepingCapacity: true)
      timeline.reloadData()
    } else {
      for index in changes {
        rendered.removeValue(forKey: rows[index].id)
        planLayouts.removeValue(forKey: rows[index].id)
      }
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
    guard !applyingResize, !showingUsage else { return }
    let width = timelineScroll.contentSize.width
    guard abs(width - lastWidth) > 1 else {
      resizeWork?.cancel()
      resizeWork = nil
      if !liveResizing, window?.inLiveResize != true { resizeAnchor = nil }
      return
    }
    if resizeAnchor == nil { resizeAnchor = scrollAnchor() }
    // Preserve the rows while a window edge or split divider is being dragged.
    guard !liveResizing, window?.inLiveResize != true else { return }
    if NSEvent.pressedMouseButtons & 1 != 0 {
      resizeWork?.cancel()
      let work = DispatchWorkItem { [weak self] in self?.resized() }
      resizeWork = work
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
      return
    }
    applyResize()
  }

  private func applyResize() {
    resizeWork?.cancel()
    resizeWork = nil
    let anchor = resizeAnchor ?? scrollAnchor()
    resizeAnchor = nil
    let width = timelineScroll.contentSize.width
    guard !applyingResize, abs(width - lastWidth) > 1 else { return }
    applyingResize = true
    defer { applyingResize = false }
    lastWidth = width
    rendered.removeAll(keepingCapacity: true)
    planLayouts.removeAll(keepingCapacity: true)
    timeline.noteHeightOfRows(withIndexesChanged: IndexSet(rows.indices))
    timeline.reloadData(forRowIndexes: IndexSet(rows.indices), columnIndexes: IndexSet(integer: 0))
    restoreScroll(anchor)
  }

  private func messageWidth(_ row: TimelineRow) -> CGFloat {
    let available = max(120, timelineLayoutWidth - 24)
    guard row.kind == "user_message" else { return available }
    let natural =
      (row.text as NSString).size(withAttributes: [.font: appearanceValues.resolvedInterfaceFont])
      .width + 4
    return min(available * 0.82, max(row.attachments.isEmpty ? 100 : 300, natural))
  }

  private func render(_ row: TimelineRow) -> (RenderedMarkdown, CGFloat) {
    let width = messageWidth(row)
    if let cached = rendered[row.id], cached.row == row, cached.width == width {
      return (cached.markdown, cached.height)
    }
    let markdown: RenderedMarkdown
    if row.kind == "user_message" {
      markdown = RenderedMarkdown(
        text: NSAttributedString(
          string: row.text,
          attributes: [
            .font: appearanceValues.resolvedInterfaceFont, .foregroundColor: NSColor.labelColor,
          ]), codeBlocks: [])
    } else if ["assistant_message", "reasoning", "proposed_plan"].contains(row.kind) {
      let root = store.workspaceLocation?.root
      markdown = MarkdownRenderer.render(
        row.text, width: width, configuration: markdownConfiguration
      ) { destination in
        WorkspaceMarkdown.link(destination, filePath: "", root: root)
      }
    } else {
      let font =
        ["command_execution", "dynamic_tool", "file_change"].contains(row.kind)
        ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) : NSFont.systemFont(ofSize: 14)
      markdown = RenderedMarkdown(
        text: NSAttributedString(
          string: row.text,
          attributes: [.font: font, .foregroundColor: NSColor.labelColor]), codeBlocks: [])
    }
    let height =
      max(
        row.kind == "user_message" ? 60 : 44,
        MarkdownRenderer.height(of: markdown.text, width: width)
          + (row.kind == "user_message" ? 40 : 44))
      + MessageTextView.horizontalScrollerAllowance(for: markdown, width: width)
      + attachmentHeight(row)
    rendered[row.id] = (row, markdown, width, height)
    return (markdown, height)
  }

  func numberOfRows(in tableView: NSTableView) -> Int {
    rows.count
  }

  private func attachmentHeight(_ row: TimelineRow) -> CGFloat {
    let attachments = row.attachments
    return attachments.isEmpty ? 0 : MessageAttachmentsView.height(attachments) + 6
  }

  func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
    switch rows[row] {
    case .item(let item): item.kind == "proposed_plan" ? planLayout(item).height : render(item).1
    case .work: 36
    case .changes(let checkpoint): CheckpointCard.height(checkpoint)
    }
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int)
    -> NSView?
  {
    if case .work(let group) = rows[index] { return workCell(group) }
    if case .changes(let checkpoint) = rows[index] {
      let location = store.workspaceLocation
      return CheckpointCard(checkpoint) { [weak self] path in
        guard let self, let location, store.workspaceLocation == location,
          checkpoint.threadID == location.threadID
        else { return }
        if reviewItem?.isCollapsed == true { toggleReview() }
        review.openCheckpoint(checkpoint.id, filePath: path)
        review.focus()
      }
    }
    guard case .item(let row) = rows[index] else { return nil }
    if row.kind == "proposed_plan" {
      let layout = planLayout(row)
      let location = store.workspaceLocation
      return PlanCardView(
        layout: layout, inherited: row.inherited, canSave: store.ready && location != nil,
        toggle: { [weak self] in self?.togglePlan(row.id) },
        copy: { [weak self] in
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(layout.document.contents, forType: .string)
          self?.showNotice("Plan copied")
        },
        download: { [weak self] in self?.downloadPlan(layout.document) },
        save: { [weak self] in
          if let location { self?.savePlan(layout.document, rowID: row.id, location: location) }
        },
        openLink: { [weak self] in self?.openMarkdownLink($0, at: location) },
        fileLinkMenu: { [weak store] url in
          guard let store else { return nil }
          return FileContextMenu.forLink(url, at: location, store: store)
        })
    }
    let cell = NSView()
    let isUser = row.kind == "user_message"
    let isAssistant = row.kind == "assistant_message"
    let (markdown, height) = render(row)
    let bodyHeight = height - (isUser ? 40 : 44) - attachmentHeight(row)
    let body = MessageTextView(rendered: markdown, width: messageWidth(row), height: bodyHeight)
    let bodyView = body.horizontalScrollContainer()
    body.setAccessibilityLabel(
      isUser ? "Your message" : isAssistant ? "Assistant response" : row.title)
    let scope = planScope
    body.onCodeWrapChange = { [weak self] codeIndex, wraps in
      guard let self, planScope == scope, let current = rendered[row.id], current.row == row else {
        return
      }
      let next = MarkdownRenderer.settingCodeWrapping(
        wraps, at: codeIndex, in: current.markdown, width: messageWidth(row))
      let height =
        max(
          isUser ? 60 : 44,
          MarkdownRenderer.height(of: next.text, width: messageWidth(row)) + (isUser ? 40 : 44))
        + MessageTextView.horizontalScrollerAllowance(for: next, width: messageWidth(row))
        + attachmentHeight(row)
      rendered[row.id] = (row, next, current.width, height)
      guard let index = rows.firstIndex(where: { $0.id == row.id }) else { return }
      let anchor = scrollAnchor()
      timeline.noteHeightOfRows(withIndexesChanged: IndexSet(integer: index))
      timeline.reloadData(
        forRowIndexes: IndexSet(integer: index), columnIndexes: IndexSet(integer: 0))
      restoreScroll(anchor)
    }
    let location = store.workspaceLocation
    body.onOpenLink = { [weak self] in self?.openMarkdownLink($0, at: location) }
    body.fileLinkMenu = { [weak store] url in
      guard let store else { return nil }
      return FileContextMenu.forLink(url, at: location, store: store)
    }
    let copy = sidebarIcon("Copy message", "doc.on.doc", size: 22) {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(row.text, forType: .string)
    }
    let title = NSTextField(
      labelWithString: (isUser || isAssistant ? "" : row.title)
        + (row.inherited ? " · inherited" : "")
        + (row.failed ? " · failed" : row.streaming ? " · streaming" : ""))
    title.font = .systemFont(ofSize: 11)
    title.textColor = row.failed ? .systemRed : .secondaryLabelColor
    let actions = NSStackView(views: [title, NSView(), copy])
    actions.spacing = 6
    if row.item["outputOmitted"].bool {
      let busy = store.commandsInFlight.contains(row.id + ":output")
      let output = ActionButton(busy ? "Loading output…" : "Load full output") { [weak store] in
        store?.loadOutput(row)
      }
      output.isEnabled = store.ready && !busy
      output.controlSize = .small
      actions.insertArrangedSubview(output, at: 1)
    }
    let stack = NSStackView(views: isAssistant || isUser ? [bodyView] : [actions, bodyView])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 6
    if !row.attachments.isEmpty {
      let attachments = MessageAttachmentsView(
        attachments: row.attachments, store: store, previews: attachmentPreviews
      ) { [weak self] in self?.downloadAttachment($0) }
      stack.addArrangedSubview(attachments)
      attachments.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
      attachments.heightAnchor.constraint(equalToConstant: attachmentHeight(row) - 6).isActive =
        true
    }
    if isAssistant { stack.addArrangedSubview(actions) }
    let container = isUser ? MessageBubble() : NSView()
    container.addSubview(stack)
    cell.addSubview(container)
    stack.translatesAutoresizingMaskIntoConstraints = false
    container.translatesAutoresizingMaskIntoConstraints = false
    let inset: CGFloat = isUser ? 14 : 0
    NSLayoutConstraint.activate([
      container.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12),
      container.topAnchor.constraint(equalTo: cell.topAnchor, constant: 8),
      container.widthAnchor.constraint(equalToConstant: messageWidth(row) + inset * 2),
      stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
      stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
      stack.topAnchor.constraint(equalTo: container.topAnchor, constant: isUser ? 12 : 0),
      stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: isUser ? -12 : 0),
      bodyView.widthAnchor.constraint(equalTo: stack.widthAnchor),
      bodyView.heightAnchor.constraint(equalToConstant: max(20, bodyHeight)),
    ])
    if !isUser { actions.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    return cell
  }

  private var planScope: String { store.environmentKey + "\n" + (store.selectedID ?? "") }
  private var timelineLayoutWidth: CGFloat {
    lastWidth > 0 ? lastWidth : timeline.bounds.width
  }
  private func planLayout(_ row: TimelineRow) -> PlanCardLayout {
    let expanded = expandedPlans[planScope]?.contains(row.id) == true
    let width = timelineLayoutWidth
    if let cached = planLayouts[row.id], cached.row == row, cached.width == width,
      cached.expanded == expanded
    {
      return cached.layout
    }
    let root = store.workspaceLocation?.root
    let layout = PlanCardLayout(markdown: row.text, width: width, expanded: expanded) {
      destination in
      WorkspaceMarkdown.link(destination, filePath: "", root: root)
    }
    planLayouts[row.id] = (row, width, expanded, layout)
    return layout
  }
  private func togglePlan(_ rowID: String) {
    guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
    var anchor = scrollAnchor()
    anchor.followsBottom = false
    if expandedPlans[planScope, default: []].contains(rowID) {
      expandedPlans[planScope, default: []].remove(rowID)
      if anchor.id == rowID { anchor.offset = 0 }
    } else {
      expandedPlans[planScope, default: []].insert(rowID)
    }
    planLayouts.removeValue(forKey: rowID)
    timeline.noteHeightOfRows(withIndexesChanged: IndexSet(integer: index))
    timeline.reloadData(
      forRowIndexes: IndexSet(integer: index), columnIndexes: IndexSet(integer: 0))
    restoreScroll(anchor)
  }
  private func showNotice(_ message: String) {
    noticeReset?.cancel()
    notice = message
    status.stringValue = message
    noticeReset = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(4)) } catch { return }
      self?.notice = nil
      if let self { status.stringValue = store.status }
    }
  }
  private func downloadPlan(_ document: PlanDocument) {
    guard let window else { return }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = document.filename
    panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let url = panel.url else { return }
      Task { @MainActor in
        do {
          try await document.save(to: url)
          self?.showNotice("Plan saved as \(url.lastPathComponent)")
        } catch {
          self?.store.error = error.localizedDescription
          self?.refresh()
        }
      }
    }
  }
  private func savePlan(_ document: PlanDocument, rowID: String, location: WorkspaceLocation) {
    guard let window, planSaveSheet == nil else { return }
    let key = location.environment + "\n" + location.threadID + "\n" + rowID
    let sheet = WorkspaceSaveSheet(
      root: location.root, path: planSavePaths[key] ?? document.filename,
      write: { [store] path in try await store.savePlan(document, at: location, relativePath: path)
      },
      saved: { [weak self] path in self?.showNotice("Plan saved to workspace · \(path)") },
      closed: { [weak self] path in
        self?.planSavePaths[key] = path
        self?.planSaveSheet = nil
      })
    planSaveSheet = sheet
    sheet.present(on: window)
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

  override func showWindow(_ sender: Any?) {
    super.showWindow(sender)
    guard !didSetSidebarWidth else { return }
    didSetSidebarWidth = true
    DispatchQueue.main.async { [weak self] in
      guard let split = (self?.window?.contentViewController as? NSSplitViewController)?.splitView
      else { return }
      split.layoutSubtreeIfNeeded()
      split.setPosition(256, ofDividerAt: 0)
      self?.sidebarItem?.minimumThickness = 208
    }
  }
  func windowDidBecomeKey(_ notification: Notification) { store.markVisibleThreadRead() }
  func windowWillStartLiveResize(_ notification: Notification) {
    liveResizing = true
    resizeWork?.cancel()
    resizeAnchor = scrollAnchor()
  }
  func windowDidEndLiveResize(_ notification: Notification) {
    liveResizing = false
    window?.contentView?.layoutSubtreeIfNeeded()
    applyResize()
  }
  func textDidChange(_ notification: Notification) {
    store.composerText = composer.string
    composer.needsDisplay = true
    updateComposerControls()
    requestsPanel.refresh()
    refreshCompletion()
  }
  func textViewDidChangeSelection(_ notification: Notification) {
    guard notification.object as? NSTextView === composer else { return }
    refreshCompletion()
  }
  private func refreshCompletion() {
    guard !showingUsage, window?.firstResponder === composer, store.questionRequest == nil
    else {
      completion.dismiss()
      return
    }
    completion.refresh(text: composer.string, cursor: composer.selectedRange().location)
  }
  private func updateComposerControls() {
    let sending = store.composerBusy
    sendButton.isEnabled = store.sendBlockReason == nil
    attachButton.isEnabled = store.canAttach
    composer.allowsAttachments = store.canAttach
    let action = store.composerAction
    let plan = action == .plan ? store.planFollowUp : nil
    planBanner.isHidden = plan == nil
    planBanner.stringValue =
      plan.map {
        (store.pendingPlanSubmission == nil ? "Plan ready · " : "Plan send pending · ") + $0.title
      } ?? ""
    sendButton.title = plan == nil ? "" : sending ? "Sending…" : store.planActionTitle
    sendButton.imagePosition = plan == nil ? .imageOnly : .noImage
    let label: String
    switch action {
    case .question:
      label = store.activeQuestionProgress?.isLast == true ? "Submit answers" : "Next question"
    case .plan: label = store.planActionTitle
    case .resume: label = "Resume thread"
    case .stop: label = "Stop generation"
    case .message:
      label =
        store.queuedEdit != nil
        ? "Save queued message" : store.delivery == .auto ? "Send message" : store.delivery.title
    }
    sendButton.toolTip = store.sendBlockReason ?? label + " (⌘ Return)"
    sendButton.setAccessibilityLabel(sending ? "Sending message" : label)
    sendButton.image = NSImage(
      systemSymbolName: action == .resume
        ? "play.fill"
        : action == .stop
          ? "stop.fill"
          : store.queuedEdit == nil ? "arrow.up" : "checkmark",
      accessibilityDescription: nil)
    let execution = store.execution
    let state =
      "\(action):\(store.delivery):\(execution.canQueue):\(execution.canSteer):\(execution.canRestart):\(execution.steeringInterruptsTools):\(store.queuedEdit != nil):\(sending):\(store.questionRequest != nil):\(plan != nil):\(store.planActionTitle):\(store.sendBlockReason ?? "")"
    if deliveryState != state {
      deliveryState = state
      deliveryButton.removeAllItems()
      deliveryButton.addItem(withTitle: "")
      deliveryButton.item(at: 0)?.image = NSImage(
        systemSymbolName: "chevron.down", accessibilityDescription: nil)
      deliveryButton.menu?.autoenablesItems = false
      if plan != nil {
        if store.pendingPlanSubmission != nil {
          let item = ActionMenuItem("Stop retrying this send") { [weak store] in
            store?.discardPlanRetry()
          }
          item.toolTip = "Dismiss the saved retry. Work already accepted by the server continues."
          item.isEnabled = !sending
          deliveryButton.menu?.addItem(item)
        } else {
          let item = ActionMenuItem("Implement in a new thread") { [weak store] in
            store?.submitPlan(newThread: true)
          }
          deliveryButton.menu?.addItem(item)
          item.isEnabled = store.sendBlockReason == nil
        }
      } else {
        for mode in MessageDelivery.allCases {
          let title =
            mode == .steer && execution.steeringInterruptsTools
            ? "Steer now (interrupts tools)" : mode.title
          let item = ActionMenuItem(title) { [weak store] in store?.setDelivery(mode) }
          deliveryButton.menu?.addItem(item)
          item.state = store.delivery == mode ? .on : .off
          item.isEnabled =
            mode == .auto || mode == .queue && execution.canQueue
            || mode == .steer && execution.canSteer || mode == .restart && execution.canRestart
        }
      }
      deliveryButton.isHidden =
        action == .resume || action == .stop || store.queuedEdit != nil
        || store.questionRequest != nil
        || (plan != nil && store.pendingPlanSubmission == nil
          && store.planActionTitle != "Implement")
      deliveryButton.isEnabled = !sending
      deliveryButton.toolTip =
        plan == nil ? "Message delivery: " + store.delivery.title : "Implementation actions"
      deliveryButton.setAccessibilityLabel(
        plan == nil ? "Message delivery" : "Implementation actions")
    }
  }
  @objc private func send() { store.submitComposer() }
  private func downloadAttachment(_ attachment: JSON) {
    guard let window else { return }
    let panel = NSSavePanel()
    let environment = store.environmentKey
    panel.nameFieldStringValue = attachment["name"].string ?? "Attachment"
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let url = panel.url, let self, self.store.environmentKey == environment
      else { return }
      Task {
        guard self.store.environmentKey == environment else { return }
        do {
          let request = try self.store.attachmentPreviewRequest(attachment)
          let file = try await self.attachmentPreviews.cache.file(for: request)
          try await file.save(to: url)
        } catch {
          self.store.error = error.localizedDescription
          self.refresh()
        }
      }
    }
  }
  @objc private func attachFiles() {
    guard let window, store.canAttach else { return }
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = true
    panel.prompt = "Attach"
    let selected = store.composerDraftID
    let environment = store.environmentKey
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let self, self.store.composerDraftID == selected,
        self.store.environmentKey == environment
      else { return }
      self.store.addAttachments(panel.urls)
    }
  }
  @objc private func stop() { store.stop() }
  @objc private func resume() { store.resume() }
  @objc private func steerNextQueued() {
    if let first = store.execution.queued.first { store.steerQueuedMessage(first.id) }
  }
  @objc private func older() { store.loadOlder() }
  @objc private func newThread() {
    showConversation()
    sidebar.clearSearch()
    if sidebar.selectedProjectID == nil, store.selectedThread == nil,
      store.catalog.scratchWorkspaceRoot == nil
    {
      showProjectPicker(create: false)
      return
    }
    store.newThread(projectID: sidebar.selectedProjectID)
  }
  @objc private func openProject() { showProjectPicker(create: false) }
  @objc private func newProject() { showProjectPicker(create: true) }
  private func chooseExistingProject() {
    guard newChatProject.isEnabled, let draftID = store.selectedDraft?.id else { return }
    projectSelection?.performClose(nil)
    let session = store.projectSessionID
    projectSelectionContext = (session, draftID)
    let popover = NSPopover()
    popover.behavior = .transient
    popover.contentViewController = ExistingProjectPicker(
      projects: Array(store.shell.projectDetails.values),
      selectedID: store.selectedDraft?.project["id"].string,
      choose: { [weak self] project in
        guard let self, session == store.projectSessionID, store.selectedID == draftID,
          store.canEditThread, !store.composerBusy,
          let id = project["id"].string, let current = store.shell.projectDetails[id]
        else { return }
        store.setDraftProject(current)
      }, openFolder: { [weak self] in self?.showProjectPicker(create: false) },
      close: { [weak self] in
        self?.projectSelection?.performClose(nil)
        self?.projectSelectionContext = nil
        self?.window?.makeFirstResponder(self?.composer)
      })
    popover.contentSize = NSSize(width: 400, height: 340)
    projectSelection = popover
    popover.show(relativeTo: newChatProject.bounds, of: newChatProject, preferredEdge: .maxY)
  }
  private func showProjectPicker(create: Bool) {
    guard let window, projectPicker == nil, store.ready && store.catalogReady else { return }
    projectPicker = ProjectPicker(
      store: store, create: create,
      opened: { [weak self] project, warning in
        guard let self, let id = project["id"].string else { return }
        showConversation()
        sidebar.selectProject(id)
        if store.isNewConversation {
          store.setDraftProject(project)
          if let warning { store.error = warning }
        } else {
          store.newThread(project: project, warning: warning)
        }
      }, closed: { [weak self] in self?.projectPicker = nil })
    projectPicker?.present(on: window)
  }
  @objc private func retry() {
    guard !reconnecting else { return }
    connectionAttempt = UUID()
    let attempt = connectionAttempt
    let session = store.usageSessionID
    reconnecting = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      defer { reconnecting = false }
      let validate: @MainActor () throws -> Void = {
        try Task.checkCancellation()
        guard self.connectionAttempt == attempt, self.store.usageSessionID == session else {
          throw CancellationError()
        }
      }
      do {
        let repository = try await ConnectionRepository(validating: validate)
        try validate()
        guard
          let saved = repository.values.environments.first(where: {
            $0.id == repository.values.selectedID
          }),
          saved.id == store.environmentKey || !store.hasConnection,
          saved.local || saved.cloudEnvironmentID != nil
        else {
          if store.hasConnection { store.retry() } else { connect() }
          return
        }
        let settings = try await repository.connectionForLaunch(validating: validate)
        try validate()
        if let settings { store.connect(settings) }
      } catch {
        guard connectionAttempt == attempt, store.usageSessionID == session,
          !(error is CancellationError)
        else { return }
        store.error = error.localizedDescription
        refresh()
      }
    }
  }

  @objc func connect() {
    let attempt = UUID()
    connectionAttempt = attempt
    let session = store.usageSessionID
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
      guard result == .alertFirstButtonReturn, let self,
        connectionAttempt == attempt, store.usageSessionID == session
      else { return }
      let address = endpoint.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      let credential = token.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      Task { @MainActor in
        do {
          guard let url = URL(string: address) else { throw T3Error("Invalid server address.") }
          let settings =
            pairing.state == .on
            ? try await EnvironmentHTTP.pair(endpoint: url, credential: credential)
            : try ConnectionSettings(endpoint: url, token: credential)
          try Task.checkCancellation()
          guard connectionAttempt == attempt, store.usageSessionID == session else { return }
          guard store.saveDraftsBeforeExit() else {
            throw T3Error(store.storageError ?? "Save the current drafts before switching servers.")
          }
          let validate: @MainActor () throws -> Void = {
            try Task.checkCancellation()
            guard self.connectionAttempt == attempt, self.store.usageSessionID == session else {
              throw CancellationError()
            }
          }
          try await Credentials.save(settings, validating: validate)
          try validate()
          store.connect(settings)
        } catch {
          guard connectionAttempt == attempt, store.usageSessionID == session,
            !(error is CancellationError)
          else { return }
          store.error = error.localizedDescription
          refresh()
        }
      }
    }
  }
}
