import Foundation
import T3Core
import Testing

@testable import T3Native

@MainActor private func composerStore(
  status: String = "interrupted", question: Bool = false,
  queued: Bool = false
) throws -> ClientStore {
  let store = ClientStore(
    draftDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  )
  store.catalog = ProviderCatalog(planModeEnabled: true)
  let thread: JSON = .object([
    "id": .string("t"), "projectId": .string("p"), "title": .string("Plan"),
    "interactionMode": .string("plan"),
  ])
  try store.shell.apply(
    .object([
      "kind": .string("snapshot"),
      "snapshot": .object([
        "snapshotSequence": .number(1), "threads": .array([thread]),
      ]),
    ]))
  store.selectedID = "t"
  var runs: [JSON] = [
    .object([
      "id": .string("run"), "ordinal": .number(1), "status": .string(status),
      "rootNodeId": .string("root"),
      "startedAt": .string("2026-10-11T12:00:00Z"),
      "completedAt": status == "running" ? .null : .string("2026-10-11T12:01:00Z"),
    ])
  ]
  if queued {
    runs.append(
      .object([
        "id": .string("queued"), "ordinal": .number(2), "status": .string("queued"),
        "queueHeld": .bool(true), "userMessageId": .string("message"),
      ]))
  }
  let request: JSON = .object([
    "id": .string("request"), "kind": .string("user_input"), "status": .string("pending"),
    "responseCapability": .object(["type": .string("message")]),
  ])
  let item: JSON = .object([
    "id": .string("item"), "threadId": .string("t"), "ordinal": .number(0),
    "type": .string("user_input_request"), "requestId": .string("request"),
    "questions": .array([.object(["id": .string("q"), "question": .string("Which option?")])]),
  ])
  var state = ThreadState(id: "t")
  _ = try state.apply(
    .object([
      "kind": .string("snapshot"), "snapshotSequence": .number(1),
      "projection": .object([
        "thread": thread, "runs": .array(runs),
        "runtimeRequests": .array(question ? [request] : []),
        "turnItems": .array(question ? [item] : []),
        "messages": .array([
          .object(["id": .string("message"), "text": .string("Queued follow-up")])
        ]),
        "plans": .array([
          .object([
            "id": .string("plan"), "runId": .string("run"), "kind": .string("proposed_plan"),
            "status": .string("active"), "markdown": .string("# Proposed plan\n\nDo the work."),
          ])
        ]),
      ]),
    ]))
  _ = try state.apply(.object(["kind": .string("synchronized")]))
  store.thread = state
  store.ready = true
  return store
}

@MainActor @Test func interruptedPlanResumesUntilTheUserWritesRefinement() throws {
  let store = try composerStore()
  #expect(store.planFollowUp != nil)
  #expect(store.composerAction == .resume)
  #expect(store.sendBlockReason == nil)
  store.composerText = " \n"
  #expect(store.composerAction == .resume)
  store.composerText = "Make the first step smaller."
  #expect(store.composerAction == .plan)
  #expect(store.planActionTitle == "Refine")
  store.composerText = ""
  #expect(store.composerAction == .resume)
  _ = try store.thread?.apply(
    .object([
      "kind": .string("event"), "sequence": .number(2),
      "event": .object([
        "type": .string("run.updated"),
        "payload": .object([
          "id": .string("run"), "ordinal": .number(1), "status": .string("completed"),
          "completedAt": .string("2026-10-11T12:02:00Z"),
        ]),
      ]),
    ]))
  #expect(store.composerAction == .plan)
  #expect(store.planActionTitle == "Implement")
}

@MainActor @Test func emptyRunningComposerStopsButDraftsRemainSendable() throws {
  let store = try composerStore(status: "running", queued: true)
  #expect(store.composerAction == .stop)
  #expect(store.sendBlockReason == nil)
  store.composerText = "A follow-up"
  #expect(store.composerAction == .message)
  #expect(store.sendBlockReason == nil)
  store.composerText = ""
  store.ready = false
  #expect(store.composerAction == .stop)
  #expect(store.sendBlockReason != nil)
  let stopped = try composerStore()
  stopped.ready = false
  #expect(stopped.composerAction == .resume)
  #expect(stopped.sendBlockReason != nil)
}

