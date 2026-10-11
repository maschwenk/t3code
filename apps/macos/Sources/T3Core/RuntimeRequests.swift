import Foundation

public struct QuestionDraft: Codable, Sendable, Equatable {
  public var selected: [String] = []
  public var custom = ""
  public init() {}

  public func answer(for question: JSON, attachmentCount: Int = 0, blocked: Bool = false) -> JSON? {
    guard !blocked else { return nil }
    let custom = custom.trimmingCharacters(in: .whitespacesAndNewlines)
    if question["allowCustomAnswer"] != .bool(false), !custom.isEmpty { return .string(custom) }
    let allowed = question["options"].array.compactMap { $0["value"].string ?? $0["label"].string }
    var seen = Set<String>()
    let selected = selected.filter { allowed.contains($0) && seen.insert($0).inserted }
    guard let first = selected.first else {
      return question["allowCustomAnswer"] != .bool(false) && attachmentCount > 0
        ? .string("") : nil
    }
    return question["multiSelect"].bool ? .array(selected.map(JSON.string)) : .string(first)
  }

  public static func attachmentKey(threadID: String, requestID: String, questionID: String)
    -> String
  {
    "question:"
      + (try! JSONEncoder().encode([threadID, requestID, questionID])).base64EncodedString()
  }
  public static func attachmentScope(_ key: String) -> (threadID: String, requestID: String)? {
    guard key.hasPrefix("question:"), let data = Data(base64Encoded: String(key.dropFirst(9))),
      let fields = try? JSONDecoder().decode([String].self, from: data), fields.count == 3
    else { return nil }
    return (fields[0], fields[1])
  }
}

public struct QuestionProgress: Equatable, Sendable {
  public let index: Int
  public let question: JSON
  public let answer: JSON?
  public let answers: JSON?
  public let answeredCount: Int
  public let isLast: Bool
  public init(
    questions: [JSON], drafts: [String: QuestionDraft], index: Int,
    attachmentCounts: [String: Int] = [:], blocked: Set<String> = []
  ) {
    self.index = min(max(0, index), max(0, questions.count - 1))
    question = questions.isEmpty ? .null : questions[self.index]
    var resolved: [String: JSON] = [:]
    for question in questions {
      guard let id = question["id"].string else { continue }
      resolved[id] = (drafts[id] ?? QuestionDraft()).answer(
        for: question, attachmentCount: attachmentCounts[id] ?? 0, blocked: blocked.contains(id))
    }
    answer = resolved[question["id"].string ?? ""]
    answeredCount = resolved.count
    answers = !questions.isEmpty && resolved.count == questions.count ? .object(resolved) : nil
    isLast = self.index == max(0, questions.count - 1)
  }
}

public struct PendingQuestionResponse: Codable, Sendable, Equatable {
  public let commandID: String
  public let threadID: String
  public let requestID: String
  public let answers: JSON
  public let attachments: [String: [DraftAttachment]]
  public init(
    threadID: String, requestID: String, answers: JSON,
    attachments: [String: [DraftAttachment]], commandID: String = UUID().uuidString
  ) {
    self.threadID = threadID
    self.requestID = requestID
    self.answers = answers
    self.attachments = attachments.filter { !$0.value.isEmpty }
    self.commandID = commandID
  }
  public var localAttachmentIDs: Set<String> { Set(attachments.values.flatMap { $0.map(\.id) }) }
  public func matches(answers: JSON, attachments: [String: [DraftAttachment]]) -> Bool {
    self.answers == answers
      && self.attachments.mapValues { $0.map(\.id) }
        == attachments.filter { !$0.value.isEmpty }.mapValues { $0.map(\.id) }
  }
  public var payload: JSON {
    var fields: [String: JSON] = [
      "type": .string("runtime-request.respond"), "commandId": .string(commandID),
      "threadId": .string(threadID), "requestId": .string(requestID), "answers": answers,
    ]
    if !attachments.isEmpty {
      fields["attachmentsByQuestionId"] = .object(
        attachments.mapValues { .array($0.compactMap(\.wire)) })
    }
    return .object(fields)
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
    QuestionProgress(questions: questions, drafts: drafts, index: 0).answers
  }
}
