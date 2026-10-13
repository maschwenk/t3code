import Foundation

public struct NewConversationDraft: Codable, Sendable, Equatable {
  public let id: String
  public var project: JSON
  public var model: JSON
  public var runtimeMode: String
  public var interactionMode: String
  public var workspaceMode: String
  public var branch: String?
  public let createdAt: String

  public init(project: JSON, configuration: NewThreadConfiguration, workspaceMode: String = "local")
  {
    id = UUID().uuidString
    self.project = project
    model = configuration.model
    runtimeMode = configuration.runtimeMode
    interactionMode = configuration.interactionMode
    self.workspaceMode = workspaceMode
    branch = nil
    createdAt = ISO8601DateFormatter().string(from: Date())
  }

  public var summary: ThreadSummary? {
    try? ThreadSummary(
      .object([
        "id": .string(id), "projectId": project["id"], "title": .string("New conversation"),
        "createdAt": .string(createdAt),
        "updatedAt": .string(createdAt), "modelSelection": model,
        "runtimeMode": .string(runtimeMode), "interactionMode": .string(interactionMode),
        "branch": branch.map(JSON.string) ?? .null,
      ]))
  }

  public func launch(_ submission: PendingSubmission) throws -> JSON {
    let strategy: JSON
    if workspaceMode == "worktree" {
      guard let branch, !branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw T3Error("Select a base branch before starting in a new worktree.")
      }
      strategy = .object(["type": .string("worktree"), "baseRef": .string(branch)])
    } else {
      var fields: [String: JSON] = ["type": .string("root")]
      if let branch { fields["branch"] = .string(branch) }
      strategy = .object(fields)
    }
    let title = String(submission.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
    return .object([
      "commandId": .string(submission.command), "threadId": .string(id),
      "creationSource": .string("web"), "projectId": project["id"],
      "title": .string(title.isEmpty ? "New conversation" : title), "generateTitle": .bool(true),
      "modelSelection": model, "runtimeMode": .string(runtimeMode),
      "interactionMode": .string(interactionMode), "workspaceStrategy": strategy,
      "initialMessage": .object([
        "messageId": .string(submission.message), "text": .string(submission.text),
        "attachments": .array(submission.attachments ?? []),
      ]),
    ])
  }
}
