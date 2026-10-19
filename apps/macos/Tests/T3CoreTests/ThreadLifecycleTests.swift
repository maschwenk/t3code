import Foundation
import Testing

@testable import T3Core

private let now = ThreadDates.parse("2026-10-11T16:00:00.000Z")!
private func shellThread(_ id: String = "t", _ fields: [String: JSON] = [:]) throws -> ThreadSummary
{
  try ThreadSummary(
    .object(
      [
        "id": .string(id), "projectId": .string("p"), "title": .string(id),
        "createdAt": .string("2026-10-01T00:00:00Z"), "updatedAt": .string("2026-10-11T15:00:00Z"),
      ].merging(fields) { _, value in value }))
}

@Test func activityDoesNotReorderThreadsButReopeningAndManualKeysDo() throws {
  let oldBusy = try shellThread("old", ["updatedAt": .string("2026-10-11T16:00:00Z")])
  let newer = try shellThread("new", ["createdAt": .string("2026-10-10T00:00:00Z")])
  let reopened = try shellThread("reopened", ["unsettledAt": .string("2026-10-11T00:00:00Z")])
  let firstManual = try shellThread("first", ["activeOrderKey": .string("a0")])
  let secondManual = try shellThread("second", ["activeOrderKey": .string("a1")])
  #expect(
    ThreadGroup.sorted([oldBusy, secondManual, newer, firstManual, reopened], in: .active).map(\.id)
      == ["reopened", "new", "old", "first", "second"])
  let pinned = try shellThread("pinned", ["pinOrderKey": .string("a0")])
  #expect(
    ThreadGroup.sorted([newer, pinned, oldBusy], in: .pinned).map(\.id) == ["pinned", "new", "old"])
}

@Test func settledOrderUsesSettlementNotUnrelatedMetadataChanges() throws {
  let older = try shellThread(
    "old",
    ["settledAt": .string("2026-10-01T00:00:00Z"), "updatedAt": .string("2026-10-12T00:00:00Z")])
  let newer = try shellThread("new", ["settledAt": .string("2026-10-10T00:00:00Z")])
  let legacy = try shellThread("legacy", ["latestRunCompletedAt": .string("2026-10-09T00:00:00Z")])
  #expect(
    ThreadGroup.sorted([older, newer, legacy], in: .settled).map(\.id) == ["new", "legacy", "old"])
}

@Test func snoozeWakesOnAttentionFreshFailureCompletionOrExpiry() throws {
  let snooze: [String: JSON] = [
    "snoozedAt": .string("2026-10-11T15:00:00Z"),
    "snoozedUntil": .string("2026-10-11T18:00:00Z"),
  ]
  func state(_ extra: [String: JSON] = [:]) throws -> ThreadLifecycle {
    try shellThread("t", snooze.merging(extra) { _, new in new }).lifecycle
  }
  #expect(try state().snoozed(at: now))
  #expect(try !state().snoozed(at: now.addingTimeInterval(7200)))
  #expect(
    try !state(["pendingRuntimeRequest": .object(["kind": .string("user_input")])]).snoozed(at: now)
  )
  #expect(try state(["status": .string("failed")]).snoozed(at: now))
  let failed = try state([
    "status": .string("failed"), "updatedAt": .string("2026-10-11T15:30:00Z"),
  ])
  #expect(!failed.snoozed(at: now))
  let finished = try state([
    "latestRunId": .string("run"), "status": .string("idle"),
    "latestRunCompletedAt": .string("2026-10-11T15:30:00Z"),
  ])
  #expect(!finished.snoozed(at: now))
  #expect(finished.wokeAt(now) == finished.wokeAt(now.addingTimeInterval(10800)))
  #expect(try !state(["snoozedUntil": .string("invalid")]).snoozed(at: now))
}

