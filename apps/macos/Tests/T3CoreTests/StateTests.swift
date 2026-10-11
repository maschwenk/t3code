import Foundation
import Testing

@testable import T3Core

private func item(
  _ id: String, text: String, ordinal: Int = 0, thread: String = "thread",
  type: String = "assistant_message"
) -> JSON {
  .object([
    "id": .string(id), "threadId": .string(thread), "type": .string(type),
    "text": .string(text), "ordinal": .number(Double(ordinal)), "streaming": .bool(false),
  ])
}

private func visible(
  _ item: JSON, position: Int, source: String = "thread", inherited: Bool = false
) -> JSON {
  .object([
    "item": item, "position": .number(Double(position)), "sourceThreadId": .string(source),
    "visibility": .string(inherited ? "inherited" : "local"),
  ])
}

private func snapshot(_ items: [JSON], sequence: Int = 10) -> JSON {
  .object([
    "kind": .string("snapshot"), "snapshotSequence": .number(Double(sequence)),
    "projection": .object([
      "thread": .object(["id": .string("thread")]), "visibleTurnItems": .array(items),
    ]),
    "historyCursor": .string("opaque-cursor"), "hasMoreHistory": .bool(true),
  ])
}

private func update(_ item: JSON, sequence: Int, type: String = "turn-item.updated") -> JSON {
  .object([
    "kind": .string("event"), "sequence": .number(Double(sequence)),
    "event": .object(["type": .string(type), "payload": item]),
  ])
}

@Test func liveUpdatesReplaceOneRowAndRejectReplay() throws {
  var state = ThreadState(id: "thread")
  _ = try state.apply(snapshot([visible(item("a", text: "old"), position: 0)]))
  _ = try state.apply(update(item("a", text: "new"), sequence: 12))
  _ = try state.apply(update(item("a", text: "stale"), sequence: 11))
  _ = try state.apply(update(item("b", text: "next", ordinal: 1), sequence: 13))
  #expect(state.rows.map(\.text) == ["new", "next"])
  #expect(state.sequence == 13)
}

@Test func historyCannotOverwriteNewerLiveContent() throws {
  var state = ThreadState(id: "thread")
  _ = try state.apply(snapshot([visible(item("b", text: "initial"), position: 1)]))
  _ = try state.apply(update(item("b", text: "live"), sequence: 11))
  try state.prependHistory(
    .object([
      "items": .array([
        visible(item("a", text: "older"), position: 0),
        visible(item("b", text: "outdated"), position: 1),
      ]),
      "hasMoreHistory": .bool(false), "nextCursor": .null, "snapshotSequence": .number(10),
    ]))
  #expect(state.rows.map(\.text) == ["older", "live"])
  #expect(state.sequence == 11)
  #expect(!state.hasMore)
  #expect(state.cursor == nil)
}

@Test func inheritedRowsWithSameItemIDStayDistinct() throws {
  var state = ThreadState(id: "thread")
  _ = try state.apply(
    snapshot([
      visible(
        item("a", text: "parent", thread: "parent"), position: 0, source: "parent", inherited: true),
      visible(item("a", text: "local"), position: 1),
    ]))
  _ = try state.apply(update(item("a", text: "changed"), sequence: 11))
  #expect(state.rows.map(\.text) == ["parent", "changed"])
  #expect(state.rows[0].inherited)
}

@Test func malformedKnownEventDoesNotAdvanceCursor() throws {
  var state = ThreadState(id: "thread")
  _ = try state.apply(snapshot([]))
  #expect(throws: T3Error.self) {
    try state.apply(
      update(
        .object([
          "id": .string("a"), "threadId": .string("thread"), "type": .string("assistant_message"),
        ]), sequence: 11))
  }
  #expect(state.sequence == 10)
  #expect(state.rows.isEmpty)
}

@Test func unrelatedThreadCannotReplaceCurrentSnapshot() throws {
  var state = ThreadState(id: "other")
  #expect(throws: T3Error.self) { try state.apply(snapshot([])) }
  #expect(state.sequence == -1)
}

