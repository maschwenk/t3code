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
      let blocked = try BrowserTab(
        await connection.call(
          "preview.navigate",
          payload: .object([
            "threadId": .string(threadID), "tabId": .string(tab.id),
            "url": .string("http://localhost:1/unavailable"),
          ])))
      page.receive(blocked)
      let deadline = Date().addingTimeInterval(10)
      while page.failure == nil && Date() < deadline {
        try await Task.sleep(for: .milliseconds(50))
      }
      guard page.failure != nil else {
        throw T3Error("WebKit rejected an address without showing an error.")
      }
      let restored = try BrowserTab(
        await connection.call(
          "preview.navigate",
          payload: .object([
            "threadId": .string(threadID), "tabId": .string(tab.id),
            "url": .string(fixture.absoluteString),
          ])))
      page.receive(restored, navigate: true)
      try await wait { !page.web.isLoading && page.web.title == "Browser fixture One" }
      guard page.failure == nil else {
        throw T3Error("Browser navigation did not recover after an error.")
      }
      print("Browser smoke: blocked address reports failure and recovers on valid navigation")
      try await browserDownloads(page: page)
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
    let preferences = BrowserPreferences(file: directory.appendingPathComponent("browser.json"))
    let panel = BrowserPanel(
      store: store, preferences: preferences,
      downloads: BrowserDownloads(agentDirectory: directory.appendingPathComponent("downloads")))
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
      func expectViewport(_ setting: BrowserViewport) async throws {
        panel.resize(setting)
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
          panel.view.layoutSubtreeIfNeeded()
          if let actual = try await regular.evaluateJavaScript("[innerWidth,innerHeight]")
            as? [Int],
            actual == [setting.width!, setting.height!]
          {
            return
          }
          try await Task.sleep(for: .milliseconds(50))
        }
        let actual = try await regular.evaluateJavaScript("[innerWidth,innerHeight]")
        throw T3Error(
          "Requested viewport \(setting.width!) × \(setting.height!), got \(String(describing: actual))."
        )
      }
      let phone = BrowserDevicePreset.all[0].viewport
      try await expectViewport(phone)
      let stored = try await connection.call(
        "preview.list", payload: .object(["threadId": .string(threadID)]))
      guard stored["sessions"].array.contains(where: { $0["viewport"] == phone.json }) else {
        throw T3Error("Device viewport did not persist on the server.")
      }
      try await expectViewport(phone.rotated)
      regular.pageZoom = 1.5
      try await expectViewport(try BrowserViewport(width: 1024, height: 768))
      guard
        try await regular.evaluateJavaScript("document.getElementById('draft').value") as? String
          == "preserved across conversations"
      else { throw T3Error("Resizing discarded the page form.") }
      regular.pageZoom = 1
      panel.resize(.fill)
      try await wait {
        (views(panel.view).first { $0 is BrowserViewportView } as? BrowserViewportView)?.setting
          == .fill
      }
      print(
        "Browser smoke: preset, rotated and custom CSS viewports, page zoom, server persistence and form retention"
      )
      let alternate = UUID().uuidString
      guard let template = store.selectedThread else { throw T3Error("No browser fixture thread.") }
      _ = try await connection.call(
        "orchestration.dispatchCommand",
        payload: Commands.newThread(
          template: template, id: alternate, title: "Native browser switching verification"))
      try await waitForStore(store) { store.shell.threads[alternate] != nil }
      let regularID = try stored["sessions"].array.first?.requiredString("tabId") ?? ""
      func regularAction(_ operation: String, _ input: [String: JSON]) async throws -> JSON {
        try await panel.automate(
          .object([
            "requestId": .string(UUID().uuidString), "threadId": .string(threadID),
            "tabId": .string(regularID), "operation": .string(operation), "input": .object(input),
          ]), deadline: BrowserAutomationDeadline(milliseconds: 10_000))
      }
      let pendingClick = Task {
        try await regularAction("click", ["selector": .string("#after-switch")])
      }
      defer { pendingClick.cancel() }
      let pendingDeadline = Date().addingTimeInterval(5)
      while true {
        let snapshot = try await regularAction("snapshot", [:])
        if snapshot["actionTimeline"].array.contains(where: {
          $0["action"].string == "click" && $0["status"].string == "running"
        }) {
          break
        }
        guard Date() < pendingDeadline else {
          throw T3Error("Pending click did not start before switching conversations.")
        }
      }
      store.select(alternate)
      try await waitForStore(store) { store.canEditThread && store.selectedID == alternate }
      panel.refresh(active: true)
      try await wait { web() == nil }
      _ = try await regularAction(
        "evaluate",
        [
          "expression": .string(
            "const control=document.createElement('button'); control.id='after-switch'; control.textContent='Deferred control'; control.onclick=()=>window.clickedAfterSwitch=true; document.body.append(control); true"
          )
        ])
      _ = try await pendingClick.value
      guard
        try await regularAction("evaluate", ["expression": .string("window.clickedAfterSwitch")])
          == .bool(true)
      else {
        throw T3Error("Switching conversations detached the page during an agent action.")
      }
      print(
        "Browser smoke: in-flight agent click survives switching away from a manually opened page")
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
      let profile = try preferences.create("Smoke profile")
      let otherProfile = try preferences.create("Other smoke profile")
      let profiles = BrowserProfiles()
      do {
        try preferences.update {
          $0.defaultProfileID = profile.id
          $0.viewport = BrowserDevicePreset.all[0].viewport.json
          $0.zoom = 1.25
          $0.appearance = "dark"
          $0.showAgentPreview = false
        }
        panel.open(fixture.absoluteString, newTab: true)
        try await wait {
          web() !== privateWeb && web()?.title == "Browser fixture One" && web()?.isLoading == false
        }
        guard let custom = web() else { throw T3Error("New profile tab has no page.") }
        panel.view.layoutSubtreeIfNeeded()
        let dimensions = try await custom.evaluateJavaScript("[innerWidth,innerHeight]") as? [Int]
        guard custom.pageZoom == 1.25, custom.appearance?.name == .darkAqua,
          dimensions == [375, 667]
        else {
          throw T3Error(
            "New tab ignored defaults: zoom \(custom.pageZoom), appearance \(String(describing: custom.appearance?.name)), viewport \(String(describing: dimensions))."
          )
        }
        let profileCookie = HTTPCookie(properties: [
          .domain: "localhost", .path: "/", .name: cookie, .value: "custom",
          .expires: Date().addingTimeInterval(3600),
        ])!
        await custom.configuration.websiteDataStore.httpCookieStore.setCookie(profileCookie)
        let cookies = await profiles.dataStore(profile: profile.id).httpCookieStore.allCookies()
        guard cookies.contains(where: { $0.name == cookie }),
          await profiles.dataStore(profile: otherProfile.id).httpCookieStore.allCookies().isEmpty
        else { throw T3Error("Browser profiles did not isolate or restore their cookie stores.") }
        await profiles.dataStore(profile: otherProfile.id).httpCookieStore.setCookie(profileCookie)
        await profiles.clear(profile: profile.id, kinds: .cookies)
        guard await custom.configuration.websiteDataStore.httpCookieStore.allCookies().isEmpty,
          await profiles.dataStore(profile: otherProfile.id).httpCookieStore.allCookies().contains(
            where: { $0.name == cookie })
        else { throw T3Error("Clearing one profile affected another profile.") }
        let opened = try await panel.automate(
          .object([
            "requestId": .string(UUID().uuidString), "threadId": .string(alternate),
            "operation": .string("open"),
            "input": .object([
              "url": .string(fixture.absoluteString), "reuseExistingTab": .bool(false),
            ]),
          ]), deadline: BrowserAutomationDeadline(milliseconds: 15_000))
        let agentTabs = try await connection.call(
          "preview.list", payload: .object(["threadId": .string(alternate)]))
        guard opened["visible"] == .bool(false),
          agentTabs["sessions"].array.contains(where: {
            $0["tabId"] == opened["tabId"] && $0["profileId"].string == profile.id
              && $0["viewport"] == preferences.values.viewport
          })
        else { throw T3Error("Agent tab ignored profile, viewport or presentation preferences.") }
        _ = try await connection.call(
          "preview.close",
          payload: .object(["threadId": .string(alternate), "tabId": opened["tabId"]]))
        try preferences.rename(profile.id, to: "Renamed smoke profile")
        try preferences.remove(profile.id)
        guard preferences.values.defaultProfileID == "default" else {
          throw T3Error("Removed default profile did not fall back to Default.")
        }
        try preferences.update { $0 = BrowserPreferenceValues() }
        await profiles.clear(profile: profile.id, kinds: .all)
        await profiles.clear(profile: otherProfile.id, kinds: .all)
      } catch {
        await profiles.clear(profile: profile.id, kinds: .all)
        await profiles.clear(profile: otherProfile.id, kinds: .all)
        throw error
      }
      print(
        "Browser smoke: saved manual and agent defaults, profile cookie isolation and scoped clearing"
      )
      try await browserAutomation(
        panel: panel, store: store, connection: connection, threadID: threadID,
        alternate: alternate, fixture: fixture)
      try await cleanTabs()
    } catch {
      try? await cleanTabs()
      throw error
    }
  }
}
