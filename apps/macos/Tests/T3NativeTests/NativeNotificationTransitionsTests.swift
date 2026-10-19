import Foundation
import T3Core
import Testing

@testable import T3Native

private func nativeNoticeThread(
  status: String, run: String = "run-1", completed: String? = nil,
  request: String? = nil, archived: Bool = false, subagent: Bool = false
) -> JSON {
  .object([
    "id": .string("thread-1"), "projectId": .string("project-1"), "title": .string("My thread"),
    "status": .string(status), "latestRunId": .string(run),
    "latestRunCompletedAt": completed.map(JSON.string) ?? .null,
    "pendingRuntimeRequest": request.map {
      .object(["id": .string($0), "kind": .string("user_input")])
    } ?? .null,
    "archivedAt": archived ? .string("2026-10-12T12:00:00Z") : .null,
    "lineage": .object(["relationshipToParent": .string(subagent ? "subagent" : "root")]),
  ])
}
private func nativeNoticeSnapshot(_ thread: JSON) -> JSON {
  .object([
    "kind": .string("snapshot"),
    "snapshot": .object(["snapshotSequence": .number(1), "threads": .array([thread])]),
  ])
}
private func nativeNoticeUpdate(_ thread: JSON, sequence: Int) -> JSON {
  .object([
    "kind": .string("thread.updated"), "sequence": .number(Double(sequence)), "thread": thread,
  ])
}

@Test func nativeNotificationsAlertOnceForCompletionAndIgnoreShellReplayOrTitleEdits() {
  var tracker = NativeNotificationTransitionTracker()
  #expect(tracker.receive(nativeNoticeSnapshot(nativeNoticeThread(status: "running"))).isEmpty)
  let completed = nativeNoticeThread(status: "completed", completed: "2026-10-12T12:00:00Z")
  let notices = tracker.receive(nativeNoticeUpdate(completed, sequence: 2))
  #expect(notices.count == 1)
  #expect(notices.first?.kind == .completion)
  #expect(tracker.receive(nativeNoticeUpdate(completed, sequence: 2)).isEmpty)
  #expect(tracker.receive(nativeNoticeUpdate(completed, sequence: 3)).isEmpty)
  #expect(tracker.receive(nativeNoticeSnapshot(completed)).isEmpty)
  #expect(tracker.receive(nativeNoticeUpdate(completed, sequence: 4)).isEmpty)
}

@Test func nativeNotificationsSeedSnapshotsSilentlyAndDeduplicateRepeatedRequests() {
  var tracker = NativeNotificationTransitionTracker()
  #expect(
    tracker.receive(nativeNoticeSnapshot(nativeNoticeThread(status: "waiting", request: "old")))
      .isEmpty)
  #expect(
    tracker.receive(
      nativeNoticeUpdate(nativeNoticeThread(status: "waiting", request: "old"), sequence: 2)
    ).isEmpty)
  let first = tracker.receive(
    nativeNoticeUpdate(nativeNoticeThread(status: "waiting", request: "new"), sequence: 3))
  #expect(first.first?.kind == .attention)
  #expect(
    tracker.receive(nativeNoticeUpdate(nativeNoticeThread(status: "running"), sequence: 4)).isEmpty)
  #expect(
    tracker.receive(
      nativeNoticeUpdate(nativeNoticeThread(status: "waiting", request: "new"), sequence: 5)
    ).isEmpty)
  #expect(
    tracker.receive(
      nativeNoticeUpdate(nativeNoticeThread(status: "waiting", request: "next"), sequence: 6)
    ).count == 1)
}

@Test func nativeNotificationsIgnoreArchivedSubagentsInterruptedAndCancelledWork() {
  for thread in [
    nativeNoticeThread(status: "completed", completed: "2026-10-12T12:00:00Z", archived: true),
    nativeNoticeThread(status: "completed", completed: "2026-10-12T12:00:00Z", subagent: true),
    nativeNoticeThread(status: "interrupted", completed: "2026-10-12T12:00:00Z"),
    nativeNoticeThread(status: "cancelled", completed: "2026-10-12T12:00:00Z"),
  ] {
    var tracker = NativeNotificationTransitionTracker()
    _ = tracker.receive(nativeNoticeSnapshot(nativeNoticeThread(status: "running")))
    #expect(tracker.receive(nativeNoticeUpdate(thread, sequence: 2)).isEmpty)
  }
}

