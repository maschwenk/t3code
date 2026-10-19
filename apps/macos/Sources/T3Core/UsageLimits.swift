import Foundation

public struct UsageWindow: Sendable, Equatable, Identifiable {
  public let id: String
  public let kind: String
  public let label: String
  public let used: Double
  public let resetsAt: Date?
  public let durationMinutes: Double?
  public var key: String { kind + ":" + id }
  public var remaining: Int { Int((100 - used).rounded()) }
  public var order: Int { ["session", "weekly", "monthly", "other"].firstIndex(of: kind) ?? 3 }

  init?(_ value: JSON) {
    guard let id = value["id"].string, let label = value["label"].string,
      let kind = value["kind"].string, let used = value["usedPercent"].usageNumber,
      (0...100).contains(used)
    else { return nil }
    self.id = id
    self.kind = kind
    self.label = label
    self.used = used
    resetsAt = ThreadDates.parse(value["resetsAt"].string)
    durationMinutes = value["windowDurationMins"].usageNumber
  }

  public func elapsed(at now: Date) -> Double? {
    guard let resetsAt, let durationMinutes, durationMinutes > 0 else { return nil }
    return max(0, min(1, 1 - resetsAt.timeIntervalSince(now) / (durationMinutes * 60)))
  }

  public func resetDescription(at now: Date) -> String? {
    guard let resetsAt else { return nil }
    return resetsAt <= now ? "Resets now" : UsageFormat.duration(resetsAt.timeIntervalSince(now))
  }
}

public struct UsageAccount: Sendable, Equatable, Identifiable {
  public let id: String
  public let driver: String
  public var name: String
  public let email: String?
  public var plan: String?
  public var source: String?
  public var windows: [UsageWindow]
  public var checkedAt: Date?
  public var credits: Int?
  public var creditExpiresAt: Date?
  public var redeemInput: JSON?

  init(
    _ value: JSON, driver: String, fallback: String, name: String?, source: String?, redeem: JSON?
  ) {
    let limits = value["usageLimits"]
    email = value["email"].string ?? value["auth"]["email"].string
    let normalizedEmail = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if let normalizedEmail, !normalizedEmail.isEmpty {
      id = driver + ":" + normalizedEmail
    } else if let fingerprint = limits["credentialFingerprint"].string {
      id = driver + ":credential:" + fingerprint
    } else {
      id = fallback
    }
    self.driver = driver
    self.name =
      name ?? email.map {
        $0.split(separator: "@").compactMap { $0.first.map(String.init) }.joined().uppercased()
      } ?? UsageFormat.provider(driver)
    plan = value["plan"].string ?? value["auth"]["plan"].string
    self.source = source
    windows = limits["windows"].array.compactMap(UsageWindow.init)
    checkedAt = ThreadDates.parse(limits["checkedAt"].string)
    credits = limits["resetCredits"]["availableCount"].int
    creditExpiresAt = ThreadDates.parse(limits["resetCredits"]["nextExpiresAt"].string)
    redeemInput = redeem
  }
}

public struct UsagePool: Sendable, Equatable, Identifiable {
  public let driver: String
  public let accounts: [UsageAccount]
  public let windows: [UsagePoolWindow]
  public var id: String { driver }
}

public struct UsagePoolWindow: Sendable, Equatable, Identifiable {
  public struct Member: Sendable, Equatable, Identifiable {
    public let account: UsageAccount
    public let window: UsageWindow?
    public var id: String { account.id }
  }
  public let id: String
  public let label: String
  public let columns: [Member]
  public let remaining: Int
  public let pace: String?
  public let nextRecovery: Int?
  public let nextReset: Date?

