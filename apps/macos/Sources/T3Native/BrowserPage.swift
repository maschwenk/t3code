import AppKit
import CryptoKit
import T3Core
import WebKit

@MainActor final class BrowserPage: NSObject, WKNavigationDelegate, WKUIDelegate {
  let web: WKWebView
  let picker: BrowserElementPicker
  let automation: BrowserAutomationPage
  let recording = BrowserRecording()
  let tabID: String
  let threadID: String
  let environment: URL
  var suppressAgentPresentation = false
  var agentDriven = false
  var activeAutomation = 0
  var onHumanInput: (() -> Void)?
  var onDownload: ((WKDownload, Bool, NSWindow?) -> Void)?
  var onChange: (() -> Void)?
  var onNewTab: ((URL) -> Void)?
  private(set) var failure: String?
  private(set) var synchronizationError: String?
  private(set) var snapshot: BrowserTab
  private let connection: RPCConnection
  private var disposed = false
  private var observations: [NSKeyValueObservation] = []
  private var expectedReports: [JSON] = []
  private var pendingReport: JSON?
  private var lastReport: JSON?
  private var reportTask: Task<Void, Never>?
  private var serverURL: URL?
  private var retryURL: URL?
  private var requestedURL: URL?
  private var started = false
  private var expectingDownload = false
  private(set) var navigationPending = false
  private(set) var navigationCommitted = false
  var displayedURL: URL? { failure == nil ? web.url ?? snapshot.url : retryURL ?? snapshot.url }

  init(tab: BrowserTab, environment: URL, connection: RPCConnection, dataStore: WKWebsiteDataStore)
  {
    snapshot = tab
    tabID = tab.id
    threadID = tab.threadID
    self.environment = environment
    self.connection = connection
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = dataStore
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    web = WKWebView(frame: .zero, configuration: configuration)
    picker = BrowserElementPicker(web: web)
    automation = BrowserAutomationPage(web: web)
    super.init()
    web.navigationDelegate = self
    web.uiDelegate = self
    web.allowsBackForwardNavigationGestures = true
    web.isInspectable = true
    for keyPath in [\WKWebView.isLoading, \WKWebView.canGoBack, \WKWebView.canGoForward] {
      observations.append(
        web.observe(keyPath) { [weak self] _, _ in
          Task { @MainActor in self?.onChange?() }
        })
    }
    observations.append(
      web.observe(\.title) { [weak self] _, _ in
        Task { @MainActor in
          guard let self else { return }
          if !self.web.isLoading && self.failure == nil { self.report(kind: "Success") }
          self.onChange?()
        }
      })
    observations.append(
      web.observe(\.url) { [weak self] _, _ in
        Task { @MainActor in
          guard let self else { return }
          if !self.web.isLoading && self.failure == nil { self.report(kind: "Success") }
          self.onChange?()
        }
      })
  }

  func receive(_ tab: BrowserTab, navigate: Bool = false) {
    snapshot = tab
    if !navigate, let index = expectedReports.firstIndex(of: tab.status) {
      expectedReports.removeFirst(index + 1)
      serverURL = tab.url
      return
    }
    guard navigate || !started || serverURL != tab.url else { return }
    if navigate { expectedReports = [] }
    started = true
    serverURL = tab.url
    guard let url = tab.url else { return }
    do {
      let resolved = try BrowserURL.resolve(url, environment: environment)
      if web.url != resolved || failure != nil, !(web.isLoading && requestedURL == resolved) {
        load(resolved)
      }
    } catch {
      failure = error.localizedDescription
      onChange?()
    }
  }

  func dispose() {
    disposed = true
    onChange = nil
    recording.cancel()
    automation.interrupt()
    picker.dispose()
    automation.invalidate()
    web.stopLoading()
    web.navigationDelegate = nil
    web.uiDelegate = nil
    observations = []
    reportTask?.cancel()
    reportTask = nil
  }

  func takeControl() {
    agentDriven = false
    automation.interrupt()
    onHumanInput?()
  }

  func reload(hard: Bool = false) {
    failure = nil
    if let url = retryURL ?? (web.url == nil ? snapshot.url : nil) {
      do { load(try BrowserURL.resolve(url, environment: environment)) } catch {
        failure = error.localizedDescription
      }
    } else {
      requestedURL = web.url
      navigationPending = true
      navigationCommitted = false
      if hard { web.reloadFromOrigin() } else { web.reload() }
    }
    onChange?()
  }

