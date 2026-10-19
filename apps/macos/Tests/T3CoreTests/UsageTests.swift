import Foundation
import Testing

@testable import T3Core

private let usageNow = ThreadDates.parse("2026-10-11T20:00:00Z")!

private func quota(_ id: String, used: Double, kind: String = "weekly", reset: String? = nil)
  -> JSON
{
  .object([
    "id": .string(id), "label": .string(id), "kind": .string(kind), "usedPercent": .number(used),
    "resetsAt": reset.map(JSON.string) ?? .null,
    "windowDurationMins": .number(kind == "session" ? 300 : 10_080),
  ])
}
private func usageProvider(
  _ id: String, email: String? = nil, windows: [JSON], checked: String = "2026-10-11T19:00:00Z",
  fingerprint: String? = nil
) -> JSON {
  .object([
    "instanceId": .string(id), "driver": .string("claudeAgent"), "displayName": .string(id),
    "enabled": .bool(true), "installed": .bool(true),
    "auth": .object(["email": email.map(JSON.string) ?? .null]),
    "usageLimits": .object([
      "checkedAt": .string(checked), "windows": .array(windows),
      "credentialFingerprint": fingerprint.map(JSON.string) ?? .null,
    ]),
  ])
}
private func limitsSnapshot(_ providers: [JSON], sources: [JSON] = []) -> UsageLimitsSnapshot {
  var snapshot = UsageLimitsSnapshot()
  snapshot.apply(
    .object([
      "type": .string("snapshot"),
      "config": .object([
        "providers": .array(providers), "usageLimitSources": .array(sources),
      ]),
    ]))
  return snapshot
}

@Test func usageDeduplicatesAccountsAcrossInstancesAndHubsAndKeepsNativeNames() throws {
  let a = usageProvider("Work", email: " SAME@example.test ", windows: [quota("week", used: 20)])
  let b = usageProvider(
    "Duplicate", email: "same@example.test", windows: [quota("week", used: 30)],
    checked: "2026-10-11T19:30:00Z")
  let limits: JSON = .object([
    "checkedAt": .string("2026-10-11T20:00:00Z"), "windows": .array([quota("week", used: 90)]),
    "resetCredits": .object(["availableCount": .number(2), "nextCreditId": .string("credit-a")]),
  ])
  let source: JSON = .object([
    "id": .string("hub"), "label": .string("Hub"),
    "accounts": .array([
      .object([
        "id": .string("account"), "driver": .string("claudeAgent"),
        "email": .string("same@example.test"), "usageLimits": limits,
      ])
    ]),
  ])
  var snapshot = limitsSnapshot([a, b], sources: [source])
  let account = try #require(snapshot.accounts.first)
  #expect(snapshot.accounts.count == 1)
  #expect(account.name == "Work")
  #expect(account.windows.first?.remaining == 10)
  #expect(account.credits == 2)
  #expect(account.redeemInput?["sourceId"].string == "hub")
  snapshot.apply(
    .object([
      "type": .string("usageLimitSourcesUpdated"), "payload": .object(["sources": .array([])]),
    ]))
  #expect(snapshot.accounts.first?.windows.first?.remaining == 70)
  #expect(snapshot.accounts.first?.credits == nil)
  let sameCredential = limitsSnapshot([
    usageProvider("One", windows: [quota("week", used: 10)], fingerprint: "hash"),
    usageProvider("Two", windows: [quota("week", used: 10)], fingerprint: "hash"),
  ])
  #expect(sameCredential.accounts.count == 1)
}

@Test func usagePoolsOnlyReportedWindowsAndKeepsFixedAccountColumnsAndKinds() throws {
  let snapshot = limitsSnapshot([
    usageProvider(
      "A",
      windows: [quota("week", used: 96, reset: "2026-10-12T20:00:00Z"), quota("fable", used: 100)]),
    usageProvider(
      "B",
      windows: [quota("week", used: 56, reset: "2026-10-13T20:00:00Z"), quota("fable", used: 81)]),
    usageProvider(
      "C",
      windows: [
        quota("week", used: 37, reset: "2026-10-14T20:00:00Z"), quota("fable", used: 47),
        quota("week", used: 4, kind: "monthly"),
      ]),
  ])
  let pool = try #require(snapshot.pools(at: usageNow).first)
  let weekly = try #require(pool.windows.first { $0.id == "weekly:week" })
  #expect(weekly.remaining == 37)
  #expect(weekly.nextRecovery == 32)
  #expect(pool.windows.first { $0.id == "weekly:fable" }?.remaining == 24)
  let monthly = try #require(pool.windows.first { $0.id == "monthly:week" })
  #expect(monthly.remaining == 96)
  #expect(monthly.columns.map(\.account.name) == weekly.columns.map(\.account.name))
  #expect(monthly.columns.compactMap(\.window).count == 1)
}