  init(window: UsageWindow, accounts: [UsageAccount], now: Date) {
    id = window.key
    label = window.label
    columns = accounts.map {
      Member(account: $0, window: $0.windows.first { $0.key == window.key })
    }
    let reported = columns.compactMap(\.window)
    remaining = Int((100 - reported.reduce(0) { $0 + $1.used } / Double(reported.count)).rounded())
    let timed = reported.compactMap { w in w.elapsed(at: now).map { (used: w.used, elapsed: $0) } }
    if timed.isEmpty {
      pace = nil
    } else {
      let gap = timed.reduce(0) { $0 + $1.used - $1.elapsed * 100 } / Double(timed.count)
      pace =
        gap > 5
        ? "Spending faster than the window elapses"
        : gap < -5 ? "Headroom for the rest of the window" : "On pace"
    }
    let first = reported.filter { $0.resetsAt != nil }.min { $0.resetsAt! < $1.resetsAt! }
    nextRecovery = first.map { Int(($0.used / Double(reported.count)).rounded()) }
    nextReset = first?.resetsAt
  }
}

public struct UsageLimitsSnapshot: Sendable, Equatable {
  public struct ExternalLink: Sendable, Equatable, Identifiable {
    public let label: String
    public let url: URL
    public var id: URL { url }
  }
  public private(set) var accounts: [UsageAccount] = []
  public private(set) var notices: [String] = []
  public private(set) var links: [ExternalLink] = []
  public private(set) var environmentLabel = "Connected environment"
  private var providers: [JSON] = []
  private var sources: [JSON] = []
  public init() {}
  public static func == (left: Self, right: Self) -> Bool {
    left.accounts == right.accounts && left.notices == right.notices && left.links == right.links
      && left.environmentLabel == right.environmentLabel
  }

  public mutating func apply(_ event: JSON) {
    switch event["type"].string {
    case "snapshot":
      providers = event["config"]["providers"].array
      sources = event["config"]["usageLimitSources"].array
      environmentLabel = event["config"]["environment"]["label"].string ?? "Connected environment"
    case "providerStatuses": providers = event["payload"]["providers"].array
    case "usageLimitSourcesUpdated": sources = event["payload"]["sources"].array
    default: return
    }
    rebuild()
  }

  private mutating func rebuild() {
    var merged: [String: UsageAccount] = [:]
    notices = []
    links = []
    func merge(_ next: UsageAccount) {
      guard var previous = merged[next.id] else {
        merged[next.id] = next
        return
      }
      let fresher = (next.checkedAt ?? .distantPast) > (previous.checkedAt ?? .distantPast)
      if fresher {
        previous.windows = next.windows
        previous.checkedAt = next.checkedAt
      }
      if next.credits != nil && (previous.credits == nil || fresher) {
        previous.credits = next.credits
        previous.creditExpiresAt = next.creditExpiresAt
      }
      // Hub redemption also clears that hub's routing cooldown for this subscription.
      if next.redeemInput?["sourceId"].string != nil || previous.redeemInput == nil {
        previous.redeemInput = next.redeemInput
      }
      previous.plan = previous.plan ?? next.plan
      merged[next.id] = previous
    }
    for provider in providers
    where provider["enabled"].bool && provider["installed"].bool
      && provider["availability"].string != "unavailable" && provider["usageLimits"] != .null
    {
      guard let driver = provider["driver"].string, let instance = provider["instanceId"].string
      else { continue }
      let name = provider["displayName"].string ?? UsageFormat.provider(driver)
      let limits = provider["usageLimits"]
      if let urlString = limits["externalUsage"]["url"].string, let url = URL(string: urlString),
        ["https", "http"].contains(url.scheme ?? ""),
        provider["auth"]["status"].string == "authenticated",
        !links.contains(where: { $0.url == url })
      {
        links.append(ExternalLink(label: limits["externalUsage"]["label"].string ?? name, url: url))
      }
      if let notice = Self.notice(limits) {
        if limits["unavailable"]["reason"].string != "unsupported" {
          notices.append(name + ": " + notice)
        }
        continue
      }
      merge(
        UsageAccount(
          provider, driver: driver, fallback: instance, name: name, source: nil,
          redeem: .object(["instanceId": .string(instance)])))
    }
    for source in sources {
      let label = source["label"].string ?? "Usage source"
      if let error = source["error"].string {
        notices.append(label + ": " + error)
      } else if source["accounts"].array.isEmpty {
        notices.append(label + ": No accounts reported.")
      }
      for account in source["accounts"].array {
        guard let driver = account["driver"].string, let id = account["id"].string,
          let sourceID = source["id"].string
        else { continue }
        if let notice = Self.notice(account["usageLimits"]) {
          if account["usageLimits"]["unavailable"]["reason"].string != "unsupported" {
            notices.append(label + ": " + notice)
          }
          continue
        }
        let credit = account["usageLimits"]["resetCredits"]["nextCreditId"].string
        merge(
          UsageAccount(
            account, driver: driver, fallback: sourceID + ":" + id,
            name: account["email"].string == nil
              ? id.replacingOccurrences(of: ".json", with: "") : nil,
            source: label,
            redeem: credit.map {
              .object([
                "sourceId": .string(sourceID), "accountId": .string(id), "creditId": .string($0),
              ])
            }))
      }
    }
    accounts = merged.values.sorted { $0.id < $1.id }
  }

