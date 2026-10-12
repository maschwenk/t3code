import AppKit
import T3Core
import WebKit

@MainActor final class BrowserAutomationPage {
  let cursor: BrowserAgentCursor
  private let web: WKWebView
  private let world = WKContentWorld.world(name: "T3BrowserAutomation")
  private var installed = false
  private var document = UUID()
  private var calls: [UUID: JavaScriptCall] = [:]
  private(set) var controlRevision = UUID()
  private(set) var actions: [JSON] = []
  private static let injected: String = {
    let file = Bundle.module.url(
      forResource: "PlaywrightInjected", withExtension: "js", subdirectory: "Resources")!
    return try! String(contentsOf: file, encoding: .utf8)
  }()
  private static let operations: String = {
    let file = Bundle.module.url(
      forResource: "BrowserAutomation", withExtension: "js", subdirectory: "Resources")!
    return try! String(contentsOf: file, encoding: .utf8)
  }()
  init(web: WKWebView) {
    self.web = web
    cursor = BrowserAgentCursor(frame: web.bounds)
    cursor.autoresizingMask = [.width, .height]
    web.addSubview(cursor, positioned: .above, relativeTo: nil)
  }
  func interrupt() {
    controlRevision = UUID()
    cursor.hide()
    for call in calls.values { call.finish(.failure(BrowserAutomationError.interrupted)) }
  }
  func invalidate() {
    installed = false
    document = UUID()
  }

  func record(
    _ operation: String, status: String, id: String, started: String, error: String? = nil
  ) {
    var value: [String: JSON] = [
      "id": .string(id), "action": .string(operation), "status": .string(status),
      "startedAt": .string(started),
    ]
    if status != "running" { value["completedAt"] = .string(Date().ISO8601Format()) }
    if let error { value["error"] = .string(error) }
    if let index = actions.firstIndex(where: { $0["id"].string == id }) {
      actions[index] = .object(value)
    } else {
      actions.append(.object(value))
      if actions.count > 50 { actions.removeFirst() }
    }
  }

  private func install(_ deadline: BrowserAutomationDeadline) async throws {
    guard !installed else { return }
    let document = document
    _ = try await script(
      """
      if (!globalThis.__t3PlaywrightInjected) {
        const module = {exports:{}};
        \(Self.injected)
        globalThis.__t3PlaywrightInjected = new (module.exports.InjectedScript())(globalThis, {
          isUnderTest:false, sdkLanguage:'javascript', testIdAttributeName:'data-testid', stableRafCount:1,
          browserName:'webkit', shouldPrependErrorPrefix:false, isUtilityWorld:true, customEngines:[]
        });
      }
      return JSON.stringify(true);
      """, arguments: [:], world: world, deadline: deadline)
    guard self.document == document else { throw BrowserAutomationError.interrupted }
    installed = true
  }

  func query(_ operation: String, input: JSON = .object([:]), deadline: BrowserAutomationDeadline)
    async throws -> JSON
  {
    try await install(deadline)
    return try await script(
      "const input = JSON.parse(payload); const value = await (async () => {\n" + Self.operations
        + "\n})(); return JSON.stringify(value ?? null);",
      arguments: [
        "operation": operation, "payload": String(decoding: try input.data(), as: UTF8.self),
      ], world: world, deadline: deadline)
  }

