import Foundation

public enum UsageMetric: String, CaseIterable, Sendable {
  case cost, tokens, limits
  public var title: String { rawValue.capitalized }
}

public enum UsagePeriod: Int, CaseIterable, Sendable {
  case day = 1
  case week = 7
  case month = 30
  case quarter = 90
  public var title: String { self == .day ? "Past 24h" : "\(rawValue) days" }

  public func window(at now: Date = Date(), timeZone: TimeZone = .current) -> UsageHistoryWindow {
    UsageHistoryWindow(period: self, now: now, timeZone: timeZone)
  }
}

public struct UsageHistoryWindow: Sendable, Equatable {
  public let input: JSON
  public let periods: [String]
  public let hourly: Bool
  public let timeZone: TimeZone

  init(period: UsagePeriod, now: Date, timeZone: TimeZone) {
    self.timeZone = timeZone
    hourly = period == .day
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = calendar
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    let until =
      hourly ? Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 60) * 60) : now
    let since =
      hourly
      ? until.addingTimeInterval(-86_400)
      : calendar.date(
        byAdding: .day, value: -(period.rawValue - 1), to: calendar.startOfDay(for: until))!
    var fields: [String: JSON] = [
      "sinceDay": .string(formatter.string(from: since)),
      "untilDay": .string(formatter.string(from: until)),
      "timeZone": .string(timeZone.identifier), "resolution": .string(hourly ? "hour" : "day"),
    ]
    if hourly {
      fields["sinceTime"] = .string(ThreadDates.string(since))
      fields["untilTime"] = .string(ThreadDates.string(until))
      periods = (0..<24).map { ThreadDates.string(since.addingTimeInterval(Double($0) * 3_600)) }
    } else {
      periods = (0..<period.rawValue).map {
        formatter.string(from: calendar.date(byAdding: .day, value: $0, to: since)!)
      }
    }
    input = .object(fields)
  }

  public func label(_ period: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = .current
    if hourly, let date = ThreadDates.parse(period) {
      formatter.timeZone = timeZone
      formatter.dateFormat = "MMM d, h:mm a z"
      return formatter.string(from: date)
    }
    let parts = period.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return period }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    guard
      let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    else { return period }
    formatter.timeZone = timeZone
    formatter.dateFormat = "MMM d"
    return formatter.string(from: date)
  }
}

public struct UsageTotals: Sendable, Equatable {
  public var cost = 0.0
  public var input = 0.0
  public var cached = 0.0
  public var cacheWrite = 0.0
  public var output = 0.0
  public var reasoning = 0.0
  public var records = 0.0
  public var unpriced = 0.0
  public var cacheSavings = 0.0
  public var inputCost = 0.0
  public var cacheReadCost = 0.0
  public var cacheWriteCost = 0.0
  public var outputCost = 0.0
  public var speedPremium = 0.0
  public var totalTokens: Double { input + cached + cacheWrite + output }
  public var costUnknown: Bool { records > 0 && unpriced >= records }
  public init() {}
  public func value(_ metric: UsageMetric) -> Double { metric == .tokens ? totalTokens : cost }
  public func display(_ metric: UsageMetric) -> String {
    metric == .tokens
      ? UsageFormat.tokens(totalTokens) : costUnknown ? "Unpriced" : UsageFormat.cost(cost)
  }
  mutating func add(_ bucket: JSON) {
    cost += bucket["costUsd"].usageNumber ?? 0
    input += bucket["totals"]["uncachedInputTokens"].usageNumber ?? 0
    cached += bucket["totals"]["cachedInputTokens"].usageNumber ?? 0
    cacheWrite += bucket["totals"]["cacheCreationTokens"].usageNumber ?? 0
    output += bucket["totals"]["outputTokens"].usageNumber ?? 0
    reasoning += bucket["totals"]["reasoningTokens"].usageNumber ?? 0
    records += bucket["records"].usageNumber ?? 0
    unpriced += bucket["unpricedRecords"].usageNumber ?? 0
    cacheSavings += bucket["cacheSavingsUsd"].usageNumber ?? 0
    inputCost += bucket["categoryCostUsd"]["input"].usageNumber ?? 0
    cacheReadCost += bucket["categoryCostUsd"]["cacheRead"].usageNumber ?? 0
    cacheWriteCost += bucket["categoryCostUsd"]["cacheWrite"].usageNumber ?? 0
    outputCost += bucket["categoryCostUsd"]["output"].usageNumber ?? 0
    speedPremium += bucket["speedPremiumUsd"].usageNumber ?? 0
  }
}

