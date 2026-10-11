import Foundation
import Testing

@testable import T3Core

@Test func draftsAndRetryIdentitySurviveRestartWithoutCrossingEnvironments() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let repository = DraftRepository(directory: directory)
  let local = URL(string: "http://127.0.0.1:4773")!
  let other = URL(string: "http://127.0.0.1:3773")!
  var answer = QuestionDraft()
  answer.selected = ["first", " second "]
  let pending = PendingSubmission(text: "A possibly accepted message")
  let saved = SavedDrafts(
    messages: ["same-thread-id": pending.text], submissions: ["same-thread-id": pending],
    questions: ["request": ["question": answer]])
  try repository.save(saved, for: local)
  let reopened = DraftRepository(directory: directory)
  #expect(try reopened.load(for: local) == saved)
  #expect(try reopened.load(for: other) == SavedDrafts())
  let permission =
    try FileManager.default.attributesOfItem(atPath: repository.file(for: local).path)[
      .posixPermissions] as? Int
  #expect(permission == 0o600)
  let directoryPermission =
    try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
  #expect(directoryPermission == 0o700)
  try repository.save(SavedDrafts(), for: local)
  #expect(try reopened.load(for: local).messages.isEmpty)
  #expect(try reopened.load(for: local).submissions.isEmpty)
}

@Test func malformedDraftFileIsPreservedForRecovery() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let repository = DraftRepository(directory: directory)
  let endpoint = URL(string: "https://example.test")!
  try repository.save(SavedDrafts(), for: endpoint)
  let data = Data("{unfinished".utf8)
  try data.write(to: repository.file(for: endpoint))
  #expect(throws: (any Error).self) { try repository.load(for: endpoint) }
  #expect(try Data(contentsOf: repository.file(for: endpoint)) == data)
  #expect(
    repository.file(for: endpoint)
      == repository.file(for: URL(string: "https://EXAMPLE.test:443/")!))
}
