import Foundation

public struct NewThreadConfiguration: Sendable, Equatable {
  public let projectID: String
  public let model: JSON
  public let runtimeMode: String
  public let interactionMode: String

  public func command(id: String) -> JSON {
    .object([
      "type": .string("thread.create"), "commandId": .string(UUID().uuidString),
      "threadId": .string(id), "projectId": .string(projectID), "title": .string("New thread"),
      "modelSelection": model, "runtimeMode": .string(runtimeMode),
      "interactionMode": .string(interactionMode), "branch": .null, "worktreePath": .null,
      "createdBy": .string("user"), "creationSource": .string("web"),
    ])
  }
}
