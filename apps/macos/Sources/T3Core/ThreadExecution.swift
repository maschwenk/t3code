import Foundation

public enum MessageDelivery: String, Codable, CaseIterable, Sendable {
  case auto, queue, steer, restart
  public var title: String {
    switch self {
    case .auto: "Auto"
    case .queue: "Queue next"
    case .steer: "Steer now"
    case .restart: "Interrupt and restart"
    }
  }
}

public struct QueuedMessage: Equatable, Sendable, Identifiable {
  public let id: String
  public let messageID: String
  public let text: String
  public let attachments: [JSON]
  public let context: JSON
}

public struct QueuedEdit: Codable, Equatable, Sendable {
  public var active = true
  public let threadID: String
  public let runID: String
  public let messageID: String
  public var attachments: [JSON]
  public let context: JSON
  public var draftID: String { "queued-edit:" + runID }
  public init(_ message: QueuedMessage, threadID: String) {
    self.threadID = threadID
    runID = message.id
    messageID = message.messageID
    attachments = message.attachments
    context = message.context
  }
  public var retainedContext: JSON {
    guard case .object(var fields) = context else { return .null }
    let ids = Set(attachments.compactMap { $0["id"].string })
    fields["records"] = .array(
      context["records"].array.filter {
        $0["attachmentId"].string.map { ids.contains($0) } ?? true
      })
    return .object(fields)
  }
}

/// Only execution events rebuild the queue; streaming text does not scan run history.
public struct ThreadExecution: Sendable {
  public private(set) var queued: [QueuedMessage] = []
  public private(set) var activeRunID: String?
  public private(set) var isHeld = false
  public private(set) var canQueue = false
  public private(set) var canSteer = false
  public private(set) var canRestart = false
  public private(set) var steeringInterruptsTools = false
  public private(set) var resumableRunID: String?
  public private(set) var latestRunID: String?
  public private(set) var latestRunSettled = false
  public private(set) var hiddenUserMessageIDs: Set<String> = []
  private var thread: JSON = .null
  private var runs: [String: JSON] = [:]
  private var messages: [String: JSON] = [:]
  private var sessions: [String: JSON] = [:]
  private var providerThreads: [String: JSON] = [:]
  private var turns: [String: JSON] = [:]
  private var failures: [String: JSON] = [:]
  private struct UsageReport: Sendable {
    let ordinal: Int
    let usage: ContextUsage
  }
  private var liveReports: [String: UsageReport] = [:]
  private var providerReports: [String: ContextUsage] = [:]
  private var compactedReports: [String: ContextUsage] = [:]
  private var compactableItems: Set<String> = []
  public private(set) var hasDismissedResumeCompaction = false
  public var selectedProviderThread: JSON {
    thread["activeProviderThreadId"].string.flatMap { providerThreads[$0] } ?? .null
  }
  public var liveProviderTurnUsage: ContextUsage? {
    thread["activeProviderThreadId"].string.flatMap { liveReports[$0]?.usage }
  }
  public var contextUsage: ContextUsage? {
    guard let id = thread["activeProviderThreadId"].string else { return nil }
    return liveReports[id]?.usage ?? providerReports[id] ?? compactedReports[id]
  }
  public var hasCompactableConversation: Bool { !compactableItems.isEmpty }

  public init(_ projection: JSON = .null) {
    func indexed(_ values: JSON) -> [String: JSON] {
      Dictionary(
        values.array.compactMap { value in value["id"].string.map { ($0, value) } },
        uniquingKeysWith: { _, new in new })
    }
    thread = projection["thread"]
    runs = indexed(projection["runs"])
    messages = indexed(
      .array(
        projection["messages"].array.filter { $0["role"].string == "user" || $0["role"] == .null }))
    sessions = indexed(projection["providerSessions"])
    providerThreads = indexed(projection["providerThreads"])
    turns = indexed(projection["providerTurns"])
    failures = indexed(
      .array(projection["turnItems"].array.filter { $0["type"].string == "error" }))
    for provider in providerThreads.values { recordProviderUsage(provider) }
    for turn in turns.values { recordLiveUsage(turn) }
    let visible = projection["visibleTurnItems"].array
    let items = visible.isEmpty ? projection["turnItems"].array : visible.map { $0["item"] }
    for item in items { recordContextItem(item) }
    hasDismissedResumeCompaction = projection["runtimeRequests"].array.contains(
      where: ContextUsage.hasPermanentDismissal)
    rebuild()
  }

