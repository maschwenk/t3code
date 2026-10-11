import Foundation

public struct ProposedPlan: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let runID: String?
  public let status: String
  public let markdown: String
  public let title: String
  public private(set) var updatedAt: String

  public init?(_ value: JSON, updatedAt: String) {
    guard value["kind"].string == "proposed_plan", let id = value["id"].string else { return nil }
    self.id = id
    runID = value["runId"].string
    status = value["status"].string ?? "draft"
    markdown = value["markdown"].string ?? ""
    title = Self.title(in: markdown)
    self.updatedAt = updatedAt
  }

  private static func title(in markdown: String) -> String {
    for line in markdown.components(separatedBy: .newlines) {
      guard line.range(of: #"^\s{0,3}#{1,6}\s+(.+)$"#, options: .regularExpression) != nil
      else { continue }
      let heading = line.replacingOccurrences(
        of: #"^\s{0,3}#{1,6}\s+"#, with: "", options: .regularExpression
      )
      .trimmingCharacters(in: .whitespacesAndNewlines)
      if !heading.isEmpty { return heading }
    }
    return "Plan"
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
        title: String(
          (plan.title == "Plan" ? "Implement plan" : "Implement " + plan.title).prefix(120)),
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
