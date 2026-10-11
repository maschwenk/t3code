import Foundation

public struct ThreadSummary: Sendable, Equatable, Identifiable {
  public let id: String
  public let projectID: String
  public let title: String
  public let updatedAt: String
  public let status: String
  public let activeRunID: String?
  public let model: JSON
  public let runtimeMode: String
  public let interactionMode: String
  public let archived: Bool

  public init(_ value: JSON) throws {
    id = try value.requiredString("id")
    projectID = try value.requiredString("projectId")
    title = try value.requiredString("title")
    updatedAt = value["updatedAt"].string ?? ""
    status = value["activityRunStatus"].string ?? value["status"].string ?? "idle"
    activeRunID = value["activeRunId"].string
    model = value["modelSelection"]
    runtimeMode = value["runtimeMode"].string ?? "approval-required"
    interactionMode = value["interactionMode"].string ?? "default"
    archived = value["archivedAt"].string != nil
  }
}

public struct ShellState: Sendable {
  public private(set) var threads: [String: ThreadSummary] = [:]
  public private(set) var projects: [String: String] = [:]
  public private(set) var sequence = -1
  public private(set) var synchronized = false
  public init() {}

  public mutating func apply(_ value: JSON) throws {
    switch value["kind"].string {
    case "snapshot":
      // Repository identity enrichment contains no authoritative thread list.
      if case .array = value["resolvedRepositoryIdentityRoots"] { return }
      let snapshot = value["snapshot"]
      let nextSequence = try snapshot.requiredInt("snapshotSequence")
      var next: [String: ThreadSummary] = [:]
      for item in snapshot["threads"].array {
        let thread = try ThreadSummary(item)
        next[thread.id] = thread
      }
      threads = next
      projects = Dictionary(
        snapshot["projects"].array.compactMap { project in
          guard let id = project["id"].string else { return nil }
          return (id, project["title"].string ?? project["name"].string ?? "Project")
        }, uniquingKeysWith: { _, new in new })
      sequence = nextSequence
      synchronized = false
    case "synchronized": synchronized = true
    default:
      let nextSequence = try value.requiredInt("sequence")
      guard nextSequence > sequence else { return }
      switch value["kind"].string {
      case "thread.updated":
        let thread = try ThreadSummary(value["thread"])
        if value["location"].string == "archive" || thread.archived {
          threads.removeValue(forKey: thread.id)
        } else {
          threads[thread.id] = thread
        }
      case "thread.removed": threads.removeValue(forKey: try value.requiredString("threadId"))
      case "project.updated":
        let project = value["project"]
        projects[try project.requiredString("id")] =
          project["title"].string ?? project["name"].string ?? "Project"
      case "project.removed": projects.removeValue(forKey: try value.requiredString("projectId"))
      default: break
      }
      sequence = nextSequence
    }
  }
}

public struct TimelineRow: Sendable, Equatable, Identifiable {
  public let id: String
  public let sourceID: String
  public let kind: String
  public let text: String
  public let title: String
  public let streaming: Bool
  public let position: Int
  public let inherited: Bool

  public init(item: JSON, position: Int, sourceID: String, inherited: Bool = false) throws {
    self.sourceID = sourceID
    id = sourceID + ":" + (try item.requiredString("id"))
    kind = try item.requiredString("type")
    self.position = position
    self.inherited = inherited
    streaming = item["streaming"].bool || item["status"].string == "running"
    switch kind {
    case "user_message":
      title = "You"
      text = try item.requiredString("text")
    case "assistant_message":
      title = "Assistant"
      text = try item.requiredString("text")
    case "reasoning":
      title = "Thinking"
      text = try item.requiredString("text")
    case "proposed_plan":
      title = "Plan"
      text = item["markdown"].string ?? ""
    case "command_execution":
      title = "Terminal"
      text = [item["input"].string, item["output"].string].compactMap { $0 }.joined(separator: "\n")
    case "file_change":
      title = "File change"
      text = item["fileName"].string ?? ""
    case "approval_request", "user_input_request", "secret_request":
      title = "Needs your attention"
      text =
        (item["prompt"].string ?? item["reason"].string ?? item["title"].string
          ?? "An agent needs your response.") + "\nRespond in the existing T3 app."
    default:
      title = kind.replacingOccurrences(of: "_", with: " ").capitalized
      text = item["title"].string ?? item["toolName"].string ?? item["progress"].string ?? title
    }
  }
}