  public mutating func apply(_ event: JSON) {
    let payload = event["payload"]
    let type = event["type"].string ?? ""
    let id = payload["id"].string
    switch type {
    case "run.created", "run.updated": if let id { runs[id] = payload }
    case "message.updated":
      guard payload["role"].string == "user" || payload["role"] == .null else { return }
      if let id { messages[id] = payload }
    case "provider-session.attached", "provider-session.updated":
      if let id { sessions[id] = payload }
    case "provider-session.detached":
      if let id = payload["providerSessionId"].string { sessions.removeValue(forKey: id) }
    case "provider-thread.updated":
      if let id {
        providerThreads[id] = payload
        recordProviderUsage(payload)
      }
    case "provider-turn.updated":
      guard let id else { return }
      let previous = turns[id]
      recordLiveUsage(payload)
      turns[id] = payload
      guard
        previous?["runAttemptId"] != payload["runAttemptId"]
          || previous?["status"] != payload["status"]
      else { return }
    case "runtime-request.updated":
      hasDismissedResumeCompaction =
        hasDismissedResumeCompaction || ContextUsage.hasPermanentDismissal(payload)
      return
    case "turn-item.updated":
      recordContextItem(payload)
      guard payload["type"].string == "error", let id else { return }
      failures[id] = payload
    default:
      guard type.hasPrefix("thread."), payload["id"] == thread["id"] else { return }
      thread = payload
    }
    rebuild()
  }

  public func hidesQueuedMessage(_ item: JSON) -> Bool {
    item["type"].string == "user_message" && item["inputIntent"].string == "queued_turn"
      && hiddenUserMessageIDs.contains(item["messageId"].string ?? "")
  }

  private mutating func recordProviderUsage(_ provider: JSON) {
    guard let id = provider["id"].string,
      let usage = ContextUsage(
        report: provider["contextUsage"], updatedAt: provider["updatedAt"].string)
    else { return }
    if let previous = providerReports[id],
      (ThreadDates.parse(usage.updatedAt) ?? .distantPast)
        < (ThreadDates.parse(previous.updatedAt) ?? .distantPast)
    {
      return
    }
    providerReports[id] = usage
  }

  private mutating func recordLiveUsage(_ turn: JSON) {
    guard let providerID = turn["providerThreadId"].string, turn["id"].string != nil,
      let usage = ContextUsage(report: turn["tokenUsage"], live: true)
    else { return }
    let ordinal = turn["ordinal"].int ?? 0
    if let previous = liveReports[providerID] {
      guard ordinal >= previous.ordinal else { return }
      if ordinal == previous.ordinal,
        (ThreadDates.parse(usage.updatedAt) ?? .distantPast)
          < (ThreadDates.parse(previous.usage.updatedAt) ?? .distantPast)
      {
        return
      }
    }
    liveReports[providerID] = UsageReport(ordinal: ordinal, usage: usage)
  }

  private mutating func recordContextItem(_ item: JSON) {
    if item["type"].string == "user_message", let id = item["id"].string {
      let text =
        item["text"].string?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
      if text != "/compact" || !item["attachments"].array.isEmpty {
        compactableItems.insert(id)
      } else {
        compactableItems.remove(id)
      }
    }
    guard let usage = ContextUsage.compaction(item),
      let id = item["providerThreadId"].string ?? thread["activeProviderThreadId"].string
    else { return }
    if let previous = compactedReports[id],
      (ThreadDates.parse(usage.updatedAt) ?? .distantPast)
        < (ThreadDates.parse(previous.updatedAt) ?? .distantPast)
    {
      return
    }
    compactedReports[id] = usage
  }

