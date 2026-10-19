import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import T3Core

@Test func oldTextDraftsUpgradeWithoutDroppingMessagesOrRetryIDs() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let repository = DraftRepository(directory: root)
  let endpoint = URL(string: "https://example.test")!
  try repository.save(SavedDrafts(), for: endpoint)
  let old = Data(
    #"{"version":1,"messages":{"t":"keep me"},"questions":{},"submissions":{"t":{"text":"keep me","command":"stable-command","message":"stable-message"}}}"#
      .utf8)
  try old.write(to: repository.file(for: endpoint))
  let restored = try repository.load(for: endpoint)
  #expect(restored.messages["t"] == "keep me")
  #expect(restored.submissions["t"]?.command == "stable-command")
  #expect(restored.submissions["t"]?.matches(text: "keep me", attachments: []) == true)
  let saved = SavedDrafts(
    messages: restored.messages, submissions: restored.submissions, questions: restored.questions,
    attachments: [:])
  try repository.save(saved, for: endpoint)
  #expect(try repository.load(for: endpoint).version == 5)
  let future = Data(#"{"version":6,"messages":{},"questions":{},"submissions":{}}"#.utf8)
  try future.write(to: repository.file(for: endpoint))
  #expect(throws: T3Error.self) { try repository.load(for: endpoint) }
  #expect(try Data(contentsOf: repository.file(for: endpoint)) == future)
}

@Test func nativeImageConversionProducesProviderSupportedBytes() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let context = CGContext(
    data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
  let image = context.makeImage()!
  let source = root.appendingPathComponent("fixture.tiff")
  let output = CGImageDestinationCreateWithURL(
    source as CFURL, UTType.tiff.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(output, image, nil)
  #expect(CGImageDestinationFinalize(output))
  let repository = AttachmentRepository(directory: root.appendingPathComponent("copies"))
  let staged = try repository.stage(source)
  #expect(staged.name == "fixture.jpg")
  #expect(staged.type == "image")
  #expect(staged.mimeType == "image/jpeg")
  let converted = CGImageSourceCreateWithURL(try repository.file(staged) as CFURL, nil)!
  #expect(CGImageSourceGetType(converted) as String? == UTType.jpeg.identifier)
  let decoded = CGImageSourceCreateImageAtIndex(converted, 0, nil)
  #expect(decoded?.width == 16)
  #expect(decoded?.height == 16)
}

@Test func attachmentCopiesAndSendIdentitySurviveSourceRemovalAndRestart() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let source = root.appendingPathComponent("context.txt")
  let content = Data("Original attachment content\n".utf8)
  try content.write(to: source)
  let endpoint = URL(string: "https://example.test")!
  let drafts = DraftRepository(directory: root.appendingPathComponent("drafts"))
  let files = drafts.attachmentRepository(for: endpoint)
  var staged = try files.stage(source)
  try Data("Changed original".utf8).write(to: source)
  try FileManager.default.removeItem(at: source)
  #expect(try Data(contentsOf: files.file(staged)) == content)
  #expect(
    try FileManager.default.attributesOfItem(atPath: files.file(staged).path)[.posixPermissions]
      as? Int == 0o600)
  staged.uploadedID = "pending_file_123"
  let submission = PendingSubmission(
    text: "", attachments: [staged.wire!], localAttachmentIDs: [staged.id])
  try drafts.save(
    SavedDrafts(submissions: ["thread": submission], attachments: ["thread": [staged]]),
    for: endpoint)
  let restored = try drafts.load(for: endpoint)
  #expect(restored.attachments?["thread"] == [staged])
  #expect(restored.submissions["thread"] == submission)
  #expect(submission.matches(text: "", attachments: [staged]))
  #expect(!submission.matches(text: "changed", attachments: [staged]))
  #expect(!submission.matches(text: "", attachments: []))
  var refreshed = staged
  refreshed.uploadedID = "different_upload"
  #expect(submission.attachments == [staged.wire!])
  #expect(submission.attachments != [refreshed.wire!])
  #expect(
    Commands.message(
      threadID: "thread", text: "", commandID: submission.command,
      messageID: submission.message, attachments: submission.attachments!)["attachments"]
      == .array([staged.wire!]))
  #expect(try drafts.load(for: URL(string: "https://other.test")!).attachments == nil)
  files.remove(staged)
  #expect(!FileManager.default.fileExists(atPath: try files.file(staged).path))
}

