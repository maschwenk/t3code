import Foundation

public enum ThreadDates {
  public static func parse(_ value: String?) -> Date? {
    guard let value else { return nil }
    return
      (try? Date(
        value,
        strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(
          separator: .colon)))
      ?? (try? Date(value, strategy: .iso8601))
  }
  public static func string(_ value: Date) -> String {
    value.ISO8601Format(
      .iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(
        separator: .colon))
  }
}

public struct ThreadLifecycle: Sendable, Equatable {
  public let createdAt: Date?
  public let updatedAt: Date?
  public let settled: Bool
  public let settledAt: Date?
  public let unsettledAt: Date?
  public let snoozedUntil: Date?
  public let snoozedAt: Date?
  public let pinned: Bool
  public let pinOrderKey: String?
  public let activeOrderKey: String?
  public let lastVisitedAt: Date?
  public let latestUserMessageAt: Date?
  public let latestRunRequestedAt: Date?
  public let latestRunStartedAt: Date?
  public let latestRunCompletedAt: Date?
  public let pendingRequestKind: String?
  public let status: String
  public let runStatus: String
  public let hasLatestRun: Bool
  public let backgroundWaiting: Bool
  public let planReady: Bool
  public let autoSettleDisabled: Bool

  public init(_ value: JSON) {
    createdAt = ThreadDates.parse(value["createdAt"].string)
    updatedAt = ThreadDates.parse(value["updatedAt"].string)
    settled = value["settledOverride"].string == "settled"
    settledAt = ThreadDates.parse(value["settledAt"].string)
    unsettledAt = ThreadDates.parse(value["unsettledAt"].string)
    snoozedUntil = ThreadDates.parse(value["snoozedUntil"].string)
    snoozedAt = ThreadDates.parse(value["snoozedAt"].string)
    pinned = value["pinnedAt"].string != nil
    pinOrderKey = value["pinOrderKey"].string
    activeOrderKey = value["activeOrderKey"].string
    lastVisitedAt = ThreadDates.parse(value["lastVisitedAt"].string)
    latestUserMessageAt = ThreadDates.parse(value["latestUserMessageAt"].string)
    latestRunRequestedAt = ThreadDates.parse(value["latestRunRequestedAt"].string)
    latestRunStartedAt = ThreadDates.parse(value["latestRunStartedAt"].string)
    hasLatestRun = value["latestRunId"].string != nil
    runStatus = value["status"].string ?? "idle"
    if case .object(let object) = value, object["latestRunCompletedAt"] == nil,
      hasLatestRun,
      ["idle", "completed", "cancelled", "failed", "interrupted", "rolled_back"].contains(runStatus)
    {
      latestRunCompletedAt = updatedAt
    } else {
      latestRunCompletedAt = ThreadDates.parse(value["latestRunCompletedAt"].string)
    }
    pendingRequestKind = value["pendingRuntimeRequest"]["kind"].string
    backgroundWaiting = value["pendingBackgroundTasks"].array.contains {
      $0["kind"].string != "command"
    }
    status =
      backgroundWaiting && runStatus != "failed"
      ? "idle" : value["activityRunStatus"].string ?? runStatus
    planReady =
      value["interactionMode"].string == "plan" && value["hasActionableProposedPlan"].bool
      && ["idle", "completed", "interrupted", "cancelled", "failed"].contains(status)
    autoSettleDisabled = value["autoSettleDisabledAt"].string != nil
  }

  public var needsAttention: Bool {
    pendingRequestKind != nil && pendingRequestKind != "auth_refresh"
  }
  public var activeAnchor: Date { max(createdAt ?? .distantPast, unsettledAt ?? .distantPast) }
  public var settledAnchor: Date {
    settledAt ?? [
      latestUserMessageAt, latestRunRequestedAt, latestRunStartedAt, latestRunCompletedAt,
    ]
    .compactMap { $0 }.max() ?? updatedAt ?? .distantPast
  }
  public var unread: Bool {
    guard let lastVisitedAt, let latestRunCompletedAt else { return false }
    return latestRunCompletedAt > lastVisitedAt
  }

  public func hasQueuedStart(at now: Date) -> Bool {
    if ["preparing", "starting", "queued"].contains(status) { return true }
    guard status != "error", let message = latestUserMessageAt,
      abs(now.timeIntervalSince(message)) <= 120
    else { return false }
    return !hasLatestRun
      || [latestRunRequestedAt, latestRunStartedAt, latestRunCompletedAt]
        .allSatisfy { $0 == nil || $0! < message }
  }

  public func canSnooze(at now: Date) -> Bool { !needsAttention && !hasQueuedStart(at: now) }