  func run(_ operation: String, input: JSON, deadline: BrowserAutomationDeadline) async throws
    -> JSON
  {
    let revision = controlRevision
    func check() throws {
      try deadline.check()
      guard revision == controlRevision else { throw BrowserAutomationError.interrupted }
    }
    try check()
    if operation == "evaluate" {
      guard input["returnByValue"] != .bool(false) else {
        throw BrowserAutomationError(
          "PreviewAutomationUnsupportedClientError",
          "Native WebKit returns values; remote JavaScript object handles are unavailable.")
      }
      let result = try await script(
        "let value = (0,eval)(expression); if (wait) value = await value; return JSON.stringify(value ?? null);",
        arguments: [
          "expression": try input.requiredString("expression"),
          "wait": input["awaitPromise"] != .bool(false),
        ], world: .page, deadline: deadline)
      try check()
      return result
    }
    if ["type", "scroll", "press"].contains(operation) {
      let target = try await query("pointer", input: input, deadline: deadline)
      try check()
      if case .number(let x) = target["x"], case .number(let y) = target["y"] {
        let duration = try cursor.move(css: CGPoint(x: x, y: y), zoom: web.pageZoom)
        if duration > 0 { try await Task.sleep(for: .seconds(duration)) }
        try check()
      }
      // Do not display typed text: it may be a password or another secret.
      let key = input["key"].string ?? "key"
      let modifiers = input["modifiers"].array.compactMap(\.string)
      let label =
        key.count > 1 || modifiers.contains("Meta") || modifiers.contains("Control")
        ? (modifiers + [key]).joined(separator: "+") : "key"
      cursor.showFeedback(
        operation == "type"
          ? "Agent typing" : operation == "scroll" ? "Agent scroll" : "Agent " + label)
    }
    if operation == "press" {
      try await press(input, deadline: deadline)
      try check()
      return .null
    }
    while true {
      try check()
      let result = try await query(operation, input: input, deadline: deadline)
      try check()
      if let tag = result["error"]["_tag"].string {
        throw BrowserAutomationError(
          tag, result["error"]["message"].string ?? "Browser action failed.")
      }
      if result["pending"].bool {
        try await Task.sleep(for: .milliseconds(80))
        continue
      }
      if operation == "click" {
        guard case .number(let x) = result["x"], case .number(let y) = result["y"] else {
          throw T3Error("Browser target did not provide coordinates.")
        }
        // Seed the first movement so the agent is visibly approaching its first target.
        if cursor.target == nil {
          _ = try cursor.move(
            css: CGPoint(
              x: min(16, web.bounds.width / web.pageZoom / 2),
              y: min(16, web.bounds.height / web.pageZoom / 2)), zoom: web.pageZoom, animate: false)
        }
        let duration = try cursor.move(css: CGPoint(x: x, y: y), zoom: web.pageZoom)
        if duration > 0 { try await Task.sleep(for: .seconds(duration)) }
        try check()
        // Layout or scrolling can change during the transition; resolve the target again.
        let resolved = try await query(operation, input: input, deadline: deadline)
        try check()
        if resolved["pending"].bool { continue }
        guard case .number(let rx) = resolved["x"], case .number(let ry) = resolved["y"] else {
          throw T3Error("Browser target no longer provides coordinates.")
        }
        _ = try cursor.move(css: CGPoint(x: rx, y: ry), zoom: web.pageZoom, animate: false)
        cursor.click()
        try click(resolved)
        return .null
      }
      if ["type", "scroll", "waitFor"].contains(operation) { return .null }
      return result
    }
  }