@Test func attachmentLimitsRespectServerCapabilitiesAndAggregateImageBytes() throws {
  func attachment(_ type: String, _ size: Int) -> DraftAttachment {
    DraftAttachment(
      id: UUID().uuidString, name: "example",
      mimeType: type == "image" ? "image/png" : "text/plain", sizeBytes: size, type: type)
  }
  let policy = AttachmentPolicy(
    .object([
      "attachmentUploads": .bool(true),
      "fileAttachments": .object(["maxUploadBytes": .number(1024)]),
    ]))
  try policy.validate([attachment("file", 1024)])
  #expect(throws: T3Error.self) { try policy.validate([attachment("file", 1025)]) }
  #expect(throws: T3Error.self) { try policy.validate([attachment("file", 0)]) }
  #expect(throws: T3Error.self) { try AttachmentPolicy().validate([attachment("image", 1)]) }
  try policy.validate(Array(repeating: attachment("image", AttachmentPolicy.imageLimit), count: 8))
  #expect(throws: T3Error.self) {
    try policy.validate(
      Array(repeating: attachment("image", AttachmentPolicy.imageLimit), count: 9))
  }
  #expect(throws: T3Error.self) {
    try policy.validate(Array(repeating: attachment("file", 1), count: 101))
  }
  #expect(throws: T3Error.self) {
    try policy.validate([attachment("image", AttachmentPolicy.imageLimit + 1)])
  }
  #expect(
    AttachmentPolicy(
      .object(["fileAttachments": .object(["maxUploadBytes": .number(999_999_999)])])
    ).fileBytes == AttachmentPolicy.fileLimit)
}

@Test func attachmentStagingRejectsDirectoriesEmptyFilesAndUnsafeLocalIDs() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let files = AttachmentRepository(directory: root.appendingPathComponent("copies"))
  #expect(throws: T3Error.self) { try files.stage(root) }
  let empty = root.appendingPathComponent("empty.txt")
  try Data().write(to: empty)
  #expect(throws: T3Error.self) { try files.stage(empty) }
  let unsafe = DraftAttachment(
    id: "../source", name: "source", mimeType: "text/plain", sizeBytes: 1, type: "file")
  #expect(throws: T3Error.self) { try files.file(unsafe) }
}

@Test func signedAttachmentURLsCannotSendBytesToAnotherOrigin() throws {
  let endpoint = URL(string: "https://example.test")!
  let prefix = "/api/attachments/upload/"
  #expect(
    try AttachmentHTTP.signedURL(prefix + "signed.token", endpoint: endpoint, prefix: prefix)
      .absoluteString == "https://example.test/api/attachments/upload/signed.token")
  for value in [
    "https://other.test" + prefix + "token", "//other.test" + prefix + "token", "/oauth/token",
    prefix + "../secret", prefix + "%2E%2E/secret", "file:///tmp/upload",
  ] {
    #expect(throws: T3Error.self) {
      try AttachmentHTTP.signedURL(value, endpoint: endpoint, prefix: prefix)
    }
  }
  let failure: JSON = .object([
    "cause": .object([
      "reasons": .array([
        .object([
          "_tag": .string("Fail"),
          "error": .object(["_tag": .string("AssetAttachmentNotFoundError")]),
        ])
      ])
    ])
  ])
  #expect(RPCConnection.failureCode(failure) == "AssetAttachmentNotFoundError")
  #expect(RPCConnection.failureCode(.object(["message": .string("offline")])) == nil)
}
