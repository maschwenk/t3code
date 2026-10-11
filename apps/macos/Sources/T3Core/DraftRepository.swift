import CryptoKit
import Foundation

public struct PendingSubmission: Codable, Sendable, Equatable {
  public let text: String
  public let command: String
  public let message: String
  public let attachments: [JSON]?
  public let localAttachmentIDs: [String]?
  public init(
    text: String, command: String = UUID().uuidString, message: String = UUID().uuidString,
    attachments: [JSON]? = nil, localAttachmentIDs: [String]? = nil
  ) {
    self.text = text
    self.command = command
    self.message = message
    self.attachments = attachments
    self.localAttachmentIDs = localAttachmentIDs
  }
  public func matches(text: String, attachments: [DraftAttachment]) -> Bool {
    self.text == text && (localAttachmentIDs ?? []) == attachments.map(\.id)
  }
}

public struct SavedDrafts: Codable, Sendable, Equatable {
  public var version = 2
  public var messages: [String: String] = [:]
  public var submissions: [String: PendingSubmission] = [:]
  public var questions: [String: [String: QuestionDraft]] = [:]
  public var attachments: [String: [DraftAttachment]]?
  public init(
    messages: [String: String] = [:], submissions: [String: PendingSubmission] = [:],
    questions: [String: [String: QuestionDraft]] = [:],
    attachments: [String: [DraftAttachment]]? = nil
  ) {
    self.messages = messages
    self.submissions = submissions
    self.questions = questions
    self.attachments = attachments
  }
}

public struct DraftRepository: Sendable {
  public let directory: URL
  public init(directory: URL) { self.directory = directory }

  public func attachmentRepository(for endpoint: URL) -> AttachmentRepository {
    AttachmentRepository(
      directory: file(for: endpoint).deletingPathExtension().appendingPathComponent("Attachments"))
  }

  public func file(for endpoint: URL) -> URL {
    var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
    parts.path = ""
    parts.host = parts.host?.lowercased()
    if (parts.scheme == "https" && parts.port == 443)
      || (parts.scheme == "http" && parts.port == 80)
    {
      parts.port = nil
    }
    let key = SHA256.hash(data: Data(parts.string!.utf8)).map { String(format: "%02x", $0) }
      .joined()
    return directory.appendingPathComponent(key + ".json")
  }

  public func load(for endpoint: URL) throws -> SavedDrafts {
    let file = file(for: endpoint)
    guard FileManager.default.fileExists(atPath: file.path) else { return SavedDrafts() }
    let drafts = try JSONDecoder().decode(SavedDrafts.self, from: Data(contentsOf: file))
    guard (1...2).contains(drafts.version) else {
      throw T3Error("The saved drafts use a newer format.")
    }
    return drafts
  }

  public func save(_ drafts: SavedDrafts, for endpoint: URL) throws {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let file = file(for: endpoint)
    try JSONEncoder().encode(drafts).write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  }
}
