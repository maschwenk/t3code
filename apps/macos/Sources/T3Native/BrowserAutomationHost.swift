import AppKit
import T3Core

struct BrowserAutomationError: LocalizedError {
  let tag: String
  let message: String
  var errorDescription: String? { message }
  init(_ tag: String, _ message: String) {
    self.tag = tag
    self.message = message
  }
  static let interrupted = Self(
    "PreviewAutomationControlInterruptedError", "Browser control was interrupted.")
}

struct BrowserAutomationDeadline {
  let end: ContinuousClock.Instant
  init(milliseconds: Int) {
    end = .now.advanced(by: .milliseconds(min(120_000, max(1, milliseconds))))
  }
  var remaining: Duration { ContinuousClock.now.duration(to: end) }
  func check() throws {
    try Task.checkCancellation()
    guard ContinuousClock.now < end else {
      throw BrowserAutomationError(
        "PreviewAutomationTimeoutError", "The browser operation timed out.")
    }
  }
}

@MainActor final class BrowserAutomationHost {
  typealias Handler = (JSON, BrowserAutomationDeadline) async throws -> JSON
  var handle: Handler?
  var liveTabs: (() -> [JSON])?
  var onChange: (() -> Void)?
  private(set) var error: String?
  private(set) var running = 0
  private(set) var paused = false
  private let clientID = "native-" + UUID().uuidString
  private var connection: RPCConnection?
  private var environmentID: String?
  private var connectionID: String?
  private var streamTask: Task<Void, Never>?
  private var work: [String: Task<Void, Never>] = [:]
  private var owners: [String: String] = [:]
  private var queues: [String: (id: String, task: Task<Void, Never>)] = [:]
  private var seen: [String] = []
  private var generation = UUID()
  private var focusTask: Task<Void, Never>?
  private var pendingFocus: JSON?
  private var lastFocus: JSON?
  private var activityTasks: [Task<Void, Never>] = []
  static let operations = [
    "status", "open", "navigate", "snapshot", "click", "type", "press", "scroll", "evaluate",
    "waitFor", "resize", "setColorScheme", "recordingStart", "recordingStop",
  ]

