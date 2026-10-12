import Foundation

public struct ScheduledPrompt: Identifiable, Sendable, Equatable {
  public let id: String
  public let title: String
  public let prompt: String
  public let enabled: Bool
  public let schedule: JSON
  public let projectID: String
  public let threadID: String?
  public let model: JSON
  public let workspace: JSON
  public let runtimeMode: String
  public let interactionMode: String
  public let nextRun: Date?
  public let lastRun: Date?
  public let lastStatus: String
  public let runCount: Int
  public let source: JSON
  public var editable: Bool { ["interval", "fixed_time"].contains(schedule["type"].string ?? "") }
  public var lifecycle: String {
    if !enabled { return "Paused" }
    return nextRun == nil && (source["endsAt"] != .null || source["maxRuns"] != .null)
      ? "Ended" : "Active"
  }
  public init(_ value: JSON) throws {
    id = try value.requiredString("id")
    title = try value.requiredString("title")
    prompt = try value.requiredString("prompt")
    projectID = try value.requiredString("projectId")
    enabled = value["enabled"].bool
    schedule = value["schedule"]
    threadID = value["threadId"].string
    model = value["modelSelection"]
    workspace = value["workspaceStrategy"]
    runtimeMode = value["runtimeMode"].string ?? "approval-required"
    interactionMode = value["interactionMode"].string ?? "default"
    nextRun = try Self.date(value["nextRunAt"])
    lastRun = try Self.date(value["lastRunAt"])
    lastStatus = value["lastRunStatus"].string ?? "never"
    runCount = try value.requiredInt("runCount")
    source = value
  }
  public static func date(_ value: JSON) throws -> Date? {
    if value == .null { return nil }
    guard let text = value.string else { throw T3Error("Invalid schedule date.") }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: text) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    guard let date = formatter.date(from: text) else { throw T3Error("Invalid schedule date.") }
    return date
  }
  public var cadence: String {
    if schedule["type"].string == "interval" {
      return "Every \(Double(schedule["everyMs"].int ?? 0) / 60_000) minutes"
    }
    guard schedule["type"].string == "fixed_time" else { return "Unsupported trigger" }
    let days = Set(schedule["weekdays"].array.compactMap(\.int))
    let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    let label =
      days.isEmpty || days.count == 7
      ? "Daily"
      : days.sorted().compactMap { names.indices.contains($0) ? names[$0] : nil }.joined(
        separator: ", ")
    return label + " at " + (schedule["timeOfDay"].string ?? "") + " · server time"
  }
}

public struct ScheduledPromptDraft: Codable, Sendable {
  public let id: String
  public let commandID: String
  public let editing: Bool
  public var title = ""
  public var prompt = ""
  public var enabled = true
  public var mode = "fixed_time"
  public var timeOfDay = "09:00"
  public var weekdays: Set<Int> = Set(0..<7)
  public var intervalMinutes = "15"
  public var projectID = ""
  public var threadID = ""
  public var model: JSON = .null
  public var workspaceMode = "root"
  public var baseRef = "main"
  public var worktreePath = ""
  public var branch = ""
  public var startFromOrigin = true
  public var runtimeMode = "approval-required"
  public var interactionMode = "default"

  public init(task: ScheduledPrompt? = nil) {
    commandID = UUID().uuidString.lowercased()
    id = task?.id ?? "scheduled-task:" + commandID
    editing = task != nil
    guard let task else { return }
    title = task.title
    prompt = task.prompt
    enabled = task.enabled
    mode = task.schedule["type"].string ?? "fixed_time"
    timeOfDay = task.schedule["timeOfDay"].string ?? "09:00"
    let savedDays = task.schedule["weekdays"].array.compactMap(\.int)
    weekdays = savedDays.isEmpty ? Set(0..<7) : Set(savedDays)
    intervalMinutes = String(Double(task.schedule["everyMs"].int ?? 900_000) / 60_000)
    projectID = task.projectID
    threadID = task.threadID ?? ""
    model = task.model
    workspaceMode = task.workspace["type"].string ?? "root"
    baseRef = task.workspace["baseRef"].string ?? "main"
    worktreePath = task.workspace["worktreePath"].string ?? ""
    branch = task.workspace["branch"].string ?? ""
    startFromOrigin = task.workspace["startFromOrigin"] != .bool(false)
    runtimeMode = task.runtimeMode
    interactionMode = task.interactionMode
  }
  public func payload() throws -> JSON {
    func trimmed(_ value: String) -> String {
      value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard !trimmed(title).isEmpty, !trimmed(prompt).isEmpty, !projectID.isEmpty,
      !(model["instanceId"].string ?? "").isEmpty, !(model["model"].string ?? "").isEmpty
    else {
      throw T3Error("Choose a project and model, and enter a title and prompt.")
    }
    guard ["approval-required", "auto-accept-edits", "auto", "full-access"].contains(runtimeMode),
      ["default", "plan"].contains(interactionMode)
    else {
      throw T3Error("Choose supported permissions and an interaction mode.")
    }
    let schedule: JSON
    switch mode {
    case "fixed_time":
      guard
        timeOfDay.range(of: "^([01]?[0-9]|2[0-3]):[0-5][0-9]$", options: .regularExpression) != nil,
        weekdays.allSatisfy({ (0...6).contains($0) })
      else { throw T3Error("Enter a server time such as 09:30.") }
      var fields: [String: JSON] = ["type": .string(mode), "timeOfDay": .string(timeOfDay)]
      if !weekdays.isEmpty && weekdays.count < 7 {
        fields["weekdays"] = .array(weekdays.sorted().map { .number(Double($0)) })
      }
      schedule = .object(fields)
    case "interval":
      guard let minutes = Double(intervalMinutes), minutes.isFinite, minutes >= 1,
        minutes * 60_000 < 9_007_199_254_740_991
      else { throw T3Error("Intervals must be at least one minute.") }
      schedule = .object(["type": .string(mode), "everyMs": .number((minutes * 60_000).rounded())])
    default: throw T3Error("Only fixed times and recurring intervals can be edited here.")
    }
    var workspace: [String: JSON] = ["type": .string(workspaceMode)]
    switch workspaceMode {
    case "root": break
    case "worktree":
      guard !trimmed(baseRef).isEmpty else {
        throw T3Error("Enter a base branch for the worktree.")
      }
      workspace["baseRef"] = .string(trimmed(baseRef))
      workspace["startFromOrigin"] = .bool(startFromOrigin)
    case "existing_worktree":
      guard !trimmed(worktreePath).isEmpty else {
        throw T3Error("Enter a worktree path on the server.")
      }
      workspace["worktreePath"] = .string(trimmed(worktreePath))
    default: throw T3Error("Choose a supported workspace strategy.")
    }
    if !trimmed(branch).isEmpty { workspace["branch"] = .string(trimmed(branch)) }
    var payload: [String: JSON] = [
      "id": .string(id), "commandId": .string(commandID), "requireExisting": .bool(editing),
      "title": .string(trimmed(title)), "prompt": .string(trimmed(prompt)),
      "enabled": .bool(enabled),
      "schedule": schedule, "projectId": .string(projectID),
      "threadId": threadID.isEmpty ? .null : .string(threadID),
      "workspaceStrategy": .object(workspace), "modelSelection": model,
      "runtimeMode": .string(runtimeMode), "interactionMode": .string(interactionMode),
    ]
    // Omission preserves end conditions on servers with this contract, including past end dates.
    if !editing {
      payload["createdBy"] = .string("user")
      payload["creationSource"] = .string("web")
    }
    return .object(payload)
  }
}
