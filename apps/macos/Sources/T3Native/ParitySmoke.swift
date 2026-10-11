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
    let store = ClientStore()
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
    guard CommandLine.arguments.contains("--question-smoke") else {
      try await dispatch(
        "thread.interaction-mode.set", fields: ["interactionMode": .string("default")])
      return
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