  private func load(_ url: URL) {
    requestedURL = url
    navigationPending = true
    navigationCommitted = false
    failure = nil
    if web.load(URLRequest(url: url)) == nil { rejectedNavigation(url) }
  }
  private func rejectedNavigation(_ url: URL) {
    failed(
      NSError(
        domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost,
        userInfo: [
          NSURLErrorFailingURLErrorKey: url,
          NSLocalizedDescriptionKey:
            "WebKit could not open this address. Check the URL and port, then try again.",
        ]))
  }

  func captureImage(mouse: Bool = true, keys: Bool = true, deterministic: Bool = true) async throws
    -> NSImage
  {
    try await BrowserCapture.image(
      web: web, cursor: automation.cursor, mouse: mouse,
      keys: keys, deterministic: deterministic)
  }
  func capture() async throws -> URL {
    let image = try await captureImage()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "t3-browser-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let url = directory.appendingPathComponent("Browser screenshot.png")
    do {
      try BrowserAnnotationRenderer.png(image).write(to: url, options: .atomic)
      return url
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }

  func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    navigationPending = true
    navigationCommitted = false
    picker.cancel()
    automation.invalidate()
    failure = nil
    retryURL = nil
    onChange?()
  }
  func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
    automation.invalidate()
    navigationCommitted = true
  }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    navigationPending = false
    if webView.url?.absoluteString == "about:blank", let requestedURL,
      ["http", "https"].contains(requestedURL.scheme ?? "")
    {
      rejectedNavigation(requestedURL)
      return
    }
    requestedURL = nil
    failure = nil
    report(kind: "Success")
    onChange?()
  }
  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error)
  { failed(error) }
  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: any Error
  ) { failed(error) }
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    navigationPending = false
    automation.invalidate()
    failure = "This page’s web process stopped. Reload to restore it."
    onChange?()
  }
  private func failed(_ error: any Error) {
    let error = error as NSError
    guard error.code != NSURLErrorCancelled else { return }
    // Converting navigation to WKDownload interrupts the old frame with legacy
    // WebKit policy code 102, even when the file has downloaded successfully.
    if expectingDownload, error.domain == "WebKitErrorDomain", error.code == 102 {
      expectingDownload = false
      navigationPending = false
      return
    }
    navigationPending = false
    requestedURL = nil
    failure = error.localizedDescription
    retryURL = (error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? serverURL
    report(kind: "LoadFailed", error: error as NSError)
    onChange?()
  }

  private func report(kind: String, error: NSError? = nil) {
    guard !disposed else { return }
    guard let url = error?.userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? web.url ?? serverURL,
      ["http", "https"].contains(url.scheme ?? ""), url.absoluteString.utf8.count <= 2_048
    else { return }
    var status: [String: JSON] = [
      "_tag": .string(kind), "url": .string(url.absoluteString),
      "title": .string(String((web.title ?? "").prefix(512))),
    ]
    if let error {
      status["code"] = .number(Double(error.code))
      status["description"] = .string(error.localizedDescription)
    }
    let input: JSON = .object([
      "threadId": .string(threadID), "tabId": .string(tabID), "navStatus": .object(status),
      "canGoBack": .bool(web.canGoBack), "canGoForward": .bool(web.canGoForward),
    ])
    guard lastReport != input else { return }
    lastReport = input
    pendingReport = input
    guard reportTask == nil else { return }
    reportTask = Task { [weak self] in
      guard let self else { return }
      defer { reportTask = nil }
      while let input = pendingReport, !Task.isCancelled {
        pendingReport = nil
        expectedReports.append(input["navStatus"])
        if expectedReports.count > 16 { expectedReports.removeFirst() }
        do {
          _ = try await connection.call("preview.reportStatus", payload: input)
          guard !disposed, !Task.isCancelled else { return }
          synchronizationError = nil
        } catch {
          guard !disposed, !Task.isCancelled else { return }
          expectedReports.removeAll { $0 == input["navStatus"] }
          if lastReport == input { lastReport = nil }
          synchronizationError = "Browser tab could not sync: " + error.localizedDescription
        }
        onChange?()
      }
    }
  }

  func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async
    -> WKNavigationActionPolicy
  {
    guard let url = action.request.url else { return .cancel }
    if action.targetFrame?.isMainFrame == true { expectingDownload = false }
    if action.shouldPerformDownload,
      ["http", "https", "blob", "data"].contains(url.scheme?.lowercased() ?? "")
    {
      expectingDownload = true
      return .download
    }
    if url.absoluteString == "about:blank" { return .allow }
    guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return .cancel }
    if action.targetFrame == nil {
      onNewTab?(url)
      return .cancel
    }
    if action.targetFrame?.isMainFrame == true {
      do {
        let resolved = try BrowserURL.resolve(
          try BrowserURL.normalize(url.absoluteString), environment: environment)
        requestedURL = resolved
        if resolved != url {
          load(resolved)
          return .cancel
        }
      } catch {
        failure = error.localizedDescription
        onChange?()
        return .cancel
      }
    }
    return .allow
  }

  func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async
    -> WKNavigationResponsePolicy
  {
    let disposition =
      (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")
      ?? ""
    if !response.canShowMIMEType || disposition.lowercased().hasPrefix("attachment") {
      expectingDownload = true
      return .download
    }
    return .allow
  }
  func webView(
    _ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload
  ) {
    becameDownload(download)
  }
  func webView(
    _ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload
  ) {
    becameDownload(download)
  }
  private func becameDownload(_ download: WKDownload) {
    navigationPending = false
    requestedURL = nil
    failure = nil
    if let onDownload {
      onDownload(download, agentDriven, web.window)
    } else {
      download.cancel(nil)
    }
    onChange?()
  }

  func webView(
    _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
    for action: WKNavigationAction, windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    if let url = action.request.url, ["http", "https"].contains(url.scheme ?? "") {
      onNewTab?(url)
    }
    return nil
  }
  func webView(
    _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
    initiatedByFrame frame: WKFrameInfo
  ) async {
    _ = await dialog(message: message, confirm: false)
  }
  func webView(
    _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
    initiatedByFrame frame: WKFrameInfo
  ) async -> Bool {
    await dialog(message: message, confirm: true)
  }
  func webView(
    _ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
    defaultText: String?, initiatedByFrame frame: WKFrameInfo
  ) async -> String? {
    guard let window = web.window, !web.isHiddenOrHasHiddenAncestor else { return nil }
    let alert = NSAlert()
    alert.messageText = frame.securityOrigin.host
    alert.informativeText = String(prompt.prefix(4_000))
    let field = NSTextField(string: defaultText ?? "")
    field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
    alert.accessoryView = field
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = field
    return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
      ? field.stringValue : nil
  }
  func webView(
    _ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
    initiatedByFrame frame: WKFrameInfo
  ) async -> [URL]? {
    guard let window = web.window, !web.isHiddenOrHasHiddenAncestor else { return nil }
    let panel = NSOpenPanel()
    panel.message = "Choose files for \(frame.securityOrigin.host)"
    panel.allowsMultipleSelection = parameters.allowsMultipleSelection
    panel.canChooseDirectories = parameters.allowsDirectories
    panel.canChooseFiles = true
    return await panel.beginSheetModal(for: window) == .OK ? panel.urls : nil
  }
  private func dialog(message: String, confirm: Bool) async -> Bool {
    guard let window = web.window, !web.isHiddenOrHasHiddenAncestor else { return false }
    let alert = NSAlert()
    alert.messageText = web.url?.host ?? "Website"
    alert.informativeText = String(message.prefix(4_000))
    alert.addButton(withTitle: "OK")
    if confirm { alert.addButton(withTitle: "Cancel") }
    return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
  }
}

