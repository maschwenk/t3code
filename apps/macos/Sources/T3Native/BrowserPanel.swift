import AppKit
import T3Core
import WebKit

@MainActor final class BrowserPanel: NSViewController {
  var onClose: (() -> Void)?
  var onAgentReveal: (() -> Void)?
  var onContextAdded: (() -> Void)?
  var onExpand: (() -> Void)?
  // Parent may use this for an artifact gallery/reveal UI. Attachment import stays in ClientStore.
  var onArtifactSaved: ((URL) -> Void)?
  private var annotationWindows: [BrowserAnnotationWindow] = []
  private var recordingPage: BrowserPage?
  private var lastArtifact: (file: URL, thread: String, connection: RPCConnection)?
  private var recordingOptions = BrowserRecordingOptions()
  var recordingActive: Bool { pages.values.contains { $0.recording.active } }
  var recordingSettings: BrowserRecordingOptions { recordingOptions }
  func configureRecording(_ options: BrowserRecordingOptions) throws {
    guard !recordingActive else {
      throw T3Error("Stop recording before changing recording options.")
    }
    try options.validate()
    recordingOptions = options
    render()
  }
  private let automationHost = BrowserAutomationHost()
  var agentPaused: Bool { automationHost.paused }
  func toggleAgentControl() {
    automationHost.setPaused(!automationHost.paused)
    if automationHost.paused { chromiumCommand("stop") }
  }
  let chromium = BrowserChromiumController()
  private var chromiumOpening = Set<String>()
  private var chromiumURLs: [String: String] = [:]
  func stopChromiumHelper() { chromium.stop() }
  func finishBeforeQuit(window: NSWindow?) async -> Bool {
    let wasPaused = automationHost.paused
    automationHost.setPaused(true)
    var allowed = false
    defer { if !allowed { automationHost.setPaused(wasPaused) } }
    let recordings = pages.values.filter { $0.recording.active }
    if !recordings.isEmpty {
      let alert = NSAlert()
      alert.messageText = "Browser recording is still running"
      alert.informativeText =
        "Save \(recordings.count) recording(s) before quitting, or discard them."
      alert.addButton(withTitle: "Save and quit")
      alert.addButton(withTitle: "Keep recording")
      alert.addButton(withTitle: "Discard recordings and quit")
      let result =
        if let window, window.isVisible { await alert.beginSheetModal(for: window) } else {
          alert.runModal()
        }
      if result == .alertSecondButtonReturn { return false }
      if result == .alertFirstButtonReturn {
        do { for page in recordings { _ = try await page.recording.finishForQuit() } } catch {
          NSAlert(error: error).runModal()
          return false
        }
      } else {
        for page in recordings { page.recording.cancel() }
      }
      recordingPage = nil
    }
    guard await downloads.finishBeforeQuit(window: window) else { return false }
    allowed = await chromium.finishBeforeQuit(window: window)
    return allowed
  }

  private let stopAgent = NSButton(title: "Stop agent", target: nil, action: nil)
  private var automationSurfaces: [String: BrowserAutomationSurface] = [:]
  private var automationMetadata: Task<Void, Never>?
  private let store: ClientStore
  private let profiles = BrowserProfiles()
  private let inputMonitor = BrowserInputMonitor()
  let downloads: BrowserDownloads
  private let downloadButton = NSButton()
  private var downloadsWindow: BrowserDownloadsWindow?
  let preferences: BrowserPreferences
  var opensLinksExternally: Bool { preferences.values.externalLinks }
  private var settingsWindow: BrowserSettingsWindow?
  private let profilePicker = NSPopUpButton(frame: .zero, pullsDown: true)
  private var profileMenuSignature = ""
  private let tabs = NSStackView()
  private let host = BrowserViewportView()
  private let devices = BrowserDeviceToolbar()
  private let deviceToggle = NSButton()
  private var lastViewports: [String: BrowserViewport] = [:]
  private let address = NSTextField()
  private let empty = NSStackView()
  private let footer = NSStackView()
  private let status = NSTextField(wrappingLabelWithString: "")
  private let back = NSButton()
  private let forward = NSButton()
  private let reload = NSButton()
  private let capture = NSButton()
  private let pick = NSButton()
  private let more = NSPopUpButton(frame: .zero, pullsDown: true)
  private let add = NSButton()
  private let retry = NSButton(title: "Retry", target: nil, action: nil)
  private var directory = BrowserDirectory(threadID: "")
  private var connection: RPCConnection?
  private var endpoint: URL?
  private var threadID: String?
  private var pages: [String: BrowserPage] = [:]
  private var selections: [String: String] = [:]
  private var selectedID: String?
  private var shownPage: BrowserPage?
  private var metadata: Task<Void, Never>?
  private var discovery: Task<Void, Never>?
  private var operation: Task<Void, Never>?
  private var generation = UUID()
  private var active = false
  private var loading = false
  private var busy = false
  private var error: String?
  private var discoveryError: String?
  private var servers: [BrowserLocalServer] = []
  private var renderedTabs: [String] = []
  private var renderedEmpty = ""
  private var addressSelection: String?
  private var pendingOpen: (text: String?, newTab: Bool, profile: String?)?
  private var focusWhenReady = false

