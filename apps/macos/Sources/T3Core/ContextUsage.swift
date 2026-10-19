import Foundation

/// A provider report, normalized once at the event boundary.
public struct ContextUsage: Equatable, Sendable {
  public let usedTokens: Double
  public let updatedAt: String
  public let fields: JSON
  public let maxTokens: Double?
  public var usedPercentage: Double? {
    maxTokens.flatMap { $0 > 0 ? min(100, usedTokens / $0 * 100) : nil }
  }
  public var remainingTokens: Double? { maxTokens.map { max(0, ($0 - usedTokens).rounded()) } }
  public var isOverloaded: Bool { (usedPercentage ?? 0) > 90 }
  public var formattedPercentage: String? {
    usedPercentage.map {
      $0 < 10 ? Self.decimal($0) + "%" : String(format: "%.0f", $0.rounded()) + "%"
    }
  }
  public var compactsAutomatically: Bool? {
    fields["compactsAutomatically"] == .null ? nil : fields["compactsAutomatically"].bool
  }
  public func number(_ key: String) -> Double? { Self.finite(fields[key]) }

  public init?(report: JSON, updatedAt: String? = nil, live: Bool = false) {
    guard let used = Self.finite(report["usedTokens"]), used >= 0,
      let time = updatedAt ?? report["updatedAt"].string
    else { return nil }
    usedTokens = used
    self.updatedAt = time
    maxTokens = Self.finite(report["maxTokens"])
    if live {
      var values: [String: JSON] = ["compactsAutomatically": .bool(true)]
      for key in ["inputTokens", "cachedInputTokens", "outputTokens", "reasoningOutputTokens"] {
        values[key] = report[key]
      }
      fields = .object(values)
    } else {
      fields = report
    }
  }

  public static func compaction(_ item: JSON) -> ContextUsage? {
    guard item["type"].string == "compaction" else { return nil }
    return ContextUsage(
      report: .object([
        "usedTokens": item["afterTokenCount"], "totalProcessedTokens": item["beforeTokenCount"],
        "compactsAutomatically": .bool(true),
      ]), updatedAt: item["startedAt"].string ?? item["updatedAt"].string)
  }
  private static func finite(_ value: JSON) -> Double? {
    guard case .number(let number) = value, number.isFinite else { return nil }
    return number
  }
  public static func formatTokens(_ value: Double) -> String {
    guard value.isFinite else { return "0" }
    if value < 1_000 { return String(format: "%.0f", value.rounded()) }
    if value < 10_000 { return decimal(value / 1_000) + "k" }
    if value < 1_000_000 { return String(format: "%.0f", (value / 1_000).rounded()) + "k" }
    return decimal(value / 1_000_000) + "m"
  }
  private static func decimal(_ value: Double) -> String {
    let value = String(format: "%.1f", (value * 10).rounded() / 10)
    return value.hasSuffix(".0") ? String(value.dropLast(2)) : value
  }
  public func shouldOfferResume(provider: String?, now: Date = Date()) -> Bool {
    guard provider == "claudeAgent", usedTokens >= 100_000,
      let date = ThreadDates.parse(updatedAt)
    else { return false }
    return now.timeIntervalSince(date) >= 70 * 60
  }
  public static func hasPermanentDismissal(_ request: JSON) -> Bool {
    guard request["kind"].string == "user_input", request["status"].string == "resolved",
      case .object(let answers) = request["answers"]
    else { return false }
    let pattern =
      #"^This session is (?:\d+h \d+m|\d+m) old and uses \d{1,3}(?:,\d{3})* tokens\. Compact it before continuing\?$"#
    return answers.contains { question, answer in
      answer.string == "Don't ask again"
        && question.range(of: pattern, options: .regularExpression) != nil
    }
  }
}

/// Keep-full-history hides this exact report; another environment or newer report is independent.
public struct ContextResumeDismissals: Sendable {
  private struct Report: Hashable {
    let environment: String
    let thread: String
    let updatedAt: String
  }
  private var reports: Set<Report> = []
  public init() {}
  public mutating func dismiss(environment: String, thread: String, usage: ContextUsage) {
    reports.insert(Report(environment: environment, thread: thread, updatedAt: usage.updatedAt))
  }
  public func contains(environment: String, thread: String, usage: ContextUsage) -> Bool {
    reports.contains(Report(environment: environment, thread: thread, updatedAt: usage.updatedAt))
  }
}

/// Uses server capabilities and the same continuation-group selection as the web composer.
public struct ContextCompactionProviders: Sendable {
  private var providers: [JSON] = []
  private var settings: JSON = .null
  public init() {}
  public mutating func apply(_ event: JSON) {
    switch event["type"].string {
    case "snapshot":
      providers = event["config"]["providers"].array
      settings = event["config"]["settings"]
    case "providerStatuses": providers = event["payload"]["providers"].array
    case "settingsUpdated": settings = event["payload"]["settings"]
    default: break
    }
  }
  public func reportsContextWindow(instance: String?) -> Bool? {
    guard let provider = providers.first(where: { $0["instanceId"].string == instance }),
      case .bool(let reports) = provider["reportsContextWindow"]
    else { return nil }
    return reports
  }
  public func supportsCompact(driver: String, instance: String?, lockedInstance: String?) -> Bool {
    let driverProviders = providers.filter { $0["driver"].string == driver }
    let group = driverProviders.first { $0["instanceId"].string == lockedInstance }?[
      "continuation"]["groupKey"].string
    let compatible = driverProviders.filter {
      group == nil || $0["continuation"]["groupKey"].string == group
    }
    func selectable(_ value: JSON) -> Bool {
      let id = value["instanceId"].string ?? ""
      let explicit = settings["providerInstances"][id]
      let legacy = settings["providers"][driver]
      let enabled: Bool
      if explicit != .null {
        if explicit["enabled"] == .bool(false) || explicit["config"]["enabled"] == .bool(false) {
          enabled = false
        } else if explicit["enabled"] != .null {
          enabled = explicit["enabled"].bool
        } else if explicit["config"]["enabled"] != .null {
          enabled = explicit["config"]["enabled"].bool
        } else {
          enabled = !["cursor", "grok", "antigravity", "pi", "opencode"].contains(driver)
        }
      } else if id == driver && legacy != .null {
        enabled = legacy["enabled"] == .null ? value["enabled"].bool : legacy["enabled"].bool
      } else {
        enabled = settings == .null ? value["enabled"].bool : false
      }
      return enabled && value["availability"].string != "unavailable"
    }
    let requested = compatible.first { $0["instanceId"].string == instance && selectable($0) }
    let selected =
      requested
      ?? compatible.first { selectable($0) && $0["status"].string == "ready" }
      ?? compatible.first { selectable($0) && $0["status"].string != "error" }
    return selected?["slashCommands"].array.contains { $0["name"].string == "compact" } == true
  }
}
