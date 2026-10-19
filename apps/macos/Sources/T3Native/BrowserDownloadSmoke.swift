import AppKit
import T3Core
import WebKit

extension ParitySmoke {
  @MainActor static func browserDownloads(page: BrowserPage) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "t3-download-smoke-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let downloads = BrowserDownloads(agentDirectory: directory.appendingPathComponent("agent"))
    page.onDownload = { downloads.receive($0, agent: $1, window: $2) }
    let target = directory.appendingPathComponent("chosen.txt")
    var savePrompts = 0
    var selected: URL? = target
    downloads.chooseDestination = { _, _ in
      savePrompts += 1
      return selected
    }
    defer {
      page.onDownload = nil
      try? FileManager.default.removeItem(at: directory)
    }
    func wait(_ condition: () -> Bool) async throws {
      let end = Date().addingTimeInterval(10)
      while !condition() {
        guard Date() < end else {
          throw T3Error(
            "Browser download timed out: "
              + downloads.items.map { "\($0.state): \($0.error ?? "")" }.joined(separator: "; "))
        }
        try await Task.sleep(for: .milliseconds(25))
      }
    }
    func click(_ selector: String) async throws {
      _ = try await page.automation.run(
        "click", input: .object(["selector": .string(selector)]),
        deadline: BrowserAutomationDeadline(milliseconds: 5000))
    }
    func completed(_ count: Int) async throws -> BrowserDownloadItem {
      try await wait { downloads.items.count == count && downloads.activeCount == 0 }
      guard let item = downloads.items.first, item.state == .finished, item.file != nil else {
        throw T3Error(
          "Browser download failed: " + (downloads.items.first?.error ?? "No completed file"))
      }
      return item
    }
    let cookie = HTTPCookie(properties: [
      .domain: "localhost", .path: "/", .name: "downloadSmoke", .value: "signed-in",
    ])!
    await page.web.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
    page.agentDriven = true
    try await click("#download")
    let first = try await completed(1)
    let receivedCookie =
      try first.file.map {
        try String(contentsOf: $0, encoding: .utf8).contains("downloadSmoke=signed-in")
      } ?? false
    guard savePrompts == 0, let firstFile = first.file,
      receivedCookie, page.failure == nil
    else {
      throw T3Error(
        "Agent download mismatch: cookie=\(receivedCookie), prompts=\(savePrompts), navigation=\(page.failure ?? "none")."
      )
    }
    try await click("#blob-download")
    let blob = try await completed(2)
    guard let blobFile = blob.file, blobFile != firstFile,
      try String(contentsOf: blobFile, encoding: .utf8) == "native blob download"
    else {
      throw T3Error("Blob download lost its bytes or replaced another download.")
    }
    try await click("#redirect-download")
    _ = try await completed(3)
    print(
      "Browser downloads: cookies, HTTP redirects, blob exports and unique automatic agent files")

    let monitor = BrowserInputMonitor()
    monitor.register(page)
    let pending = Task {
      try await page.automation.run(
        "evaluate",
        input: .object(["expression": .string("window.takeoverReady=true; new Promise(() => {})")]),
        deadline: BrowserAutomationDeadline(milliseconds: 10_000))
    }
    let end = Date().addingTimeInterval(5)
    while try await page.web.evaluateJavaScript("window.takeoverReady === true") as? Bool != true {
      guard Date() < end else { throw T3Error("Takeover action did not reach the page.") }
      try await Task.sleep(for: .milliseconds(25))
    }
    guard let window = page.web.window else {
      throw T3Error("No browser window for input routing.")
    }
    window.makeFirstResponder(page.web)
    let event = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
      context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
    monitor.receive(event)
    do {
      _ = try await pending.value
      throw T3Error("Human input did not interrupt the pending page action.")
    } catch let error as BrowserAutomationError {
      guard error.tag == "PreviewAutomationControlInterruptedError", !page.agentDriven else {
        throw error
      }
    }
    try Data("original file".utf8).write(to: target)
    try await click("#download")
    let manual = try await completed(4)
    guard savePrompts == 1, manual.file == target, manual.name == target.lastPathComponent,
      try String(contentsOf: target, encoding: .utf8).hasPrefix("native browser download")
    else {
      throw T3Error("Human takeover did not restore the chosen download destination.")
    }
    selected = nil
    try await click("#download")
    try await wait { downloads.items.count == 5 && downloads.activeCount == 0 }
    guard downloads.items.first?.state == .cancelled, savePrompts == 2 else {
      throw T3Error("Cancelling Save did not cancel the download.")
    }
    print("Browser downloads: human input interrupts agent work and restores manual Save or Cancel")

    selected = target
    try Data("keep this file".utf8).write(to: target)
    try await click("#slow-download")
    try await wait { downloads.items.count == 6 && downloads.items[0].received > 0 }
    guard try String(contentsOf: target, encoding: .utf8) == "keep this file" else {
      throw T3Error("An unfinished download replaced the existing file.")
    }
    downloads.cancel(downloads.items[0].id)
    try await wait { downloads.activeCount == 0 }
    guard downloads.items[0].state == .cancelled,
      try String(contentsOf: target, encoding: .utf8) == "keep this file"
    else { throw T3Error("Cancellation lost the existing file.") }
    try await click("#failed-download")
    try await wait { downloads.items.count == 7 && downloads.activeCount == 0 }
    guard downloads.items[0].state == .failed,
      try String(contentsOf: target, encoding: .utf8) == "keep this file",
      try !FileManager.default.contentsOfDirectory(atPath: directory.path).contains(where: {
        $0.hasPrefix(".t3-download-")
      })
    else {
      throw T3Error("Failed download lost an existing file or left a partial file behind.")
    }
    page.agentDriven = true
    try await click("#slow-download")
    try await wait { downloads.items.count == 8 && downloads.items[0].received > 0 }
    page.dispose()
    page.web.removeFromSuperview()
    _ = try await completed(8)
    print(
      "Browser downloads: progress, cancellation, failure cleanup, safe replacement and tab-close survival"
    )
  }
}
