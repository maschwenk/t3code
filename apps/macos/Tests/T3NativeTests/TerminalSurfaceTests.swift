import AppKit
import T3Core
import Testing

@testable import T3Native

@MainActor @Test func terminalEnginePreservesHistoryAndEncodesInput() async throws {
  _ = NSApplication.shared
  let surface = TerminalSurface(frame: NSRect(x: 0, y: 0, width: 800, height: 320))
  defer { surface.stop() }
  var failure: String?
  var grid: TerminalGrid?
  surface.onError = { failure = $0 }
  surface.onResize = { grid = $0 }
  surface.start()
  #expect(failure == nil)
  #expect(try #require(grid).columns > 40)
  surface.inputEnabled = true
  var output = TerminalOutput()
  output.append("\u{1B}[32m日本語 👋\u{1B}[0m\r\nsecond line")
  try await terminalReply(surface) {
    output.append("\u{1B}[6n")
    surface.synchronize(output)
  }
  surface.selectAll(nil)
  let selected = try #require(surface.selectedText)
  #expect(selected.contains("日本語 👋"))
  #expect(selected.contains("second line"))
  #expect(!selected.contains("[32m"))
  #expect((surface.accessibilityValue() as? String)?.contains("日本語 👋") == true)

  // Synchronizing the same snapshot must not duplicate the text.
  try await terminalReply(surface) {
    surface.synchronize(output)
    output.append("\u{1B}[6n")
    surface.synchronize(output)
  }
  surface.selectAll(nil)
  #expect(try #require(surface.selectedText).components(separatedBy: "second line").count == 2)

  let input = try await terminalReply(
    surface, until: { $0.contains("a\r") },
    perform: {
      for (code, text) in [(UInt16(0), "a"), (UInt16(36), "\r")] {
        let event = NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
          context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false,
          keyCode: code)!
        surface.keyDown(with: event)
      }
    })
  #expect(input == "a\r")
  let committed = try await terminalReply(
    surface, until: { $0.contains("日本語") },
    perform: {
      surface.setMarkedText(
        "に", selectedRange: NSRange(location: 1, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0))
      surface.insertText("日本語", replacementRange: NSRange(location: NSNotFound, length: 0))
    })
  #expect(committed == "日本語")
  #expect(!surface.hasMarkedText())

  try await terminalReply(surface) {
    output.append("\u{1B}[?2004h\u{1B}[6n")
    surface.synchronize(output)
  }
  let pasted = String(repeating: "日本語 👋\n", count: 2000)
  let bracketed = try await terminalReply(
    surface, until: { $0.hasSuffix("\u{1B}[201~") },
    perform: {
      surface.pasteText(pasted)
    })
  #expect(bracketed == "\u{1B}[200~" + pasted + "\u{1B}[201~")

  try await terminalReply(surface) {
    output.reset("fresh history\u{1B}[6n")
    surface.synchronize(output)
  }
  surface.selectAll(nil)
  #expect(try #require(surface.selectedText).contains("fresh history"))
  #expect(!(surface.selectedText ?? "").contains("second line"))
  surface.stop()
  surface.start()
  surface.inputEnabled = true
  try await terminalReply(surface) { surface.synchronize(output) }
  surface.selectAll(nil)
  #expect(try #require(surface.selectedText).contains("fresh history"))
}

@discardableResult @MainActor private func terminalReply(
  _ surface: TerminalSurface, until predicate: @escaping (String) -> Bool = { $0.hasSuffix("R") },
  perform: () -> Void
) async throws -> String {
  let (stream, continuation) = AsyncStream<String>.makeStream()
  surface.onInput = { continuation.yield($0) }
  let timeout = Task {
    try await Task.sleep(for: .seconds(8))
    continuation.finish()
  }
  defer {
    timeout.cancel()
    continuation.finish()
    surface.onInput = nil
  }
  perform()
  var received = ""
  for await bytes in stream {
    received += bytes
    if predicate(received) { return received }
  }
  throw T3Error("Terminal engine did not acknowledge the input/output check.")
}