@Test func nativeNotificationsNewRunsCanFailAgainAndPreferencesFilterEachKind() {
  var tracker = NativeNotificationTransitionTracker()
  _ = tracker.receive(nativeNoticeSnapshot(nativeNoticeThread(status: "running")))
  #expect(
    tracker.receive(nativeNoticeUpdate(nativeNoticeThread(status: "failed"), sequence: 2)).first?
      .kind == .failure)
  #expect(
    tracker.receive(nativeNoticeUpdate(nativeNoticeThread(status: "failed"), sequence: 3)).isEmpty)
  #expect(
    tracker.receive(
      nativeNoticeUpdate(nativeNoticeThread(status: "failed", run: "run-2"), sequence: 4)
    ).count == 1)
  var choices = NativeNotificationValues()
  #expect(!choices.allows(.completion))
  choices.mode = .notificationsAndSound
  #expect(choices.allows(.completion))
  choices.attention = false
  #expect(!choices.allows(.attention))
  #expect(choices.allows(.failure))
  tracker.reset()
  #expect(
    tracker.receive(nativeNoticeUpdate(nativeNoticeThread(status: "failed"), sequence: 5)).isEmpty)
}

@Test func nativeNotificationsUsageLimitFailuresAreAttentionAndResetTimeChangesDoNotRepeat() {
  var tracker = NativeNotificationTransitionTracker()
  _ = tracker.receive(nativeNoticeSnapshot(nativeNoticeThread(status: "running")))
  guard case .object(var fields) = nativeNoticeThread(status: "failed") else { return }
  fields["lastErrorClass"] = .string("usage_limit")
  fields["usageLimitResetAt"] = .string("2026-10-12T14:00:00Z")
  let limited = tracker.receive(nativeNoticeUpdate(.object(fields), sequence: 2))
  #expect(limited.first?.kind == .attention)
  #expect(limited.first?.title == "Usage limit reached")
  fields["usageLimitResetAt"] = .string("2026-10-12T15:00:00Z")
  #expect(tracker.receive(nativeNoticeUpdate(.object(fields), sequence: 3)).isEmpty)
}

@Test func nativeNotificationsDoNotReplayAttentionSeededBySnapshots() {
  var tracker = NativeNotificationTransitionTracker()
  _ = tracker.receive(
    nativeNoticeSnapshot(nativeNoticeThread(status: "waiting", request: "existing")))
  _ = tracker.receive(nativeNoticeUpdate(nativeNoticeThread(status: "running"), sequence: 2))
  #expect(
    tracker.receive(
      nativeNoticeUpdate(nativeNoticeThread(status: "waiting", request: "existing"), sequence: 3)
    ).isEmpty)
  #expect(
    tracker.receive(
      nativeNoticeUpdate(nativeNoticeThread(status: "waiting", request: "new"), sequence: 4)
    ).count == 1)
  _ = tracker.receive(nativeNoticeSnapshot(nativeNoticeThread(status: "running")))
  #expect(
    tracker.receive(
      nativeNoticeUpdate(nativeNoticeThread(status: "waiting", request: "new"), sequence: 5)
    ).isEmpty)
}

@Test func nativeNotificationsBackgroundWaitsDoNotProduceCompletionAlerts() {
  var tracker = NativeNotificationTransitionTracker()
  _ = tracker.receive(nativeNoticeSnapshot(nativeNoticeThread(status: "running")))
  guard
    case .object(var fields) = nativeNoticeThread(
      status: "completed", completed: "2026-10-12T12:00:00Z")
  else { return }
  fields["pendingBackgroundTasks"] = .array([.object(["kind": .string("monitor")])])
  #expect(tracker.receive(nativeNoticeUpdate(.object(fields), sequence: 2)).isEmpty)
}
