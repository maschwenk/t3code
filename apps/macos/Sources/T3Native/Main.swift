import AppKit
import T3Core

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
  private let store = ClientStore()
  private var controller: ChatWindow?

  func applicationDidFinishLaunching(_ notification: Notification) {
    let controller = ChatWindow(store: store)
    self.controller = controller
    controller.showWindow(nil)
    NSApp.activate(ignoringOtherApps: true)
    do {
      if let path = Arguments.value("--connection-file") {
        store.connect(try ConnectionSettings.load(URL(fileURLWithPath: path)))
      } else if let settings = Credentials.load() {
        store.connect(settings)
      }
    } catch {
      store.error = error.localizedDescription
      controller.refresh()
    }
  }

  func applicationWillTerminate(_ notification: Notification) { store.disconnect() }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !store.saveDraftsBeforeExit() else { return .terminateNow }
    let alert = NSAlert()
    alert.messageText = "Drafts could not be saved"
    alert.informativeText =
      store.storageError ?? "Keep the app open to preserve your unsent drafts."
    alert.addButton(withTitle: "Keep open")
    alert.addButton(withTitle: "Quit without saving")
    return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

enum Arguments {
  static func value(_ flag: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: flag),
      CommandLine.arguments.indices.contains(index + 1)
    else { return nil }
    return CommandLine.arguments[index + 1]
  }
}