@Test func futureEventsAdvanceCursorAndRollbackRequiresSnapshot() throws {
  var state = ThreadState(id: "thread")
  _ = try state.apply(snapshot([]))
  #expect(try !state.apply(update(.null, sequence: 11, type: "future.event")))
  #expect(state.sequence == 11)
  #expect(try state.apply(update(.null, sequence: 12, type: "checkpoint.rollback-requested")))
  #expect(state.sequence == 11)
}

@Test func shellRemovesArchivedThreadsAndIgnoresOlderEvents() throws {
  let thread: JSON = .object([
    "id": .string("t"), "projectId": .string("p"), "title": .string("Example"),
  ])
  var state = ShellState()
  try state.apply(
    .object([
      "kind": .string("snapshot"),
      "snapshot": .object([
        "snapshotSequence": .number(5), "threads": .array([thread]),
        "projects": .array([.object(["id": .string("p"), "title": .string("Workspace")])]),
      ]),
    ]))
  try state.apply(
    .object([
      "kind": .string("thread.updated"), "sequence": .number(6), "location": .string("archive"),
      "thread": thread,
    ]))
  try state.apply(
    .object([
      "kind": .string("thread.updated"), "sequence": .number(5), "location": .string("active"),
      "thread": thread,
    ]))
  #expect(state.threads.isEmpty)
  #expect(state.projects["p"] == "Workspace")
}

@Test func credentialsCannotBeSentOverRemoteHTTPOrAmbiguousURLs() throws {
  for endpoint in [
    "http://example.com", "https://user:password@example.com", "https://example.com/?token=x",
    "https://example.com/path",
  ] {
    #expect(throws: T3Error.self) {
      try ConnectionSettings(endpoint: URL(string: endpoint)!, token: "secret")
    }
  }
  let settings = try ConnectionSettings(
    endpoint: URL(string: "http://127.0.0.1:4773")!, token: "secret")
  let request = settings.request("/api/orchestration/shell")
  #expect(request.url?.query == nil)
  #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
  #expect(request.value(forHTTPHeaderField: "x-t3-orchestration-protocol") == "2")
}

@Test func metadataEnrichmentDoesNotEraseThreadsOrReadiness() throws {
  var state = ShellState()
  let thread: JSON = .object([
    "id": .string("t"), "projectId": .string("p"), "title": .string("Keep me"),
  ])
  try state.apply(
    .object([
      "kind": .string("snapshot"),
      "snapshot": .object([
        "snapshotSequence": .number(10), "threads": .array([thread]), "projects": .array([]),
      ]),
    ]))
  try state.apply(.object(["kind": .string("synchronized")]))
  try state.apply(
    .object([
      "kind": .string("snapshot"), "resolvedRepositoryIdentityRoots": .array([]),
      "snapshot": .object([
        "snapshotSequence": .number(0), "threads": .array([]), "projects": .array([]),
      ]),
    ]))
  #expect(state.threads["t"]?.title == "Keep me")
  #expect(state.sequence == 10)
  #expect(state.synchronized)
}

@Test func authoritativeReconnectSnapshotReplacesCacheAndItsCursor() throws {
  var state = ThreadState(id: "thread")
  _ = try state.apply(snapshot([visible(item("old", text: "cached"), position: 0)], sequence: 20))
  _ = try state.apply(.object(["kind": .string("synchronized")]))
  _ = try state.apply(snapshot([visible(item("new", text: "restored"), position: 0)], sequence: 3))
  #expect(!state.synchronized)
  _ = try state.apply(update(item("new", text: "live after restore"), sequence: 4))
  #expect(state.rows.map(\.text) == ["live after restore"])
  #expect(state.sequence == 4)
}