@Test func usageDoesNotInventQuotaWhenAProbeFailsOrHasNoWindow() throws {
  var provider = try #require(usageProvider("Unavailable", windows: []).objectValue)
  provider["usageLimits"] = .object([
    "windows": .array([quota("week", used: 0)]),
    "unavailable": .object([
      "reason": .string("probeFailed"), "message": .string("Try again"),
    ]),
  ])
  let snapshot = limitsSnapshot([.object(provider), usageProvider("Empty", windows: [])])
  #expect(snapshot.accounts.isEmpty)
  #expect(snapshot.notices == ["Unavailable: Try again", "Empty: No limits reported."])
  let window = try #require(UsageWindow(quota("week", used: 10)))
  #expect(window.resetDescription(at: usageNow) == nil)
  #expect(window.elapsed(at: usageNow) == nil)
  let expired = try #require(UsageWindow(quota("week", used: 100, reset: "2026-10-10T20:00:00Z")))
  #expect(expired.resetDescription(at: usageNow) == "Resets now")
  #expect(expired.remaining == 0)
}

@Test func usageWindowsRespectLocalCalendarDaysAndExact24HoursAcrossDST() throws {
  let zone = try #require(TimeZone(identifier: "America/New_York"))
  for timestamp in ["2026-03-08T23:30:00Z", "2026-11-01T23:30:00Z"] {
    let now = try #require(ThreadDates.parse(timestamp))
    let day = UsagePeriod.day.window(at: now, timeZone: zone)
    let start = try #require(ThreadDates.parse(day.input["sinceTime"].string))
    let end = try #require(ThreadDates.parse(day.input["untilTime"].string))
    #expect(end.timeIntervalSince(start) == 86_400)
    #expect(day.periods.count == 24)
    #expect(Set(day.periods).count == 24)
    let week = UsagePeriod.week.window(at: now, timeZone: zone)
    #expect(week.periods.count == 7)
    #expect(
      week.input["sinceDay"].string == (timestamp.contains("03-08") ? "2026-03-02" : "2026-10-26"))
  }
}

@Test func usageHistoryDoesNotDoubleCountReasoningOrSessionsAndExposesMissingPrices() throws {
  let window = UsagePeriod.week.window(at: usageNow, timeZone: TimeZone(secondsFromGMT: 0)!)
  func bucket(_ day: String, model: String, unpriced: Bool = false) -> JSON {
    .object([
      "day": .string(day), "provider": .string("claude"), "model": .string(model),
      "costUsd": .number(unpriced ? 0 : 2.5), "records": .number(2),
      "unpricedRecords": .number(unpriced ? 2 : 0),
      "sessions": .number(50),
      "totals": .object([
        "uncachedInputTokens": .number(100), "cachedInputTokens": .number(200),
        "cacheCreationTokens": .number(30),
        "outputTokens": .number(40), "reasoningTokens": .number(15),
      ]),
    ])
  }
  var payload: [String: JSON] = [
    "contractVersion": .number(6), "readAt": .string(ThreadDates.string(usageNow)),
    "pricing": .object(["status": .string("cached")]),
    "sources": .array([
      .object([
        "distinctSessions": .number(3), "status": .string("partial"),
        "message": .string("One file skipped"),
        "fingerprint": .object(["provider": .string("claude")]),
      ])
    ]),
    "buckets": .array([
      bucket("2026-10-10", model: "fable"), bucket("2026-10-11", model: "fable"),
      bucket("2026-10-11", model: "new-model", unpriced: true),
      bucket("2026-10-01", model: "outside-window"),
    ]),
  ]
  let history = try UsageHistory(.object(payload), window: window)
  #expect(history.totals.totalTokens == 1_110)
  #expect(history.totals.reasoning == 45)
  #expect(history.totals.cost == 5)
  #expect(history.sessions == 3)
  #expect(history.periods.count == 7)
  #expect(history.periods.first?.totals.totalTokens == 0)
  #expect(history.models.first { $0.name == "new-model" }?.totals.costUnknown == true)
  #expect(history.notices == ["Claude: One file skipped"])
  payload["contractVersion"] = .number(7)
  #expect(throws: T3Error.self) { try UsageHistory(.object(payload), window: window) }
}

extension JSON {
  fileprivate var objectValue: [String: JSON]? {
    if case .object(let fields) = self { fields } else { nil }
  }
}
