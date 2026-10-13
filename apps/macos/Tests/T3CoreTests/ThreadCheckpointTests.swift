import Testing

@testable import T3Core

private func checkpoint(
  _ id: String, turn: Int?, run: String?, status: String = "ready", files: [JSON] = []
) -> JSON {
  .object([
    "id": .string(id), "threadId": .string("t"), "runId": run.map(JSON.string) ?? .null,
    "appRunOrdinal": turn.map { .number(Double($0)) } ?? .null,
    "ref": .string("refs/checkpoints/" + id), "status": .string(status),
    "capturedAt": .string("2026-10-11T12:00:00Z"), "files": .array(files),
  ])
}
private func message(
  _ id: String, run: String, time: String = "2026-10-11T12:00:00Z", text: String = "reply"
) -> JSON {
  .object([
    "id": .string(id), "threadId": .string("t"), "runId": .string(run),
    "role": .string("assistant"), "createdAt": .string(time), "text": .string(text),
  ])
}
private func projection(checkpoints: [JSON], messages: [JSON] = []) -> JSON {
  .object([
    "thread": .object(["id": .string("t")]), "checkpoints": .array(checkpoints),
    "messages": .array(messages),
    "runs": .array([
      .object(["id": .string("r1"), "status": .string("completed")]),
      .object(["id": .string("r2"), "status": .string("completed")]),
    ]),
  ])
}
private func event(_ type: String, _ value: JSON) -> JSON {
  .object(["type": .string(type), "payload": value])
}

@Test func checkpointOrdinalsExcludeBaselinesAndKeepUnavailableTurnsExplicit() throws {
  let index = ThreadCheckpoints(
    projection(checkpoints: [
      checkpoint("baseline", turn: nil, run: nil),
      checkpoint("c2", turn: 7, run: "r2", status: "missing"),
      checkpoint("c1", turn: 2, run: "r1"), checkpoint("subagent", turn: nil, run: "r1"),
    ]))
  #expect(index.items.map(\.turnCount) == [7, 2])
  #expect(index.items[0].unavailableReason?.contains("missing") == true)
  #expect(throws: T3Error.self) {
    try CheckpointDiffRequest(index.items[0], fullThread: false, ignoreWhitespace: true)
  }
  let turn = try CheckpointDiffRequest(index.items[1], fullThread: false, ignoreWhitespace: false)
  #expect(turn.from == 1 && turn.to == 2)
  #expect(turn.input["ignoreWhitespace"] == .bool(false))
  let full = try CheckpointDiffRequest(index.items[1], fullThread: true, ignoreWhitespace: true)
  #expect(full.from == 0 && full.to == 2 && full.input["fromTurnCount"] == .null)
  #expect(full.method == "orchestration.getFullThreadDiff")
  #expect(throws: T3Error.self) {
    try full.validate(
      .object([
        "threadId": .string("other"), "fromTurnCount": .number(0), "toTurnCount": .number(2),
        "diff": .string(""),
      ]))
  }
}

@Test func checkpointUpdatesDoNotRebuildOnTokensOrMoveCardsToOldMessages() throws {
  var index = ThreadCheckpoints(
    projection(
      checkpoints: [checkpoint("c1", turn: 1, run: "r1")],
      messages: [
        message("a", run: "r1"), message("b", run: "r1"),
      ]))
  #expect(index.items.first?.assistantMessageID == "b")
  let revision = index.revision
  index.apply(event("message.updated", message("a", run: "r1", text: "late old message update")))
  index.apply(event("message.updated", message("b", run: "r1", text: "more text")))
  #expect(index.revision == revision)
  index.apply(event("message.updated", message("c", run: "r1", time: "2026-10-11T12:01:00Z")))
  #expect(index.items.first?.assistantMessageID == "c")
  #expect(index.revision != revision)
  index.apply(event("checkpoint.captured", checkpoint("c2", turn: 2, run: "r2")))
  #expect(index.items.map(\.turnCount) == [2, 1])
  let updated = index.revision
  index.apply(event("checkpoint.captured", checkpoint("c2", turn: 2, run: "r2")))
  #expect(index.revision == updated)
  index.apply(
    event(
      "run.updated",
      .object(["id": .string("r2"), "threadId": .string("t"), "status": .string("failed")])))
  #expect(index.items.first?.unavailableReason?.contains("not completed") == true)
  let rolledBack = ThreadCheckpoints(
    projection(checkpoints: [checkpoint("c1", turn: 1, run: "r1")]))
  #expect(rolledBack.items.count == 1 && rolledBack.revision != index.revision)
}

@Test func checkpointCardsFollowTheirAssistantAndNeverDuplicateOrCrossInheritedHistory() throws {
  let file: JSON = .object([
    "path": .string("file.swift"), "additions": .number(3), "deletions": .number(1),
  ])
  let checkpoints = ThreadCheckpoints(
    projection(
      checkpoints: [checkpoint("c1", turn: 1, run: "r1", files: [file])],
      messages: [message("reply", run: "r1")])
  ).items
  func row(_ id: String, kind: String, source: String = "t", inherited: Bool = false) throws
    -> TimelineRow
  {
    try TimelineRow(
      item: .object([
        "id": .string(id), "type": .string(kind), "messageId": .string("reply"),
        "checkpointId": .string("c1"), "text": .string("reply"), "files": .array([file]),
      ]), position: 1, sourceID: source, inherited: inherited)
  }
  let assistant = try row("assistant", kind: "assistant_message")
  let checkpointRow = try row("checkpoint", kind: "checkpoint")
  let entries = ConversationTimeline.entries(
    from: [assistant, checkpointRow], activeRunID: nil, checkpoints: checkpoints)
  #expect(entries.count == 2 && entries.first?.item == assistant)
  #expect(entries.last == .changes(checkpoints[0]))
  #expect(
    ConversationTimeline.entries(
      from: [checkpointRow, assistant], activeRunID: nil, checkpoints: checkpoints) == entries)
  let inherited = try row("assistant", kind: "assistant_message", source: "parent", inherited: true)
  #expect(
    ConversationTimeline.entries(from: [inherited], activeRunID: nil, checkpoints: checkpoints) == [
      .item(inherited)
    ])
}

@Test func checkpointPatchesCanBeCopiedPerFileWithoutReserializingTheirContents() throws {
  let first = "diff --git a/a b/a\n@@ -1 +1 @@\n-before\r\n+after\r\n"
  let second = "diff --git a/b b/b\n@@ -0,0 +1 @@\n+new\n\\ No newline at end of file\n"
  let files = UnifiedDiff.parse(first + second)
  try #require(files.count == 2)
  #expect(files[0].rawPatch == first && files[1].rawPatch == second)
  #expect(files[0].lines.last?.text == "after\r")
}