public struct UsageBreakdown: Sendable, Equatable, Identifiable {
  public let id: String
  public let provider: String
  public let name: String
  public var totals = UsageTotals()
}

public struct UsageHistory: Sendable, Equatable {
  public let readAt: Date?
  public let window: UsageHistoryWindow
  public let totals: UsageTotals
  public let providers: [UsageBreakdown]
  public let models: [UsageBreakdown]
  public let periods: [UsageBreakdown]
  public let series: [UsageBreakdown]
  public let notices: [String]
  public let pricing: String
  public let sessions: Int

  public init(_ value: JSON, window: UsageHistoryWindow) throws {
    guard let version = value["contractVersion"].int, (4...6).contains(version) else {
      throw T3Error(
        "This server’s usage format is incompatible. Update the server and native app to view totals."
      )
    }
    self.window = window
    readAt = ThreadDates.parse(value["readAt"].string)
    pricing = value["pricing"]["status"].string ?? "unavailable"
    var notices: [String] = []
    var seenSources: Set<String> = []
    var sessions = 0
    for source in value["sources"].array {
      let fingerprint = source["fingerprint"]
      let key = ["hostId", "provider", "resolvedHomePath", "volumeId"].map {
        fingerprint[$0].string ?? ""
      }.joined(separator: "\0")
      if seenSources.insert(key).inserted { sessions += source["distinctSessions"].int ?? 0 }
      if source["status"].string != "ok" {
        let provider = UsageFormat.provider(fingerprint["provider"].string ?? "Source")
        notices.append(
          provider + ": "
            + (source["message"].string ?? "\(source["status"].string ?? "Unknown") coverage"))
      }
    }
    self.sessions = sessions
    self.notices = Array(Set(notices)).sorted()
    var totals = UsageTotals()
    var providers: [String: UsageBreakdown] = [:]
    var models: [String: UsageBreakdown] = [:]
    var periods = Dictionary(
      uniqueKeysWithValues: window.periods.map {
        ($0, UsageBreakdown(id: $0, provider: "", name: $0))
      })
    var series: [String: UsageBreakdown] = [:]
    for bucket in value["buckets"].array {
      guard let provider = bucket["provider"].string, let model = bucket["model"].string else {
        continue
      }
      let period =
        window.hourly
        ? ThreadDates.parse(bucket["hourStart"].string).map(ThreadDates.string)
        : bucket["day"].string
      guard let period, periods[period] != nil else { continue }
      totals.add(bucket)
      let modelKey = provider + ":" + model
      let seriesKey = provider + ":" + period
      providers[
        provider,
        default: UsageBreakdown(
          id: provider, provider: provider, name: UsageFormat.provider(provider))
      ].totals.add(bucket)
      models[modelKey, default: UsageBreakdown(id: modelKey, provider: provider, name: model)]
        .totals.add(bucket)
      periods[period]?.totals.add(bucket)
      series[seriesKey, default: UsageBreakdown(id: seriesKey, provider: provider, name: period)]
        .totals.add(bucket)
    }
    self.totals = totals
    let sortedProviders = providers.values.sorted {
      UsageFormat.providerOrder($0.provider) < UsageFormat.providerOrder($1.provider)
    }
    self.providers = sortedProviders
    self.models = models.values.sorted { $0.totals.cost > $1.totals.cost }
    self.periods = window.periods.compactMap { periods[$0] }
    self.series = window.periods.flatMap { period in
      sortedProviders.map { provider in
        series[provider.id + ":" + period]
          ?? UsageBreakdown(id: provider.id + ":" + period, provider: provider.id, name: period)
      }
    }
  }
}
