import Foundation
import Testing

@testable import T3Core

private func questionsFixture() throws -> [JSON] {
  try JSONDecoder().decode(
    JSON.self,
    from: Data(
      #"""
      [
        {"id":"color","options":[{"label":"Blue","value":" blue "}],"allowCustomAnswer":false},
        {"id":"evidence","options":[],"multiSelect":true}
      ]
      """#.utf8)
  ).array
}

@Test func pagedQuestionsCountAttachmentOnlyAnswersAndBlockIncompleteUploads() throws {
  let questions = try questionsFixture()
  var color = QuestionDraft()
  color.selected = [" blue "]
  let drafts = ["color": color]
  let first = QuestionProgress(questions: questions, drafts: drafts, index: -3)
  #expect(first.index == 0 && first.answer == .string(" blue "))
  #expect(first.answeredCount == 1 && first.answers == nil && !first.isLast)
  let uploading = QuestionProgress(
    questions: questions, drafts: drafts, index: 1, attachmentCounts: ["evidence": 1],
    blocked: ["evidence"])
  #expect(uploading.answer == nil && uploading.answers == nil)
  let ready = QuestionProgress(
    questions: questions, drafts: drafts, index: 99, attachmentCounts: ["evidence": 1])
  #expect(ready.index == 1 && ready.isLast && ready.answeredCount == 2)
  #expect(ready.answers == .object(["color": .string(" blue "), "evidence": .string("")]))
  #expect(QuestionDraft().answer(for: questions[0], attachmentCount: 1) == nil)
  #expect(QuestionProgress(questions: [], drafts: [:], index: 3).answers == nil)
}

@Test func questionFilesAndResponseIdentitySurviveRestartWithoutUsingTheMessageDraft() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let source = root.appendingPathComponent("answer.txt")
  let bytes = Data("Question attachment content\n".utf8)
  try bytes.write(to: source)
  let endpoint = URL(string: "https://example.test")!
  let repository = DraftRepository(directory: root.appendingPathComponent("drafts"))
  let files = repository.attachmentRepository(for: endpoint)
  var attachment = try files.stage(source)
  attachment.uploadedID = "original-upload"
  try FileManager.default.removeItem(at: source)
  let key = QuestionDraft.attachmentKey(
    threadID: "thread", requestID: "request", questionID: "evidence")
  var draft = QuestionDraft()
  draft.custom = "Keep this answer"
  let response = PendingQuestionResponse(
    threadID: "thread", requestID: "request", answers: .object(["evidence": .string(draft.custom)]),
    attachments: ["evidence": [attachment]])
  try repository.save(
    SavedDrafts(
      messages: ["thread": "Separate unsent message"], questions: ["request": ["evidence": draft]],
      attachments: [key: [attachment]], questionPages: ["request": 1],
      questionResponses: ["request": response]), for: endpoint)
  let restored = try repository.load(for: endpoint)
  #expect(restored.messages["thread"] == "Separate unsent message")
  #expect(restored.questions["request"]?["evidence"] == draft)
  #expect(restored.questionPages?["request"] == 1)
  let retried = try #require(restored.questionResponses?["request"])
  #expect(retried.payload == response.payload)
  #expect(try Data(contentsOf: files.file(attachment)) == bytes)
  attachment.uploadedID = "replacement-upload"
  #expect(retried.matches(answers: response.answers, attachments: ["evidence": [attachment]]))
  #expect(
    retried.payload["attachmentsByQuestionId"]["evidence"].array.first?["id"].string
      == "original-upload")
  #expect(!retried.matches(answers: response.answers, attachments: [:]))
  #expect(
    key
      != QuestionDraft.attachmentKey(
        threadID: "other", requestID: "request", questionID: "evidence"))
  #expect(try repository.load(for: URL(string: "https://other.test")!).questionResponses == nil)
}
