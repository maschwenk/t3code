import Foundation

public struct QuestionDraft: Sendable, Equatable {
  public var selected: [String] = []
  public var custom = ""
  public init() {}

  public func answer(for question: JSON) -> JSON? {
    let custom = custom.trimmingCharacters(in: .whitespacesAndNewlines)
    if question["allowCustomAnswer"] != .bool(false), !custom.isEmpty { return .string(custom) }
    let allowed = question["options"].array.compactMap { $0["value"].string ?? $0["label"].string }
    var seen = Set<String>()
    let selected = selected.filter { allowed.contains($0) && seen.insert($0).inserted }
    guard let first = selected.first else { return nil }
    return question["multiSelect"].bool ? .array(selected.map(JSON.string)) : .string(first)
  }
}

public struct PendingRequest: Sendable, Equatable, Identifiable {
  public let id: String
  public let kind: String
  public let capability: String
  public let reason: String?
  public let createdAt: String
  public let item: JSON
  public var isQuestion: Bool { kind == "user_input" }
  public var canRespond: Bool {
    isQuestion
      ? ["live", "message"].contains(capability)
      : capability == "live"
        && ["command", "file-read", "file-change", "apply-patch", "permission", "mcp-elicitation"]
          .contains(kind)
  }
  public var dismissible: Bool {
    isQuestion && (capability == "message" || item["responseMode"].string == "message")
  }
  public var questions: [JSON] { item["questions"].array }
  public var title: String {
    switch kind {
    case "user_input": "Question from the agent"
    case "command": "Command approval"
    case "file-read": "File read approval"
    case "permission": "Permission approval"
    case "mcp-elicitation": "App access approval"
    default: "File change approval"
    }
  }
  public var detail: String { item["prompt"].string ?? item["appName"].string ?? title }
  public var options: [JSON] {
    if case .array(let options) = item["options"] { return options }
    return [
      ("decline", "Decline"), ("accept", "Approve"),
      ("acceptForSession", "Always allow this session"), ("cancel", "Cancel"),
    ].map { .object(["decision": .string($0.0), "label": .string($0.1)]) }
  }

  public init(request: JSON, item: JSON) throws {
    id = try request.requiredString("id")
    kind = try request.requiredString("kind")
    capability = request["responseCapability"]["type"].string ?? "not_resumable"
    reason = request["responseCapability"]["reason"].string
    createdAt = request["createdAt"].string ?? ""
    self.item = item
  }

  public func answers(from drafts: [String: QuestionDraft]) -> JSON? {
    var answers: [String: JSON] = [:]
    for question in questions {
      guard let id = question["id"].string,
        let answer = (drafts[id] ?? QuestionDraft()).answer(for: question)
      else { return nil }
      answers[id] = answer
    }
    return questions.isEmpty ? nil : .object(answers)
  }
}
