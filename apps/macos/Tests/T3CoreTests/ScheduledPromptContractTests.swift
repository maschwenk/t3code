import Foundation
import Testing

@testable import T3Core

@Suite struct ScheduledPromptContractTests {
  private func json(_ text: String) throws -> JSON { try JSON.decode(Data(text.utf8)) }
  private func draft() -> ScheduledPromptDraft {
    var draft = ScheduledPromptDraft()
    draft.title = " Daily review "
    draft.prompt = " Inspect the project "
    draft.projectID = "project-1"
    draft.model = .object([
      "instanceId": .string("codex_work"), "model": .string("gpt-current"),
      "options": .array([.object(["id": .string("effort"), "value": .string("high")])]),
    ])
    return draft
  }
  @Test func serverWallClockIsSentVerbatimWithSundayBasedWeekdays() throws {
    var value = draft()
    value.timeOfDay = "09:30"
    value.weekdays = [5, 1, 3]
    let wire = try JSON.decode(value.payload().data())
    #expect(
      try wire["schedule"]
        == json(
          """
          {"type":"fixed_time","timeOfDay":"09:30","weekdays":[1,3,5]}
          """))
    #expect(wire["title"] == .string("Daily review"))
    #expect(wire["modelSelection"] == value.model)
    #expect(wire["workspaceStrategy"] == .object(["type": .string("root")]))
    #expect(wire["creationSource"] == .string("web"))
    #expect(wire["threadId"] == .null)
    value.weekdays = Set(0...6)
    #expect(try value.payload()["schedule"]["weekdays"] == .null)
    value.weekdays = []
    #expect(try value.payload()["schedule"]["weekdays"] == .null)
    value.timeOfDay = "24:00"
    #expect(throws: T3Error.self) { try value.payload() }
    value.timeOfDay = "09:30"
    value.weekdays = [7]
    #expect(throws: T3Error.self) { try value.payload() }
  }
  @Test func retriesReuseTaskAndCommandIDsAndWritesEnforceMinuteMinimum() throws {
    var value = draft()
    value.mode = "interval"
    value.intervalMinutes = "1.25"
    let first = try value.payload()
    #expect(try first == value.payload())
    #expect(first["schedule"]["everyMs"] == .number(75_000))
    #expect(first["id"] == .string(value.id))
    #expect(first["requireExisting"] == .bool(false))
    for invalid in ["0.999", "nan", "inf", "-10", "1e100"] {
      value.intervalMinutes = invalid
      #expect(throws: T3Error.self) { try value.payload() }
    }
    value.mode = "webhook"
    #expect(throws: T3Error.self) { try value.payload() }
  }
  @Test func readingRealWireDatesAndEditingPreservesHistoryAndEndConditionsByOmission() throws {
    let task = try ScheduledPrompt(
      json(
        """
        {"id":"scheduled-task:existing","title":"Review","prompt":"Inspect changes","enabled":true,
         "schedule":{"type":"interval","everyMs":30000},"projectId":"project-1","threadId":"thread-8",
         "workspaceStrategy":{"type":"worktree","baseRef":"release","branch":"scheduled-review","startFromOrigin":false},
         "modelSelection":{"instanceId":"claude_work","model":"opus","options":[{"id":"effort","value":"high"}]},
         "runtimeMode":"full-access","interactionMode":"plan","runCount":3,"lastRunStatus":"failed",
         "nextRunAt":null,"lastRunAt":"2026-10-12T14:33:45.123Z","endsAt":"2026-10-11T09:00:00-04:00","maxRuns":3}
        """))
    #expect(task.lifecycle == "Ended")
    #expect(task.lastRun == Date(timeIntervalSince1970: 1791815625.123))
    var value = ScheduledPromptDraft(task: task)
    #expect(throws: T3Error.self) { try value.payload() }
    value.intervalMinutes = "15"
    value.title = "Renamed"
    let wire = try value.payload()
    #expect(wire["requireExisting"] == .bool(true))
    #expect(wire["id"] == .string(task.id))
    #expect(wire["workspaceStrategy"] == task.workspace)
    #expect(wire["modelSelection"] == task.model)
    #expect(wire["endsAt"] == .null)
    #expect(wire["maxRuns"] == .null)
    if case .object(let fields) = wire {
      #expect(fields["endsAt"] == nil)
      #expect(fields["maxRuns"] == nil)
      #expect(fields["runCount"] == nil)
      #expect(fields["nextRunAt"] == nil)
    }
    #expect(
      try ScheduledPrompt.date(.string("2026-10-12T10:33:45-04:00"))
        == ScheduledPrompt.date(.string("2026-10-12T14:33:45Z")))
    #expect(throws: T3Error.self) { try ScheduledPrompt.date(.string("2026-13-99")) }
  }
  @Test func unknownTriggerIsReadableButCannotBeEditedAndWorktreePathsAreServerSide() throws {
    let task = try ScheduledPrompt(
      json(
        """
        {"id":"future","title":"Future trigger","prompt":"Inspect","enabled":false,"schedule":{"type":"future-trigger"},
         "projectId":"project-1","modelSelection":{"instanceId":"codex","model":"gpt"},"runCount":0,"lastRunStatus":"never"}
        """))
    #expect(!task.editable)
    #expect(task.lifecycle == "Paused")
    #expect(throws: T3Error.self) { try ScheduledPromptDraft(task: task).payload() }
    var value = draft()
    value.workspaceMode = "existing_worktree"
    #expect(throws: T3Error.self) { try value.payload() }
    value.worktreePath = "/remote/worktrees/review"
    #expect(
      try value.payload()["workspaceStrategy"]["worktreePath"]
        == .string("/remote/worktrees/review"))
  }

  @Test func interruptedCreateRecoversExactPayloadAcrossSettingsLifetimes() throws {
    var value = draft()
    value.workspaceMode = "worktree"
    value.baseRef = "release"
    value.weekdays = [1, 5]
    let submitted = try value.payload()
    let persisted = try JSONEncoder().encode(value)
    let recovered = try JSONDecoder().decode(ScheduledPromptDraft.self, from: persisted)
    #expect(try recovered.payload() == submitted)
    #expect(recovered.id == value.id)
    #expect(recovered.commandID == value.commandID)
  }
}