@Test func fullOutputIsScopedToItsSourceAndCannotOverwriteStreamingUpdates() throws {
  func command(_ fields: [String: JSON] = [:]) -> JSON {
    .object(
      [
        "id": .string("cmd"), "threadId": .string("parent"), "type": .string("command_execution"),
        "input": .string("printf hello"), "outputOmitted": .bool(true),
        "updatedAt": .string("rev1"),
      ]
      .merging(fields) { _, new in new })
  }
  var state = ThreadState(id: "thread")
  _ = try state.apply(
    snapshot([visible(command(), position: 0, source: "parent", inherited: true)]))
  let original = try #require(state.rows.first)
  #expect(
    try !state.hydrateOutput(
      command([
        "threadId": .string("thread"), "outputOmitted": .bool(false), "output": .string("wrong"),
      ]), replacing: original))
  #expect(
    try !state.hydrateOutput(
      command([
        "updatedAt": .string("rev2"), "outputOmitted": .bool(false), "output": .string("raced"),
      ]), replacing: original))
  #expect(
    try state.hydrateOutput(
      command(["outputOmitted": .bool(false), "output": .string("hello")]), replacing: original))
  #expect(state.rows[0].text == "printf hello\nhello")
  #expect(state.rows[0].inherited)
  #expect(state.sequence == 10)

  var local = ThreadState(id: "thread")
  let localItem = command(["threadId": .string("thread")])
  _ = try local.apply(snapshot([visible(localItem, position: 0)]))
  let before = try #require(local.rows.first)
  _ = try local.apply(
    update(
      command([
        "threadId": .string("thread"), "updatedAt": .string("rev2"),
        "input": .string("new command"),
      ]), sequence: 11))
  #expect(
    try !local.hydrateOutput(
      command([
        "threadId": .string("thread"), "outputOmitted": .bool(false),
        "output": .string("old response"),
      ]), replacing: before))
  #expect(local.rows[0].text == "new command")
  #expect(local.sequence == 11)
}

@Test func workspaceRefreshFollowsSettledFileToolsAndCheckpoints() throws {
  func fileItem(_ id: String, status: String, type: String = "file_change") -> JSON {
    .object([
      "id": .string(id), "threadId": .string("thread"), "type": .string(type),
      "status": .string(status),
    ])
  }
  var state = ThreadState(id: "thread")
  _ = try state.apply(
    snapshot([
      visible(fileItem("earlier", status: "completed"), position: 0),
      visible(fileItem("later", status: "running", type: "command_execution"), position: 1),
    ]))
  let first = try #require(state.workspaceMutationToken)
  _ = try state.apply(update(item("stream", text: "Streaming text"), sequence: 11))
  #expect(state.workspaceMutationToken == first)
  _ = try state.apply(
    update(fileItem("later", status: "waiting", type: "command_execution"), sequence: 12))
  #expect(state.workspaceMutationToken == first)
  _ = try state.apply(
    update(fileItem("later", status: "failed", type: "command_execution"), sequence: 13))
  let second = try #require(state.workspaceMutationToken)
  #expect(second != first)
  _ = try state.apply(update(fileItem("earlier", status: "completed"), sequence: 14))
  #expect(state.workspaceMutationToken == second)
  let checkpoint: JSON = .object([
    "id": .string("checkpoint"), "appRunOrdinal": .number(1),
    "runId": .string("run"), "capturedAt": .string("2026-10-11T20:00:00Z"),
  ])
  _ = try state.apply(update(checkpoint, sequence: 15, type: "checkpoint.captured"))
  let captured = state.workspaceMutationToken
  #expect(captured != second)
  _ = try state.apply(update(checkpoint, sequence: 16, type: "checkpoint.captured"))
  #expect(state.workspaceMutationToken == captured)
  _ = try state.apply(snapshot([], sequence: 20))
  #expect(state.workspaceMutationToken == nil)
  try state.prependHistory(
    .object([
      "items": .array([
        visible(
          fileItem("inherited", status: "completed"), position: 0, source: "parent", inherited: true
        )
      ])
    ]))
  #expect(state.workspaceMutationToken?.hasPrefix("parent:inherited") == true)
}
