import Foundation

public struct TerminalTarget: Hashable, Sendable {
  public let environment: String
  public let threadID: String
  public let terminalID: String
  public init(environment: String, threadID: String, terminalID: String) {
    self.environment = environment
    self.threadID = threadID
    self.terminalID = terminalID
  }
  public func input(_ fields: [String: JSON] = [:]) -> JSON {
    var fields = fields
    fields["threadId"] = .string(threadID)
    fields["terminalId"] = .string(terminalID)
    return .object(fields)
  }
  public func matches(_ event: JSON) -> Bool {
    event["threadId"].string == threadID && event["terminalId"].string == terminalID
  }
}

public struct TerminalGrid: Equatable, Sendable {
  public let columns: Int
  public let rows: Int
  public init(columns: Int, rows: Int) {
    self.columns = min(1000, max(1, columns))
    self.rows = min(500, max(1, rows))
  }
  public var fields: [String: JSON] {
    ["cols": .number(Double(columns)), "rows": .number(Double(rows))]
  }
}

/// A cursor reads only new bytes. A reconnect, clear, or lagging consumer gets a bounded reset.
public struct TerminalOutput: Sendable {
  public struct Cursor: Equatable, Sendable {
    fileprivate let generation: UUID
    fileprivate let offset: Int
  }
  public struct Update: Sendable {
    public let reset: Bool
    public let bytes: Data
    public let cursor: Cursor
  }
  private var generation = UUID()
  private var chunks: [Data] = []
  private var end = 0
  public private(set) var retainedBytes = 0
  public let limit: Int
  public init(limit: Int = 512 * 1024) { self.limit = max(0, limit) }

  public mutating func reset(_ text: String = "") {
    generation = UUID()
    chunks = []
    retainedBytes = 0
    end = 0
    append(text)
  }

  public mutating func append(_ text: String) {
    let bytes = Data(text.utf8)
    guard !bytes.isEmpty else { return }
    end += bytes.count
    if limit == 0 { return }
    for part in Self.split(bytes, size: 16 * 1024) {
      if let last = chunks.last, last.count + part.count <= 16 * 1024 {
        chunks[chunks.count - 1].append(part)
      } else {
        chunks.append(part)
      }
      retainedBytes += part.count
    }
    while retainedBytes > limit, let first = chunks.first {
      let excess = retainedBytes - limit
      if first.count <= excess {
        retainedBytes -= first.count
        chunks.removeFirst()
      } else {
        var start = first.startIndex + excess
        while start < first.endIndex && first[start] & 0xC0 == 0x80 { start += 1 }
        retainedBytes -= start - first.startIndex
        chunks[0] = Data(first[start...])
      }
    }
  }

  public func read(after cursor: Cursor?) -> Update {
    let start = end - retainedBytes
    let reset =
      cursor == nil || cursor?.generation != generation
      || cursor!.offset < start || cursor!.offset > end
    var skip = reset ? 0 : cursor!.offset - start
    var result = Data()
    for chunk in chunks {
      if skip >= chunk.count {
        skip -= chunk.count
        continue
      }
      result.append(contentsOf: chunk.dropFirst(skip))
      skip = 0
    }
    return Update(reset: reset, bytes: result, cursor: Cursor(generation: generation, offset: end))
  }

  public static func split(_ bytes: Data, size: Int) -> [Data] {
    var result: [Data] = []
    var start = bytes.startIndex
    while start < bytes.endIndex {
      var end = min(bytes.endIndex, start + max(4, size))
      while end < bytes.endIndex && bytes[end] & 0xC0 == 0x80 { end -= 1 }
      result.append(Data(bytes[start..<end]))
      start = end
    }
    return result
  }
}

public struct TerminalState: Sendable {
  public let target: TerminalTarget
  public private(set) var output = TerminalOutput()
  public private(set) var status = "connecting"
  public private(set) var label: String
  public private(set) var error: String?
  public private(set) var pid: Int?
  public private(set) var hasRunningSubprocess = false
  public private(set) var sequence: Int?
  public private(set) var receivedSnapshot = false
  public init(target: TerminalTarget) {
    self.target = target
    label = target.terminalID
  }
  @discardableResult public mutating func apply(_ event: JSON) throws -> Bool {
    let type = try event.requiredString("type")
    if type == "snapshot" || type == "restarted" {
      let snapshot = event["snapshot"]
      guard target.matches(snapshot) else { return false }
      output.reset(try snapshot.requiredString("history"))
      status = try snapshot.requiredString("status")
      label = snapshot["label"].string ?? target.terminalID
      pid = snapshot["pid"].int
      sequence = snapshot["sequence"].int
      receivedSnapshot = true
      error = nil
      return true
    }
    guard target.matches(event), receivedSnapshot else { return false }
    // Terminal events can be published out of sequence while history is persisted.
    // The attach stream owns snapshot deduplication; consume its live events in arrival order.
    if let next = event["sequence"].int { sequence = next }
    switch type {
    case "output":
      output.append(try event.requiredString("data"))
      error = nil
    case "cleared":
      output.reset()
      error = nil
    case "exited", "closed":
      status = type
      pid = nil
      hasRunningSubprocess = false
      error = nil
    case "error":
      status = "error"
      error = try event.requiredString("message")
    case "activity":
      label = event["label"].string ?? label
      hasRunningSubprocess = event["hasRunningSubprocess"].bool
    default: return false
    }
    return true
  }
}

