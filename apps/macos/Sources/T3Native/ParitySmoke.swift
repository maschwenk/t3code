import Foundation
import T3Core

enum ParitySmoke {
  @MainActor static func run() async throws {
    guard let file = Arguments.value("--connection-file"),
      let project = Arguments.value("--sandbox-project")
    else {
      throw T3Error(
        "--parity-smoke requires a private --connection-file and an isolated --sandbox-project.")
    }
    let settings = try ConnectionSettings.load(URL(fileURLWithPath: file))
    let connection = RPCConnection(settings: settings)
    let timeout = Task {
      try await Task.sleep(for: .seconds(120))
      await connection.close(error: T3Error("Parity smoke timed out."))
    }
    defer {
      timeout.cancel()
      Task { await connection.close() }
    }
    try await connection.open()
    if let threadID = Arguments.value("--resume-tool-thread") {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "t3-tool-resume-" + UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: directory) }
      let store = ClientStore(draftDirectory: directory)
      store.connect(settings, selecting: threadID)
      defer { store.disconnect() }
      try await waitForStore(store) { store.canEditThread }
      guard store.selectedThread?.projectID == project,
        store.selectedThread?.title == "Native tool output verification"
      else {
        throw T3Error("Resume requires the isolated tool-output test thread.")
      }
      try await toolOutput(store, connection: connection, threadID: threadID, resume: true)
      return
    }
    let configs = try await connection.subscribe("subscribeServerConfig")
    var catalog = ProviderCatalog()
    for try await event in configs.values {
      try catalog.apply(event)
      if event["type"].string == "snapshot" { break }
    }
    await connection.cancel(configs.id)
    guard let provider = catalog.providers.first(where: { $0.id == "codex" && $0.available }),
      let model = provider.models.first(where: { $0.id == "gpt-6.1-sol" }) ?? provider.models.first
    else {
      throw T3Error("Parity smoke requires a configured Codex instance.")
    }
    let id = UUID().uuidString
    let selection = model.selection(instanceID: provider.id)
    let template = try ThreadSummary(
      .object([
        "id": .string(id), "projectId": .string(project),
        "title": .string("Native parity verification"),
        "modelSelection": selection, "runtimeMode": .string("approval-required"),
      ]))
    _ = try await connection.call(
      "orchestration.dispatchCommand",
      payload: Commands.newThread(template: template, id: id, title: "Native parity verification"))
    print("Parity thread: \(id)")
    if CommandLine.arguments.contains("--attachment-smoke") {
      try await attachments(settings: settings, connection: connection, threadID: id)
      return
    }
    func dispatch(_ type: String, fields: [String: JSON]) async throws {
      var fields = fields
      fields["type"] = .string(type)
      fields["threadId"] = .string(id)
      fields["commandId"] = .string(UUID().uuidString)
      _ = try await connection.call("orchestration.dispatchCommand", payload: .object(fields))
    }
    func verify(_ key: String, _ expected: JSON) async throws {
      let projection = try await connection.call(
        "orchestration.getThreadProjection", payload: .object(["threadId": .string(id)]))
      guard projection["thread"][key] == expected else {
        throw T3Error("Read-back mismatch for \(key).")
      }
    }
    for mode in provider.runtimeModes.isEmpty
      ? ["approval-required", "full-access"] : provider.runtimeModes
    {
      try await dispatch("thread.runtime-mode.set", fields: ["runtimeMode": .string(mode)])
      try await verify("runtimeMode", .string(mode))
    }
    try await dispatch(
      "thread.runtime-mode.set", fields: ["runtimeMode": .string("approval-required")])
    try await verify("runtimeMode", .string("approval-required"))
    if let other = provider.models.first(where: { $0.id != model.id }) {
      let changed = other.selection(instanceID: provider.id, preserving: selection)
      try await dispatch("thread.model-selection.set", fields: ["modelSelection": changed])
      try await verify("modelSelection", changed)
    }
    try await dispatch("thread.model-selection.set", fields: ["modelSelection": selection])
    try await verify("modelSelection", selection)
    try await dispatch("thread.interaction-mode.set", fields: ["interactionMode": .string("plan")])
    try await verify("interactionMode", .string("plan"))
    print("Provider catalog, model/options, runtime modes, and plan mode round trips passed.")
    let draftDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "t3-native-smoke-drafts-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: draftDirectory) }
    let store = ClientStore(draftDirectory: draftDirectory)
    store.connect(settings, selecting: id)
    defer { store.disconnect() }
    try await waitForStore(store) { store.canEditThread && store.catalogReady }
    guard store.selectedID == id else { throw T3Error("Controller selected the wrong thread.") }
    if let descriptor = catalog.model(for: selection)?.descriptors.first(where: {
      $0["type"].string == "select" && $0["options"].array.count > 1
    }), let optionID = descriptor["id"].string, let choice = descriptor["options"].array.last {
      store.setModelOption(optionID, value: choice["id"])
      try await waitForStore(store) {
        store.canEditThread
          && store.selectedThread?.model["options"].array.contains {
            $0["id"].string == optionID && $0["value"] == choice["id"]
          } == true
      }
      store.setModel(selection)
      try await waitForStore(store) {
        store.canEditThread && store.selectedThread?.model == selection
      }
    }
    store.drafts[id] = "Draft survives reconnect"
    store.retry()
    try await waitForStore(store) { store.canEditThread && store.catalogReady }
    guard store.drafts[id] == "Draft survives reconnect" else {
      throw T3Error("Controller lost the draft on reconnect.")
    }
    print("ClientStore model options, shell read-back, and reconnect/draft checks passed.")
    store.disconnect()
    let reopened = ClientStore(draftDirectory: draftDirectory)
    reopened.connect(settings, selecting: id)
    try await waitForStore(reopened) { reopened.canEditThread && reopened.catalogReady }
    guard reopened.drafts[id] == "Draft survives reconnect" else {
      throw T3Error("Draft did not survive a new controller instance.")
    }
    reopened.disconnect()
    store.connect(settings, selecting: id)
    try await waitForStore(store) { store.canEditThread && store.catalogReady }
    print("Draft restored in a fresh app controller.")
    store.rename(id, to: "Native thread lifecycle verification")
    try await waitForStore(store) {
      !store.lifecycleBusy(id)
        && store.selectedThread?.title == "Native thread lifecycle verification"
    }
    store.setPinned(id, true)
    try await waitForStore(store) {
      !store.lifecycleBusy(id) && store.selectedThread?.lifecycle.pinned == true
    }
    store.setSettled(id, true)
    try await waitForStore(store) {
      !store.lifecycleBusy(id) && store.selectedThread?.lifecycle.settled == true
        && store.selectedThread?.lifecycle.pinned == false
    }
    store.setSettled(id, false)
    try await waitForStore(store) {
      !store.lifecycleBusy(id) && store.selectedThread?.lifecycle.settled == false
    }
    let wake = Date().addingTimeInterval(3600)
    store.snooze(id, until: wake)
    try await waitForStore(store) {
      !store.lifecycleBusy(id) && store.selectedThread?.lifecycle.snoozed(at: Date()) == true
    }
    store.setPinned(id, true)
    try await waitForStore(store) {
      !store.lifecycleBusy(id) && store.selectedThread?.lifecycle.pinned == true
        && store.selectedThread?.lifecycle.snoozedUntil == nil
    }
    store.setPinned(id, false)
    try await waitForStore(store) {
      !store.lifecycleBusy(id) && store.selectedThread?.lifecycle.pinned == false
    }
    store.setAutoSettle(id, enabled: false)
    try await waitForStore(store) {
      !store.lifecycleBusy(id) && store.selectedThread?.lifecycle.autoSettleDisabled == true
    }
    store.setAutoSettle(id, enabled: true)
    try await waitForStore(store) {
      !store.lifecycleBusy(id) && store.selectedThread?.lifecycle.autoSettleDisabled == false
    }
    store.markVisibleThreadRead()
    try await waitForStore(store) { store.selectedThread?.lifecycle.lastVisitedAt != nil }
    store.showArchives(true)
    try await waitForStore(store) { store.archives.synchronized }
    store.setArchived(id, true)
    try await waitForStore(store) {
      !store.lifecycleBusy(id) && store.shell.threads[id] == nil
        && store.archives.threads[id] != nil
    }
    store.select(id)
    try await waitForStore(store) { store.thread?.synchronized == true }
    guard !store.canEditThread else { throw T3Error("Archived composer remained editable.") }
    store.setArchived(id, false)
    try await waitForStore(store) {
      !store.lifecycleBusy(id) && store.shell.threads[id] != nil
        && store.archives.threads[id] == nil
    }
    store.showArchives(false)
    store.select(id, force: true)
    try await waitForStore(store) { store.canEditThread }
    guard store.drafts[id] == "Draft survives reconnect" else {
      throw T3Error("Thread lifecycle lost the draft.")
    }
    print(
      "Thread rename, pin/settle/snooze, auto-settle, visit, archive/restore, and draft retention round trips passed."
    )
    if CommandLine.arguments.contains("--tool-output-smoke") {
      try await dispatch(
        "thread.interaction-mode.set", fields: ["interactionMode": .string("default")])
      store.rename(id, to: "Native tool output verification")
      try await waitForStore(store) {
        !store.lifecycleBusy(id) && store.selectedThread?.title == "Native tool output verification"
      }
      try await toolOutput(store, connection: connection, threadID: id)
      return
    }
    let manualQuestion = CommandLine.arguments.contains("--manual-question")
    guard CommandLine.arguments.contains("--question-smoke") || manualQuestion else {
      try await dispatch(
        "thread.interaction-mode.set", fields: ["interactionMode": .string("default")])
      return
    }
    if manualQuestion {
      store.rename(id, to: "Native question UI verification")
      try await waitForStore(store) {
        !store.lifecycleBusy(id) && store.selectedThread?.title == "Native question UI verification"
      }
    }
    let stream = try await connection.subscribe(
      "orchestration.subscribeThread",
      payload: .object([
        "threadId": .string(id), "requestCompletionMarker": .bool(true),
        "acceptBoundedSnapshot": .bool(true),
      ]))
    defer { Task { await connection.cancel(stream.id) } }
    _ = try await connection.call(
      "orchestration.dispatchCommand",
      payload: Commands.message(
        threadID: id,
        text:
          "This is an interaction test. Use the request_user_input tool to ask one question, Which color?, with choices Blue and Green. Wait for the answer, then reply with exactly NATIVE_QUESTION_OK. Do not execute commands, inspect files, or use any other tool.",
        commandID: UUID().uuidString, messageID: UUID().uuidString))
    var state = ThreadState(id: id)
    var answered = Set<String>()
    for try await event in stream.values {
      _ = try state.apply(event)
      for request in state.pendingRequests
      where request.isQuestion && request.canRespond && !answered.contains(request.id) {
        if manualQuestion {
          print(
            "Real provider question is pending in Native question UI verification. Complete it in the app."
          )
          return
        }
        var drafts: [String: QuestionDraft] = [:]
        for question in request.questions {
          guard let questionID = question["id"].string else { continue }
          var draft = QuestionDraft()
          if let option = question["options"].array.first {
            draft.selected = [option["value"].string ?? option["label"].string ?? ""]
          } else {
            draft.custom = "Blue"
          }
          drafts[questionID] = draft
        }
        guard let answers = request.answers(from: drafts) else {
          throw T3Error("Provider question could not be answered.")
        }
        try await waitForStore(store) {
          store.thread?.pendingRequests.contains(where: { $0.id == request.id }) == true
        }
        guard let actual = store.thread?.pendingRequests.first(where: { $0.id == request.id })
        else { throw T3Error("Controller missed the request.") }
        store.questionDrafts[request.id] = drafts
        guard actual.answers(from: drafts) == answers else {
          throw T3Error("Controller question disagrees with wire projection.")
        }
        store.respond(actual)
        try await waitForStore(store) {
          store.thread?.pendingRequests.contains(where: { $0.id == request.id }) == false
        }
        answered.insert(request.id)
        print("Answered one real provider question.")
      }
      if !answered.isEmpty, state.pendingRequests.isEmpty,
        state.rows.contains(where: {
          $0.kind == "assistant_message" && !$0.streaming && $0.text.contains("NATIVE_QUESTION_OK")
        })
      {
        print("Question response, resolved state, and completed provider reply passed.")
        return
      }
    }
    throw T3Error("Question stream ended before verification completed.")
  }

  @MainActor private static func toolOutput(
    _ store: ClientStore, connection: RPCConnection, threadID: String, resume: Bool = false
  ) async throws {
    let stream = try await connection.subscribe(
      "orchestration.subscribeThread",
      payload: .object([
        "threadId": .string(threadID), "requestCompletionMarker": .bool(true),
        "acceptBoundedSnapshot": .bool(true),
      ]))
    defer { Task { await connection.cancel(stream.id) } }
    if !resume {
      _ = try await connection.call(
        "orchestration.dispatchCommand",
        payload: Commands.message(
          threadID: threadID,
          text:
            "This is a tool-output test. Run exactly `printf NATIVE_TOOL_OUTPUT_OK` once with your shell tool, then reply exactly NATIVE_TOOL_DONE. Do not read, write, or modify files, inspect the workspace, use the network, or run any other command.",
          commandID: UUID().uuidString, messageID: UUID().uuidString))
    }
    var state = ThreadState(id: threadID)
    var fetched = false
    var approved = Set<String>()
    for try await event in stream.values {
      _ = try state.apply(event)
      for request in state.pendingRequests where !approved.contains(request.id) {
        guard request.kind == "command", request.canRespond,
          ["printf NATIVE_TOOL_OUTPUT_OK", "/bin/zsh -lc 'printf NATIVE_TOOL_OUTPUT_OK'"].contains(
            request.detail),
          request.options.contains(where: { $0["decision"].string == "accept" })
        else {
          throw T3Error("Tool-output test stopped at an unexpected approval request.")
        }
        try await waitForStore(store) {
          store.thread?.pendingRequests.contains(where: { $0.id == request.id }) == true
        }
        guard let actual = store.thread?.pendingRequests.first(where: { $0.id == request.id })
        else { throw T3Error("Controller missed command approval.") }
        store.respond(actual, decision: "accept")
        try await waitForStore(store) {
          store.thread?.pendingRequests.contains(where: { $0.id == request.id }) == false
        }
        approved.insert(request.id)
        print(
          "ClientStore approved the exact diagnostic printf command once and observed resolution.")
      }
      if !fetched,
        let row = state.rows.first(where: {
          $0.item["outputOmitted"].bool && $0.item["status"].string == "completed"
        })
      {
        try await waitForStore(store) {
          store.thread?.rows.contains(where: {
            $0.id == row.id && $0.item["status"].string == "completed"
          }) == true
        }
        guard let current = store.thread?.rows.first(where: { $0.id == row.id }) else {
          throw T3Error("Controller missed tool output.")
        }
        store.loadOutput(current)
        try await waitForStore(store) {
          store.thread?.rows.contains(where: {
            $0.id == row.id && !$0.item["outputOmitted"].bool
              && $0.item["output"].displayText.contains("NATIVE_TOOL_OUTPUT_OK")
          }) == true
        }
        fetched = true
        print("Real tool output was omitted from the live feed and fetched by ClientStore.")
      }
      if state.rows.contains(where: {
        $0.kind == "assistant_message" && !$0.streaming && $0.text == "NATIVE_TOOL_DONE"
      }) {
        guard fetched else {
          throw T3Error("Provider completed without exercising omitted tool output.")
        }
        print("Tool-output hydration and completed provider reply passed.")
        return
      }
    }
    throw T3Error("Tool-output verification ended before completion.")
  }

  @MainActor private static func attachments(
    settings: ConnectionSettings, connection: RPCConnection, threadID: String
  ) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "t3-attachment-smoke-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("native-attachment.txt")
    let content = Data("NATIVE_ATTACHMENT_BYTES_OK\n".utf8)
    try content.write(to: source)
    let image = directory.appendingPathComponent("native-image.png")
    let imageBytes = Data(
      base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aJ1sAAAAASUVORK5CYII="
    )!
    try imageBytes.write(to: image)
    let drafts = directory.appendingPathComponent("drafts")
    let store = ClientStore(draftDirectory: drafts)
    store.connect(settings, selecting: threadID)
    try await waitForStore(store) { store.canEditThread && store.catalogReady }
    store.rename(threadID, to: "Native attachment verification")
    store.addAttachments([source, image])
    try await waitForStore(store) {
      store.selectedAttachments.count == 2
        && store.selectedAttachments.allSatisfy { store.attachmentUploads[$0.id] == .ready }
    }
    let original = store.selectedAttachments
    try await store.downloadAttachment(
      original[0].wire!, to: directory.appendingPathComponent("download-before.txt"))
    guard try Data(contentsOf: directory.appendingPathComponent("download-before.txt")) == content
    else { throw T3Error("Uploaded bytes changed.") }
    try FileManager.default.removeItem(at: source)
    try FileManager.default.removeItem(at: image)
    guard store.saveDraftsBeforeExit() else {
      throw T3Error("Could not persist the attachment draft.")
    }
    store.disconnect()
    _ = try await connection.call(
      "attachments.delete", payload: .object(["attachmentId": .string(original[0].uploadedID!)]))
    let restored = ClientStore(draftDirectory: drafts)
    restored.connect(settings, selecting: threadID)
    defer { restored.disconnect() }
    try await waitForStore(restored) {
      restored.canEditThread && restored.selectedAttachments.count == 2
        && restored.selectedAttachments.allSatisfy { restored.attachmentUploads[$0.id] == .ready }
    }
    guard restored.selectedAttachments[0].uploadedID != original[0].uploadedID,
      restored.selectedAttachments[1].uploadedID == original[1].uploadedID
    else {
      throw T3Error("Attachment recovery did not replace only the missing upload.")
    }
    restored.drafts[threadID] =
      "This is an attachment delivery test. Reply exactly NATIVE_ATTACHMENT_DONE without opening the attached files or using any tools."
    restored.send()
    try await waitForStore(restored) {
      !restored.sending.contains(threadID) && restored.selectedAttachments.isEmpty
    }
    try await waitForStore(restored) {
      restored.thread?.rows.contains {
        $0.kind == "assistant_message" && !$0.streaming
          && $0.text.contains("NATIVE_ATTACHMENT_DONE")
      } == true
    }
    guard let message = restored.thread?.rows.last(where: { $0.kind == "user_message" }),
      message.item["attachments"].array.count == 2
    else {
      throw T3Error("The accepted message did not contain both attachments.")
    }
    for attachment in message.item["attachments"].array {
      let destination = directory.appendingPathComponent("download-after")
      try await restored.downloadAttachment(attachment, to: destination)
      let expected = attachment["type"].string == "image" ? imageBytes : content
      guard try Data(contentsOf: destination) == expected else {
        throw T3Error("Claimed attachment bytes changed.")
      }
    }
    print(
      "Attachment upload/download, restart after source removal, expired-upload recovery, real send/reply and claimed bytes passed."
    )
  }

  @MainActor private static func waitForStore(
    _ store: ClientStore, until predicate: @escaping @MainActor () -> Bool
  ) async throws {
    let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    store.onChange = { continuation.yield(()) }
    let timeout = Task {
      try await Task.sleep(for: .seconds(25))
      continuation.finish()
    }
    defer {
      store.onChange = nil
      timeout.cancel()
      continuation.finish()
    }
    continuation.yield(())
    for await _ in stream {
      if predicate() { return }
      if let error = store.error { throw T3Error(error) }
    }
    throw T3Error("Timed out waiting for ClientStore state.")
  }
}
