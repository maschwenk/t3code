import AppKit
import T3Core
import WebKit

@MainActor final class BrowserPanel: NSViewController {
  var onClose: (() -> Void)?
  var onContextAdded: (() -> Void)?
  var onExpand: (() -> Void)?
  private let store: ClientStore
  private let profiles = BrowserProfiles()
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

  init(store: ClientStore) {
    self.store = store
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  isolated deinit {
    detach()
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
    let top = NSStackView(views: [tabScroll, add, expand, close])
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
    let contextChanged =
      connection !== nextConnection || threadID != nextThread || self.active != active
    guard contextChanged else {
      render()
      return
    }
    if connection !== nextConnection {
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
    endpoint = store.browserEndpoint
    threadID = nextThread
    shownPage?.picker.cancel()
    host.show(nil)
    shownPage = nil
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
    for tab in directory.tabs { pages[key(tab.id, thread: threadID)]?.receive(tab) }
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
      host.show(nil)
      shownPage = nil
      empty.isHidden = false
      return
    }
    let key = key(tab.id, thread: threadID)
    let page: BrowserPage
    if let existing = pages[key] {
      page = existing
    } else {
      page = BrowserPage(
        tab: tab, environment: endpoint, connection: connection,
        dataStore: profiles.dataStore(profile: tab.profileID))
      pages[key] = page
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
      page.onChange = { [weak self] in self?.render() }
      page.onNewTab = { [weak self, weak page] url in
        guard let self, let page, self.threadID == page.threadID, self.active else { return }
        self.open(url.absoluteString, newTab: true, profile: tab.profileID)
      }
    }
    if shownPage !== page {
      shownPage?.picker.cancel()
      host.show(nil)
      shownPage = page
      host.show(page.web)
    }
    page.receive(tab)
    page.web.isHidden = tab.url == nil && page.web.url == nil
    empty.isHidden = !page.web.isHidden
  }

  private func render() {
    guard isViewLoaded else { return }
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
    let message = error ?? page?.failure ?? page?.synchronizationError ?? discoveryError
    status.stringValue =
      message
      ?? (page?.picker.active == true
        ? "Click an element to add it to your message. Escape cancels." : nil)
      ?? (loading
        ? "Loading browser tabs…"
        : connection == nil
          ? "Connect to use Browser"
          : threadID == nil
            ? "Select a conversation to use Browser"
            : page?.web.isLoading == true ? "Loading…" : "")
    status.isHidden = status.stringValue.isEmpty
    retry.isHidden = message == nil
    footer.isHidden = status.isHidden && retry.isHidden
    renderEmpty()
  }

  private func tabTitle(_ tab: BrowserTab) -> String {
    let loaded = pages[key(tab.id, thread: tab.threadID)]?.web.title ?? ""
    return (tab.profileID == "incognito" ? "Private · " : "")
      + (loaded.isEmpty ? tab.title : loaded)
  }

  private func renderEmpty() {
    let signature = servers.map(\.id).joined(separator: "\n") + "\n\(connection != nil):\(loading)"
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
    let title = NSTextField(labelWithString: "No preview yet")
    title.font = .systemFont(ofSize: 22, weight: .semibold)
    let detail = NSTextField(
      wrappingLabelWithString:
        "Type a URL above, or run a dev script. Browser-ready localhost servers will show up here automatically."
    )
    detail.font = .systemFont(ofSize: 13)
    detail.textColor = .secondaryLabelColor
    detail.alignment = .center
    for child in [icon, title, detail] { empty.addArrangedSubview(child) }
    detail.widthAnchor.constraint(lessThanOrEqualTo: host.widthAnchor, constant: -48).isActive =
      true
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
    var input: [String: JSON] = ["threadId": .string(threadID)]
    if let tab { input["tabId"] = .string(tab) }
    if let url { input["url"] = .string(url.absoluteString) }
    if let profile { input["profileId"] = .string(profile) }
    mutate(tab == nil ? "preview.open" : "preview.navigate", input: input, connection: connection) {
      [weak self] result in
      guard let self, let id = result["tabId"].string else { return }
      self.selectedID = id
      self.selections[threadID] = id
    }
  }

  private func close(_ id: String) {
    guard let connection, let threadID else { return }
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
      ("Open in Default Browser", #selector(openExternal)),
      ("Reload Without Cache", #selector(hardReload)), ("Zoom In", #selector(zoomIn)),
      ("Zoom Out", #selector(zoomOut)), ("Actual Size", #selector(resetZoom)),
      ("New Private Tab", #selector(newPrivateTab)),
    ] {
      more.addItem(withTitle: title)
      more.lastItem?.target = self
      more.lastItem?.action = action
    }
  }
  @objc private func togglePicker() {
    guard let page, store.canAddBrowserContext else { return }
    if page.picker.active { page.picker.cancel() } else { page.picker.start() }
  }
  func resize(_ viewport: BrowserViewport) {
    guard let connection, let threadID, let selectedID else { return }
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
  @objc private func goBack() { page?.web.goBack() }
  @objc private func goForward() { page?.web.goForward() }
  @objc private func reloadPage() {
    if page?.web.isLoading == true { page?.web.stopLoading() } else { page?.reload() }
  }
  @objc private func hardReload() { page?.reload(hard: true) }
  @objc private func zoomIn() {
    if let web = page?.web {
      web.pageZoom = min(5, web.pageZoom + 0.1)
      host.needsLayout = true
    }
  }
  @objc private func zoomOut() {
    if let web = page?.web {
      web.pageZoom = max(0.25, web.pageZoom - 0.1)
      host.needsLayout = true
    }
  }
  @objc private func resetZoom() {
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
    if error != nil || discoveryError != nil {
      self.active = false
      refresh(active: true)
    } else {
      page?.reload()
    }
  }
  @objc private func capturePage() {
    guard let page, store.canAttach else { return }
    let threadID = page.threadID
    let endpoint = store.environmentKey
    Task {
      do {
        let file = try await page.capture()
        guard store.selectedID == threadID, store.environmentKey == endpoint, store.canAttach else {
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
