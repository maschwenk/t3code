import Foundation
import Testing

@testable import T3Core

struct WorkspaceFilesTests {
  private func file(_ contents: String, path: String = "src/file.swift", truncated: Bool = false)
    throws
    -> WorkspaceFileDocument
  {
    try WorkspaceFileDocument(
      .object([
        "relativePath": .string(path), "contents": .string(contents),
        "byteLength": .number(Double(contents.utf8.count)), "truncated": .bool(truncated),
      ]))
  }

  @Test func saveConflictsAndLostRepliesPreserveEdits() throws {
    var document = try file("original\r\n🦉\n")
    document.contents = "my edit\r\n🦉\n"
    try document.validateSave(against: file("original\r\n🦉\n"))
    #expect(throws: T3Error.self) { try document.validateSave(against: file("agent edit")) }
    #expect(document.isDirty)
    try document.validateSave(against: file(document.contents))
    let submitted = document.contents
    document.contents += "more edits while saving"
    document.acknowledgeSave(submitted)
    #expect(document.isDirty)
    #expect(document.original == submitted)
    try document.validateSave(against: file(submitted))
    #expect(throws: T3Error.self) {
      try document.validateSave(against: file(submitted, truncated: true))
    }
    #expect(throws: T3Error.self) {
      try document.validateSave(against: file(submitted, path: "another.swift"))
    }
    for path in ["/etc/hosts", "../outside.txt", "src/../../outside.txt"] {
      let host = try file("text", path: path)
      #expect(throws: T3Error.self) { try host.validateSave(against: host) }
    }
  }

  @Test func folderEntriesStayImmediateAndNaturallyOrdered() throws {
    func entry(_ path: String, _ kind: String = "file", ignored: Bool = false) -> JSON {
      .object(["path": .string(path), "kind": .string(kind), "ignored": .bool(ignored)])
    }
    let result: JSON = .object([
      "entries": .array([
        entry("src/z.swift"), entry("src/folder", "directory"), entry("src/file10.swift"),
        entry("src/file2.swift", ignored: true), entry("src/folder/hidden.swift"),
        entry("src/file2.swift"), entry("other/file.swift"),
      ])
    ])
    let children = try WorkspaceEntry.entries(result, directory: "src")
    #expect(
      children.map(\.path) == ["src/folder", "src/file2.swift", "src/file10.swift", "src/z.swift"])
    #expect(children[1].ignored)
    let search = try WorkspaceEntry.entries(result)
    #expect(search.count == 6)
    #expect(search.contains { $0.path == "src/folder/hidden.swift" })
  }

  @Test func recoveryIsPrivateAndScopedToEnvironmentAndRoot() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = WorkspaceDraftRepository(directory: directory)
    #expect(try repository.load().isEmpty)
    func id(_ environment: String, root: String) throws -> WorkspaceFileID {
      let thread = try ThreadSummary(
        .object([
          "id": .string("thread"), "projectId": .string("project"), "title": .string("Test"),
        ]))
      let location = WorkspaceLocation(
        environment: environment, thread: thread,
        project: .object(["workspaceRoot": .string(root)]))!
      return WorkspaceFileID(location: location, path: "src/file.swift")
    }
    let first = try id("one", root: "/workspace")
    let otherServer = try id("two", root: "/workspace")
    let worktree = try id("one", root: "/worktree")
    var edited = try file("before")
    edited.contents = "saved locally\n日本語"
    try repository.save([first: edited, otherServer: edited, worktree: try file("clean")])
    #expect(try repository.load() == [first: edited, otherServer: edited])
    let mode =
      try FileManager.default.attributesOfItem(atPath: repository.file.path)[.posixPermissions]
      as? NSNumber
    #expect(mode?.intValue == 0o600)
    try repository.save([:])
    #expect(try repository.load().isEmpty)
    try Data("invalid recovery".utf8).write(to: repository.file)
    #expect(throws: (any Error).self) { try repository.load() }
    #expect(try String(contentsOf: repository.file, encoding: .utf8) == "invalid recovery")
  }
}

@Test func undoDuringAnUncertainSaveSurvivesRestart() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let repository = WorkspaceDraftRepository(directory: directory)
  let thread = try ThreadSummary(
    .object([
      "id": .string("thread"), "projectId": .string("project"), "title": .string("Test"),
    ]))
  let location = WorkspaceLocation(
    environment: "server", thread: thread,
    project: .object(["workspaceRoot": .string("/workspace")]))!
  let id = WorkspaceFileID(location: location, path: "file.txt")
  func document(_ text: String) throws -> WorkspaceFileDocument {
    try WorkspaceFileDocument(
      .object([
        "relativePath": .string("file.txt"), "contents": .string(text),
        "byteLength": .number(Double(text.utf8.count)), "truncated": .bool(false),
      ]))
  }
  var local = try document("original")
  local.contents = "first edit"
  local.recordSaveAttempt("first edit")
  local.contents = "original"
  #expect(!local.isDirty && local.requiresRecovery)
  try repository.save([id: local])
  var recovered = try #require(repository.load()[id])
  try recovered.validateSave(against: document("first edit"))
  #expect(recovered.contents == "original")
  #expect(throws: T3Error.self) {
    try recovered.validateSave(against: document("another client's edit"))
  }
  recovered.acknowledgeSave("first edit")
  recovered.recordSaveAttempt("original")
  try repository.save([id: recovered])
  recovered = try #require(repository.load()[id])
  try recovered.validateSave(against: document("original"))
  recovered.acknowledgeSave("original")
  #expect(!recovered.requiresRecovery)
  try repository.save([id: recovered])
  #expect(try repository.load().isEmpty)
}
