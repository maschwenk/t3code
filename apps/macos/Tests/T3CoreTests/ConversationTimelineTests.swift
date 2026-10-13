import Testing

@testable import T3Core

private func activity(
  _ id: String, kind: String = "command_execution", source: String = "thread",
  inherited: Bool = false, fields: [String: JSON] = [:]
) throws -> TimelineRow {
  try TimelineRow(
    item: .object(
      [
        "id": .string(id), "type": .string(kind), "runId": .string("run"),
        "providerTurnId": .string("turn"), "status": .string("completed"),
        "input": .string("printf \(id)"), "text": .string(id),
      ].merging(fields) { _, new in new }), position: 0, sourceID: source, inherited: inherited)
}

private func groups(_ entries: [ConversationEntry]) -> [TimelineWorkGroup] {
  entries.compactMap { if case .work(let group) = $0 { group } else { nil } }
}

@Test func workCollapsesWithoutHidingMessagesRequestsOrErrors() throws {
  let rows = try [
    activity("prompt", kind: "user_message"), activity("search", kind: "file_search"),
    activity("command"), activity("approval", kind: "approval_request"),
    activity("failed", fields: ["exitCode": .number(1)]),
    activity("reasoning", kind: "reasoning"), activity("notice", kind: "system_notice"),
    activity("question", kind: "user_input_request"), activity("reply", kind: "assistant_message"),
  ]
  let entries = ConversationTimeline.entries(from: rows, activeRunID: nil)
  #expect(
    groups(entries).map { $0.entries.map(\.id) } == [
      ["thread:search", "thread:command"], ["thread:reasoning"],
    ])
  #expect(
    entries.compactMap(\.item).map(\.id) == [
      "thread:prompt", "thread:approval", "thread:failed", "thread:notice", "thread:question",
      "thread:reply",
    ])
  #expect(groups(entries).first?.summary == "1 command · 1 file search")
  for fields: [String: JSON] in [
    ["status": .string("failed")], ["status": .string("cancelled")],
    ["status": .string("interrupted")], ["outputIndicatesFailure": .bool(true)],
    ["toolNonExecutionKind": .string("declined")], ["output": .object(["isError": .bool(true)])],
  ] {
    let row = try activity("outcome", kind: "dynamic_tool", fields: fields)
    #expect(ConversationTimeline.entries(from: [row], activeRunID: "run") == [.item(row)])
  }
}

@Test func expansionSurvivesStreamUpdatesAndOlderHistoryWithoutMixingSources() throws {
  let command = try activity("cmd", fields: ["status": .string("running")])
  let first = ConversationTimeline.entries(from: [command], activeRunID: "run")
  let firstGroup = try #require(groups(first).first)
  #expect(firstGroup.active)
  #expect(firstGroup.summary == "Running printf cmd")
  let complete = try activity("cmd", fields: ["output": .string("done")])
  let next = try activity("next", kind: "file_search")
  let entries = ConversationTimeline.entries(
    from: [complete, next], activeRunID: "run", expandedItemIDs: [command.id])
  let updated = try #require(groups(entries).first)
  #expect(updated.id == firstGroup.id)
  #expect(updated.active)
  #expect(updated.summary == "Searched files · 2 activities")
  #expect(updated.expanded)
  #expect(entries.compactMap(\.item) == [complete, next])
  let older = try activity("older")
  let paged = ConversationTimeline.entries(
    from: [older, complete, next], activeRunID: nil, expandedItemIDs: [command.id])
  #expect(groups(paged).first?.expanded == true)
  #expect(groups(paged).first?.active == false)
  #expect(paged.compactMap(\.item) == [older, complete, next])
  #expect(
    groups(ConversationTimeline.entries(from: [complete, next], activeRunID: nil)).first?.expanded
      == false)
}

@Test func workGroupsRespectRunAttemptSubagentAndInheritedBoundaries() throws {
  let first = try activity("a")
  for field in ["runId", "providerTurnId", "nodeId", "providerThreadId", "parentItemId"] {
    let other = try activity("b", fields: [field: .string("other")])
    #expect(
      groups(ConversationTimeline.entries(from: [first, other], activeRunID: "run")).count == 2)
  }
  let parent = try activity(
    "a", source: "parent", inherited: true, fields: ["status": .string("running")])
  let inherited = ConversationTimeline.entries(
    from: [parent, first], activeRunID: "run", expandedItemIDs: [first.id])
  #expect(groups(inherited).count == 2)
  #expect(groups(inherited)[0].active == false)
  #expect(groups(inherited)[0].expanded == false)
  #expect(groups(inherited)[1].expanded)
  #expect(inherited.compactMap(\.item) == [first])
}

@Test func completedActivityStaysVisibleUntilTheNextResponseAndStopsWithItsRun() throws {
  let row = try activity("command")
  let tail = ConversationTimeline.entries(from: [row], activeRunID: "run")
  #expect(groups(tail).first?.active == true)
  #expect(groups(tail).first?.summary == "Ran printf command")
  let reply = try activity("reply", kind: "assistant_message")
  #expect(
    groups(ConversationTimeline.entries(from: [row, reply], activeRunID: "run")).first?.active
      == false)
  let staleRunning = try activity("command", fields: ["status": .string("running")])
  #expect(
    groups(ConversationTimeline.entries(from: [staleRunning], activeRunID: nil)).first?.active
      == false)
  let checkpoint = try activity("checkpoint", kind: "checkpoint")
  #expect(
    groups(ConversationTimeline.entries(from: [row, checkpoint, row], activeRunID: nil)).count == 1)
}
