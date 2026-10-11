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
  public let lifecycle: ThreadLifecycle
  public let branch: String?
  public let deleted: Bool

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
    lifecycle = ThreadLifecycle(value)
    branch = value["branch"].string
    deleted = value["deletedAt"].string != nil
  }
}

public struct ShellState: Sendable {
  public private(set) var threads: [String: ThreadSummary] = [:]
  public private(set) var projects: [String: String] = [:]
  public private(set) var projectDetails: [String: JSON] = [:]
  public private(set) var sequence = -1
  public private(set) var synchronized = false
  public let archived: Bool
  public init(archived: Bool = false) { self.archived = archived }

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
        if !thread.deleted && thread.archived == archived { next[thread.id] = thread }
      }
      threads = next
      projects = Dictionary(
        snapshot["projects"].array.compactMap { project in
          guard let id = project["id"].string else { return nil }
          return (id, project["title"].string ?? project["name"].string ?? "Project")
        }, uniquingKeysWith: { _, new in new })
      projectDetails = Dictionary(
        snapshot["projects"].array.compactMap { project in
          project["id"].string.map { ($0, project) }
        }, uniquingKeysWith: { _, new in new })
      sequence = nextSequence
      synchronized = archived
    case "synchronized": synchronized = true
    default:
      let nextSequence = try value.requiredInt("sequence")
      guard nextSequence > sequence else { return }
      switch value["kind"].string {
      case "thread.updated":
        let thread = try ThreadSummary(value["thread"])
        let isArchived = value["location"].string.map { $0 == "archive" } ?? thread.archived
        if thread.deleted || isArchived != archived {
          threads.removeValue(forKey: thread.id)
        } else {
          threads[thread.id] = thread
        }
      case "thread.removed": threads.removeValue(forKey: try value.requiredString("threadId"))
      case "project.updated":
        let project = value["project"]
        let id = try project.requiredString("id")
        projectDetails[id] = project
        projects[id] =
          project["title"].string ?? project["name"].string ?? "Project"
      case "project.removed":
        let id = try value.requiredString("projectId")
        projects.removeValue(forKey: id)
        projectDetails.removeValue(forKey: id)
      default: break
      }
      sequence = nextSequence
    }
  }
}

public struct TimelineRow: Sendable, Equatable, Identifiable {
  public let item: JSON
  public let id: String
  public let sourceID: String
  public let kind: String
  public let text: String
  public let title: String
  public let streaming: Bool
  public let position: Int
  public let inherited: Bool

  public init(item: JSON, position: Int, sourceID: String, inherited: Bool = false) throws {
    self.item = item
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
      text = [item["fileName"].string, item["diffStr"].string].compactMap { $0 }.joined(
        separator: "\n")
    case "dynamic_tool":
      title = item["toolName"].string ?? item["title"].string ?? "Tool"
      text = [item["input"].displayText, item["output"].displayText].filter { !$0.isEmpty }.joined(
        separator: "\n\n")
    case "file_search":
      title = "File search"
      text =
        ([item["pattern"].string].compactMap { $0 }
        + item["results"].array.map { result in
          (result["fileName"].string ?? "") + (result["line"].int.map { ":\($0)" } ?? "")
            + (result["preview"].string.map { "\n" + $0 } ?? "")
        }).joined(separator: "\n")
    case "web_search":
      title = "Web search"
      text =
        (item["patterns"].array.compactMap(\.string)
        + item["results"].array.map { result in
          [result["title"].string, result["url"].string, result["snippet"].string].compactMap { $0 }
            .joined(separator: "\n")
        }).joined(separator: "\n\n")
    case "approval_request":
      title = "Approval request"
      text = item["prompt"].string ?? item["appName"].string ?? "Agent requested approval"
    case "user_input_request":
      title = "Question"
      text = item["questions"].array.compactMap { $0["question"].string }.joined(separator: "\n")
    case "todo_list":
      title = "Plan"
      text = item["steps"].array.map {
        ($0["status"].string == "completed" ? "✓ " : "○ ")
          + ($0["step"].string ?? $0["title"].string ?? "")
      }.joined(separator: "\n")
    case "system_notice", "run_interrupt_request", "run_interrupt_result":
      title = "Notice"
      text = item["message"].string ?? ""
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
  public private(set) var pendingRequests: [PendingRequest] = []
  private var requests: [String: JSON] = [:]
  private var requestItems: [String: JSON] = [:]
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
      var nextRequests: [String: JSON] = [:]
      for request in projection["runtimeRequests"].array {
        nextRequests[try request.requiredString("id")] = request
      }
      var nextRequestItems: [String: JSON] = [:]
      for item in projection["turnItems"].array {
        if let id = item["requestId"].string { nextRequestItems[id] = item }
      }
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
      requests = nextRequests
      requestItems = nextRequestItems
      for row in rows where !row.inherited {
        if let id = row.item["requestId"].string { requestItems[id] = row.item }
      }
      try rebuildRequests()
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
        if let id = item["requestId"].string {
          requestItems[id] = item
          try rebuildRequests()
        }
      } else if type == "runtime-request.updated" {
        let request = event["payload"]
        let requestID = try request.requiredString("id")
        _ = try request.requiredString("kind")
        requests[requestID] = request
        try rebuildRequests()
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

  @discardableResult public mutating func hydrateOutput(
    _ item: JSON, replacing original: TimelineRow
  ) throws -> Bool {
    guard let index = indices[original.id], rows[index] == original,
      original.item["outputOmitted"].bool,
      item["id"] == original.item["id"], item["threadId"].string == original.sourceID,
      item["updatedAt"] == original.item["updatedAt"],
      !item["outputOmitted"].bool,
      case .object(var full) = original.item
    else { return false }
    full["output"] = item["output"]
    full.removeValue(forKey: "outputOmitted")
    rows[index] = try TimelineRow(
      item: .object(full), position: original.position, sourceID: original.sourceID,
      inherited: original.inherited)
    return true
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

  private mutating func rebuildRequests() throws {
    pendingRequests = try requests.values.compactMap { request in
      guard request["status"].string == "pending",
        !["auth_refresh", "dynamic_tool_call"].contains(request["kind"].string ?? "")
      else { return nil }
      let item = requestItems[try request.requiredString("id")] ?? .null
      if request["kind"].string == "user_input", item == .null { return nil }
      return try PendingRequest(request: request, item: item)
    }.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
  }
}

public enum Commands {
  public static func message(
    threadID: String, text: String, commandID: String, messageID: String, attachments: [JSON] = []
  )
    -> JSON
  {
    .object([
      "type": .string("message.dispatch"), "commandId": .string(commandID),
      "threadId": .string(threadID), "messageId": .string(messageID), "text": .string(text),
      "createdBy": .string("user"), "creationSource": .string("web"),
      "attachments": .array(attachments),
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