  init(
    store: ClientStore, preferences: BrowserPreferences? = nil, downloads: BrowserDownloads? = nil
  ) {
    self.store = store
    self.preferences = preferences ?? BrowserPreferences()
    self.downloads = downloads ?? BrowserDownloads()
    super.init(nibName: nil, bundle: nil)
    self.preferences.onChange = { [weak self] in self?.render() }
    self.downloads.onChange = { [weak self] in self?.render() }
    chromium.onChange = { [weak self] in self?.render() }
    chromium.onEvent = { [weak self] event, value in self?.chromiumEvent(event, value: value) }

    automationHost.handle = { [weak self] request, deadline in
      guard let self else { throw BrowserAutomationError.interrupted }
      return try await self.automate(request, deadline: deadline)
    }
    automationHost.liveTabs = { [weak self] in
      guard let self else { return [] }
      let chromiumTabs = self.chromium.pages.values.map { value in
        JSON.object([
          "threadId": value["threadId"], "tabId": value["tabId"], "visible": value["visible"],
        ])
      }
      return chromiumTabs
        + self.pages.values.map { page in
          .object([
            "threadId": .string(page.threadID), "tabId": .string(page.tabID),
            "visible": .bool(page.web.window?.isVisible == true && !page.web.isHidden),
          ])
        }
    }
    automationHost.onChange = { [weak self] in self?.render() }
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  isolated deinit {
    detach()
    chromium.stop()
    automationMetadata?.cancel()
    automationHost.synchronize(connection: nil, environmentID: nil)
    for surface in automationSurfaces.values { surface.close() }
    for page in pages.values { page.dispose() }
  }

  override func loadView() {
    view = SurfaceView()
    tabs.orientation = .horizontal
    tabs.spacing = 4
    let tabScroll = NSScrollView()
    tabScroll.drawsBackground = false
    tabScroll.hasHorizontalScroller = true
    tabScroll.autohidesScrollers = true
    tabScroll.documentView = tabs
    tabs.translatesAutoresizingMaskIntoConstraints = false
    tabs.leadingAnchor.constraint(equalTo: tabScroll.contentView.leadingAnchor).isActive = true
    tabs.topAnchor.constraint(equalTo: tabScroll.contentView.topAnchor).isActive = true
    tabs.heightAnchor.constraint(equalToConstant: 30).isActive = true
    configure(add, symbol: "plus", label: "New browser tab", action: #selector(newTab))
    let expand = NSButton()
    configure(
      expand, symbol: "arrow.up.left.and.arrow.down.right", label: "Expand browser",
      action: #selector(expandPanel))
    let close = NSButton()
    configure(close, symbol: "xmark", label: "Hide browser", action: #selector(hidePanel))
    profilePicker.bezelStyle = .inline
    profilePicker.setAccessibilityLabel("Browser profiles")
    configure(
      downloadButton, symbol: "arrow.down.circle", label: "Browser downloads",
      action: #selector(showDownloads))
    let top = NSStackView(views: [tabScroll, add, profilePicker, downloadButton, expand, close])
    top.spacing = 6
    configure(back, symbol: "arrow.left", label: "Back", action: #selector(goBack))
    configure(forward, symbol: "arrow.right", label: "Forward", action: #selector(goForward))
    configure(reload, symbol: "arrow.clockwise", label: "Reload", action: #selector(reloadPage))
    configure(
      capture, symbol: "camera", label: "Attach browser screenshot", action: #selector(capturePage))
    configure(
      pick, symbol: "cursorarrow.click.2", label: "Select element for message",
      action: #selector(togglePicker))
    address.placeholderString = "Search or enter URL"
    address.font = .systemFont(ofSize: 13)
    address.isBezeled = false
    address.drawsBackground = false
    address.target = self
    address.action = #selector(submitAddress)
    address.setAccessibilityLabel("Browser address")
    address.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    more.bezelStyle = .inline
    more.setAccessibilityLabel("Browser actions")
    configure(
      deviceToggle, symbol: "rectangle.on.rectangle", label: "Toggle device toolbar",
      action: #selector(toggleDevices))
    devices.onChange = { [weak self] in self?.resize($0) }
    devices.onError = { [weak self] message in
      self?.error = message
      self?.render()
    }
    let navigation = NSStackView(views: [
      back, forward, reload, address, pick, capture, deviceToggle, more,
    ])
    navigation.spacing = 7
    let divider = NSBox()
    divider.boxType = .separator
    status.font = .systemFont(ofSize: 11)
    status.textColor = .secondaryLabelColor
    status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    retry.target = self
    retry.action = #selector(retryBrowser)
    retry.bezelStyle = .inline
    footer.addArrangedSubview(status)
    footer.addArrangedSubview(retry)
    stopAgent.target = self
    stopAgent.action = #selector(toggleAgent)
    stopAgent.bezelStyle = .inline
    footer.addArrangedSubview(stopAgent)
    footer.setContentHuggingPriority(.required, for: .vertical)
    status.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let stack = NSStackView(views: [top, navigation, divider, devices, host, footer])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    view.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
      stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
      stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 42),
      stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
      tabScroll.heightAnchor.constraint(equalToConstant: 30),
      host.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),
      address.widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
      more.widthAnchor.constraint(equalToConstant: 28),
      profilePicker.widthAnchor.constraint(equalToConstant: 28),
    ])
    for child in [top, navigation, divider, devices, host, footer] {
      child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    empty.orientation = .vertical
    empty.alignment = .centerX
    empty.spacing = 15
    host.addSubview(empty)
    empty.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      empty.centerXAnchor.constraint(equalTo: host.centerXAnchor),
      empty.topAnchor.constraint(equalTo: host.topAnchor, constant: 55),
      empty.widthAnchor.constraint(lessThanOrEqualTo: host.widthAnchor, constant: -30),
      empty.widthAnchor.constraint(lessThanOrEqualToConstant: 500),
    ])
    render()
    buildMenu()
  }

  private func configure(_ button: NSButton, symbol: String, label: String, action: Selector) {
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
    button.imagePosition = .imageOnly
    button.bezelStyle = .inline
    button.isBordered = false
    button.target = self
    button.action = action
    button.toolTip = label
    button.setAccessibilityLabel(label)
    button.widthAnchor.constraint(equalToConstant: 24).isActive = true
  }

  func refresh(active: Bool) {
    _ = view
    let nextConnection = store.browserConnection
    let nextThread = store.selectedID
    automationHost.synchronize(
      connection: nextConnection, environmentID: store.browserEnvironmentID)
    let contextChanged =
      connection !== nextConnection || threadID != nextThread || self.active != active
    guard contextChanged else {
      render()
      return
    }
    if connection !== nextConnection {
      chromium.stop()
      chromiumOpening = []
      chromiumURLs = [:]
      recordingPage?.recording.cancel()
      recordingPage = nil
    }
    if connection !== nextConnection {
      automationMetadata?.cancel()
      automationMetadata = nil
      for surface in automationSurfaces.values { surface.close() }
      automationSurfaces = [:]
      for page in pages.values {
        page.dispose()
        page.web.removeFromSuperview()
      }
      pages = [:]
      shownPage = nil
    }
    detach()
    self.active = active
    connection = nextConnection
    chromium.environmentID = store.browserEnvironmentID
    endpoint = store.browserEndpoint
    if automationMetadata == nil, let nextConnection { watchAutomationTabs(nextConnection) }
    threadID = nextThread
    shownPage?.picker.cancel()
    let detachedPage = shownPage
    host.show(nil)
    shownPage = nil
    retainDetachedPage(detachedPage)
    empty.isHidden = false
    directory = BrowserDirectory(threadID: nextThread ?? "")
    selectedID = nextThread.flatMap { selections[$0] }
    error = nil
    discoveryError = nil
    servers = []
    render()
    guard active, let connection, let threadID else { return }
    subscribe(connection: connection, threadID: threadID)
  }

  private func detach() {
    generation = UUID()
    metadata?.cancel()
    metadata = nil
    discovery?.cancel()
    discovery = nil
    operation?.cancel()
    operation = nil
    loading = false
    busy = false
    pendingOpen = nil
  }
  private func key(_ tabID: String, thread: String) -> String { thread + "\n" + tabID }
  private var page: BrowserPage? {
    guard let threadID, let selectedID else { return nil }
    return pages[key(selectedID, thread: threadID)]
  }

  private func subscribe(connection: RPCConnection, threadID: String) {
    let generation = generation
    loading = true
    metadata = Task { [weak self] in
      guard let self else { return }
      do {
        let stream = try await connection.subscribe("subscribePreviewEvents")
        defer { Task { await connection.cancel(stream.id) } }
        // The stream buffers events while the list is in flight; revisions reject list-era events.
        let result = try await connection.call(
          "preview.list", payload: .object(["threadId": .string(threadID)]))
        try Task.checkCancellation()
        guard self.generation == generation else { return }
        try directory.snapshot(result)
        loading = false
        reconcile()
        if focusWhenReady { focusAddress() }
        if let request = pendingOpen {
          pendingOpen = nil
          open(request.text, newTab: request.newTab, profile: request.profile)
        }
        for try await event in stream.values {
          try Task.checkCancellation()
          guard self.generation == generation else { return }
          if try directory.apply(event) { reconcile() }
        }
        throw T3Error("Browser updates ended. Retry to reconnect.")
      } catch {
        guard !Task.isCancelled, self.generation == generation else { return }
        loading = false
        self.error = error.localizedDescription
        render()
      }
    }
    discovery = Task { [weak self] in
      guard let self else { return }
      do {
        let stream = try await connection.subscribe("subscribeDiscoveredLocalServers")
        defer { Task { await connection.cancel(stream.id) } }
        for try await value in stream.values {
          try Task.checkCancellation()
          guard self.generation == generation else { return }
          let servers = value["servers"].array.compactMap(BrowserLocalServer.init).sorted {
            if ($0.threadID == threadID) != ($1.threadID == threadID) {
              return $0.threadID == threadID
            }
            return ($0.url.port ?? 0) < ($1.url.port ?? 0)
          }
          if self.servers != servers {
            self.servers = servers
            renderEmpty()
          }
        }
      } catch {
        guard !Task.isCancelled, self.generation == generation else { return }
        discoveryError = "Local-server discovery: " + error.localizedDescription
        render()
      }
    }
  }

  private func reconcile() {
    guard let threadID else { return }
    let live = Set(directory.tabs.map(\.id))
    for (key, page) in pages where page.threadID == threadID && !live.contains(page.tabID) {
      page.dispose()
      page.web.removeFromSuperview()
      pages.removeValue(forKey: key)
    }
    if !chromium.enabled {
      for tab in directory.tabs { pages[key(tab.id, thread: threadID)]?.receive(tab) }
    }
    if selectedID == nil || !live.contains(selectedID!) { selectedID = directory.tabs.first?.id }
    selections[threadID] = selectedID
    showSelected()
    render()
  }

  private func showSelected() {
    guard active, let threadID, let connection, let endpoint,
      let tab = directory.tabs.first(where: { $0.id == selectedID })
    else {
      shownPage?.picker.cancel()
      let previous = shownPage
      host.show(nil)
      shownPage = nil
      retainDetachedPage(previous)
      empty.isHidden = false
      return
    }
    if chromium.enabled {
      shownPage?.picker.cancel()
      host.show(nil)
      shownPage = nil
      empty.isHidden = false
      handoffChromium(tab, connection: connection, endpoint: endpoint)
      return
    }
    let key = key(tab.id, thread: threadID)
    let page: BrowserPage
    if let existing = pages[key] {
      page = existing
    } else {
      page = makePage(tab, connection: connection, endpoint: endpoint)
    }
    if shownPage !== page {
      shownPage?.picker.cancel()
      let previous = shownPage
      host.show(nil)
      retainDetachedPage(previous)
      shownPage = page
      automationSurfaces[key]?.viewport.show(nil)
      automationSurfaces[key]?.window.orderOut(nil)
      host.show(page.web)
    }
    page.receive(tab)
    page.web.isHidden = tab.url == nil && page.web.url == nil
    empty.isHidden = !page.web.isHidden
  }

  private func retainDetachedPage(_ page: BrowserPage?) {
    guard let page else { return }
    let key = key(page.tabID, thread: page.threadID)
    guard page.activeAutomation > 0 || automationSurfaces[key] != nil else { return }
    let surface = automationSurfaces[key] ?? BrowserAutomationSurface()
    automationSurfaces[key] = surface
    surface.onStop = { [weak self] in self?.automationHost.setPaused(true) }
    surface.attach(page, show: false, title: "Browser")
  }

  private func makePage(_ tab: BrowserTab, connection: RPCConnection, endpoint: URL) -> BrowserPage
  {
    let page = BrowserPage(
      tab: tab, environment: endpoint, connection: connection,
      dataStore: profiles.dataStore(profile: tab.profileID))
    page.web.pageZoom = preferences.values.zoom
    page.web.appearance =
      preferences.values.appearance == "system"
      ? nil
      : NSAppearance(named: preferences.values.appearance == "dark" ? .darkAqua : .aqua)
    pages[key(tab.id, thread: tab.threadID)] = page
    inputMonitor.register(page)
    page.onHumanInput = { [weak self, weak page] in
      guard let self, let page else { return }
      automationHost.interrupt(threadID: page.threadID)
    }
    page.onDownload = { [weak downloads] download, agent, window in
      downloads?.receive(download, agent: agent, window: window)
    }
    page.picker.onChange = { [weak self] in self?.render() }
    page.picker.onError = { [weak self] message in
      self?.error = message
      self?.render()
    }
    page.picker.onSelection = { [weak self, weak page] context in
      guard let self, let page, self.shownPage === page, self.active,
        self.store.selectedID == page.threadID, self.connection === self.store.browserConnection
      else { return }
      self.store.addBrowserContext(context)
      self.onContextAdded?()
    }
    page.onChange = { [weak self] in
      guard let self, store.browserConnection === connection else { return }
      render()
    }
    page.recording.onChange = { [weak self, weak page] in
      guard let self, let page else { return }
      if case .saved(let file) = page.recording.state,
        self.connection === connection, store.browserConnection === connection,
        lastArtifact?.file != file
      {
        lastArtifact = (file, page.threadID, connection)
        onArtifactSaved?(file)
      }
      render()
    }
    page.onNewTab = { [weak self, weak page] url in
      guard let self, let page else { return }
      if !page.agentDriven, self.threadID == page.threadID, self.active, self.shownPage === page {
        self.open(url.absoluteString, newTab: true, profile: tab.profileID)
      } else {
        self.openBackgroundPopup(url, from: page)
      }
    }
    return page
  }

  private func render() {
    guard isViewLoaded else { return }
    renderProfiles()
    if chromium.nativeRecordingActive != recordingActive {
      chromium.nativeRecordingActive = recordingActive
    }
    let downloadError = downloads.items.first?.error
    downloadButton.toolTip =
      downloads.activeCount > 0
      ? "\(downloads.activeCount) downloads in progress" : downloadError ?? "Browser downloads"
    downloadButton.image = NSImage(
      systemSymbolName: downloads.activeCount > 0
        ? "arrow.down.circle.fill"
        : downloadError == nil ? "arrow.down.circle" : "exclamationmark.circle",
      accessibilityDescription: "Browser downloads")
    automationHost.refreshFocus()
    let tabLabels = directory.tabs.map { tab in
      return tab.id + "\n" + tabTitle(tab)
        + "\n" + (tab.url?.absoluteString ?? "")
        + (tab.id == selectedID ? "\nselected" : "")
    }
    if renderedTabs != tabLabels || tabs.arrangedSubviews.isEmpty {
      renderedTabs = tabLabels
      for child in tabs.arrangedSubviews {
        tabs.removeArrangedSubview(child)
        child.removeFromSuperview()
      }
      if directory.tabs.isEmpty {
        let label = NSTextField(labelWithString: "◎ Browser")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        tabs.addArrangedSubview(label)
      }
      for tab in directory.tabs {
        let title = tabTitle(tab)
        let select = ActionButton(title) { [weak self] in self?.select(tab.id) }
        select.bezelStyle = .inline
        select.state = tab.id == selectedID ? .on : .off
        select.toolTip = tab.url?.absoluteString ?? "Empty browser tab"
        select.lineBreakMode = .byTruncatingTail
        select.widthAnchor.constraint(lessThanOrEqualToConstant: 165).isActive = true
        let close = ActionButton("×") { [weak self] in self?.close(tab.id) }
        close.bezelStyle = .inline
        close.setAccessibilityLabel("Close " + title)
        tabs.addArrangedSubview(NSStackView(views: [select, close]))
      }
    }
    let page = page
    let viewport = (try? BrowserViewport(page?.snapshot.viewport ?? .null)) ?? .fill
    host.setting = viewport
    devices.render(viewport, enabled: !loading && !busy && page != nil)
    deviceToggle.isEnabled = page != nil && !loading && !busy
    deviceToggle.state = viewport.width == nil ? .off : .on
    let selectedChanged = addressSelection != selectedID
    addressSelection = selectedID
    if selectedChanged || address.currentEditor() == nil {
      address.stringValue =
        page?.displayedURL?.absoluteString ?? directory.tabs.first { $0.id == selectedID }?.url?
        .absoluteString ?? ""
    }
    address.isEnabled = connection != nil && threadID != nil && !loading && !busy
    add.isEnabled = address.isEnabled
    profilePicker.isEnabled = address.isEnabled
    back.isEnabled = page?.web.canGoBack == true
    forward.isEnabled = page?.web.canGoForward == true
    reload.isEnabled = page?.web.url != nil || page?.snapshot.url != nil
    reload.image = NSImage(
      systemSymbolName: page?.web.isLoading == true ? "xmark" : "arrow.clockwise",
      accessibilityDescription: page?.web.isLoading == true ? "Stop loading" : "Reload")
    pick.isEnabled =
      page?.web.url != nil && page?.failure == nil && page?.web.isLoading == false
      && store.canAddBrowserContext
    pick.state = page?.picker.active == true ? .on : .off
    pick.toolTip =
      page?.picker.active == true
      ? "Cancel element selection (Escape)" : "Select element for message"
    capture.isEnabled =
      page?.web.url != nil && page?.failure == nil && page?.web.isLoading == false
      && store.canAttach
    if chromium.enabled {
      pick.isEnabled = false
      deviceToggle.isEnabled = false
      capture.isEnabled = selectedID != nil && chromium.running && store.canAttach
      back.isEnabled = selectedID != nil && chromium.running
      forward.isEnabled = back.isEnabled
      reload.isEnabled = back.isEnabled
    }
    let message =
      error ?? chromium.error ?? page?.failure ?? page?.synchronizationError ?? discoveryError
      ?? automationHost.error
    stopAgent.isHidden = automationHost.running == 0 && !automationHost.paused
    stopAgent.title = automationHost.paused ? "Resume agent browser" : "Stop agent"
    status.stringValue =
      message
      ?? (chromium.enabled ? chromium.state + " · " + chromium.passwordStatus : nil)
      ?? (automationHost.paused
        ? "Agent browser control paused"
        : automationHost.running > 0 ? "Agent is using Browser…" : nil)
      ?? (page?.picker.active == true
        ? "Click an element to add it to your message. Escape cancels." : nil)
      ?? (recordingPage?.recording.active == true
        ? "Recording Browser · \(recordingOptions.framesPerSecond) fps target · stop to save" : nil)
      ?? (loading
        ? "Loading browser tabs…"
        : connection == nil
          ? "Connect to use Browser"
          : threadID == nil
            ? "Select a conversation to use Browser"
            : page?.web.isLoading == true ? "Loading…" : "")
    status.isHidden = status.stringValue.isEmpty
    retry.isHidden = message == nil
    footer.isHidden = status.isHidden && retry.isHidden && stopAgent.isHidden
    renderEmpty()
  }

  private func tabTitle(_ tab: BrowserTab) -> String {
    let loaded = pages[key(tab.id, thread: tab.threadID)]?.web.title ?? ""
    return (tab.profileID == "incognito" ? "Private · " : "")
      + (loaded.isEmpty ? tab.title : loaded)
  }

  private func renderEmpty() {
    let signature =
      servers.map(\.id).joined(separator: "\n")
      + "\n\(connection != nil):\(loading):\(chromium.enabled):\(chromium.state)"
    guard signature != renderedEmpty || empty.arrangedSubviews.isEmpty else { return }
    renderedEmpty = signature
    for child in empty.arrangedSubviews {
      empty.removeArrangedSubview(child)
      child.removeFromSuperview()
    }
    let icon = NSImageView(
      image: NSImage(systemSymbolName: "globe", accessibilityDescription: nil)!)
    icon.contentTintColor = .secondaryLabelColor
    icon.heightAnchor.constraint(equalToConstant: 40).isActive = true
    let title = NSTextField(
      labelWithString: chromium.enabled ? "1Password Browser" : "No preview yet")
    title.font = .systemFont(ofSize: 22, weight: .semibold)
    let detail = NSTextField(
      wrappingLabelWithString:
        chromium.enabled
        ? "The live Chromium page and 1Password popup run in a managed floating window. Cookies stay in its selected profile."
        : "Type a URL above, or run a dev script. Browser-ready localhost servers will show up here automatically."
    )
    detail.font = .systemFont(ofSize: 13)
    detail.textColor = .secondaryLabelColor
    detail.alignment = .center
    for child in [icon, title, detail] { empty.addArrangedSubview(child) }
    detail.widthAnchor.constraint(lessThanOrEqualTo: host.widthAnchor, constant: -48).isActive =
      true
    if chromium.enabled {
      for (label, action) in [
        ("Reveal page", #selector(revealChromiumBrowser)),
        ("1Password", #selector(openChromiumPassword)),
        ("Close page", #selector(closeChromiumPage)),
        ("Stop helper", #selector(stopChromium)),
      ] {
        let button = NSButton(title: label, target: self, action: action)
        button.bezelStyle = .inline
        empty.addArrangedSubview(button)
      }
    }
    for server in servers.prefix(8) {
      let button = ActionButton(server.process + " · " + server.url.absoluteString) { [weak self] in
        self?.open(server.url.absoluteString)
      }
      button.bezelStyle = .inline
      button.lineBreakMode = .byTruncatingMiddle
      empty.addArrangedSubview(button)
      button.widthAnchor.constraint(lessThanOrEqualTo: host.widthAnchor, constant: -48).isActive =
        true
    }
  }

  func focusAddress() {
    focusWhenReady = loading
    guard !loading else { return }
    view.window?.makeFirstResponder(address)
    address.selectText(nil)
  }
  private func select(_ id: String) {
    selectedID = id
    if let threadID { selections[threadID] = id }
    showSelected()
    render()
  }
  @objc func newTab() { open(nil, newTab: true) }
  @objc private func submitAddress() { open(address.stringValue) }
  func open(_ text: String?, newTab: Bool = false, profile: String? = nil) {
    guard let connection, let threadID, active, !busy else { return }
    if loading {
      pendingOpen = (text, newTab, profile)
      return
    }
    let url: URL?
    do {
      if let text {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Search terms use the same explicit address submission as a URL; no keystroke suggestions leave the app.
        if text.contains(where: { $0.isWhitespace }), !text.contains("://") {
          var search = URLComponents(string: "https://www.google.com/search")!
          search.queryItems = [URLQueryItem(name: "q", value: text)]
          url = search.url
        } else {
          url = try BrowserURL.normalize(text)
        }
        if let url, let endpoint { _ = try BrowserURL.resolve(url, environment: endpoint) }
      } else {
        url = nil
      }
    } catch {
      self.error = error.localizedDescription
      render()
      return
    }
    let tab = newTab ? nil : selectedID
    if tab != nil { page?.takeControl() }
    var input: [String: JSON] = ["threadId": .string(threadID)]
    if let tab { input["tabId"] = .string(tab) }
    if let url { input["url"] = .string(url.absoluteString) }
    if tab == nil {
      input["profileId"] = .string(profile ?? preferences.values.defaultProfileID)
      input["viewport"] = preferences.values.viewport
    }
    mutate(tab == nil ? "preview.open" : "preview.navigate", input: input, connection: connection) {
      [weak self] result in
      guard let self, let id = result["tabId"].string else { return }
      self.selectedID = id
      self.selections[threadID] = id
    }
  }

  private func close(_ id: String) {
    guard let connection, let threadID else { return }
    pages[key(id, thread: threadID)]?.takeControl()
    mutate(
      "preview.close", input: ["threadId": .string(threadID), "tabId": .string(id)],
      connection: connection)
  }
  private func mutate(
    _ method: String, input: [String: JSON], connection: RPCConnection,
    completed: ((JSON) -> Void)? = nil
  ) {
    guard !busy, let threadID else { return }
    let generation = generation
    busy = true
    error = nil
    render()
    operation = Task { [weak self] in
      guard let self else { return }
      defer {
        if self.generation == generation {
          busy = false
          operation = nil
          render()
          if method == "preview.open", input["url"] == nil {
            focusAddress()
          } else if self.error == nil, method == "preview.open" || method == "preview.navigate",
            let page
          {
            view.window?.makeFirstResponder(page.web)
          }
        }
      }
      do {
        let result = try await connection.call(method, payload: .object(input))
        try Task.checkCancellation()
        guard self.generation == generation else { return }
        if method == "preview.navigate", let tab = try? BrowserTab(result), tab.id == selectedID {
          // Explicit navigation must not be mistaken for an old status echo after a failed load.
          page?.receive(tab, navigate: true)
        }
        completed?(result)
        let snapshot = try await connection.call(
          "preview.list", payload: .object(["threadId": .string(threadID)]))
        try Task.checkCancellation()
        guard self.generation == generation else { return }
        try directory.snapshot(snapshot)
        reconcile()
      } catch {
        guard !Task.isCancelled, self.generation == generation else { return }
        self.error = error.localizedDescription
      }
    }
  }

  private func buildMenu() {
    more.removeAllItems()
    more.addItem(withTitle: "•••")
    for (title, action) in [
      ("Use 1Password Browser", #selector(useChromiumBrowser)),
      ("Use Native Browser", #selector(useNativeBrowser)),
      ("Reveal 1Password Browser", #selector(revealChromiumBrowser)),
      ("Open 1Password Popup", #selector(openChromiumPassword)),
      ("Install Official 1Password Extension", #selector(installChromiumPassword)),
      ("Import 1Password From Browser…", #selector(importChromiumPassword)),
      ("Close Chromium Page", #selector(closeChromiumPage)),
      ("Stop Chromium Helper", #selector(stopChromium)),
      ("Start Recording", #selector(startRecording)),
      ("Stop Recording and Save", #selector(stopRecording)),
      ("Cancel Recording", #selector(cancelRecording)),
      ("Recording: 30 fps", #selector(recordAt30)),
      ("Recording: 60 fps", #selector(recordAt60)),
      ("Toggle Mouse Overlay", #selector(toggleRecordingMouse)),
      ("Toggle Key Overlay", #selector(toggleRecordingKeys)),
      ("Annotate Screenshot…", #selector(annotatePage)),
      ("Attach Last Saved Artifact", #selector(attachLastArtifact)),
      ("Show Saved Browser Artifacts", #selector(showArtifacts)),
      ("Open in Default Browser", #selector(openExternal)),
      ("Reload Without Cache", #selector(hardReload)), ("Zoom In", #selector(zoomIn)),
      ("Zoom Out", #selector(zoomOut)), ("Actual Size", #selector(resetZoom)),
      ("New Private Tab", #selector(newPrivateTab)),
      ("Clear Profile Cookies…", #selector(clearProfileCookies)),
      ("Clear Profile Cache…", #selector(clearProfileCache)),
      ("Browser Settings…", #selector(showBrowserSettings)),
      ("Downloads…", #selector(showDownloads)),
    ] {
      more.addItem(withTitle: title)
      more.lastItem?.target = self
      more.lastItem?.action = action
    }
  }
  private func renderProfiles() {
    let current = page?.snapshot.profileID ?? preferences.values.defaultProfileID
    let signature =
      String(describing: preferences.values.availableProfiles) + current
      + preferences.values.defaultProfileID
    guard signature != profileMenuSignature else { return }
    profileMenuSignature = signature
    profilePicker.removeAllItems()
    profilePicker.addItem(withTitle: "")
    profilePicker.item(at: 0)?.image = NSImage(
      systemSymbolName: "person.crop.circle", accessibilityDescription: nil)
    profilePicker.toolTip = "Profile: " + preferences.name(current)
    let heading = NSMenuItem(title: "New tab with profile", action: nil, keyEquivalent: "")
    heading.isEnabled = false
    profilePicker.menu?.addItem(heading)
    for profile in preferences.values.availableProfiles {
      let item = NSMenuItem(
        title: profile.name, action: #selector(openProfile(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = profile.id
      item.state = profile.id == current ? .on : .off
      profilePicker.menu?.addItem(item)
    }
    profilePicker.menu?.addItem(.separator())
    let manage = NSMenuItem(
      title: "Manage Profiles…", action: #selector(showBrowserSettings), keyEquivalent: "")
    manage.target = self
    profilePicker.menu?.addItem(manage)
  }
  @objc private func openProfile(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? String else { return }
    open(nil, newTab: true, profile: id)
  }
  @objc func showBrowserSettings() {
    if settingsWindow == nil {
      settingsWindow = BrowserSettingsWindow(
        preferences: preferences, profiles: profiles, chromium: chromium,
        onModeChange: { [weak self] in self?.chromiumModeChanged() })
    }
    settingsWindow?.showWindow(nil)
    settingsWindow?.window?.makeKeyAndOrderFront(nil)
  }
  @objc func showDownloads() {
    if downloadsWindow == nil { downloadsWindow = BrowserDownloadsWindow(downloads: downloads) }
    downloadsWindow?.showWindow(nil)
    downloadsWindow?.window?.makeKeyAndOrderFront(nil)
  }
  @objc private func clearProfileCookies() { clearProfile(.cookies) }
  @objc private func clearProfileCache() { clearProfile(.cache) }
  private func clearProfile(_ kinds: BrowserProfiles.DataKinds) {
    guard let window = view.window,
      let tab = directory.tabs.first(where: { $0.id == selectedID })
    else { return }
    let profile = tab.profileID
    let alert = NSAlert()
    alert.messageText =
      kinds == .cookies
      ? "Clear cookies for \(preferences.name(profile))?"
      : "Clear cache for \(preferences.name(profile))?"
    alert.informativeText =
      kinds == .cookies
      ? "This signs you out of websites in this profile."
      : "Websites in this profile will download fresh copies of cached content."
    alert.addButton(withTitle: "Clear")
    alert.addButton(withTitle: "Cancel")
    Task { [weak self] in
      guard let self, await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else {
        return
      }
      do {
        if chromium.enabled {
          try await chromium.clearProfile(profile ?? "default", kinds: kinds)
        } else {
          await profiles.clear(profile: profile, kinds: kinds)
        }
      } catch {
        self.error = error.localizedDescription
        render()
      }
    }
  }
  @objc private func toggleAgent() { toggleAgentControl() }
  @objc private func togglePicker() {
    guard let page, store.canAddBrowserContext else { return }
    page.takeControl()
    if page.picker.active { page.picker.cancel() } else { page.picker.start() }
  }
  func resize(_ viewport: BrowserViewport) {
    guard let connection, let threadID, let selectedID else { return }
    page?.takeControl()
    let key = key(selectedID, thread: threadID)
    mutate(
      "preview.resize",
      input: [
        "threadId": .string(threadID), "tabId": .string(selectedID),
        "viewport": viewport.json,
      ], connection: connection
    ) { [weak self] _ in
      if viewport.width != nil { self?.lastViewports[key] = viewport }
    }
  }
  @objc private func toggleDevices() {
    guard let page else { return }
    if host.setting.width != nil {
      resize(.fill)
      return
    }
    let previous = lastViewports[key(page.tabID, thread: page.threadID)]
    let width = min(3840, max(240, Int(host.bounds.width / page.web.pageZoom)))
    let height = min(2160, max(240, Int((host.bounds.height - 42) / page.web.pageZoom)))
    resize(
      previous ?? (try? BrowserViewport(width: width, height: height))
        ?? BrowserDevicePreset.all[0].viewport)
  }
  @objc private func goBack() {
    if chromium.enabled {
      chromiumCommand("back")
      return
    }
    page?.takeControl()
    page?.web.goBack()
  }
  @objc private func goForward() {
    if chromium.enabled {
      chromiumCommand("forward")
      return
    }
    page?.takeControl()
    page?.web.goForward()
  }
  @objc private func reloadPage() {
    if chromium.enabled {
      chromiumCommand("reload")
      return
    }
    page?.takeControl()
    if page?.web.isLoading == true { page?.web.stopLoading() } else { page?.reload() }
  }
  @objc private func hardReload() {
    if chromium.enabled {
      chromiumCommand("reload")
      return
    }
    page?.takeControl()
    page?.reload(hard: true)
  }
  @objc private func zoomIn() {
    if chromium.enabled {
      chromiumCommand("zoom", extra: ["delta": .number(0.1)])
      return
    }
    page?.takeControl()
    if let web = page?.web {
      web.pageZoom = min(5, web.pageZoom + 0.1)
      host.needsLayout = true
    }
  }
  @objc private func zoomOut() {
    if chromium.enabled {
      chromiumCommand("zoom", extra: ["delta": .number(-0.1)])
      return
    }
    page?.takeControl()
    if let web = page?.web {
      web.pageZoom = max(0.25, web.pageZoom - 0.1)
      host.needsLayout = true
    }
  }
  @objc private func resetZoom() {
    if chromium.enabled {
      chromiumCommand("zoom", extra: ["factor": .number(1)])
      return
    }
    page?.takeControl()
    page?.web.pageZoom = 1
    host.needsLayout = true
  }
  @objc private func newPrivateTab() { open(nil, newTab: true, profile: "incognito") }
  @objc private func openExternal() {
    if let url = page?.web.url, ["http", "https"].contains(url.scheme ?? "") {
      NSWorkspace.shared.open(url)
    }
  }
  @objc private func hidePanel() { onClose?() }
  @objc private func expandPanel() { onExpand?() }
  @objc private func retryBrowser() {
    if automationHost.error != nil { automationHost.retry() }
    if error != nil || discoveryError != nil {
      self.active = false
      refresh(active: true)
    } else {
      page?.reload()
    }
  }
  @objc func startRecording() {
    guard let page, let connection, store.browserConnection === connection, !recordingActive else {
      return
    }
    recordingPage = page
    let options = recordingOptions
    Task { [weak self, weak page] in
      guard let self, let page else { return }
      do {
        try await page.recording.start(options: options, directory: BrowserArtifacts.directory) {
          [weak page] options in
          guard let page else { throw CancellationError() }
          return try await page.captureImage(
            mouse: options.showMouse, keys: options.showKeys, deterministic: false)
        }
        guard self.connection === connection, store.browserConnection === connection,
          recordingPage === page
        else {
          page.recording.cancel()
          return
        }
      } catch {
        guard self.connection === connection, store.browserConnection === connection,
          recordingPage === page
        else { return }
        self.error = error.localizedDescription
        render()
      }
    }
  }
  @objc func stopRecording() {
    guard let page = recordingPage, let connection else { return }
    Task { [weak self] in
      guard let self else { return }
      do {
        let file = try await page.recording.stop()
        guard self.connection === connection, store.browserConnection === connection,
          recordingPage === page
        else { return }
        recordingPage = nil
        lastArtifact = (file, page.threadID, connection)
        render()
      } catch {
        guard self.connection === connection, store.browserConnection === connection,
          recordingPage === page
        else { return }
        self.error = error.localizedDescription
        render()
      }
    }
  }
  @objc func cancelRecording() {
    recordingPage?.recording.cancel()
    recordingPage = nil
    render()
  }
  @objc private func recordAt30() { recordingOptions.framesPerSecond = 30 }
  @objc private func recordAt60() { recordingOptions.framesPerSecond = 60 }
  @objc private func toggleRecordingMouse() { recordingOptions.showMouse.toggle() }
  @objc private func toggleRecordingKeys() { recordingOptions.showKeys.toggle() }
  @objc func showArtifacts() {
    do {
      try FileManager.default.createDirectory(
        at: BrowserArtifacts.directory,
        withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      if !NSWorkspace.shared.open(BrowserArtifacts.directory) {
        throw T3Error("Could not open saved browser artifacts.")
      }
    } catch {
      self.error = error.localizedDescription
      render()
    }
  }
  @objc func attachLastArtifact() {
    guard let artifact = lastArtifact, store.selectedID == artifact.thread,
      store.browserConnection === artifact.connection, store.canAttach
    else { return }
    store.addAttachments([artifact.file])
    onContextAdded?()
  }
  @objc func annotatePage() {
    if chromium.enabled {
      captureChromium(annotate: true)
      return
    }
    guard let page, let connection, store.browserConnection === connection else { return }
    let thread = page.threadID
    Task { [weak self] in
      guard let self else { return }
      do {
        let image = try await page.captureImage()
        guard store.selectedID == thread, store.browserConnection === connection else { return }
        let window = BrowserAnnotationWindow(
          image: image, pageURL: page.displayedURL?.absoluteString ?? "")
        window.onSave = { [weak self] file, attach in
          guard let self else { return }
          onArtifactSaved?(file)
          guard store.selectedID == thread, store.browserConnection === connection else { return }
          lastArtifact = (file, thread, connection)
          if attach, store.canAttach {
            store.addAttachments([file])
            onContextAdded?()
          }
        }
        window.onClose = { [weak self, weak window] in
          self?.annotationWindows.removeAll { $0 === window }
        }
        annotationWindows.append(window)
        window.showWindow(nil)
        window.window?.center()
        window.window?.makeKeyAndOrderFront(nil)
      } catch {
        guard store.browserConnection === connection else { return }
        self.error = error.localizedDescription
        render()
      }
    }
  }
  @objc private func capturePage() {
    if chromium.enabled {
      captureChromium(annotate: false)
      return
    }
    guard let page, store.canAttach else { return }
    let threadID = page.threadID
    let endpoint = store.environmentKey
    let connection = store.browserConnection
    Task {
      do {
        let file = try await page.capture()
        guard store.selectedID == threadID, store.environmentKey == endpoint,
          store.browserConnection === connection, store.canAttach
        else {
          try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
          return
        }
        store.addAttachments([file], deleteSources: true)
      } catch {
        self.error = error.localizedDescription
        render()
      }
    }
  }
}

extension BrowserPanel {
  private func openBackgroundPopup(_ url: URL, from source: BrowserPage) {
    guard let connection, let endpoint else { return }
    Task { [weak self, weak source] in
      guard let self, let source,
        self.connection === connection && self.store.browserConnection === connection
      else { return }
      do {
        let tab = try BrowserTab(
          await connection.call(
            "preview.open",
            payload: .object([
              "threadId": .string(source.threadID), "url": .string(url.absoluteString),
              "profileId": .string(source.snapshot.profileID ?? "default"),
              "viewport": source.snapshot.viewport,
            ])))
        guard self.connection === connection && self.store.browserConnection === connection,
          self.pages[key(source.tabID, thread: source.threadID)] === source
        else {
          _ = try? await connection.call(
            "preview.close",
            payload: .object(["threadId": .string(tab.threadID), "tabId": .string(tab.id)]))
          return
        }
        let page = makePage(tab, connection: connection, endpoint: endpoint)
        page.agentDriven = source.agentDriven
        let surface = BrowserAutomationSurface()
        surface.onStop = { [weak self] in self?.automationHost.setPaused(true) }
        automationSurfaces[key(tab.id, thread: tab.threadID)] = surface
        surface.attach(
          page, show: source.web.window?.isVisible == true,
          title: "Browser · "
            + (store.shell.threads[tab.threadID]?.title ?? "Background conversation"))
        page.receive(tab)
        selections[tab.threadID] = tab.id
        automationHost.refreshFocus()
      } catch {
        guard self.connection === connection && self.store.browserConnection === connection else {
          return
        }
        self.error = error.localizedDescription
        render()
      }
    }
  }
  private func watchAutomationTabs(_ connection: RPCConnection) {
    automationMetadata = Task { [weak self] in
      guard let self else { return }
      do {
        let events = try await connection.subscribe("subscribePreviewEvents")
        defer { Task { await connection.cancel(events.id) } }
        for try await event in events.values {
          guard !Task.isCancelled,
            self.connection === connection && self.store.browserConnection === connection,
            let thread = event["threadId"].string, let tabID = event["tabId"].string
          else { return }
          let key = key(tabID, thread: thread)
          if event["type"].string == "closed" {
            automationHost.interrupt(threadID: thread)
            automationSurfaces.removeValue(forKey: key)?.close()
            pages.removeValue(forKey: key)?.dispose()
          } else if !(active && self.threadID == thread),
            let tab = try? BrowserTab(event["snapshot"]), let page = pages[key]
          {
            page.receive(tab)
            automationSurfaces[key]?.viewport.setting =
              (try? BrowserViewport(tab.viewport)) ?? .fill
          }
          automationHost.refreshFocus()
        }
      } catch {
        guard !Task.isCancelled,
          self.connection === connection && self.store.browserConnection === connection
        else { return }
        self.error = "Browser synchronization ended: " + error.localizedDescription
        render()
      }
    }
  }

  func automate(_ request: JSON, deadline: BrowserAutomationDeadline) async throws -> JSON {
    _ = view
    try deadline.check()
    guard let connection, let endpoint else { throw BrowserAutomationError.interrupted }
    let thread = try request.requiredString("threadId")
    let operation = try request.requiredString("operation")
    let input = request["input"]
    var listing = try await connection.call(
      "preview.list", payload: .object(["threadId": .string(thread)]))
    try deadline.check()
    guard self.connection === connection && self.store.browserConnection === connection else {
      throw BrowserAutomationError.interrupted
    }
    let tabs = try listing["sessions"].array.map(BrowserTab.init).filter { $0.threadID == thread }
    let requestedID = request["tabId"].string ?? input["tabId"].string
    var tab = requestedID.flatMap { id in tabs.first { $0.id == id } }
    if operation == "recordingStop", request["tabIdExplicit"] != .bool(true) {
      let recordingTabs = pages.values.filter { $0.threadID == thread && $0.recording.active }.map(
        \.tabID)
      if recordingTabs.count == 1 { tab = tabs.first { $0.id == recordingTabs[0] } }
    }
    if requestedID == nil, tab == nil {
      tab = tabs.first { $0.id == selections[thread] } ?? tabs.first
    } else if tab == nil {
      throw BrowserAutomationError(
        "PreviewAutomationTabNotFoundError",
        "That browser tab no longer belongs to this conversation.")
    }
    if operation == "status", tab == nil {
      return .object([
        "available": .bool(false), "visible": .bool(false), "tabId": .null, "url": .null,
        "title": .null, "loading": .bool(false),
      ])
    }
    if operation == "open", tab == nil || input["reuseExistingTab"] == .bool(false) {
      var payload: [String: JSON] = [
        "threadId": .string(thread),
        "profileId": .string(preferences.values.defaultProfileID),
        "viewport": preferences.values.defaultViewport.width == nil
          ? try BrowserViewport(width: 1280, height: 800).json : preferences.values.viewport,
      ]
      if let url = input["url"].string {
        payload["url"] = .string(
          try BrowserURL.resolve(BrowserURL.normalize(url), environment: endpoint).absoluteString)
      }
      tab = try BrowserTab(await connection.call("preview.open", payload: .object(payload)))
    }
    try deadline.check()
    guard self.connection === connection, store.browserConnection === connection else {
      throw BrowserAutomationError.interrupted
    }
    guard var tab else {
      throw BrowserAutomationError(
        "PreviewAutomationTabNotFoundError", "Open a browser tab before using it.")
    }
    if chromium.enabled {
      return try await automateChromium(
        tab, operation: operation, input: input,
        connection: connection, endpoint: endpoint, deadline: deadline)
    }
    let key = key(tab.id, thread: thread)
    let page = pages[key] ?? makePage(tab, connection: connection, endpoint: endpoint)
    guard !page.picker.active else { throw BrowserAutomationError.interrupted }
    let controlRevision = page.automation.controlRevision
    page.activeAutomation += 1
    defer { page.activeAutomation -= 1 }
    if !["status", "snapshot", "waitFor"].contains(operation) { page.agentDriven = true }
    let id = request["requestId"].string ?? UUID().uuidString
    let started = Date().ISO8601Format()
    page.automation.record(operation, status: "running", id: id, started: started)
    do {
      let explicitPresentation = input["open"] == .null ? input["show"] : input["open"]
      if operation == "open" {
        page.suppressAgentPresentation = explicitPresentation == .bool(false)
      }
      let reveal =
        operation == "open"
        ? (explicitPresentation == .null
          ? preferences.values.showAgentPreview : explicitPresentation.bool)
        : operation != "status" && preferences.values.showAgentPreview
          && !page.suppressAgentPresentation
      if reveal, self.threadID == thread {
        selections[thread] = tab.id
        selectedID = tab.id
        onAgentReveal?()
      }
      if self.active, self.threadID == thread, selectedID == tab.id {
        listing = try await connection.call(
          "preview.list", payload: .object(["threadId": .string(thread)]))
        try directory.snapshot(listing)
        reconcile()
      }
      if page.web.superview == nil || page.web.window == nil {
        let surface = automationSurfaces[key] ?? BrowserAutomationSurface()
        automationSurfaces[key] = surface
        surface.onStop = { [weak self] in self?.automationHost.setPaused(true) }
        surface.attach(
          page, show: reveal,
          title: "Browser · " + (store.shell.threads[thread]?.title ?? "Background conversation"))
      } else if reveal, let surface = automationSurfaces[key], shownPage !== page {
        surface.window.orderFront(nil)
      }
      page.receive(tab)
      let expectedPage = page
      func check() throws {
        try deadline.check()
        guard self.connection === connection && self.store.browserConnection === connection,
          self.pages[key] === expectedPage,
          page.automation.controlRevision == controlRevision
        else {
          throw BrowserAutomationError.interrupted
        }
      }
      if operation == "navigate" || operation == "open" && input["url"].string != nil {
        let url = try navigationURL(input, environment: endpoint)
        tab = try BrowserTab(
          await connection.call(
            "preview.navigate",
            payload: .object([
              "threadId": .string(thread), "tabId": .string(tab.id),
              "url": .string(url.absoluteString),
            ])))
        try check()
        page.receive(tab, navigate: true)
        let readiness = input["readiness"].string ?? "load"
        while readiness != "none" {
          try check()
          if let error = page.failure { throw T3Error(error) }
          if readiness == "domContentLoaded", page.navigationCommitted {
            let state = try await page.automation.query("ready", deadline: deadline).string
            if state == "interactive" || state == "complete" { break }
          } else if !page.navigationPending && !page.web.isLoading && page.web.url != nil
            && page.web.url?.absoluteString != "about:blank"
          {
            break
          }
          try await Task.sleep(for: .milliseconds(40))
        }
      }
      let result: JSON
      switch operation {
      case "open", "navigate", "status":
        result = try await automationStatus(page, deadline: deadline)
      case "resize":
        let viewport = try automationViewport(input)
        tab = try BrowserTab(
          await connection.call(
            "preview.resize",
            payload: .object([
              "threadId": .string(thread), "tabId": .string(tab.id), "viewport": viewport.json,
            ])))
        try check()
        page.receive(tab)
        let surface = shownPage === page ? host : automationSurfaces[key]?.viewport
        surface?.setting = viewport
        surface?.layoutSubtreeIfNeeded()
        var measured = JSON.null
        repeat {
          try check()
          measured = try await page.automation.query("viewport", deadline: deadline)
          if viewport.width == nil
            || measured["width"].int == viewport.width && measured["height"].int == viewport.height
          {
            break
          }
          try await Task.sleep(for: .milliseconds(40))
        } while true
        result = .object(["tabId": .string(tab.id), "setting": viewport.json, "viewport": measured])
      case "setColorScheme":
        let scheme = input["colorScheme"].string ?? "system"
        guard ["system", "light", "dark"].contains(scheme) else {
          throw T3Error("Unknown browser appearance.")
        }
        page.web.appearance =
          scheme == "system" ? nil : NSAppearance(named: scheme == "dark" ? .darkAqua : .aqua)
        result = .object(["tabId": .string(tab.id), "colorScheme": .string(scheme)])
      case "recordingStart":
        guard !page.recording.active else {
          throw BrowserAutomationError(
            "PreviewAutomationRecordingAlreadyActiveError", "This browser tab is already recording."
          )
        }
        let options = recordingOptions
        try await page.recording.start(options: options, directory: BrowserArtifacts.directory) {
          [weak page] options in
          guard let page else { throw CancellationError() }
          return try await page.captureImage(
            mouse: options.showMouse, keys: options.showKeys, deterministic: false)
        }
        try check()
        recordingPage = page
        result = .object([
          "tabId": .string(tab.id), "recording": .bool(true),
          "startedAt": page.recording.startedAt.map { .string($0.ISO8601Format()) } ?? .null,
        ])
      case "recordingStop":
        guard page.recording.readyToStop else {
          throw BrowserAutomationError(
            "PreviewAutomationRecordingNotActiveError", "This browser tab is not recording.")
        }
        let file = try await page.recording.stop()
        try check()
        if recordingPage === page { recordingPage = nil }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        var artifact: [String: JSON] = [
          "id": .string(file.deletingPathExtension().lastPathComponent), "tabId": .string(tab.id),
          "path": .string(file.path), "mimeType": .string("video/mp4"),
          "sizeBytes": .number(Double(size)), "createdAt": .string(Date().ISO8601Format()),
        ]
        if input["transferToEnvironment"].bool {
          artifact["uploadedAttachmentId"] = .string(
            try await BrowserRecordingUpload.upload(
              file,
              connection: connection, endpoint: endpoint, deadline: deadline, check: check))
        }
        result = .object(artifact)
      case "snapshot":
        let content = try await page.automation.run(operation, input: input, deadline: deadline)
        try check()
        let file = try await page.capture()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try check()
        let data = try Data(contentsOf: file)
        guard data.count <= 16 * 1024 * 1024 else {
          throw BrowserAutomationError(
            "PreviewAutomationResultTooLargeError",
            "The browser screenshot is too large. Reduce the viewport and retry.")
        }
        guard case .object(var fields) = content, let image = NSBitmapImageRep(data: data) else {
          throw T3Error("Could not capture the browser.")
        }
        fields["screenshot"] = .object([
          "mimeType": .string("image/png"), "data": .string(data.base64EncodedString()),
          "width": .number(Double(image.pixelsWide)), "height": .number(Double(image.pixelsHigh)),
        ])
        fields["actionTimeline"] = .array(page.automation.actions)
        result = .object(fields)
      default: result = try await page.automation.run(operation, input: input, deadline: deadline)
      }
      try check()
      page.automation.record(operation, status: "succeeded", id: id, started: started)
      render()
      return result
    } catch {
      let interrupted =
        error is CancellationError
        || (error as? BrowserAutomationError)?.tag == "PreviewAutomationControlInterruptedError"
      if operation == "recordingStart", interrupted { page.recording.cancel() }
      page.automation.record(
        operation, status: interrupted ? "interrupted" : "failed", id: id,
        started: started, error: error.localizedDescription)
      throw error
    }
  }

  private var chromiumEnvironment: String? { store.browserEnvironmentID }
  private func chromiumModeChanged() {
    if chromium.enabled {
      guard !recordingActive else {
        chromium.enabled = false
        error = "Save or cancel your recording before switching browsers."
        render()
        return
      }
      for page in pages.values {
        page.dispose()
        page.web.removeFromSuperview()
      }
      pages = [:]
      shownPage = nil
      for surface in automationSurfaces.values { surface.close() }
      automationSurfaces = [:]
      recordingPage?.recording.cancel()
      recordingPage = nil
    }
    chromiumOpening = []
    chromiumURLs = [:]
    showSelected()
    render()
  }
  @objc private func useChromiumBrowser() {
    guard !recordingActive else {
      error = "Save or cancel your recording before switching browsers."
      render()
      return
    }
    chromium.enabled = true
    chromiumModeChanged()
  }
  @objc private func useNativeBrowser() {
    chromium.enabled = false
    chromiumModeChanged()
  }
  @objc private func revealChromiumBrowser() {
    guard chromium.enabled, let connection, let endpoint,
      let tab = directory.tabs.first(where: { $0.id == selectedID }),
      let environment = chromiumEnvironment
    else { return }
    if !chromium.owns(environment: environment, thread: tab.threadID, tab: tab.id) {
      chromiumURLs.removeValue(
        forKey: BrowserChromiumController.pageKey(
          environment: environment, thread: tab.threadID, tab: tab.id))
      handoffChromium(tab, connection: connection, endpoint: endpoint)
    } else {
      chromiumCommand("reveal")
    }
  }
  @objc private func openChromiumPassword() { chromiumCommand("popup") }
  @objc private func closeChromiumPage() { chromiumCommand("close") }
  @objc private func stopChromium() {
    Task { [weak self] in
      guard let self, await chromium.finishBeforeQuit(window: view.window) else { return }
      chromium.stop()
      chromiumURLs = [:]
    }
  }
  @objc private func installChromiumPassword() {
    Task { [weak self] in await self?.chromium.install() }
  }
  @objc private func importChromiumPassword() {
    Task { [weak self] in
      guard let self else { return }
      await chromium.importSelectedProfile(window: view.window)
    }
  }
  private func chromiumCommand(_ method: String, extra: [String: JSON] = [:]) {
    guard let connection, store.browserConnection === connection,
      let environment = chromiumEnvironment, let threadID, let selectedID
    else { return }
    var input = chromium.context(environment: environment, thread: threadID, tab: selectedID)
    input.merge(extra) { _, new in new }
    Task { [weak self] in
      guard let self else { return }
      do { _ = try await chromium.request(method, input: .object(input)) } catch {
        guard store.browserConnection === connection else { return }
        self.error = error.localizedDescription
        render()
      }
    }
  }
  private func handoffChromium(_ tab: BrowserTab, connection: RPCConnection, endpoint: URL) {
    guard let environment = chromiumEnvironment else { return }
    let key = BrowserChromiumController.pageKey(
      environment: environment, thread: tab.threadID, tab: tab.id)
    let url =
      (try? tab.url.map { try BrowserURL.resolve($0, environment: endpoint).absoluteString })
      ?? "about:blank"
    if chromiumURLs[key] == url || chromiumOpening.contains(key) { return }
    chromiumOpening.insert(key)
    Task { [weak self] in
      guard let self else { return }
      defer { chromiumOpening.remove(key) }
      do {
        try await ensureChromium(tab, connection: connection, endpoint: endpoint, show: true)
        guard self.connection === connection, store.browserConnection === connection,
          chromium.enabled
        else { return }
        if chromiumURLs[key] != url {
          let input = chromium.context(environment: environment, thread: tab.threadID, tab: tab.id)
            .merging(["url": .string(url)]) { _, new in new }
          _ = try await chromium.request("navigate", input: .object(input))
        }
        guard self.connection === connection, store.browserConnection === connection,
          chromium.enabled
        else { return }
        chromiumURLs[key] = url
      } catch {
        guard self.connection === connection, store.browserConnection === connection,
          chromium.enabled
        else { return }
        self.error = error.localizedDescription
        render()
      }
    }
  }
  private func ensureChromium(
    _ tab: BrowserTab, connection: RPCConnection, endpoint: URL, show: Bool
  )
    async throws
  {
    guard let environment = chromiumEnvironment, chromium.enabled,
      self.connection === connection, store.browserConnection === connection
    else { throw BrowserAutomationError.interrupted }
    let key = BrowserChromiumController.pageKey(
      environment: environment, thread: tab.threadID, tab: tab.id)
    guard !chromium.owns(environment: environment, thread: tab.threadID, tab: tab.id) else {
      return
    }
    let url =
      try tab.url.map { try BrowserURL.resolve($0, environment: endpoint).absoluteString }
      ?? "about:blank"
    var payload = chromium.context(environment: environment, thread: tab.threadID, tab: tab.id)
    payload["url"] = .string(url)
    payload["profileId"] = .string(tab.profileID ?? preferences.values.defaultProfileID)
    payload["viewport"] = tab.viewport
    payload["show"] = .bool(show)
    _ = try await chromium.request("open", input: .object(payload))
    guard self.connection === connection, store.browserConnection === connection, chromium.enabled,
      chromiumEnvironment == environment
    else { throw BrowserAutomationError.interrupted }
    chromiumURLs[key] = url
  }
  private func chromiumEvent(_ event: String, value: JSON) {
    guard let connection, let endpoint, store.browserConnection === connection,
      value["environmentID"].string == chromiumEnvironment,
      let thread = value["threadId"].string, let tab = value["tabId"].string
    else { return }
    if event == "interrupted" {
      automationHost.setPaused(true)
      return
    }
    if event == "newPage", thread == threadID, let url = value["url"].string {
      open(url, newTab: true)
      return
    }
    guard event == "closed" || event == "page" && !value["loading"].bool else { return }
    let environment = chromiumEnvironment
    Task { [weak self] in
      guard let self else { return }
      do {
        let listing = try await connection.call(
          "preview.list", payload: .object(["threadId": .string(thread)]))
        guard self.connection === connection, store.browserConnection === connection,
          chromiumEnvironment == environment, chromium.enabled,
          listing["sessions"].array.contains(where: {
            $0["tabId"].string == tab && $0["threadId"].string == thread
          })
        else { return }
        if event == "closed" {
          _ = try await connection.call(
            "preview.close", payload: .object(["threadId": .string(thread), "tabId": .string(tab)]))
          return
        }
        guard let raw = value["url"].string, let url = URL(string: raw),
          ["http", "https"].contains(url.scheme ?? ""), raw.utf8.count <= 2048
        else { return }
        _ = try BrowserURL.resolve(url, environment: endpoint)
        let key = BrowserChromiumController.pageKey(
          environment: environment ?? "", thread: thread, tab: tab)
        guard chromium.pages[key]?["url"].string == raw else { return }
        chromiumURLs[key] = raw
        _ = try await connection.call(
          "preview.reportStatus",
          payload: .object([
            "threadId": .string(thread), "tabId": .string(tab),
            "navStatus": .object([
              "_tag": .string("Success"), "url": .string(raw),
              "title": .string(String((value["title"].string ?? "").prefix(512))),
            ]),
            "canGoBack": value["canGoBack"], "canGoForward": value["canGoForward"],
          ]))
      } catch {
        guard self.connection === connection, store.browserConnection === connection else { return }
        self.error = error.localizedDescription
        render()
      }
    }
  }
  private func automateChromium(
    _ initial: BrowserTab, operation: String, input: JSON,
    connection: RPCConnection, endpoint: URL, deadline: BrowserAutomationDeadline
  ) async throws -> JSON {
    guard let environment = chromiumEnvironment else { throw BrowserAutomationError.interrupted }
    var tab = initial
    if operation == "navigate" || operation == "open" && input["url"].string != nil {
      let url = try navigationURL(input, environment: endpoint)
      tab = try BrowserTab(
        await connection.call(
          "preview.navigate",
          payload: .object([
            "threadId": .string(tab.threadID), "tabId": .string(tab.id),
            "url": .string(url.absoluteString),
          ])))
    }
    if operation == "resize" {
      let viewport = try automationViewport(input)
      tab = try BrowserTab(
        await connection.call(
          "preview.resize",
          payload: .object([
            "threadId": .string(tab.threadID), "tabId": .string(tab.id), "viewport": viewport.json,
          ])))
    }
    try deadline.check()
    guard self.connection === connection, store.browserConnection === connection,
      chromiumEnvironment == environment
    else { throw BrowserAutomationError.interrupted }
    let presentation = input["open"] == .null ? input["show"] : input["open"]
    let show = presentation == .null ? preferences.values.showAgentPreview : presentation.bool
    try await ensureChromium(tab, connection: connection, endpoint: endpoint, show: show)
    var action = input
    if operation == "navigate" || operation == "open" {
      action = .object([
        "url": .string(
          try tab.url.map { try BrowserURL.resolve($0, environment: endpoint).absoluteString }
            ?? "about:blank"),
        "readiness": input["readiness"] == .null ? .string("load") : input["readiness"],
      ])
    }
    if operation == "resize" { action = .object(["viewport": tab.viewport]) }
    var payload = chromium.context(environment: environment, thread: tab.threadID, tab: tab.id)
    payload["operation"] = .string(operation == "open" ? "navigate" : operation)
    payload["input"] = action
    let remaining = deadline.remaining.components
    let milliseconds = max(
      1, Int(remaining.seconds * 1000 + remaining.attoseconds / 1_000_000_000_000_000))
    payload["timeoutMs"] = .number(Double(milliseconds))
    let result = try await chromium.request(
      "automation", input: .object(payload), milliseconds: milliseconds)
    try deadline.check()
    guard self.connection === connection, store.browserConnection === connection,
      chromiumEnvironment == environment, chromium.enabled
    else { throw BrowserAutomationError.interrupted }
    return result
  }
  private func captureChromium(annotate: Bool) {
    guard let connection, let endpoint, let threadID,
      let tab = directory.tabs.first(where: { $0.id == selectedID })
    else { return }
    Task { [weak self] in
      guard let self else { return }
      do {
        let result = try await automateChromium(
          tab, operation: "snapshot", input: .object([:]),
          connection: connection, endpoint: endpoint,
          deadline: BrowserAutomationDeadline(milliseconds: 30_000))
        guard store.selectedID == threadID, store.browserConnection === connection,
          let encoded = result["screenshot"]["data"].string,
          let data = Data(base64Encoded: encoded), let image = NSImage(data: data)
        else { return }
        if annotate {
          let window = BrowserAnnotationWindow(image: image, pageURL: result["url"].string ?? "")
          window.onSave = { [weak self] file, attach in
            guard let self else { return }
            onArtifactSaved?(file)
            guard store.selectedID == threadID, store.browserConnection === connection else {
              return
            }
            lastArtifact = (file, threadID, connection)
            if attach, store.canAttach {
              store.addAttachments([file])
              onContextAdded?()
            }
          }
          window.onClose = { [weak self, weak window] in
            self?.annotationWindows.removeAll { $0 === window }
          }
          annotationWindows.append(window)
          window.showWindow(nil)
          window.window?.makeKeyAndOrderFront(nil)
        } else {
          try FileManager.default.createDirectory(
            at: BrowserArtifacts.directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
          let file = BrowserArtifacts.directory.appendingPathComponent(
            "chromium-" + UUID().uuidString + ".png")
          try data.write(to: file, options: .atomic)
          lastArtifact = (file, threadID, connection)
          onArtifactSaved?(file)
          if store.canAttach {
            store.addAttachments([file])
            onContextAdded?()
          }
        }
      } catch {
        guard store.browserConnection === connection else { return }
        self.error = error.localizedDescription
        render()
      }
    }
  }

  private func automationStatus(_ page: BrowserPage, deadline: BrowserAutomationDeadline)
    async throws -> JSON
  {
    var status: [String: JSON] = [
      "available": .bool(true),
      "visible": .bool(page.web.window?.isVisible == true && !page.web.isHidden),
      "tabId": .string(page.tabID),
      "url": page.displayedURL.map { .string($0.absoluteString) } ?? .null,
      "title": page.web.title.map(JSON.string) ?? .null, "loading": .bool(page.web.isLoading),
      "viewportSetting": page.snapshot.viewport,
    ]
    if page.web.url != nil {
      status["viewport"] = try await page.automation.query("viewport", deadline: deadline)
    }
    return .object(status)
  }
  private func navigationURL(_ input: JSON, environment: URL) throws -> URL {
    let target = input["target"]
    let raw: String
    if target["kind"].string == "environment-port" {
      let port = try target.requiredInt("port")
      guard (1...65535).contains(port) else { throw T3Error("Invalid local-server port.") }
      let path = target["path"].string ?? "/"
      raw =
        (target["protocol"].string ?? "http") + "://localhost:\(port)"
        + (path.hasPrefix("/") ? path : "/" + path)
    } else {
      raw = try (target["kind"].string == "url" ? target : input).requiredString("url")
    }
    return try BrowserURL.resolve(BrowserURL.normalize(raw), environment: environment)
  }
  private func automationViewport(_ input: JSON) throws -> BrowserViewport {
    switch input["mode"].string {
    case "fill": return .fill
    case "freeform":
      return try BrowserViewport(
        width: input.requiredInt("width"), height: input.requiredInt("height"))
    case "preset":
      guard
        var viewport = BrowserDevicePreset.all.first(where: { $0.id == input["preset"].string })?
          .viewport
      else { throw T3Error("Unknown device preset.") }
      if let orientation = input["orientation"].string,
        (orientation == "landscape") != (viewport.width! > viewport.height!)
      {
        viewport = viewport.rotated
      }
      return viewport
    default: throw T3Error("Unknown viewport mode.")
    }
  }
}

extension BrowserPanel: NSMenuItemValidation {
  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    switch item.action {
    case #selector(startRecording):
      return !chromium.enabled && page?.web.url != nil && !recordingActive
    case #selector(stopRecording): return recordingPage?.recording.readyToStop == true
    case #selector(cancelRecording): return recordingActive
    case #selector(recordAt30):
      item.state = recordingOptions.framesPerSecond == 30 ? .on : .off
      return !recordingActive
    case #selector(recordAt60):
      item.state = recordingOptions.framesPerSecond == 60 ? .on : .off
      return !recordingActive
    case #selector(toggleRecordingMouse):
      item.state = recordingOptions.showMouse ? .on : .off
      return !recordingActive
    case #selector(toggleRecordingKeys):
      item.state = recordingOptions.showKeys ? .on : .off
      return !recordingActive
    case #selector(annotatePage):
      return chromium.enabled
        ? selectedID != nil && chromium.running
        : page?.web.url != nil && page?.web.isLoading == false
    case #selector(useChromiumBrowser):
      item.state = chromium.enabled ? .on : .off
      return !recordingActive
    case #selector(useNativeBrowser):
      item.state = chromium.enabled ? .off : .on
      return true
    case #selector(stopChromium): return chromium.running
    case #selector(openChromiumPassword), #selector(closeChromiumPage):
      return chromium.enabled && chromium.running && selectedID != nil
    case #selector(attachLastArtifact):
      return lastArtifact?.thread == store.selectedID
        && lastArtifact?.connection === store.browserConnection && store.canAttach
    default: return true
    }
  }
}
