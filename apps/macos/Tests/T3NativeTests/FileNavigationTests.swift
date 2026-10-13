import Foundation
import T3Core
import Testing

@testable import T3Native

@MainActor @Test func fileRevealsUseRecoveredTextAndDoNotFollowTheUserToAnotherFile() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = ClientStore(draftDirectory: directory.appendingPathComponent("chat"))
  let thread: JSON = .object([
    "id": .string("t"), "projectId": .string("p"), "title": .string("Navigation"),
    "worktreePath": .string("/repo"),
  ])
  try store.shell.apply(
    .object([
      "kind": .string("snapshot"),
      "snapshot": .object([
        "snapshotSequence": .number(1), "threads": .array([thread]),
      ]),
    ]))
  store.selectedID = "t"
  let location = try #require(store.workspaceLocation)
  var documents: [WorkspaceFileID: WorkspaceFileDocument] = [:]
  for path in ["first.md", "second.md"] {
    var document = try WorkspaceFileDocument(
      .object([
        "relativePath": .string(path), "contents": .string("Original\n"), "byteLength": .number(9),
      ]))
    document.contents = "First line\r\nUnsaved edit\r\n"
    documents[WorkspaceFileID(location: location, path: path)] = document
  }
  let drafts = directory.appendingPathComponent("files")
  try WorkspaceDraftRepository(directory: drafts).save(documents)
  let files = WorkspaceFiles(store: store, directory: drafts)
  files.refreshContext()
  files.open("first.md", position: FileSourcePosition(line: 2))
  let first = try #require(files.revealRequest)
  let text = try #require(files.document?.contents)
  #expect((text as NSString).substring(with: first.position.range(in: text)) == "Unsaved edit")
  files.open("first.md", position: FileSourcePosition(line: 1))
  #expect(files.revealRequest?.id != first.id)
  #expect(files.revealRequest?.position.line == 1)
  files.open("second.md")
  #expect(files.revealRequest == nil)
  #expect(files.document?.contents == text)
  files.open("second.md", position: FileSourcePosition(line: 2, column: 3))
  #expect(files.revealRequest?.file.path == "second.md")
  store.selectedID = nil
  files.refreshContext()
  #expect(files.revealRequest == nil)
  #expect(files.document == nil)
}
