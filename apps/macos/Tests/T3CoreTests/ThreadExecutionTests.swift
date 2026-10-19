import Foundation
import Testing

@testable import T3Core

private func executionFixture() throws -> JSON {
  try JSONDecoder().decode(
    JSON.self,
    from: Data(
      #"""
      {
        "thread":{"id":"thread","activeProviderThreadId":"provider-thread"},
        "runs":[
          {"id":"active","ordinal":1,"status":"running","providerThreadId":"provider-thread","activeAttemptId":"attempt","userMessageId":"original","startedAt":"2026-10-11T12:00:00Z","completedAt":null},
          {"id":"first","ordinal":2,"queuePosition":2,"status":"queued","userMessageId":"one"},
          {"id":"second","ordinal":3,"queuePosition":1,"status":"queued","userMessageId":"two"},
          {"id":"wake","ordinal":4,"queuePosition":3,"status":"queued","userMessageId":"automatic","queueHeld":true}
        ],
        "messages":[
          {"id":"one","role":"user","text":"First draft","attachments":[{"id":"document","type":"file","name":"context.txt","sizeBytes":16,"mimeType":"text/plain"}],"context":{"version":1,"records":[{"contextId":"file","attachmentId":"document"},{"contextId":"terminal","text":"retain this"}]}},
          {"id":"two","role":"user","text":"Second draft","attachments":[]},
          {"id":"automatic","role":"user","text":"Agent wake","notification":{"kind":"background"}}
        ],
        "providerThreads":[{"id":"provider-thread","appThreadId":"thread","providerSessionId":"session"}],
        "providerSessions":[{"id":"session","status":"ready","createdAt":"2026-10-11T12:00:00Z","capabilities":{"turns":{"supportsQueuedMessages":true,"supportsActiveSteering":true,"supportsSteeringByInterruptRestart":true}}}],
        "providerTurns":[{"id":"turn","runAttemptId":"attempt","status":"running"}]
      }
      """#.utf8))
}

private func changed(_ value: JSON, _ fields: [String: JSON]) -> JSON {
  guard case .object(var existing) = value else { return .object(fields) }
  existing.merge(fields) { _, new in new }
  return .object(existing)
}
private func executionEvent(_ type: String, _ payload: JSON) -> JSON {
  .object(["type": .string(type), "threadId": .string("thread"), "payload": payload])
}

@Test func queueTracksServerOrderEditsAndAutomaticWorkSeparately() throws {
  let fixture = try executionFixture()
  var execution = ThreadExecution(fixture)
  #expect(execution.queued.map(\.id) == ["second", "first"])
  #expect(execution.queued.last?.attachments.first?["id"].string == "document")
  #expect(execution.isHeld)
  #expect(execution.canQueue && execution.canSteer && execution.canRestart)
  execution.apply(
    executionEvent("run.updated", changed(fixture["runs"].array[1], ["queuePosition": .number(1)])))
  #expect(execution.queued.map(\.id) == ["first", "second"])
  execution.apply(
    executionEvent(
      "message.updated",
      changed(fixture["messages"].array[0], ["text": .string("Edited from another client")])))
  #expect(execution.queued.first?.text == "Edited from another client")
  execution.apply(
    executionEvent(
      "run.updated", changed(fixture["runs"].array[1], ["status": .string("cancelled")])))
  #expect(execution.queued.map(\.id) == ["second"])
  #expect(execution.hiddenUserMessageIDs.contains("one"))
  let queuedItem: JSON = .object([
    "type": .string("user_message"), "messageId": .string("one"),
    "inputIntent": .string("queued_turn"),
  ])
  #expect(execution.hidesQueuedMessage(queuedItem))
  #expect(
    !execution.hidesQueuedMessage(
      changed(queuedItem, ["inputIntent": .string("promoted_queued_to_steer")])))
  execution.apply(
    executionEvent(
      "run.updated", changed(fixture["runs"].array[2], ["status": .string("starting")])))
  #expect(execution.queued.isEmpty)
  #expect(!execution.hiddenUserMessageIDs.contains("two"))
}

@Test func steeringRequiresTheCurrentLiveProviderTurnAndAttachedSession() throws {
  let fixture = try executionFixture()
  var execution = ThreadExecution(fixture)
  execution.apply(
    executionEvent(
      "provider-turn.updated",
      changed(fixture["providerTurns"].array[0], ["status": .string("completed")])))
  #expect(!execution.canSteer && !execution.canRestart)
  #expect(execution.canQueue)
  execution.apply(
    executionEvent(
      "provider-turn.updated",
      changed(fixture["providerTurns"].array[0], ["runAttemptId": .string("old-attempt")])))
  #expect(!execution.canSteer)
  execution.apply(executionEvent("provider-turn.updated", fixture["providerTurns"].array[0]))
  #expect(execution.canSteer)
  execution.apply(
    executionEvent(
      "provider-session.updated",
      changed(
        fixture["providerSessions"].array[0],
        [
          "capabilities": .object([
            "turns": .object(["supportsSteeringByInterruptRestart": .bool(true)])
          ])
        ])))
  #expect(execution.canSteer && execution.steeringInterruptsTools && !execution.canQueue)
  execution.apply(
    executionEvent("provider-session.detached", .object(["providerSessionId": .string("session")])))
  #expect(!execution.canSteer && !execution.canRestart && !execution.canQueue)
}

@Test func resumeChoosesLastExecutedWorkRatherThanTheHighestQueueOrdinal() throws {
  let fixture = try executionFixture()
  let interrupted = changed(
    fixture["runs"].array[0],
    ["status": .string("interrupted"), "completedAt": .string("2026-10-11T12:05:00Z")])
  var execution = ThreadExecution(
    changed(fixture, ["runs": .array([interrupted] + fixture["runs"].array.dropFirst())]))
  #expect(execution.resumableRunID == "active")
  let newerOrdinal = changed(
    interrupted,
    [
      "id": .string("older-completion"), "ordinal": .number(10),
      "completedAt": .string("2026-10-11T12:02:00Z"), "status": .string("completed"),
    ])
  execution.apply(executionEvent("run.created", newerOrdinal))
  #expect(execution.resumableRunID == "active")
  execution.apply(
    executionEvent(
      "run.updated", changed(newerOrdinal, ["completedAt": .string("2026-10-11T12:06:00Z")])))
  #expect(execution.resumableRunID == nil)
  #expect(execution.isHeld)
}

@Test func onlyLatestRootUsageFailureEnablesFailedRunResume() throws {
  let fixture = try executionFixture()
  let run = changed(
    fixture["runs"].array[0],
    [
      "status": .string("failed"), "rootNodeId": .string("root"),
      "completedAt": .string("2026-10-11T12:05:00Z"),
    ])
  var execution = ThreadExecution(changed(fixture, ["runs": .array([run])]))
  let failure: JSON = .object([
    "id": .string("failure"), "type": .string("error"), "runId": .string("active"),
    "nodeId": .string("subagent"), "status": .string("failed"), "ordinal": .number(2),
    "updatedAt": .string("2026-10-11T12:05:00Z"),
    "failure": .object(["class": .string("usage_limit"), "message": .string("Limit")]),
  ])
  execution.apply(executionEvent("turn-item.updated", failure))
  #expect(execution.resumableRunID == nil)
  execution.apply(
    executionEvent("turn-item.updated", changed(failure, ["nodeId": .string("root")])))
  #expect(execution.resumableRunID == "active")
  execution.apply(
    executionEvent(
      "provider-session.updated",
      changed(
        fixture["providerSessions"].array[0],
        ["lastError": .string("Session authentication failed")])))
  #expect(execution.resumableRunID == nil)
}

@Test func queueEventsRespectThreadSequenceAndOwnership() throws {
  let fixture = try executionFixture()
  var state = ThreadState(id: "thread")
  _ = try state.apply(
    .object(["kind": .string("snapshot"), "snapshotSequence": .number(10), "projection": fixture]))
  let payload = changed(fixture["runs"].array[1], ["status": .string("cancelled")])
  let event = executionEvent("run.updated", payload)
  _ = try state.apply(.object(["kind": .string("event"), "sequence": .number(9), "event": event]))
  #expect(state.execution.queued.count == 2)
  let foreign = changed(event, ["threadId": .string("another-thread")])
  #expect(throws: T3Error.self) {
    try state.apply(.object(["kind": .string("event"), "sequence": .number(11), "event": foreign]))
  }
  #expect(state.sequence == 10)
  _ = try state.apply(.object(["kind": .string("event"), "sequence": .number(11), "event": event]))
  #expect(state.execution.queued.map(\.id) == ["second"])
}

@Test func queuedEditsAndDeliveryRetryIdentitySurviveRestartBesideANormalDraft() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let repository = DraftRepository(directory: root)
  let endpoint = URL(string: "https://example.test")!
  let message = try #require(ThreadExecution(executionFixture()).queued.last)
  var edit = QueuedEdit(message, threadID: "thread")
  let otherMessage = try #require(ThreadExecution(executionFixture()).queued.first)
  var otherEdit = QueuedEdit(otherMessage, threadID: "thread")
  otherEdit.active = false
  let pending = PendingSubmission(
    text: "Saved edit", attachments: edit.attachments, localAttachmentIDs: [],
    queuedRunID: edit.runID, retainedAttachmentIDs: ["document"], context: edit.retainedContext)
  try repository.save(
    SavedDrafts(
      messages: [
        "thread": "Unrelated unsent message", edit.draftID: "Saved edit",
        otherEdit.draftID: "Another saved edit",
      ],
      submissions: [edit.draftID: pending],
      queuedEdits: [edit.runID: edit, otherEdit.runID: otherEdit],
      deliveries: ["thread": .queue]), for: endpoint)
  let restored = try repository.load(for: endpoint)
  #expect(restored.messages["thread"] == "Unrelated unsent message")
  #expect(restored.queuedEdits?[edit.runID] == edit)
  #expect(restored.queuedEdits?[otherEdit.runID] == otherEdit)
  #expect(restored.messages[otherEdit.draftID] == "Another saved edit")
  #expect(
    restored.submissions[edit.draftID]?.payload(threadID: "thread")
      == pending.payload(threadID: "thread"))
  #expect(pending.matches(text: "Saved edit", attachments: [], edit: edit))
  edit.attachments = []
  #expect(!pending.matches(text: "Saved edit", attachments: [], edit: edit))
  #expect(edit.retainedContext["records"].array.map { $0["contextId"].string } == ["terminal"])
  let queued = PendingSubmission(text: "Next", delivery: .queue)
  #expect(queued.payload(threadID: "thread")["dispatchMode"]["type"].string == "queue_after_active")
  #expect(queued.payload(threadID: "thread")["deliveryIntent"] == .null)
  #expect(queued.matches(text: "Next", attachments: [], delivery: .queue))
  #expect(!queued.matches(text: "Next", attachments: [], delivery: .steer))
  let resumed = PendingSubmission(text: "Continue", continuationOf: "interrupted")
  #expect(resumed.payload(threadID: "thread")["manualContinuationOfRunId"].string == "interrupted")
  #expect(resumed.payload(threadID: "thread")["deliveryIntent"] == .null)
  try AttachmentPolicy().validate([], retained: message.attachments)
}
