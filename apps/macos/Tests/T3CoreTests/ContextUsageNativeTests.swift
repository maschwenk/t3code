import Foundation
import Testing

@testable import T3Core

private func contextJSON(_ text: String) throws -> JSON { try JSON.decode(Data(text.utf8)) }
private func contextEvent(_ type: String, _ payload: JSON) -> JSON {
  .object(["type": .string(type), "threadId": .string("thread"), "payload": payload])
}
private func contextFields(_ value: JSON, _ fields: [String: JSON]) -> JSON {
  guard case .object(var result) = value else { return .object(fields) }
  result.merge(fields) { _, new in new }
  return .object(result)
}
private func contextFixture() throws -> JSON {
  try contextJSON(
    #"""
    {"thread":{"id":"thread","activeProviderThreadId":"claude-thread"},
     "providerThreads":[
       {"id":"claude-thread","appThreadId":"thread","driver":"claudeAgent","providerInstanceId":"claudeAgent","updatedAt":"2026-10-12T12:00:00Z","contextUsage":{"usedTokens":110000,"maxTokens":200000,"cost":{"amount":0.004,"currency":"USD"},"autoCompactThreshold":160000}},
       {"id":"codex-thread","appThreadId":"thread","driver":"codex","providerInstanceId":"codex","updatedAt":"2026-10-12T13:00:00Z","contextUsage":{"usedTokens":3000}}],
     "providerTurns":[{"id":"turn","providerThreadId":"claude-thread","ordinal":1,"status":"running","runAttemptId":"attempt","tokenUsage":{"usedTokens":120000,"maxTokens":200000,"inputTokens":100000,"updatedAt":"2026-10-12T12:10:00Z"}}],
     "turnItems":[{"id":"message","type":"user_message","text":"Review this code","attachments":[]}]}
    """#)
}

@Test func nativeContextRetainsUsageOnlyUpdatesAndRejectsOlderReports() throws {
  let fixture = try contextFixture()
  var execution = ThreadExecution(fixture)
  #expect(execution.contextUsage?.usedTokens == 120000)
  #expect(execution.contextUsage?.number("autoCompactThreshold") == nil)
  let turn = fixture["providerTurns"].array[0]
  let update = contextFields(
    turn,
    [
      "tokenUsage": try contextJSON(
        #"{"usedTokens":140000,"maxTokens":200000,"updatedAt":"2026-10-12T12:20:00Z"}"#)
    ])
  execution.apply(contextEvent("provider-turn.updated", update))
  #expect(execution.liveProviderTurnUsage?.usedTokens == 140000)
  #expect(execution.contextUsage?.remainingTokens == 60000)
  execution.apply(contextEvent("provider-turn.updated", turn))
  #expect(execution.contextUsage?.usedTokens == 140000)
  execution.apply(
    contextEvent(
      "provider-turn.updated",
      contextFields(
        update, ["id": .string("new-turn"), "ordinal": .number(2), "tokenUsage": .null])))
  #expect(execution.contextUsage?.usedTokens == 140000)
  #expect(execution.hasCompactableConversation)
}

@Test func nativeContextDoesNotLeakUsageAcrossProviderSwitches() throws {
  let fixture = try contextFixture()
  var execution = ThreadExecution(fixture)
  execution.apply(
    contextEvent(
      "thread.provider-switched",
      contextFields(fixture["thread"], ["activeProviderThreadId": .string("codex-thread")])))
  #expect(execution.selectedProviderThread["driver"].string == "codex")
  #expect(execution.contextUsage?.usedTokens == 3000)
  #expect(execution.liveProviderTurnUsage == nil)
  execution.apply(contextEvent("provider-turn.updated", fixture["providerTurns"].array[0]))
  #expect(execution.contextUsage?.usedTokens == 3000)
  execution.apply(
    contextEvent(
      "thread.provider-switched",
      contextFields(fixture["thread"], ["activeProviderThreadId": .string("unknown-thread")])))
  #expect(execution.contextUsage == nil)
}

@Test func nativeContextProviderAndCompactionFallbacksRetainActualFields() throws {
  let fixture = try contextFixture()
  var execution = ThreadExecution(contextFields(fixture, ["providerTurns": .array([])]))
  #expect(execution.contextUsage?.number("autoCompactThreshold") == 160000)
  #expect(execution.contextUsage?.fields["cost"]["amount"] == .number(0.004))
  execution.apply(
    contextEvent(
      "provider-thread.updated",
      contextFields(
        fixture["providerThreads"].array[0],
        [
          "updatedAt": .string("2026-10-12T11:00:00Z"),
          "contextUsage": .object(["usedTokens": .number(1)]),
        ])))
  #expect(execution.contextUsage?.usedTokens == 110000)
  execution = ThreadExecution(
    contextFields(
      fixture,
      [
        "providerTurns": .array([]), "providerThreads": .array([]),
        "turnItems": try contextJSON(
          #"[{"id":"compact","type":"compaction","providerThreadId":"claude-thread","beforeTokenCount":180000,"afterTokenCount":35000,"startedAt":"2026-10-12T12:00:00Z","updatedAt":"2026-10-12T12:01:00Z"}]"#
        ),
      ]))
  #expect(execution.contextUsage?.usedTokens == 35000)
  #expect(execution.contextUsage?.number("totalProcessedTokens") == 180000)
  #expect(execution.contextUsage?.maxTokens == nil)
  #expect(execution.contextUsage?.compactsAutomatically == true)
  #expect(execution.contextUsage?.updatedAt == "2026-10-12T12:00:00Z")
}

@Test func nativeContextResumeBoundaryAndDismissalAreScopedToReport() throws {
  let usage = try #require(
    ContextUsage(
      report: contextJSON(
        #"{"usedTokens":100000,"maxTokens":100000,"updatedAt":"2026-10-12T12:00:00Z"}"#)))
  let now = try #require(ThreadDates.parse("2026-10-12T13:10:00Z"))
  #expect(usage.shouldOfferResume(provider: "claudeAgent", now: now))
  #expect(!usage.shouldOfferResume(provider: "codex", now: now))
  #expect(!usage.shouldOfferResume(provider: "claudeAgent", now: now.addingTimeInterval(-1)))
  let small = try #require(
    ContextUsage(
      report: .object(["usedTokens": .number(99999), "updatedAt": .string(usage.updatedAt)])))
  #expect(!small.shouldOfferResume(provider: "claudeAgent", now: now))
  let invalid = try #require(
    ContextUsage(report: .object(["usedTokens": .number(100000), "updatedAt": .string("invalid")])))
  #expect(!invalid.shouldOfferResume(provider: "claudeAgent", now: now))
  var dismissed = ContextResumeDismissals()
  dismissed.dismiss(environment: "one", thread: "thread", usage: usage)
  #expect(dismissed.contains(environment: "one", thread: "thread", usage: usage))
  #expect(!dismissed.contains(environment: "two", thread: "thread", usage: usage))
  #expect(!dismissed.contains(environment: "one", thread: "other", usage: usage))
  let newer = try #require(ContextUsage(report: usage.fields, updatedAt: "2026-10-12T12:01:00Z"))
  #expect(!dismissed.contains(environment: "one", thread: "thread", usage: newer))
}

@Test func nativeContextPermanentDismissalRecognizesOnlyTheServerQuestion() throws {
  let request = try contextJSON(
    #"{"kind":"user_input","status":"resolved","answers":{"This session is 1h 10m old and uses 100,000 tokens. Compact it before continuing?":"Don't ask again"}}"#
  )
  #expect(ContextUsage.hasPermanentDismissal(request))
  #expect(
    !ContextUsage.hasPermanentDismissal(contextFields(request, ["status": .string("pending")])))
  #expect(
    !ContextUsage.hasPermanentDismissal(
      contextFields(
        request, ["answers": .object(["Compact before continuing?": .string("Don't ask again")])])))
  var execution = ThreadExecution()
  execution.apply(contextEvent("runtime-request.updated", request))
  #expect(execution.hasDismissedResumeCompaction)
}

@Test func nativeContextCompactionRequiresCompatibleAdvertisedCapability() throws {
  let providers = try contextJSON(
    #"""
    [{"instanceId":"claudeAgent","driver":"claudeAgent","enabled":true,"status":"error","continuation":{"groupKey":"shared"},"slashCommands":[{"name":"compact"}]},
     {"instanceId":"alternate","driver":"claudeAgent","enabled":true,"status":"ready","continuation":{"groupKey":"other"},"slashCommands":[{"name":"compact"}]},
     {"instanceId":"codex","driver":"codex","enabled":true,"status":"ready","slashCommands":[{"name":"compact"}]}]
    """#)
  var catalog = ContextCompactionProviders()
  catalog.apply(
    .object(["type": .string("snapshot"), "config": .object(["providers": providers])]))
  #expect(
    catalog.supportsCompact(
      driver: "claudeAgent", instance: "claudeAgent", lockedInstance: "claudeAgent"))
  catalog.apply(
    .object([
      "type": .string("settingsUpdated"),
      "payload": .object([
        "settings": try contextJSON(
          #"{"providerInstances":{"claudeAgent":{"driver":"claudeAgent","enabled":false},"alternate":{"driver":"claudeAgent","enabled":true}},"providers":{"codex":{"enabled":true}}}"#
        )
      ]),
    ]))
  #expect(
    !catalog.supportsCompact(
      driver: "claudeAgent", instance: "claudeAgent", lockedInstance: "claudeAgent"))
  #expect(
    catalog.supportsCompact(driver: "claudeAgent", instance: "claudeAgent", lockedInstance: nil))
  #expect(catalog.supportsCompact(driver: "codex", instance: "codex", lockedInstance: "codex"))
  catalog.apply(
    .object([
      "type": .string("providerStatuses"),
      "payload": .object([
        "providers": .array(
          providers.array.map { contextFields($0, ["availability": .string("unavailable")]) })
      ]),
    ]))
  #expect(!catalog.supportsCompact(driver: "codex", instance: "codex", lockedInstance: nil))
}

@Test func nativeContextCompactOnlyMessageDoesNotStartAConversation() throws {
  var execution = ThreadExecution(
    try contextJSON(
      #"{"thread":{"id":"thread"},"turnItems":[{"id":"message","type":"user_message","text":" /compact\n","attachments":[]}]}"#
    ))
  #expect(!execution.hasCompactableConversation)
  execution.apply(
    contextEvent(
      "turn-item.updated",
      try contextJSON(
        #"{"id":"message","type":"user_message","text":"/compact","attachments":[{"id":"file"}]}"#))
  )
  #expect(execution.hasCompactableConversation)
}

@Test func nativeContextTokenFormattingAndWarningMatchWebBoundaries() throws {
  #expect(ContextUsage.formatTokens(999) == "999")
  #expect(ContextUsage.formatTokens(1500) == "1.5k")
  #expect(ContextUsage.formatTokens(10000) == "10k")
  #expect(ContextUsage.formatTokens(1_250_000) == "1.3m")
  let ninety = try #require(
    ContextUsage(report: contextJSON(#"{"usedTokens":900,"maxTokens":1000,"updatedAt":"today"}"#)))
  #expect(!ninety.isOverloaded)
  let full = try #require(
    ContextUsage(report: contextJSON(#"{"usedTokens":1100,"maxTokens":1000,"updatedAt":"today"}"#)))
  #expect(full.isOverloaded && full.usedPercentage == 100 && full.remainingTokens == 0)
}