public struct ThreadState: Sendable {
  public let id: String
  public private(set) var sequence = -1
  public private(set) var rows: [TimelineRow] = []
  public private(set) var cursor: String?
  public private(set) var hasMore = false
  public private(set) var synchronized = false
  private var indices: [String: Int] = [:]

  public init(id: String) { self.id = id }

  public mutating func markUnsynchronized() { synchronized = false }

  /// Returns true when lineage or rollback invalidates the visible timeline.
  public mutating func apply(_ value: JSON) throws -> Bool {
    switch value["kind"].string {
    case "snapshot":
      let projection = value["projection"]
      guard projection["thread"]["id"].string == id else {
        throw T3Error("Snapshot belongs to another thread.")
      }
      let nextSequence = try value.requiredInt("snapshotSequence")
      var next: [TimelineRow] = []
      for visible in projection["visibleTurnItems"].array {
        next.append(try Self.projectedRow(visible))
      }
      if next.isEmpty {
        for item in projection["turnItems"].array {
          next.append(
            try TimelineRow(item: item, position: item.requiredInt("ordinal"), sourceID: id))
        }
      }
      rows = next.sorted { $0.position < $1.position }
      reindex()
      sequence = nextSequence
      cursor = value["historyCursor"].string
      hasMore = value["hasMoreHistory"].bool
      synchronized = false
    case "synchronized": synchronized = true
    case "event":
      let nextSequence = try value.requiredInt("sequence")
      guard nextSequence > sequence else { return false }
      let event = value["event"]
      let type = try event.requiredString("type")
      if type.hasPrefix("context-transfer.") || type == "checkpoint.rollback-requested"
        || type == "thread.provider-switched"
      {
        return true
      }
      if type == "turn-item.updated" {
        let item = event["payload"]
        guard item["threadId"].string == id else {
          throw T3Error("Update belongs to another thread.")
        }
        let key = id + ":" + (try item.requiredString("id"))
        if let index = indices[key] {
          rows[index] = try TimelineRow(item: item, position: rows[index].position, sourceID: id)
        } else {
          let position = (rows.last?.position ?? -1) + 1
          let row = try TimelineRow(item: item, position: position, sourceID: id)
          indices[row.id] = rows.count
          rows.append(row)
        }
      }
      sequence = nextSequence
    default: break
    }
    return false
  }

  public mutating func prependHistory(_ page: JSON) throws {
    var older: [TimelineRow] = []
    for visible in page["items"].array {
      let row = try Self.projectedRow(visible)
      // A history response may have been generated before the latest live update.
      if indices[row.id] == nil { older.append(row) }
    }
    rows = (older + rows).sorted { $0.position < $1.position }
    reindex()
    cursor = page["nextCursor"].string
    hasMore = page["hasMoreHistory"].bool
  }

  private static func projectedRow(_ visible: JSON) throws -> TimelineRow {
    try TimelineRow(
      item: visible["item"], position: visible.requiredInt("position"),
      sourceID: visible.requiredString("sourceThreadId"),
      inherited: visible["visibility"].string == "inherited")
  }

  private mutating func reindex() {
    indices = Dictionary(
      rows.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { _, new in new })
  }
}

public enum Commands {
  public static func message(threadID: String, text: String, commandID: String, messageID: String)
    -> JSON
  {
    .object([
      "type": .string("message.dispatch"), "commandId": .string(commandID),
      "threadId": .string(threadID), "messageId": .string(messageID), "text": .string(text),
      "createdBy": .string("user"), "creationSource": .string("web"), "attachments": .array([]),
      "dispatchMode": .object(["type": .string("start_immediately")]),
      "deliveryIntent": .string("auto"),
    ])
  }

  public static func newThread(template: ThreadSummary, id: String, title: String = "New thread")
    -> JSON
  {
    .object([
      "type": .string("thread.create"), "commandId": .string(UUID().uuidString),
      "threadId": .string(id), "projectId": .string(template.projectID), "title": .string(title),
      "modelSelection": template.model, "runtimeMode": .string(template.runtimeMode),
      "interactionMode": .string(template.interactionMode), "branch": .null, "worktreePath": .null,
      "createdBy": .string("user"), "creationSource": .string("web"),
    ])
  }
}