/// Coalesces keystrokes while a write is in flight, without splitting a pasted code point.
public struct TerminalInputQueue: Sendable {
  private var chunks: [Data] = []
  public private(set) var byteCount = 0
  public init() {}
  public mutating func append(_ text: String) -> Bool {
    let bytes = Data(text.utf8)
    guard byteCount + bytes.count <= 1024 * 1024 else { return false }
    for part in TerminalOutput.split(bytes, size: 16 * 1024) {
      if let last = chunks.last, last.count + part.count <= 16 * 1024 {
        chunks[chunks.count - 1].append(part)
      } else {
        chunks.append(part)
      }
    }
    byteCount += bytes.count
    return true
  }
  public mutating func next() -> String? {
    guard !chunks.isEmpty else { return nil }
    var bytes = chunks.removeFirst()
    while let first = chunks.first, bytes.count + first.count <= 16 * 1024 {
      bytes.append(chunks.removeFirst())
    }
    byteCount -= bytes.count
    return String(decoding: bytes, as: UTF8.self)
  }
}

/// Owns one attach subscription; detaching never closes the server's shell.
@MainActor public final class RemoteTerminal {
  public private(set) var state: TerminalState
  public private(set) var attached = false
  public private(set) var error: String?
  public var onChange: (() -> Void)?
  public let connection: RPCConnection
  private let context: [String: JSON]
  private var generation = UUID()
  private var subscription: Task<Void, Never>?
  private var writer: Task<Void, Never>?
  private var resizer: Task<Void, Never>?
  private var pendingInput = TerminalInputQueue()
  private var requestedGrid = TerminalGrid(columns: 80, rows: 24)
  private var sentGrid: TerminalGrid?

  public init(target: TerminalTarget, connection: RPCConnection, context: [String: JSON]) {
    self.connection = connection
    self.context = context
    state = TerminalState(target: target)
  }
  deinit {
    subscription?.cancel()
    writer?.cancel()
    resizer?.cancel()
  }
  public func attach() {
    detach()
    error = nil
    let generation = generation
    subscription = Task { [weak self, connection, context, target = state.target] in
      var id: String?
      do {
        try Task.checkCancellation()
        var fields = context
        fields.merge(self?.requestedGrid.fields ?? [:]) { _, new in new }
        fields["restartIfNotRunning"] = .bool(false)
        let stream = try await connection.subscribe(
          "terminal.attach", payload: target.input(fields))
        id = stream.id
        for try await event in stream.values {
          guard !Task.isCancelled, let self, self.generation == generation else { break }
          if try self.state.apply(event) {
            self.attached = true
            self.error = nil
            if event["type"].string == "snapshot" || event["type"].string == "restarted" {
              self.sentGrid = nil
              self.scheduleResize()
            }
            self.onChange?()
          }
        }
        if !Task.isCancelled, let self, self.generation == generation {
          throw T3Error("Terminal connection ended. Reconnect to restore its history.")
        }
      } catch {
        if let self, self.generation == generation, !Task.isCancelled {
          self.error = error.localizedDescription
          self.attached = false
          self.onChange?()
        }
      }
      if let id { await connection.cancel(id) }
    }
  }
  public func detach() {
    generation = UUID()
    subscription?.cancel()
    subscription = nil
    writer?.cancel()
    writer = nil
    resizer?.cancel()
    resizer = nil
    pendingInput = TerminalInputQueue()
    sentGrid = nil
    attached = false
  }
  public func write(_ text: String) {
    guard attached, state.status == "running", !text.isEmpty else { return }
    guard pendingInput.append(text) else {
      error = "Terminal input is still sending. Wait before pasting more text."
      onChange?()
      return
    }
    guard writer == nil else { return }
    let generation = generation
    writer = Task { [weak self] in
      guard let self else { return }
      defer { if self.generation == generation { self.writer = nil } }
      do {
        while self.generation == generation, !Task.isCancelled, let text = pendingInput.next() {
          _ = try await connection.call(
            "terminal.write", payload: state.target.input(["data": .string(text)]))
        }
      } catch {
        guard self.generation == generation, !Task.isCancelled else { return }
        pendingInput = TerminalInputQueue()
        self.error =
          "Terminal input could not be confirmed. It will not be sent again automatically."
        onChange?()
      }
    }
  }
  public func resize(_ grid: TerminalGrid) {
    requestedGrid = grid
    scheduleResize()
  }
  private func scheduleResize() {
    guard attached, state.status == "running", resizer == nil, requestedGrid != sentGrid else {
      return
    }
    let generation = generation
    resizer = Task { [weak self] in
      guard let self else { return }
      defer { if self.generation == generation { self.resizer = nil } }
      do {
        while self.generation == generation, !Task.isCancelled, requestedGrid != sentGrid {
          let grid = requestedGrid
          _ = try await connection.call("terminal.resize", payload: state.target.input(grid.fields))
          guard self.generation == generation else { return }
          sentGrid = grid
        }
      } catch {
        guard self.generation == generation, !Task.isCancelled else { return }
        self.error = error.localizedDescription
        onChange?()
      }
    }
  }
  public func clear() async throws {
    _ = try await connection.call("terminal.clear", payload: state.target.input())
  }
  public func restart() async throws {
    var fields = context
    fields.merge(requestedGrid.fields) { _, new in new }
    _ = try await connection.call("terminal.restart", payload: state.target.input(fields))
  }
  public func close() async throws {
    _ = try await connection.call(
      "terminal.close", payload: state.target.input(["deleteHistory": .bool(true)]))
    detach()
  }
}
