import Foundation

public struct ProposedPlan: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let runID: String?
  public let status: String
  public let markdown: String
  public let heading: String?
  public let title: String
  public private(set) var updatedAt: String

  public init?(_ value: JSON, updatedAt: String) {
    guard value["kind"].string == "proposed_plan", let id = value["id"].string else { return nil }
    self.id = id
    runID = value["runId"].string
    status = value["status"].string ?? "draft"
    markdown = value["markdown"].string ?? ""
    heading =
      markdown.components(separatedBy: .newlines).lazy.compactMap(PlanDocument.heading).first
    title = heading ?? "Plan"
    self.updatedAt = updatedAt
  }

  public var implementationPrompt: String {
    "PLEASE IMPLEMENT THIS PLAN:\n" + markdown.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  mutating func updateTime(_ time: String) { updatedAt = time }

  public static func latest(_ plans: [ProposedPlan], runID: String?) -> ProposedPlan? {
    let matching = runID.map { id in plans.filter { $0.runID == id } } ?? []
    return (matching.isEmpty ? plans : matching).max {
      ($0.updatedAt, $0.id) < ($1.updatedAt, $1.id)
    }
  }
}

/// Freeze both steps before dispatch: retrying after a lost acknowledgement must not create
/// another thread or implementation message, even after the first step changes plan mode.
public struct PendingPlanSubmission: Codable, Equatable, Sendable {
  public let sourceThreadID: String
  public let targetThreadID: String
  public let plan: ProposedPlan
  public let draft: String
  public let setup: JSON
  public let message: JSON
  public var isNewThread: Bool { targetThreadID != sourceThreadID }
  public var isImplementation: Bool { message["sourcePlanRef"] != .null }

  public init(
    plan: ProposedPlan, template: ThreadSummary, draft: String, newThread: Bool,
    defaultRuntimeMode: String
  ) {
    self.plan = plan
    self.draft = draft
    sourceThreadID = template.id
    targetThreadID = newThread ? UUID().uuidString : template.id
    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    let implementing = newThread || trimmed.isEmpty
    let mode = implementing ? "default" : "plan"
    if newThread {
      setup = Commands.newThread(
        template: template, id: targetThreadID,
        title: String((plan.heading.map { "Implement " + $0 } ?? "Implement plan").prefix(120)),
        runtimeMode: defaultRuntimeMode, interactionMode: mode, inheritWorkspace: true)
    } else {
      setup = .object([
        "type": .string("thread.interaction-mode.set"), "commandId": .string(UUID().uuidString),
        "threadId": .string(template.id), "interactionMode": .string(mode),
      ])
    }
    message = Commands.message(
      threadID: targetThreadID, text: implementing ? plan.implementationPrompt : trimmed,
      commandID: UUID().uuidString, messageID: UUID().uuidString,
      sourcePlanRef: implementing
        ? .object(["threadId": .string(template.id), "planId": .string(plan.id)]) : nil,
      modelSelection: template.model)
  }
}