@MainActor final class BrowserProfiles {
  enum DataKinds { case all, cookies, cache }
  private var stores: [String: WKWebsiteDataStore] = [:]
  func clear(profile: String?, kinds: DataKinds) async {
    let types: Set<String>
    switch kinds {
    case .all: types = WKWebsiteDataStore.allWebsiteDataTypes()
    case .cookies:
      types = [
        WKWebsiteDataTypeCookies, WKWebsiteDataTypeLocalStorage,
        WKWebsiteDataTypeIndexedDBDatabases, WKWebsiteDataTypeServiceWorkerRegistrations,
      ]
    case .cache:
      types = [
        WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache,
      ]
    }
    await dataStore(profile: profile).removeData(ofTypes: types, modifiedSince: .distantPast)
  }
  func dataStore(profile: String?) -> WKWebsiteDataStore {
    let profile = profile ?? "default"
    let key = "T3NativeBrowser\n" + profile
    if let store = stores[key] { return store }
    let store: WKWebsiteDataStore
    if profile == "incognito" {
      store = .nonPersistent()
    } else {
      let hash = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
      let identifier = UUID(
        uuid: (
          hash[0], hash[1], hash[2], hash[3], hash[4], hash[5], hash[6], hash[7], hash[8], hash[9],
          hash[10], hash[11], hash[12], hash[13], hash[14], hash[15]
        ))
      store = WKWebsiteDataStore(forIdentifier: identifier)
    }
    stores[key] = store
    return store
  }
}