  init() {
    for name in [
      NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
    ] {
      activityTasks.append(
        Task { [weak self] in
          for await _ in NotificationCenter.default.notifications(named: name) {
            guard !Task.isCancelled else { return }
            self?.refreshFocus()
          }
        })
    }
  }
  isolated deinit {
    for task in activityTasks { task.cancel() }
    stop()
  }
  func retry() {
    let connection = connection
    let environmentID = environmentID
    stop()
    synchronize(connection: connection, environmentID: environmentID)
  }
  func synchronize(connection: RPCConnection?, environmentID: String?) {
    guard self.connection !== connection || self.environmentID != environmentID else {
      refreshFocus()
      return
    }
    stop()
    self.connection = connection
    self.environmentID = environmentID
    guard let connection, let environmentID else { return }
    let generation = generation
    streamTask = Task { [weak self] in
      guard let self else { return }
      do {
        let stream = try await connection.subscribe(
          "previewAutomation.connect",
          payload: .object([
            "clientId": .string(clientID), "environmentId": .string(environmentID),
            "supportedOperations": .array(Self.operations.map(JSON.string)),
          ]))
        defer { Task { await connection.cancel(stream.id) } }
        for try await event in stream.values {
          try Task.checkCancellation()
          guard self.generation == generation else { return }
          if event["type"].string == "connected" {
            connectionID = try event.requiredString("connectionId")
            error = nil
            lastFocus = nil
            refreshFocus()
            onChange?()
          } else if event["connectionId"].string == connectionID {
            enqueue(event["request"], connection: connection, generation: generation)
          }
        }
        throw T3Error("Agent browser connection ended. Reconnect to restore it.")
      } catch {
        guard !Task.isCancelled, self.generation == generation else { return }
        self.error = error.localizedDescription
        connectionID = nil
        interrupt()
        onChange?()
      }
    }
  }
  func setPaused(_ paused: Bool) {
    self.paused = paused
    if paused { interrupt() }
    onChange?()
  }
  func interrupt(threadID: String) {
    for (id, owner) in owners where owner == threadID { work[id]?.cancel() }
  }
  private func interrupt() { for task in work.values { task.cancel() } }
  private func stop() {
    generation = UUID()
    streamTask?.cancel()
    streamTask = nil
    interrupt()
    work = [:]
    owners = [:]
    queues = [:]
    seen = []
    focusTask?.cancel()
    focusTask = nil
    pendingFocus = nil
    lastFocus = nil
    connectionID = nil
    connection = nil
    environmentID = nil
    error = nil
    running = 0
  }
  private func enqueue(_ request: JSON, connection: RPCConnection, generation: UUID) {
    guard let id = request["requestId"].string, let threadID = request["threadId"].string,
      let connectionID, !seen.contains(id)
    else { return }
    seen.append(id)
    if seen.count > 256 { seen.removeFirst() }
    let maximum = request["operation"].string == "recordingStop" ? 120_000 : 60_000
    let timeoutMs = min(maximum, max(1, request["timeoutMs"].int ?? 15_000))
    // Match Electron's response margin so a page timeout does not evict a healthy host.
    let deadline = BrowserAutomationDeadline(
      milliseconds: timeoutMs - min(1_500, (timeoutMs + 4) / 5))
    let predecessor = queues[threadID]?.id
    let overCapacity = work.count >= 16
    let task = Task { [weak self] in
      guard let self else { return }
      var expired = false
      let timeout = Task {
        do { try await Task.sleep(for: deadline.remaining) } catch { return }
        expired = true
        work[id]?.cancel()
      }
      var response: [String: JSON] = [
        "clientId": .string(clientID), "connectionId": .string(connectionID),
        "requestId": .string(id),
      ]
      defer {
        timeout.cancel()
        work.removeValue(forKey: id)
        owners.removeValue(forKey: id)
        if queues[threadID]?.id == id { queues.removeValue(forKey: threadID) }
        running = work.count
        onChange?()
        refreshFocus()
      }
      do {
        guard !paused else { throw BrowserAutomationError.interrupted }
        guard !overCapacity else {
          throw T3Error("The native browser is busy. Retry after the current actions finish.")
        }
        while let predecessor, work[predecessor] != nil {
          try deadline.check()
          try await Task.sleep(for: .milliseconds(25))
        }
        try deadline.check()
        guard self.generation == generation, let handle, !paused else {
          throw BrowserAutomationError.interrupted
        }
        response["result"] = try await handle(request, deadline)
        try deadline.check()
        response["ok"] = .bool(true)
      } catch {
        let failure = error as? BrowserAutomationError
        response["ok"] = .bool(false)
        response["error"] = .object([
          "_tag": .string(
            expired
              ? "PreviewAutomationTimeoutError"
              : error is CancellationError
                ? BrowserAutomationError.interrupted.tag
                : failure?.tag ?? "PreviewAutomationExecutionError"),
          "message": .string(
            expired
              ? "The browser operation timed out." : String(error.localizedDescription.prefix(2000))
          ),
        ])
      }
      guard self.generation == generation, self.connectionID == connectionID else { return }
      do {
        let payload = JSON.object(response)
        _ = try await Task {
          try await connection.call("previewAutomation.respond", payload: payload)
        }.value
      } catch {
        if !Task.isCancelled {
          self.error = "Agent browser response failed: " + error.localizedDescription
        }
      }
    }
    work[id] = task
    owners[id] = threadID
    if !overCapacity { queues[threadID] = (id, task) }
    running = work.count
    onChange?()
  }
  func refreshFocus() {
    guard let connection, let environmentID, let connectionID else { return }
    let payload: JSON = .object([
      "clientId": .string(clientID), "environmentId": .string(environmentID),
      "connectionId": .string(connectionID),
      "focused": .bool(NSApp?.isActive == true), "liveTabs": .array(liveTabs?() ?? []),
    ])
    guard payload != lastFocus else { return }
    lastFocus = payload
    pendingFocus = payload
    guard focusTask == nil else { return }
    let generation = generation
    focusTask = Task { [weak self] in
      guard let self else { return }
      defer { if self.generation == generation { focusTask = nil } }
      while let input = pendingFocus, !Task.isCancelled, self.generation == generation {
        pendingFocus = nil
        do { _ = try await connection.call("previewAutomation.focusHost", payload: input) } catch {
          if self.generation == generation {
            lastFocus = nil
            self.error = error.localizedDescription
            onChange?()
          }
          return
        }
      }
    }
  }
}
