import Foundation

public struct TurnCheckpoint: Equatable, Sendable, Identifiable {
  public let id: String
  public let threadID: String
  public let runID: String
  public let turnCount: Int
  public let ref: String
  public let status: String
  public let capturedAt: String
  public let files: [ReviewFile]
  public var assistantMessageID: String?
  public var runCompleted: Bool
  public var unavailableReason: String? {
    if status != "ready" {
      return "Turn \(turnCount)’s checkpoint is \(status). Its saved diff is unavailable."
    }
    if !runCompleted {
      return "Turn \(turnCount) has not completed. Its saved diff is not ready yet."
    }
    return nil
  }

  init?(_ value: JSON, threadID: String) {
    guard value["threadId"].string == threadID, let id = value["id"].string,
      let runID = value["runId"].string, let ordinal = value["appRunOrdinal"].int, ordinal > 0,
      let ref = value["ref"].string, let status = value["status"].string
    else { return nil }
    self.id = id
    self.threadID = threadID
    self.runID = runID
    turnCount = ordinal
    self.ref = ref
    self.status = status
    capturedAt = value["capturedAt"].string ?? ""
    files = value["files"].array.compactMap { item in
      guard let path = item["path"].string else { return nil }
      return ReviewFile(
        path: path, previousPath: nil,
        additions: item["additions"].int ?? 0, deletions: item["deletions"].int ?? 0)
    }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    runCompleted = false
  }
}

/// Retains checkpoint metadata, not assistant text. Token updates leave this index unchanged.
public struct ThreadCheckpoints: Sendable {
  public private(set) var items: [TurnCheckpoint] = []
  public private(set) var revision = UUID()
  private var threadID = ""
  private var byID: [String: TurnCheckpoint] = [:]
  private var completed: Set<String> = []
  private var assistants: [String: (id: String, createdAt: String)] = [:]
  private var seenAssistantIDs: Set<String> = []

  public init(_ projection: JSON = .null) {
    threadID = projection["thread"]["id"].string ?? ""
    for run in projection["runs"].array where run["status"].string == "completed" {
      if let id = run["id"].string { completed.insert(id) }
    }
    for message in projection["messages"].array { _ = receiveMessage(message) }
    for value in projection["checkpoints"].array {
      if let checkpoint = TurnCheckpoint(value, threadID: threadID) {
        byID[checkpoint.id] = checkpoint
      }
    }
    rebuild()
  }

  public mutating func apply(_ event: JSON) {
    let value = event["payload"]
    guard value["threadId"].string == threadID else { return }
    switch event["type"].string {
    case "checkpoint.captured":
      guard let checkpoint = TurnCheckpoint(value, threadID: threadID) else { return }
      byID[checkpoint.id] = checkpoint
    case "message.updated":
      guard receiveMessage(value),
        byID.values.contains(where: { $0.runID == value["runId"].string })
      else { return }
    case "run.created", "run.updated":
      guard let id = value["id"].string else { return }
      let changed =
        value["status"].string == "completed"
        ? completed.insert(id).inserted : completed.remove(id) != nil
      guard changed else { return }
    default: return
    }
    rebuild()
  }

  private mutating func receiveMessage(_ value: JSON) -> Bool {
    guard value["threadId"].string == threadID, value["role"].string == "assistant",
      let run = value["runId"].string, let id = value["id"].string
    else { return false }
    guard seenAssistantIDs.insert(id).inserted else { return false }
    let time = value["createdAt"].string ?? ""
    if let previous = assistants[run], previous.id == id || previous.createdAt > time {
      return false
    }
    assistants[run] = (id, time)
    return true
  }

  private mutating func rebuild() {
    let next = byID.values.map { item in
      var item = item
      item.assistantMessageID = assistants[item.runID]?.id
      item.runCompleted = completed.contains(item.runID)
      return item
    }.sorted {
      if $0.turnCount != $1.turnCount { return $0.turnCount > $1.turnCount }
      if $0.capturedAt != $1.capturedAt { return $0.capturedAt > $1.capturedAt }
      return $0.id < $1.id
    }
    if next != items {
      items = next
      revision = UUID()
    }
  }
}

public struct CheckpointDiffRequest: Sendable, Equatable {
  public let threadID: String
  public let from: Int
  public let to: Int
  public let fullThread: Bool
  public let ignoreWhitespace: Bool
  public let checkpointID: String
  public let checkpointRef: String
  public let title: String
  public var method: String {
    fullThread ? "orchestration.getFullThreadDiff" : "orchestration.getTurnDiff"
  }
  public var input: JSON {
    var fields: [String: JSON] = [
      "threadId": .string(threadID), "toTurnCount": .number(Double(to)),
      "ignoreWhitespace": .bool(ignoreWhitespace),
    ]
    if !fullThread { fields["fromTurnCount"] = .number(Double(from)) }
    return .object(fields)
  }
  public init(_ checkpoint: TurnCheckpoint, fullThread: Bool, ignoreWhitespace: Bool) throws {
    if let error = checkpoint.unavailableReason { throw T3Error(error) }
    threadID = checkpoint.threadID
    from = fullThread ? 0 : max(0, checkpoint.turnCount - 1)
    to = checkpoint.turnCount
    self.fullThread = fullThread
    self.ignoreWhitespace = ignoreWhitespace
    checkpointID = checkpoint.id
    checkpointRef = checkpoint.ref
    title = fullThread ? "Full thread · through turn \(to)" : "Turn \(to)"
  }
  public func validate(_ result: JSON) throws -> String {
    guard result["threadId"].string == threadID, result["fromTurnCount"].int == from,
      result["toTurnCount"].int == to
    else { throw T3Error("The server returned a different checkpoint comparison.") }
    return try result.requiredString("diff")
  }
}