  public var raisedHand: Bool {
    if needsAttention { return true }
    if ["failed", "error"].contains(status),
      snoozedAt == nil || (updatedAt != nil && updatedAt! > snoozedAt!)
    {
      return true
    }
    return completedAfterSnooze
  }

  private var completedAfterSnooze: Bool {
    guard ["idle", "completed"].contains(runStatus), let snoozedAt,
      let latestRunCompletedAt
    else { return false }
    return latestRunCompletedAt > snoozedAt
  }

  public func snoozed(at now: Date) -> Bool {
    guard let snoozedUntil, snoozedUntil > now else { return false }
    return !raisedHand
  }

  public func wokeAt(_ now: Date) -> Date? {
    guard let snoozedUntil else { return nil }
    if raisedHand { return completedAfterSnooze ? latestRunCompletedAt : updatedAt ?? snoozedAt }
    return snoozedUntil <= now ? snoozedUntil : nil
  }

  public func statusLabel(at now: Date) -> String? {
    if needsAttention {
      return pendingRequestKind == "user_input" ? "Awaiting Input" : "Pending Approval"
    }
    if ["running", "waiting"].contains(status) { return "Working" }
    if ["preparing", "starting", "queued"].contains(status) { return "Connecting" }
    if backgroundWaiting { return "Waiting" }
    if planReady { return "Plan Ready" }
    if unread { return "Completed" }
    if let wake = wokeAt(now), lastVisitedAt == nil || wake > lastVisitedAt! { return "Woke" }
    return nil
  }
}

public enum ThreadSection: String, CaseIterable, Sendable {
  case pinned = "Pinned"
  case active = "Active"
  case snoozed = "Snoozed"
  case settled = "Settled"
  case archived = "Archived"
}

public struct ThreadGroup: Sendable, Equatable {
  public let section: ThreadSection
  public let threads: [ThreadSummary]

  public static func resolve(_ threads: [ThreadSummary], at now: Date) -> [ThreadGroup] {
    var groups: [ThreadSection: [ThreadSummary]] = [:]
    for thread in threads where !thread.deleted {
      let state = thread.lifecycle
      let section: ThreadSection =
        thread.archived
        ? .archived
        : state.settled
          ? .settled
          : state.snoozed(at: now) ? .snoozed : state.pinned ? .pinned : .active
      groups[section, default: []].append(thread)
    }
    return ThreadSection.allCases.compactMap { section in
      guard let items = groups[section] else { return nil }
      return ThreadGroup(section: section, threads: sorted(items, in: section))
    }
  }

  public static func sorted(_ threads: [ThreadSummary], in section: ThreadSection)
    -> [ThreadSummary]
  {
    threads.sorted { a, b in
      let left = a.lifecycle
      let right = b.lifecycle
      if section == .active || section == .pinned {
        let lKey = section == .pinned ? left.pinOrderKey : left.activeOrderKey
        let rKey = section == .pinned ? right.pinOrderKey : right.activeOrderKey
        if let lKey, let rKey, lKey != rKey { return lKey < rKey }
        if (lKey == nil) != (rKey == nil) { return section == .pinned ? lKey != nil : lKey == nil }
        if lKey != nil { return a.id < b.id }
      }
      let lDate: Date
      let rDate: Date
      switch section {
      case .pinned:
        lDate = left.createdAt ?? .distantPast
        rDate = right.createdAt ?? .distantPast
      case .settled:
        lDate = left.settledAnchor
        rDate = right.settledAnchor
      case .archived:
        lDate = left.updatedAt ?? .distantPast
        rDate = right.updatedAt ?? .distantPast
      default:
        lDate = left.activeAnchor
        rDate = right.activeAnchor
      }
      return lDate == rDate ? a.id < b.id : lDate > rDate
    }
  }
}

public struct SnoozePreset: Sendable {
  public let title: String
  public let date: Date

  public static func choices(at now: Date, calendar: Calendar = .current) -> [SnoozePreset] {
    var result = [
      SnoozePreset(title: "In 1 hour", date: now.addingTimeInterval(3600)),
      SnoozePreset(title: "In 3 hours", date: now.addingTimeInterval(10800)),
    ]
    if let evening = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: now),
      evening.timeIntervalSince(now) > 3600
    {
      result.append(.init(title: "This evening", date: evening))
    }
    if let day = calendar.date(byAdding: .day, value: 1, to: now),
      let morning = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day)
    {
      result.append(.init(title: "Tomorrow", date: morning))
    }
    let distance = (2 - calendar.component(.weekday, from: now) + 7) % 7
    if let day = calendar.date(byAdding: .day, value: distance == 0 ? 7 : distance, to: now),
      let morning = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day),
      !result.contains(where: { $0.date == morning })
    {
      result.append(.init(title: "Next week", date: morning))
    }
    return result
  }
}
