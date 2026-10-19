import AppKit
import T3Core

extension ParitySmoke {
  @MainActor static func browserAutomation(
    panel: BrowserPanel, store: ClientStore, connection: RPCConnection,
    threadID: String, alternate: String, fixture: URL
  ) async throws {
    var tabID: String?
    func action(
      _ operation: String, _ input: [String: JSON] = [:], thread: String? = nil,
      timeout: Int = 15_000
    ) async throws -> JSON {
      var request: [String: JSON] = [
        "requestId": .string(UUID().uuidString), "threadId": .string(thread ?? threadID),
        "operation": .string(operation), "input": .object(input),
      ]
      if let tabID { request["tabId"] = .string(tabID) }
      return try await panel.automate(
        .object(request), deadline: BrowserAutomationDeadline(milliseconds: timeout))
    }
    func evaluate(_ expression: String) async throws -> JSON {
      try await action("evaluate", ["expression": .string(expression)])
    }
    let opened = try await action(
      "open",
      [
        "url": .string(fixture.absoluteString), "open": .bool(false),
        "reuseExistingTab": .bool(false),
      ])
    tabID = try opened.requiredString("tabId")
    guard opened["title"].string == "Browser fixture One", opened["visible"] == .bool(false) else {
      throw T3Error("Background browser open was not ready or changed visibility.")
    }
    print("Browser automation: hidden open and loaded status")
    _ = try await action(
      "type",
      ["locator": .string("css=#draft"), "text": .string("hello native"), "clear": .bool(true)])
    guard try await evaluate("document.querySelector('#draft').value") == .string("hello native")
    else { throw T3Error("Browser typing failed.") }
    _ = try await action("press", ["key": .string("ArrowLeft")])
    _ = try await action("type", ["text": .string("!")])
    guard try await evaluate("document.querySelector('#draft').value") == .string("hello nativ!e")
    else { throw T3Error("Browser key input missed the active field.") }
    _ = try await action("press", ["key": .string("a"), "modifiers": .array([.string("Meta")])])
    _ = try await action("type", ["text": .string("selected all")])
    guard try await evaluate("document.querySelector('#draft').value") == .string("selected all")
    else {
      throw T3Error("Browser Command-A did not select the field's text.")
    }
    _ = try await action(
      "click", ["locator": .string("internal:role=button[name=\"Trusted click\"s]")])
    guard try await evaluate("window.trustedClick") == .bool(true) else {
      throw T3Error("Browser click was not trusted or hit the wrong element.")
    }
    print("Browser automation: Playwright role locator, trusted click, typing and native arrow key")
    _ = try await action(
      "type",
      [
        "selector": .string("input[name=search]"), "text": .string("native enter"),
        "clear": .bool(true),
      ])
    _ = try await action("press", ["key": .string("Enter")])
    _ = try await action(
      "waitFor",
      ["urlIncludes": .string("search=native+enter"), "text": .string("Browser fixture Two")])
    _ = try await action(
      "navigate",
      [
        "url": .string(
          fixture.deletingLastPathComponent().appendingPathComponent("redirect").absoluteString)
      ])
    guard try await evaluate("location.pathname") == .string("/two") else {
      throw T3Error("Redirect returned before its document loaded.")
    }
    _ = try await action(
      "navigate",
      ["url": .string(fixture.absoluteString), "readiness": .string("domContentLoaded")])
    guard try await evaluate("document.title") == .string("Browser fixture One") else {
      throw T3Error("DOMContentLoaded returned the previous document.")
    }
    print("Browser automation: form Enter, combined wait, redirects and document readiness")
    let resized = try await action(
      "resize", ["mode": .string("freeform"), "width": .number(667), "height": .number(375)])
    guard resized["viewport"]["width"].int == 667, resized["viewport"]["height"].int == 375 else {
      throw T3Error("Automation viewport did not apply.")
    }
    _ = try await action("setColorScheme", ["colorScheme": .string("light")])
    _ = try await action("waitFor", ["selector": .string("#draft")])
    _ = try await action("scroll", ["deltaY": .number(200)])
    guard (try await evaluate("scrollY")).int ?? 0 > 0 else {
      throw T3Error("Browser scroll did not move the page.")
    }
    let snapshot = try await action("snapshot")
    guard snapshot["interactiveElements"].array.count >= 5,
      snapshot["accessibilityTree"].string?.contains("Browser fixture One") == true,
      let png = snapshot["screenshot"]["data"].string.flatMap({ Data(base64Encoded: $0) }),
      let bitmap = NSBitmapImageRep(data: png), bitmap.pixelsWide > 0,
      bitmap.colorAt(x: 10, y: 10)?.usingColorSpace(.deviceRGB)?.blueComponent ?? 1 < 0.5
    else { throw T3Error("Browser snapshot omitted content or captured a blank hidden page.") }
    print("Browser automation: hidden screenshot, accessible tree, viewport, appearance and scroll")
    do {
      _ = try await action("click", ["selector": .string("button")])
      throw T3Error("Ambiguous selector was accepted.")
    } catch let error as BrowserAutomationError {
      guard error.tag == "PreviewAutomationInvalidSelectorError" else { throw error }
    }
    do {
      _ = try await action("type", ["selector": .string("h1"), "text": .string("wrong")])
      throw T3Error("Noneditable target was accepted.")
    } catch let error as BrowserAutomationError {
      guard error.tag == "PreviewAutomationTargetNotEditableError" else { throw error }
    }
    do {
      _ = try await action("waitFor", ["text": .string("does not exist")], timeout: 250)
      throw T3Error("Missing text did not time out.")
    } catch let error as BrowserAutomationError {
      guard error.tag == "PreviewAutomationTimeoutError" else { throw error }
    }
    do {
      _ = try await action("status", thread: alternate)
      throw T3Error("Cross-conversation tab access was accepted.")
    } catch let error as BrowserAutomationError {
      guard error.tag == "PreviewAutomationTabNotFoundError" else { throw error }
    }
    let pending = Task {
      try await action("evaluate", ["expression": .string("new Promise(() => {})")])
    }
    try await Task.sleep(for: .milliseconds(100))
    pending.cancel()
    do {
      _ = try await pending.value
      throw T3Error("Browser script cancellation failed.")
    } catch is CancellationError {}
    _ = try await evaluate("window.retainedAutomationState='kept'; true")
    store.select(alternate)
    try await waitForStore(store) { store.canEditThread && store.selectedID == alternate }
    store.onChange = { panel.refresh(active: true) }
    panel.refresh(active: true)
    guard try await evaluate("window.retainedAutomationState") == .string("kept"),
      store.selectedID == alternate
    else { throw T3Error("Background action discarded state or selected its conversation.") }
    let beforePopup = try await connection.call(
      "preview.list", payload: .object(["threadId": .string(threadID)]))
    let originalTabs = Set(beforePopup["sessions"].array.compactMap { $0["tabId"].string })
    _ = try await action("click", ["selector": .string("#popup")])
    var popupID: String?
    for _ in 0..<100 {
      let afterPopup = try await connection.call(
        "preview.list", payload: .object(["threadId": .string(threadID)]))
      popupID = afterPopup["sessions"].array.compactMap { $0["tabId"].string }.first {
        !originalTabs.contains($0)
      }
      if popupID != nil { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    guard let popupID, store.selectedID == alternate else {
      throw T3Error("Background popup was lost or changed the selected conversation.")
    }
    _ = try await connection.call(
      "preview.close", payload: .object(["threadId": .string(threadID), "tabId": .string(popupID)]))
    print(
      "Browser automation: strict selectors, editable targets, timeout, cancellation and conversation isolation"
    )
    if let file = Arguments.value("--browser-broker-fixture") {
      try await browserAutomationBroker(
        panel: panel, settings: ConnectionSettings.load(URL(fileURLWithPath: file)),
        threadID: threadID, tabID: tabID!)
    }
    let focusedWindow = NSApp.keyWindow
    let revealed = try await action("open", ["open": .bool(true)])
    guard revealed["visible"].bool, NSApp.keyWindow === focusedWindow, store.selectedID == alternate
    else {
      throw T3Error("Floating preview was hidden or took focus from the selected conversation.")
    }
    print("Browser automation: floating preview reveals without taking keyboard focus")
    var downloadPrompted = false
    panel.downloads.chooseDestination = { _, _ in
      downloadPrompted = true
      return nil
    }
    _ = try await action("click", ["selector": .string("#download")])
    let downloadDeadline = Date().addingTimeInterval(10)
    while panel.downloads.items.isEmpty || panel.downloads.activeCount > 0 {
      guard Date() < downloadDeadline else {
        throw T3Error("Agent download did not finish in the browser panel.")
      }
      try await Task.sleep(for: .milliseconds(25))
    }
    guard !downloadPrompted, let item = panel.downloads.items.first, item.state == .finished,
      let file = item.file, FileManager.default.fileExists(atPath: file.path)
    else {
      throw T3Error("Agent action opened Save or failed to save its browser download.")
    }
    print("Browser automation: page controller routes downloads to an automatic destination")
    _ = try await connection.call(
      "preview.close", payload: .object(["threadId": .string(threadID), "tabId": .string(tabID!)]))
    store.select(threadID)
    try await waitForStore(store) { store.canEditThread && store.selectedID == threadID }
    store.onChange = { panel.refresh(active: true) }
    panel.refresh(active: true)
  }

  @MainActor private static func browserAutomationBroker(
    panel: BrowserPanel, settings: ConnectionSettings,
    threadID: String, tabID: String
  ) async throws {
    guard BrowserURL.loopback(settings.endpoint.host ?? "") else {
      throw T3Error("Broker fixture must run on loopback.")
    }
    let connection = RPCConnection(settings: settings)
    let host = BrowserAutomationHost()
    host.handle = { try await panel.automate($0, deadline: $1) }
    host.liveTabs = {
      [.object(["threadId": .string(threadID), "tabId": .string(tabID), "visible": .bool(false)])]
    }
    defer {
      host.synchronize(connection: nil, environmentID: nil)
      Task { await connection.close() }
    }
    func wait(_ condition: () -> Bool) async throws {
      let end = Date().addingTimeInterval(5)
      while !condition() {
        if let error = host.error { throw T3Error(error) }
        guard Date() < end else {
          throw T3Error("Broker fixture host did not reach the expected state.")
        }
        try await Task.sleep(for: .milliseconds(20))
      }
    }
    func invoke(_ operation: String, _ input: [String: JSON] = [:], timeout: Int = 5000)
      async throws -> JSON
    {
      var request = settings.request("/invoke", method: "POST")
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSON.object([
        "threadId": .string(threadID), "tabId": .string(tabID),
        "operation": .string(operation), "input": .object(input),
        "timeoutMs": .number(Double(timeout)),
      ]).data()
      let result = try await EnvironmentHTTP.read(request)
      guard result["ok"].bool else {
        throw BrowserAutomationError(
          result["error"]["_tag"].string ?? "BrokerError",
          result["error"]["message"].string ?? "Broker request failed.")
      }
      return result["result"]
    }
    try await connection.open()
    host.synchronize(connection: connection, environmentID: "native-browser-fixture")
    let end = Date().addingTimeInterval(5)
    var initial = JSON.null
    repeat {
      initial = try await EnvironmentHTTP.read(settings.request("/status"))
      if initial["focusCount"].int ?? 0 > 0 { break }
      guard Date() < end else { throw T3Error("The agent host did not register with the broker.") }
      try await Task.sleep(for: .milliseconds(20))
    } while true
    let status = try await invoke("status")
    guard status["tabId"].string == tabID else {
      throw T3Error("Broker routed the wrong browser tab.")
    }
    _ = try await invoke(
      "type",
      [
        "selector": .string("#draft"), "text": .string("routed through broker"),
        "clear": .bool(true),
      ])
    guard
      try await invoke(
        "evaluate", ["expression": .string("document.querySelector('#draft').value")])
        == .string("routed through broker")
    else { throw T3Error("Broker response did not contain the real page result.") }
    let first = Task {
      try await invoke(
        "evaluate",
        [
          "expression": .string(
            "new Promise(resolve => setTimeout(() => { window.nativeOrder=[1]; resolve(true); }, 200))"
          )
        ])
    }
    try await wait { host.running == 1 }
    let second = Task {
      try await invoke(
        "evaluate", ["expression": .string("window.nativeOrder.push(2); window.nativeOrder")])
    }
    _ = try await first.value
    guard try await second.value == .array([.number(1), .number(2)]) else {
      throw T3Error("Broker actions ran out of order.")
    }
    let active = Task { try await invoke("waitFor", ["text": .string("missing active target")]) }
    try await wait { host.running == 1 }
    let queued = Task {
      try await invoke("evaluate", ["expression": .string("window.shouldNeverExecute=true")])
    }
    try await wait { host.running == 2 }
    host.interrupt(threadID: threadID)
    for task in [active, queued] {
      do {
        _ = try await task.value
        throw T3Error("Interrupted browser action completed successfully.")
      } catch let error as BrowserAutomationError {
        guard error.tag == "PreviewAutomationControlInterruptedError" else { throw error }
      }
    }
    host.setPaused(true)
    do {
      _ = try await invoke("status")
      throw T3Error("Paused browser accepted an agent action.")
    } catch let error as BrowserAutomationError {
      guard error.tag == "PreviewAutomationControlInterruptedError" else { throw error }
    }
    host.setPaused(false)
    do {
      _ = try await invoke(
        "evaluate", ["expression": .string("new Promise(() => {})")], timeout: 1000)
      throw T3Error("Unresolved page promise did not time out through the broker.")
    } catch let error as BrowserAutomationError {
      guard error.tag == "PreviewAutomationTimeoutError" else { throw error }
    }
    guard
      try await invoke("evaluate", ["expression": .string("window.shouldNeverExecute ?? false")])
        == .bool(false)
    else { throw T3Error("A cancelled queued action reached the page.") }
    host.retry()
    var ready = false
    for _ in 0..<100 {
      let state = try await EnvironmentHTTP.read(settings.request("/status"))
      if state["focusCount"].int ?? 0 > initial["focusCount"].int ?? 0, state["connected"].int == 1
      {
        ready = true
        break
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    guard ready, try await invoke("status")["tabId"].string == tabID else {
      throw T3Error("Agent browser reconnect failed.")
    }
    print(
      "Browser automation: real broker registration, routing, responses, ordered actions, active/queued cancellation, pause/resume and reconnect"
    )
  }
}
