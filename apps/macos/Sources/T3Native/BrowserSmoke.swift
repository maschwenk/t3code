import AppKit
import T3Core
import WebKit

extension ParitySmoke {
  @MainActor static func browser(
    settings: ConnectionSettings, connection: RPCConnection, threadID: String
  ) async throws {
    _ = NSApplication.shared
    guard let text = Arguments.value("--browser-fixture"), let fixture = URL(string: text),
      BrowserURL.loopback(fixture.host ?? ""), BrowserURL.loopback(settings.endpoint.host ?? "")
    else {
      throw T3Error("Browser smoke requires a local --browser-fixture URL and sandbox server.")
    }
    let input: JSON = .object([
      "threadId": .string(threadID), "url": .string(fixture.absoluteString),
      "profileId": .string("incognito"),
    ])
    let tab = try BrowserTab(await connection.call("preview.open", payload: input))
    let page = BrowserPage(
      tab: tab, environment: settings.endpoint, connection: connection, dataStore: .nonPersistent())
    let window = NSWindow(
      contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = "Native browser verification"
    window.contentView = page.web
    window.orderFront(nil)
    defer {
      page.dispose()
      window.close()
    }
    func close() async throws {
      _ = try await connection.call(
        "preview.close",
        payload: .object(["threadId": .string(threadID), "tabId": .string(tab.id)]))
    }
    func wait(_ condition: () -> Bool) async throws {
      let deadline = Date().addingTimeInterval(25)
      while !condition() {
        if let failure = page.failure { throw T3Error(failure) }
        guard Date() < deadline else {
          throw T3Error("Browser navigation timed out at \(page.web.url?.path ?? "blank").")
        }
        try await Task.sleep(for: .milliseconds(30))
      }
    }
    func serverTab(_ title: String) async throws -> BrowserTab {
      let deadline = Date().addingTimeInterval(15)
      while Date() < deadline {
        if let error = page.synchronizationError { throw T3Error(error) }
        let snapshot = try await connection.call(
          "preview.list", payload: .object(["threadId": .string(threadID)]))
        if let value = snapshot["sessions"].array.first(where: { $0["tabId"].string == tab.id }),
          value["navStatus"]["title"].string == title,
          value["navStatus"]["_tag"].string == "Success"
        {
          return try BrowserTab(value)
        }
        try await Task.sleep(for: .milliseconds(50))
      }
      throw T3Error("Browser navigation was not reported to the server.")
    }
    do {
      page.receive(tab)
      try await wait { !page.web.isLoading && page.web.title == "Browser fixture One" }
      let loaded = try await serverTab("Browser fixture One")
      _ = try await page.web.evaluateJavaScript(
        "document.getElementById('draft').value='keep this draft'; window.fixtureMarker='original'; 'ok'"
      )
      page.receive(loaded)
      guard !page.web.isLoading,
        try await page.web.evaluateJavaScript("window.fixtureMarker") as? String == "original"
      else { throw T3Error("A server echo reloaded the browser page.") }
      print("Browser smoke: HTTP load, status reporting and echo without reload")
      _ = try await page.web.evaluateJavaScript("document.getElementById('spa').click(); 'ok'")
      try await wait { page.web.url?.query == "step=2" }
      // URL changes are reported after page scripts have updated the title.
      let spa = try await serverTab("Browser fixture SPA")
      page.receive(spa)
      guard
        try await page.web.evaluateJavaScript("document.getElementById('draft').value") as? String
          == "keep this draft"
      else { throw T3Error("A route change discarded the form.") }
      print("Browser smoke: SPA navigation preserves form state")
      _ = try await page.web.evaluateJavaScript("document.getElementById('next').click(); 'ok'")
      try await wait { !page.web.isLoading && page.web.title == "Browser fixture Two" }
      _ = try await serverTab("Browser fixture Two")
      guard page.web.canGoBack else { throw T3Error("Browser history was not retained.") }
      page.web.goBack()
      try await wait { !page.web.isLoading && page.web.url?.query == "step=2" }
      guard page.web.canGoForward else { throw T3Error("Forward history was lost.") }
      page.web.goForward()
      try await wait { !page.web.isLoading && page.web.title == "Browser fixture Two" }
      var popups: [URL] = []
      page.onNewTab = { popups.append($0) }
      _ = try await page.web.evaluateJavaScript("document.getElementById('popup').click(); 'ok'")
      try await wait { !popups.isEmpty }
      guard popups.count == 1, popups[0].path == "/two" else {
        throw T3Error("Popup navigation opened duplicate tabs.")
      }
      let screenshot = try await page.capture()
      defer { try? FileManager.default.removeItem(at: screenshot.deletingLastPathComponent()) }
      guard let image = NSImage(contentsOf: screenshot), image.size.width > 0 else {
        throw T3Error("Browser screenshot was empty.")
      }
      print("Browser smoke: links, back/forward, popup and screenshot")
      page.reload(hard: true)
      try await wait { !page.web.isLoading && page.web.title == "Browser fixture Two" }
      try await close()
      let remaining = try await connection.call(
        "preview.list", payload: .object(["threadId": .string(threadID)]))
      guard !remaining["sessions"].array.contains(where: { $0["tabId"].string == tab.id }) else {
        throw T3Error("Closed browser tab survived.")
      }
      page.dispose()
      window.orderOut(nil)
      try await browserPanel(
        settings: settings, connection: connection, threadID: threadID, fixture: fixture)
      print("Browser smoke passed. No inference sent.")
    } catch {
      try? await close()
      throw error
    }
  }

  @MainActor private static func browserPanel(
    settings: ConnectionSettings, connection: RPCConnection, threadID: String, fixture: URL
  ) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "t3-browser-smoke-" + UUID().uuidString)
    let store = ClientStore(draftDirectory: directory)
    let panel = BrowserPanel(store: store)
    let window = NSWindow(
      contentRect: NSRect(x: 100, y: 100, width: 850, height: 700),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentViewController = panel
    window.orderFront(nil)
    defer {
      store.onChange = nil
      panel.refresh(active: false)
      store.disconnect()
      window.close()
      try? FileManager.default.removeItem(at: directory)
    }
    func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
    func web() -> WKWebView? { views(panel.view).compactMap { $0 as? WKWebView }.first }
    func wait(_ condition: () -> Bool) async throws {
      let deadline = Date().addingTimeInterval(45)
      while !condition() {
        guard Date() < deadline else { throw T3Error("Browser panel timed out.") }
        try await Task.sleep(for: .milliseconds(50))
      }
    }
    func cleanTabs() async throws {
      _ = try await connection.call(
        "preview.close", payload: .object(["threadId": .string(threadID)]))
    }
    do {
      store.connect(settings, selecting: threadID)
      try await waitForStore(store) { store.canEditThread }
      store.onChange = { panel.refresh(active: true) }
      panel.refresh(active: true)
      try await wait {
        views(panel.view).contains { ($0 as? NSButton)?.title.contains(" · http") == true }
      }
      print("Browser smoke: discovered servers render in the real panel")
      panel.open(fixture.absoluteString, newTab: true)
      try await wait { web()?.title == "Browser fixture One" && web()?.isLoading == false }
      guard let regular = web() else { throw T3Error("No attached browser view.") }
      panel.view.layoutSubtreeIfNeeded()
      guard regular.bounds.height > panel.view.bounds.height - 180 else {
        throw T3Error("The browser page did not fill the panel height.")
      }
      _ = try await regular.evaluateJavaScript(
        "document.getElementById('draft').value='preserved across conversations'; 'ok'")
      let alternate = UUID().uuidString
      guard let template = store.selectedThread else { throw T3Error("No browser fixture thread.") }
      _ = try await connection.call(
        "orchestration.dispatchCommand",
        payload: Commands.newThread(
          template: template, id: alternate, title: "Native browser switching verification"))
      try await waitForStore(store) { store.shell.threads[alternate] != nil }
      store.select(alternate)
      try await waitForStore(store) { store.canEditThread && store.selectedID == alternate }
      panel.refresh(active: true)
      try await wait { web() == nil }
      store.select(threadID)
      try await waitForStore(store) { store.canEditThread && store.selectedID == threadID }
      store.onChange = { panel.refresh(active: true) }
      panel.refresh(active: true)
      try await wait { web() === regular }
      guard
        try await regular.evaluateJavaScript("document.getElementById('draft').value") as? String
          == "preserved across conversations"
      else { throw T3Error("Switching conversations discarded the browser form.") }
      panel.refresh(active: false)
      panel.refresh(active: true)
      try await wait { web() === regular }
      let cookie = "nativeSmoke" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
      _ = try await regular.evaluateJavaScript("document.cookie='\(cookie)=regular; path=/'; 'ok'")
      panel.open(fixture.absoluteString, newTab: true, profile: "incognito")
      try await wait {
        web() !== regular && web()?.title == "Browser fixture One" && web()?.isLoading == false
      }
      guard let privateWeb = web(), !privateWeb.configuration.websiteDataStore.isPersistent,
        let cookies = try await privateWeb.evaluateJavaScript("document.cookie") as? String,
        !cookies.contains(cookie)
      else { throw T3Error("Private tabs shared persistent cookies.") }
      _ = try await regular.evaluateJavaScript(
        "document.cookie='\(cookie)=; path=/; Max-Age=0'; 'ok'")
      print(
        "Browser smoke: full-height layout, conversation/hide state retention, private cookie isolation"
      )
      try await cleanTabs()
    } catch {
      try? await cleanTabs()
      throw error
    }
  }
}
