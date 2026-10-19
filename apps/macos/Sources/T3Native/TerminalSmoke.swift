import AppKit
import T3Core

extension ParitySmoke {
  @MainActor static func terminal(
    connection: RPCConnection, settings: ConnectionSettings, threadID: String, projectID: String
  ) async throws {
    let projection = try await connection.call(
      "orchestration.getThreadProjection", payload: .object(["threadId": .string(threadID)]))
    guard projection["thread"]["projectId"].string == projectID else {
      throw T3Error("Terminal smoke requires a thread in the isolated project.")
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "t3-native-terminal-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = TerminalTarget(
      environment: settings.endpoint.absoluteString, threadID: threadID,
      terminalID: "native-smoke-" + UUID().uuidString.lowercased())
    let context: [String: JSON] = ["cwd": .string(directory.path), "worktreePath": .null]
    let terminal = RemoteTerminal(target: target, connection: connection, context: context)
    do {
      terminal.resize(TerminalGrid(columns: 97, rows: 31))
      terminal.attach()
      terminalProgress("attach \(target.terminalID)")
      try await waitForTerminal(terminal) { $0.state.status == "running" && $0.attached }
      let pid = terminal.state.pid
      guard pid != nil else { throw T3Error("Terminal started without a process.") }
      // Disable echo so matching a marker proves execution, not just echoed input.
      terminal.write("stty -echo; printf '\\n%s\\n' native-$((10 + 11))\r")
      terminalProgress("input")
      try await waitForTerminal(terminal) { terminalText($0).contains("native-21") }
      terminal.write("printf '\\033[32m%s\\033[0m\\n' '日本語 👋'; stty size; pwd\r")
      terminalProgress("Unicode and initial dimensions")
      try await waitForTerminal(terminal) {
        let text = terminalText($0)
        return text.contains("日本語 👋") && text.contains("31 97") && text.contains(directory.path)
      }
      terminal.resize(TerminalGrid(columns: 111, rows: 37))
      // resize() is intentionally asynchronous; wait for the matching server operation directly.
      _ = try await connection.call(
        "terminal.resize", payload: target.input(TerminalGrid(columns: 111, rows: 37).fields))
      terminal.write("stty size; printf '%s\\n' resize-$((20 + 22))\r")
      terminalProgress("resize")
      try await waitForTerminal(terminal) {
        terminalText($0).contains("37 111") && terminalText($0).contains("resize-42")
      }

      let beforeDetach = terminal.state.output.read(after: nil)
      terminal.detach()
      _ = try await connection.call(
        "terminal.write",
        payload: target.input(["data": .string("printf '%s\\n' detached-$((40 + 2))\r")]))
      terminal.attach()
      terminalProgress("reattach history")
      try await waitForTerminal(terminal) {
        $0.attached && terminalText($0).contains("detached-42")
      }
      guard terminal.state.pid == pid, terminal.state.output.read(after: beforeDetach.cursor).reset
      else {
        throw T3Error("Attaching restarted the process or reused an obsolete output cursor.")
      }
      guard terminalText(terminal).components(separatedBy: "resize-42").count == 2 else {
        throw T3Error("Terminal output was duplicated on attach.")
      }
      let beforeClear = terminal.state.output.read(after: nil).cursor
      try await terminal.clear()
      terminalProgress("clear")
      try await waitForTerminal(terminal) {
        $0.state.output.read(after: beforeClear).reset && !terminalText($0).contains("detached-42")
      }
      terminalProgress("cleared history verified; input after clear")
      terminal.write("printf '%s\\n' after-clear-$((1 + 2))\r")
      try await waitForTerminal(terminal) { terminalText($0).contains("after-clear-3") }
      terminal.write("exit 0\r")
      terminalProgress("exit")
      try await waitForTerminal(terminal) { $0.state.status == "exited" }
      terminal.detach()
      terminal.attach()
      terminalProgress("reattach exited session")
      try await waitForTerminal(terminal) { $0.attached && $0.state.status == "exited" }
      try await terminal.restart()
      terminalProgress("restart")
      try await waitForTerminal(terminal) {
        $0.state.status == "running" && $0.state.pid != nil && $0.state.pid != pid
      }
      terminal.write("stty -echo; printf '%s\\n' restarted-$((5 + 6))\r")
      try await waitForTerminal(terminal) { terminalText($0).contains("restarted-11") }
      _ = NSApplication.shared
      let surface = TerminalSurface(frame: NSRect(x: 0, y: 0, width: 800, height: 320))
      defer { surface.stop() }
      var rendererError: String?
      surface.onError = { rendererError = $0 }
      surface.onInput = { [weak terminal] in terminal?.write($0) }
      surface.start()
      if let rendererError { throw T3Error(rendererError) }
      surface.inputEnabled = true
      surface.synchronize(terminal.state.output)
      surface.insertText(
        "printf '%s\\n' renderer-$((6 * 7))",
        replacementRange: NSRange(location: NSNotFound, length: 0))
      let enter = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
        context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false,
        keyCode: 36)!
      surface.keyDown(with: enter)
      terminalProgress("native engine input through real PTY")
      try await waitForTerminal(terminal) { terminalText($0).contains("renderer-42") }
      try await terminal.close()
      let final = try await connection.call(
        "orchestration.getThreadProjection", payload: .object(["threadId": .string(threadID)]))
      guard final["runs"] == projection["runs"] else {
        throw T3Error("Terminal smoke unexpectedly changed inference state.")
      }
      print(
        "Terminal smoke passed: native engine input through real PTY, Unicode/ANSI, resize, detach/history replay, clear, exit, explicit restart, close."
      )
    } catch {
      terminal.detach()
      _ = try? await connection.call(
        "terminal.close", payload: target.input(["deleteHistory": .bool(true)]))
      throw error
    }
  }

  @MainActor private static func terminalText(_ terminal: RemoteTerminal) -> String {
    String(decoding: terminal.state.output.read(after: nil).bytes, as: UTF8.self)
  }

  @MainActor private static func waitForTerminal(
    _ terminal: RemoteTerminal, until predicate: @escaping @MainActor (RemoteTerminal) -> Bool
  ) async throws {
    let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    terminal.onChange = { continuation.yield(()) }
    let timeout = Task {
      try await Task.sleep(for: .seconds(15))
      continuation.finish()
    }
    defer {
      terminal.onChange = nil
      timeout.cancel()
      continuation.finish()
    }
    continuation.yield(())
    for await _ in stream {
      if predicate(terminal) { return }
      if let error = terminal.error ?? terminal.state.error { throw T3Error(error) }
    }
    throw T3Error(
      "Terminal smoke timed out with status \(terminal.state.status), attached \(terminal.attached), sequence \(terminal.state.sequence ?? -1), retained \(terminal.state.output.retainedBytes), detached marker \(terminalText(terminal).contains("detached-42")), after-clear marker \(terminalText(terminal).contains("after-clear-3"))."
    )
  }
  private static func terminalProgress(_ stage: String) {
    FileHandle.standardError.write(Data("Terminal smoke: \(stage)\n".utf8))
  }
}
