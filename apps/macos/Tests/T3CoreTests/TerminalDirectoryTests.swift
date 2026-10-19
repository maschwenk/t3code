import T3Core
import Testing

@Test func terminalTabsFollowOnlyTheirThreadAndPreserveActivityOrder() throws {
  func summary(_ id: String, thread: String = "active", label: String = "zsh") -> JSON {
    .object([
      "threadId": .string(thread), "terminalId": .string(id), "label": .string(label),
      "status": .string("running"), "hasRunningSubprocess": .bool(label != "zsh"),
    ])
  }
  var directory = TerminalDirectory(threadID: "active")
  try directory.apply(
    .object([
      "type": .string("snapshot"),
      "terminals": .array([
        summary("term-10"), summary("term-1", thread: "other"), summary("term-2"),
      ]),
    ]))
  #expect(directory.terminals.map(\.id) == ["term-2", "term-10"])
  #expect(directory.receivedSnapshot)
  try directory.apply(
    .object(["type": .string("upsert"), "terminal": summary("term-2", label: "vim")]))
  #expect(directory.terminals.map(\.id) == ["term-2", "term-10"])
  #expect(directory.terminals[0].hasRunningSubprocess)
  try directory.apply(
    .object([
      "type": .string("remove"), "threadId": .string("other"), "terminalId": .string("term-2"),
    ]))
  #expect(directory.terminals.count == 2)
  try directory.apply(
    .object([
      "type": .string("remove"), "threadId": .string("active"), "terminalId": .string("term-2"),
    ]))
  #expect(directory.terminals.map(\.id) == ["term-10"])
  // A fresh snapshot replaces stale sessions after disconnect.
  try directory.apply(
    .object(["type": .string("snapshot"), "terminals": .array([summary("term-1")])]))
  #expect(directory.terminals.map(\.id) == ["term-1"])
}