@Test func queuedStartsAreBoundedAndRunningThreadsRemainSnoozable() throws {
  let recent = try shellThread("t", ["latestUserMessageAt": .string("2026-10-11T15:59:30Z")])
    .lifecycle
  #expect(!recent.canSnooze(at: now))
  #expect(recent.canSnooze(at: now.addingTimeInterval(121)))
  let skewed = try shellThread("t", ["latestUserMessageAt": .string("2026-10-11T16:00:30Z")])
    .lifecycle
  #expect(!skewed.canSnooze(at: now))
  let adopted = try shellThread(
    "t",
    [
      "latestUserMessageAt": .string("2026-10-11T15:59:30Z"),
      "latestRunId": .string("run"), "latestRunRequestedAt": .string("2026-10-11T15:59:30Z"),
      "status": .string("running"),
    ]
  ).lifecycle
  #expect(adopted.canSnooze(at: now))
}

@Test func serverVisitWatermarkAndBackgroundWorkDriveStatus() throws {
  let complete: [String: JSON] = [
    "latestRunId": .string("run"), "status": .string("idle"),
    "latestRunCompletedAt": .string("2026-10-11T15:00:00Z"),
    "lastVisitedAt": .string("2026-10-11T14:00:00Z"),
  ]
  let unread = try shellThread("t", complete)
  #expect(unread.lifecycle.statusLabel(at: now) == "Completed")
  let read = try shellThread(
    "t", complete.merging(["lastVisitedAt": .string("2026-10-11T16:00:00Z")]) { _, new in new })
  #expect(!read.lifecycle.unread)
  #expect(read.lifecycle.statusLabel(at: now) == nil)
  let command = try shellThread(
    "t",
    complete.merging(["pendingBackgroundTasks": .array([.object(["kind": .string("command")])])]) {
      _, new in new
    })
  #expect(command.lifecycle.statusLabel(at: now) == "Completed")
  let agent = try shellThread(
    "t",
    complete.merging(["pendingBackgroundTasks": .array([.object(["kind": .string("subagent")])])]) {
      _, new in new
    })
  #expect(agent.lifecycle.statusLabel(at: now) == "Waiting")
}

@Test func archivesHaveIndependentSequenceAndRestoringRemovesArchiveRow() throws {
  let item: JSON = .object([
    "id": .string("t"), "projectId": .string("p"), "title": .string("Archived"),
    "archivedAt": .string("2026-10-11T00:00:00Z"),
  ])
  var archived = ShellState(archived: true)
  try archived.apply(
    .object([
      "kind": .string("snapshot"),
      "snapshot": .object([
        "snapshotSequence": .number(99), "threads": .array([item]), "projects": .array([]),
      ]),
    ]))
  #expect(archived.synchronized)
  #expect(archived.threads["t"]?.archived == true)
  try archived.apply(
    .object(["kind": .string("thread.removed"), "sequence": .number(100), "threadId": .string("t")])
  )
  try archived.apply(
    .object(["kind": .string("thread.updated"), "sequence": .number(99), "thread": item]))
  #expect(archived.threads.isEmpty)
  try archived.apply(
    .object([
      "kind": .string("snapshot"),
      "snapshot": .object([
        "snapshotSequence": .number(2), "threads": .array([item]), "projects": .array([]),
      ]),
    ]))
  #expect(archived.threads.count == 1)
  #expect(archived.sequence == 2)
}

@Test func snoozeCalendarPresetsRespectDSTAndDoNotDuplicateMonday() throws {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "America/New_York")!
  let beforeSpring = ThreadDates.parse("2026-03-07T23:30:00-05:00")!
  let tomorrow = try #require(
    SnoozePreset.choices(at: beforeSpring, calendar: calendar).first { $0.title == "Tomorrow" })
  #expect(ThreadDates.string(tomorrow.date) == "2026-03-08T13:00:00.000Z")
  let sunday = ThreadDates.parse("2026-10-11T12:00:00-04:00")!
  #expect(
    !SnoozePreset.choices(at: sunday, calendar: calendar).contains { $0.title == "Next week" })
}