@main enum Main {
  @MainActor static func main() {
    if CommandLine.arguments.contains("--smoke") || CommandLine.arguments.contains("--parity-smoke")
    {
      Task {
        do {
          if CommandLine.arguments.contains("--parity-smoke") {
            try await ParitySmoke.run()
          } else {
            try await Smoke.run()
          }
          exit(0)
        } catch {
          fputs("Native smoke failed: \(error.localizedDescription)\n", stderr)
          exit(1)
        }
      }
      RunLoop.main.run()
      return
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let mainMenu = NSMenu()
    let appItem = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(
      withTitle: "About T3 Native",
      action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    appMenu.addItem(.separator())
    appMenu.addItem(
      withTitle: "Quit T3 Native", action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q")
    appItem.submenu = appMenu
    mainMenu.addItem(appItem)
    let edit = NSMenuItem()
    edit.title = "Edit"
    edit.submenu = NSMenu(title: "Edit")
    for (title, action, key) in [
      ("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
      ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a"),
    ] {
      edit.submenu?.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
    }
    mainMenu.addItem(edit)
    app.mainMenu = mainMenu
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
  }
}

enum Smoke {
  static func run() async throws {
    guard let path = Arguments.value("--connection-file") else {
      throw T3Error("--connection-file is required.")
    }
    let settings = try ConnectionSettings.load(URL(fileURLWithPath: path))
    let connection = RPCConnection(settings: settings)
    let watchdog = Task {
      try await Task.sleep(for: .seconds(120))
      await connection.close(error: T3Error("Smoke test timed out."))
    }
    defer {
      watchdog.cancel()
      Task { await connection.close() }
    }
    let start = Date()
    try await connection.open()
    let subscription = try await connection.subscribe(
      "orchestration.subscribeShell", payload: .object(["requestCompletionMarker": .bool(true)]))
    var shell = ShellState()
    for try await value in subscription.values {
      try shell.apply(value)
      if shell.synchronized { break }
    }
    await connection.cancel(subscription.id)
    guard let template = shell.threads.values.sorted(by: { $0.updatedAt > $1.updatedAt }).first
    else { throw T3Error("No threads in this environment.") }
    let id = Arguments.value("--thread-id") ?? template.id
    let detail = try await connection.subscribe(
      "orchestration.subscribeThread",
      payload: .object([
        "threadId": .string(id), "requestCompletionMarker": .bool(true),
        "acceptBoundedSnapshot": .bool(true),
      ]))
    var thread = ThreadState(id: id)
    for try await value in detail.values {
      _ = try thread.apply(value)
      if thread.synchronized { break }
    }
    await connection.cancel(detail.id)
    guard thread.synchronized else { throw T3Error("Thread never synchronized.") }
    let initialRows = thread.rows.count
    if let cursor = thread.cursor, thread.hasMore {
      let page = try await EnvironmentHTTP.read(
        settings.request(
          "/api/orchestration/threads/\(id)/history",
          query: [URLQueryItem(name: "cursor", value: cursor)]))
      try thread.prependHistory(page)
    }
    print(
      "Connected: \(shell.projects.count) projects, \(shell.threads.count) threads; \(initialRows) recent rows, \(thread.rows.count) after history page; \(Int(Date().timeIntervalSince(start) * 1000)) ms to read."
    )
    if CommandLine.arguments.contains("--attachment-preview-smoke") {
      let cache = AttachmentPreviewCache()
      let attachments = thread.rows.flatMap { $0.item["attachments"].array }
      guard !attachments.isEmpty else { throw T3Error("The selected thread has no attachments.") }
      var images = 0
      for attachment in attachments {
        let request = try AttachmentPreviewRequest.remote(
          attachment, connection: connection, settings: settings)
        let file = try await cache.file(for: request)
        let reused = try await cache.file(for: request)
        guard file === reused else { throw T3Error("The preview cache did not reuse the file.") }
        if attachment["type"].string == "image" {
          let thumbnail = try await cache.thumbnail(for: request)
          guard thumbnail.width <= 512, thumbnail.height <= 512 else {
            throw T3Error("The thumbnail exceeded its decode limit.")
          }
          images += 1
        }
      }
      print(
        "PASS: \(attachments.count) signed attachment previews, \(images) decoded thumbnails, cached file reuse."
      )
    }
    if CommandLine.arguments.contains("--send-smoke") {
      guard let project = Arguments.value("--sandbox-project") else {
        throw T3Error("--send-smoke requires --sandbox-project (an isolated project ID).")
      }
      let configs = try await connection.subscribe("subscribeServerConfig")
      var model = JSON.null
      for try await value in configs.values {
        if let provider = value["config"]["providers"].array.first(where: {
          $0["instanceId"].string == "codex" && $0["status"].string == "ready"
        }),
          let choice = provider["models"].array.first(where: { $0["slug"].string == "gpt-6.1-sol" })
            ?? provider["models"].array.first
        {
          model = .object(["instanceId": provider["instanceId"], "model": choice["slug"]])
        }
        break
      }
      await connection.cancel(configs.id)
      guard model != .null else {
        throw T3Error("Smoke test needs an authenticated Codex provider.")
      }
      let templateJSON: JSON = .object([
        "id": .string(template.id), "projectId": .string(project), "title": .string("Native smoke"),
        "modelSelection": model, "runtimeMode": .string("approval-required"),
        "interactionMode": .string("default"),
      ])
      let testID = UUID().uuidString
      _ = try await connection.call(
        "orchestration.dispatchCommand",
        payload: Commands.newThread(
          template: ThreadSummary(templateJSON), id: testID, title: "Native client smoke"))
      let stream = try await connection.subscribe(
        "orchestration.subscribeThread",
        payload: .object(["threadId": .string(testID), "acceptBoundedSnapshot": .bool(true)]))
      let command = Commands.message(
        threadID: testID,
        text:
          "Reply with exactly NATIVE_T3_OK. Do not use tools, inspect files, or execute commands.",
        commandID: UUID().uuidString, messageID: UUID().uuidString)
      let receipt = try await connection.call("orchestration.dispatchCommand", payload: command)
      // A repeated command must resolve to the same receipt, not send another turn.
      let retryReceipt = try await connection.call(
        "orchestration.dispatchCommand", payload: command)
      guard receipt == retryReceipt else {
        throw T3Error("Repeated command returned a different receipt.")
      }
      var events = 0
      for try await value in stream.values {
        if value["kind"].string == "event" { events += 1 }
        let event = value["event"]
        if event["type"].string == "turn-item.updated",
          event["payload"]["type"].string == "assistant_message",
          event["payload"]["text"].string?.contains("NATIVE_T3_OK") == true,
          !event["payload"]["streaming"].bool
        {
          print(
            "PASS: real provider reply streamed through Swift (\(events) events); duplicate dispatch accepted idempotently. Test thread: \(testID)"
          )
          await connection.cancel(stream.id)
          return
        }
        if event["type"].string == "run.updated", event["payload"]["status"].string == "failed" {
          throw T3Error("Provider run failed; inspect the isolated server log.")
        }
      }
      throw T3Error("No completed provider reply received.")
    }
  }
}
