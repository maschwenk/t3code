import Foundation
import Testing

@testable import T3Core

@Test func terminalOutputReplaysOnlyMissingBytesAndResetsOnReconnectOrClear() {
  var output = TerminalOutput()
  output.append("first\r\n\u{1B}[31mred")
  let initial = output.read(after: nil)
  #expect(initial.reset)
  #expect(String(decoding: initial.bytes, as: UTF8.self) == "first\r\n\u{1B}[31mred")
  output.append(" 日本語 👋\r\n")
  let incremental = output.read(after: initial.cursor)
  #expect(!incremental.reset)
  #expect(String(decoding: incremental.bytes, as: UTF8.self) == " 日本語 👋\r\n")
  #expect(output.read(after: incremental.cursor).bytes.isEmpty)
  output.reset("reconnected history")
  let replay = output.read(after: incremental.cursor)
  #expect(replay.reset)
  #expect(String(decoding: replay.bytes, as: UTF8.self) == "reconnected history")
  output.reset()
  let cleared = output.read(after: replay.cursor)
  #expect(cleared.reset)
  #expect(cleared.bytes.isEmpty)
}

@Test func terminalOutputBoundsHistoryWithoutBreakingUTF8OrLiveOffsets() {
  var output = TerminalOutput(limit: 17)
  output.append("old history")
  let old = output.read(after: nil)
  output.append("日本語👋 abcdefgh")
  let lagging = output.read(after: nil)
  #expect(output.retainedBytes <= 17)
  #expect(String(data: lagging.bytes, encoding: .utf8) != nil)
  let live = output.read(after: old.cursor)
  #expect(live.reset)  // This consumer missed more bytes than can be retained.
  output.append("xyz")
  let tail = output.read(after: lagging.cursor)
  #expect(!tail.reset)
  #expect(String(decoding: tail.bytes, as: UTF8.self) == "xyz")
  var discarded = TerminalOutput(limit: 0)
  discarded.append("hello")
  #expect(discarded.retainedBytes == 0)
  #expect(discarded.read(after: nil).bytes.isEmpty)
}

@Test func terminalHighVolumeOutputAndInputChunksPreserveUnicodeAndControlSequences() {
  let text = String(repeating: "\u{1B}[32m日本語👋\r\n\u{FEFF}", count: 80_000)
  let parts = TerminalOutput.split(Data(text.utf8), size: 16 * 1024)
  #expect(parts.allSatisfy { $0.count <= 16 * 1024 && String(data: $0, encoding: .utf8) != nil })
  #expect(parts.reduce(into: Data()) { $0.append($1) } == Data(text.utf8))
  var output = TerminalOutput()
  output.append(text)
  let update = output.read(after: nil)
  #expect(output.retainedBytes <= 512 * 1024)
  let retained = String(data: update.bytes, encoding: .utf8)
  #expect(retained != nil)
  #expect(text.hasSuffix(retained!))
}

@Test func terminalEventsKeepOtherSessionsOutAndReplaceSnapshotHistory() throws {
  let target = TerminalTarget(
    environment: "http://localhost:4773", threadID: "thread", terminalID: "term-2")
  var state = TerminalState(target: target)
  let snapshot: JSON = .object([
    "threadId": .string("thread"), "terminalId": .string("term-2"),
    "history": .string("saved"), "status": .string("running"), "pid": .number(42),
    "label": .string("zsh"), "sequence": .number(5),
  ])
  try state.apply(.object(["type": .string("snapshot"), "snapshot": snapshot]))
  let other = TerminalTarget(
    environment: target.environment, threadID: "other", terminalID: "term-2")
  try state.apply(
    other.input(["type": .string("output"), "data": .string("wrong"), "sequence": .number(6)]))
  try state.apply(
    target.input(["type": .string("output"), "data": .string(" live"), "sequence": .number(6)]))
  #expect(String(decoding: state.output.read(after: nil).bytes, as: UTF8.self) == "saved live")
  try state.apply(
    target.input([
      "type": .string("activity"), "label": .string("build"), "hasRunningSubprocess": .bool(true),
      "sequence": .number(7),
    ]))
  #expect(state.hasRunningSubprocess && state.label == "build")
  try state.apply(target.input(["type": .string("exited"), "sequence": .number(8)]))
  #expect(state.status == "exited" && state.pid == nil && !state.hasRunningSubprocess)
  try state.apply(.object(["type": .string("snapshot"), "snapshot": snapshot]))
  #expect(state.pid == 42 && state.status == "running")
  #expect(String(decoding: state.output.read(after: nil).bytes, as: UTF8.self) == "saved")
}

@Test func queuedKeystrokesCoalesceAndPastesRemainBoundedAndInOrder() {
  var queue = TerminalInputQueue()
  for key in ["h", "e", "l", "l", "o", " 👋", "\r"] {
    let accepted = queue.append(key)
    #expect(accepted)
  }
  let keys = queue.next()
  #expect(keys == "hello 👋\r")
  #expect(queue.byteCount == 0)
  let text = String(repeating: "日本語👋", count: 4000)
  let pasted = queue.append(text)
  let refused = queue.append(String(repeating: "x", count: 1024 * 1024))
  #expect(pasted && !refused)
  var result = ""
  while let next = queue.next() {
    #expect(next.utf8.count <= 16 * 1024)
    result += next
  }
  #expect(result == text)
  #expect(queue.byteCount == 0)
}

@Test func terminalClearCannotBeDiscardedAfterNewerOutputArrivesDuringHistoryPersistence() throws {
  let target = TerminalTarget(environment: "env", threadID: "t", terminalID: "term-1")
  var state = TerminalState(target: target)
  try state.apply(
    .object([
      "type": .string("snapshot"),
      "snapshot": target.input([
        "history": .string("old history"), "status": .string("running"), "sequence": .number(236),
      ]),
    ]))
  let before = state.output.read(after: nil).cursor
  try state.apply(
    target.input([
      "type": .string("output"), "data": .string("fresh prompt"), "sequence": .number(242),
    ]))
  try state.apply(target.input(["type": .string("cleared"), "sequence": .number(237)]))
  let cleared = state.output.read(after: before)
  #expect(cleared.reset && cleared.bytes.isEmpty)
  try state.apply(
    target.input([
      "type": .string("output"), "data": .string("next command"), "sequence": .number(243),
    ]))
  #expect(
    String(decoding: state.output.read(after: cleared.cursor).bytes, as: UTF8.self)
      == "next command")
}