  private mutating func rebuild() {
    let ordered = runs.values.sorted { ($0["ordinal"].int ?? 0) < ($1["ordinal"].int ?? 0) }
    let active = ordered.last {
      ["preparing", "starting", "running", "waiting"].contains($0["status"].string ?? "")
    }
    activeRunID = active?["id"].string
    let providerThreadID =
      active?["providerThreadId"].string ?? thread["activeProviderThreadId"].string
    let attached =
      providerThreadID.flatMap { providerThreads[$0] }
      ?? providerThreads.values.sorted {
        ($0["createdAt"].string ?? "") < ($1["createdAt"].string ?? "")
      }
      .first { $0["appThreadId"] == thread["id"] && $0["providerSessionId"].string != nil }
    let session: JSON?
    if let sessionID = attached?["providerSessionId"].string {
      session = sessions[sessionID]
    } else {
      session = sessions.values.filter {
        !["stopped", "error"].contains($0["status"].string ?? "")
      }
      .max { ($0["createdAt"].string ?? "") < ($1["createdAt"].string ?? "") }
    }
    let capabilities = session?["capabilities"]["turns"] ?? .null
    let hasTurn =
      active?["status"].string == "running"
      && active?["activeAttemptId"].string != nil
      && turns.values.contains {
        $0["runAttemptId"] == active?["activeAttemptId"] && $0["status"].string == "running"
      }
    canQueue = capabilities["supportsQueuedMessages"].bool
    canRestart = hasTurn && capabilities["supportsSteeringByInterruptRestart"].bool
    canSteer = hasTurn && (capabilities["supportsActiveSteering"].bool || canRestart)
    steeringInterruptsTools =
      !capabilities["supportsActiveSteering"].bool
      || capabilities["activeSteeringInterruptsTools"].bool
    isHeld = ordered.contains { $0["status"].string == "queued" && $0["queueHeld"].bool }
    hiddenUserMessageIDs = Set(
      ordered.filter {
        $0["status"].string == "queued"
          || ($0["status"].string == "cancelled" && $0["startedAt"] == .null)
      }.compactMap { $0["userMessageId"].string })
    queued = ordered.filter { run in
      let message = messages[run["userMessageId"].string ?? ""] ?? .null
      return run["status"].string == "queued" && message["delegatedCompletion"] == .null
        && message["notification"] == .null
    }.sorted {
      let left = ($0["queuePosition"].int ?? $0["ordinal"].int ?? 0, $0["ordinal"].int ?? 0)
      let right = ($1["queuePosition"].int ?? $1["ordinal"].int ?? 0, $1["ordinal"].int ?? 0)
      return left < right
    }.compactMap { run in
      guard let id = run["id"].string, let messageID = run["userMessageId"].string else {
        return nil
      }
      let message = messages[messageID] ?? .null
      return QueuedMessage(
        id: id, messageID: messageID, text: message["text"].string ?? "Queued message",
        attachments: message["attachments"].array, context: message["context"])
    }
    let latest = ordered.filter {
      $0["status"].string != "queued"
        && !($0["status"].string == "cancelled" && $0["startedAt"] == .null)
    }.max {
      let left = ThreadDates.parse($0["completedAt"].string)?.timeIntervalSince1970 ?? .infinity
      let right = ThreadDates.parse($1["completedAt"].string)?.timeIntervalSince1970 ?? .infinity
      return (left, $0["ordinal"].int ?? 0) < (right, $1["ordinal"].int ?? 0)
    }
    let failure = failures.values.filter {
      $0["runId"] == latest?["id"] && $0["nodeId"] == latest?["rootNodeId"]
        && $0["status"].string == "failed"
    }.max {
      (
        ThreadDates.parse($0["updatedAt"].string) ?? .distantPast, $0["ordinal"].int ?? 0,
        $0["id"].string ?? ""
      )
        < (
          ThreadDates.parse($1["updatedAt"].string) ?? .distantPast, $1["ordinal"].int ?? 0,
          $1["id"].string ?? ""
        )
    }?["failure"]
    let limited =
      latest?["status"].string == "failed" && failure?["class"].string == "usage_limit"
      && (session?["lastError"].string == nil || session?["lastError"] == failure?["message"])
    latestRunID = latest?["id"].string
    latestRunSettled =
      latest != nil && activeRunID == nil
      && thread["activeRunId"].string != latestRunID
    resumableRunID =
      activeRunID == nil && (latest?["status"].string == "interrupted" || limited)
      ? latest?["id"].string : nil
  }
}
