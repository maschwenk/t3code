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