  private static func notice(_ limits: JSON) -> String? {
    if limits["unavailable"] != .null {
      return limits["unavailable"]["message"].string ?? "Could not read limits."
    }
    return limits["windows"].array.isEmpty ? "No limits reported." : nil
  }

  public func pools(at now: Date) -> [UsagePool] {
    Dictionary(grouping: accounts, by: \.driver).map { driver, members in
      let windows = members.flatMap(\.windows).sorted { $0.order < $1.order }
      let orderKey = windows.first?.key
      let sorted = members.sorted { left, right in
        let l = left.windows.first { $0.key == orderKey }?.resetsAt ?? .distantFuture
        let r = right.windows.first { $0.key == orderKey }?.resetsAt ?? .distantFuture
        if l != r { return l < r }
        if left.name != right.name {
          return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
        return left.id < right.id
      }
      var keys: Set<String> = []
      let hasCursorPools =
        windows.contains { $0.id == "autoPercentUsed" }
        && windows.contains { $0.id == "apiPercentUsed" }
      let rows = windows.filter {
        keys.insert($0.key).inserted
          && !(driver == "cursor" && hasCursorPools && $0.id == "totalPercentUsed")
      }.map { UsagePoolWindow(window: $0, accounts: sorted, now: now) }
      return UsagePool(driver: driver, accounts: sorted, windows: rows)
    }.sorted { UsageFormat.providerOrder($0.driver) < UsageFormat.providerOrder($1.driver) }
  }
}

extension JSON {
  var usageNumber: Double? {
    if case .number(let value) = self, value.isFinite { value } else { nil }
  }
}

public enum UsageFormat {
  public static func provider(_ driver: String) -> String {
    switch driver {
    case "codex": "Codex"
    case "claude", "claudeAgent": "Claude"
    case "cursor": "Cursor"
    case "grok": "Grok"
    case "opencode": "OpenCode"
    case "antigravity": "Antigravity"
    default: driver
    }
  }
  static func providerOrder(_ driver: String) -> String {
    let index =
      ["codex", "claudeAgent", "claude", "cursor", "grok", "opencode", "antigravity"].firstIndex(
        of: driver) ?? 7
    return "\(index):\(driver)"
  }
  public static func duration(_ seconds: TimeInterval) -> String {
    let minutes = Int(max(0, seconds) / 60)
    if minutes >= 1_440 { return "\(minutes / 1_440)d \((minutes % 1_440) / 60)h" }
    if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
    return "\(minutes)m"
  }
  public static func tokens(_ value: Double) -> String {
    for (scale, suffix) in [(1e12, "T"), (1e9, "B"), (1e6, "M"), (1e3, "K")] where value >= scale {
      return (value / scale).formatted(.number.precision(.significantDigits(1...3))) + suffix
    }
    return value.formatted(.number.precision(.fractionLength(0)))
  }
  public static func cost(_ value: Double) -> String { value.formatted(.currency(code: "USD")) }
}