  private func click(_ point: JSON) throws {
    guard case .number(let x) = point["x"], case .number(let y) = point["y"],
      x.isFinite, y.isFinite, x >= 0, y >= 0,
      x < web.bounds.width / web.pageZoom, y < web.bounds.height / web.pageZoom,
      let window = web.window
    else {
      throw BrowserAutomationError(
        "PreviewAutomationCoordinatesOutsideViewportError",
        "The target is outside the browser viewport.")
    }
    let local = NSPoint(
      x: x * web.pageZoom,
      y: (web.isFlipped ? y * web.pageZoom : web.bounds.height - y * web.pageZoom))
    let location = web.convert(local, to: nil)
    guard let content = window.contentView,
      let hit = content.hitTest(content.superview?.convert(location, from: nil) ?? location),
      hit === web || hit.isDescendant(of: web)
    else {
      throw BrowserAutomationError(
        "PreviewAutomationTargetNotFoundError", "The browser target is covered by another view.")
    }
    // Dispatch only to this WK view; never send global input or make another window key.
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      guard
        let event = NSEvent.mouseEvent(
          with: type, location: location, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
          pressure: type == .leftMouseDown ? 1 : 0)
      else { throw T3Error("Could not create browser input.") }
      if type == .leftMouseDown { hit.mouseDown(with: event) } else { hit.mouseUp(with: event) }
    }
  }

  private func press(_ input: JSON, deadline: BrowserAutomationDeadline) async throws {
    guard let window = web.window else { throw BrowserAutomationError.interrupted }
    let key = try input.requiredString("key")
    let keys: [String: (String, UInt16)] = [
      "Enter": ("\r", 36), "Tab": ("\t", 48), "Escape": ("\u{1b}", 53), "Backspace": ("\u{7f}", 51),
      "Delete": ("\u{f728}", 117), "ArrowLeft": ("\u{f702}", 123), "ArrowRight": ("\u{f703}", 124),
      "ArrowUp": ("\u{f700}", 126), "ArrowDown": ("\u{f701}", 125),
      "Home": ("\u{f729}", 115), "End": ("\u{f72b}", 119), "PageUp": ("\u{f72c}", 116),
      "PageDown": ("\u{f72d}", 121), "Space": (" ", 49),
    ]
    let characterCodes: [String: UInt16] = [
      "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
      "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20,
      "4": 21, "6": 22, "5": 23,
      "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33,
      "i": 34, "p": 35,
      "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
      ".": 47, " ": 49, "`": 50,
    ]
    guard let pair = keys[key] ?? characterCodes[key.lowercased()].map({ (key, $0) }) else {
      throw T3Error("Unsupported browser key: " + key + ". Use type for text input.")
    }
    var flags: NSEvent.ModifierFlags = []
    for modifier in input["modifiers"].array.compactMap(\.string) {
      switch modifier {
      case "Alt": flags.insert(.option)
      case "Control": flags.insert(.control)
      case "Meta": flags.insert(.command)
      case "Shift": flags.insert(.shift)
      default: break
      }
    }
    let responder =
      (window.firstResponder as? NSView).flatMap {
        $0 === web || $0.isDescendant(of: web) ? $0 : nil
      } ?? web
    let selectAll = #selector(NSText.selectAll(_:))
    if flags == [.command], key.lowercased() == "a", responder.responds(to: selectAll) {
      responder.perform(selectAll, with: nil)
      _ = try await query("ready", deadline: deadline)
      return
    }
    for type in [NSEvent.EventType.keyDown, .keyUp] {
      guard
        let event = NSEvent.keyEvent(
          with: type, location: .zero, modifierFlags: flags,
          timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: window.windowNumber, context: nil, characters: pair.0,
          charactersIgnoringModifiers: pair.0, isARepeat: false, keyCode: pair.1)
      else { throw T3Error("Could not create browser key input.") }
      if type == .keyDown {
        if !flags.contains(.command) || !web.performKeyEquivalent(with: event) {
          responder.keyDown(with: event)
        }
      } else {
        responder.keyUp(with: event)
      }
    }
    _ = try await query("ready", deadline: deadline)
  }

  func script(
    _ source: String, arguments: [String: Any], world: WKContentWorld,
    deadline: BrowserAutomationDeadline
  ) async throws -> JSON {
    try deadline.check()
    let call = JavaScriptCall()
    let id = UUID()
    calls[id] = call
    defer { calls.removeValue(forKey: id) }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        call.continuation = continuation
        call.timer = Task {
          do { try await Task.sleep(for: deadline.remaining) } catch { return }
          call.finish(
            .failure(
              BrowserAutomationError(
                "PreviewAutomationTimeoutError", "The page did not respond in time.")))
        }
        web.callAsyncJavaScript(source, arguments: arguments, in: nil, in: world) { result in
          switch result {
          case .success(let value):
            guard let string = value as? String, string.utf8.count <= 4_000_000 else {
              call.finish(
                .failure(T3Error("The page result was not serializable or was too large.")))
              return
            }
            call.finish(Result { try JSON.decode(Data(string.utf8)) })
          case .failure(let error): call.finish(.failure(error))
          }
        }
      }
    } onCancel: {
      Task { @MainActor in call.finish(.failure(CancellationError())) }
    }
  }
  @MainActor private final class JavaScriptCall {
    var continuation: CheckedContinuation<JSON, any Error>?
    var timer: Task<Void, Never>?
    func finish(_ result: Result<JSON, any Error>) {
      timer?.cancel()
      timer = nil
      continuation?.resume(with: result)
      continuation = nil
    }
  }
}