@MainActor @Test func questionsAndQueuedEditsDoNotTurnIntoResumeOrImplementation() throws {
  let store = try composerStore(question: true)
  #expect(store.composerAction == .question)
  #expect(store.sendBlockReason != nil)
  store.composerText = "Custom answer"
  #expect(store.composerAction == .question)
  #expect(store.sendBlockReason == nil)
  let queued = try composerStore(queued: true)
  let message = try #require(queued.execution.queued.first)
  queued.editQueuedMessage(message)
  #expect(queued.queuedEdit != nil)
  #expect(queued.composerAction == .message)
  queued.composerText = ""
  #expect(queued.composerAction == .message)
  #expect(queued.sendBlockReason != nil)
  queued.cancelQueuedEdit()
  #expect(queued.composerAction == .resume)
  let held = try composerStore(status: "completed", queued: true)
  #expect(held.execution.resumableRunID == nil)
  #expect(held.composerAction == .resume)
}

@MainActor @Test func usageFailureEnablesResumeWhenTheAuthoritativeErrorArrives() throws {
  let store = try composerStore(status: "failed")
  #expect(store.composerAction == .plan)
  _ = try store.thread?.apply(
    .object([
      "kind": .string("event"), "sequence": .number(2),
      "event": .object([
        "type": .string("turn-item.updated"),
        "payload": .object([
          "id": .string("failure"), "threadId": .string("t"), "runId": .string("run"),
          "nodeId": .string("root"), "ordinal": .number(0), "type": .string("error"),
          "status": .string("failed"),
          "failure": .object([
            "class": .string("usage_limit"), "message": .string("Usage limit reached"),
          ]),
        ]),
      ]),
    ]))
  #expect(store.composerAction == .resume)
  #expect(store.sendBlockReason == nil)
}

@MainActor @Test func recoveredPlanRetryAndFileDraftKeepTheirOriginalIntent() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let fixture = try composerStore()
  let settings = try ConnectionSettings(
    endpoint: URL(string: "http://127.0.0.1:9")!, token: "fixture")
  let repository = DraftRepository(directory: directory)
  let pending = PendingPlanSubmission(
    plan: try #require(fixture.planFollowUp), template: try #require(fixture.selectedThread),
    draft: "", newThread: false, defaultRuntimeMode: "approval-required")
  try repository.save(SavedDrafts(planSubmissions: ["t": pending]), for: settings.endpoint)
  func restored() -> ClientStore {
    let store = ClientStore(draftDirectory: directory)
    store.connect(settings, selecting: "t")
    // Read persisted drafts, then cancel before yielding to the network task.
    store.disconnect()
    store.shell = fixture.shell
    store.thread = fixture.thread
    store.selectedID = "t"
    store.ready = true
    store.catalog = fixture.catalog
    return store
  }
  let retry = restored()
  #expect(retry.execution.resumableRunID != nil)
  #expect(retry.composerAction == .plan)
  #expect(retry.planActionTitle == "Retry implementation")
  #expect(retry.pendingPlanSubmission?.setup == pending.setup)
  #expect(retry.pendingPlanSubmission?.message == pending.message)
  retry.disconnect()

  let source = directory.appendingPathComponent("attached.txt")
  try Data("An attachment-only follow-up".utf8).write(to: source)
  let attachment = try repository.attachmentRepository(for: settings.endpoint).stage(source)
  try repository.save(SavedDrafts(attachments: ["t": [attachment]]), for: settings.endpoint)
  let withFile = restored()
  #expect(withFile.selectedAttachments.count == 1)
  #expect(withFile.composerAction == .message)
  #expect(withFile.planFollowUp == nil)
  withFile.disconnect()
}
