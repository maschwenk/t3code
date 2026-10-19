import Foundation
import ImageIO

public struct AttachmentPreviewRequest: Sendable {
  public enum Key: Hashable, Sendable {
    case local(URL)
    case remote(environment: String, attachmentID: String)
  }
  public let key: Key
  public let name: String
  public let load: @Sendable (URL) async throws -> Void

  public init(key: Key, name: String, load: @escaping @Sendable (URL) async throws -> Void) {
    self.key = key
    self.name = name
    self.load = load
  }

  public static func local(_ url: URL, name: String) -> Self {
    Self(key: .local(url), name: name) { destination in
      try FileManager.default.copyItem(at: url, to: destination)
    }
  }

  public static func remote(
    _ attachment: JSON, connection: RPCConnection, settings: ConnectionSettings
  ) throws -> Self {
    Self(
      key: .remote(
        environment: settings.endpoint.absoluteString,
        attachmentID: try attachment.requiredString("id")),
      name: attachment["name"].string ?? "Attachment"
    ) { destination in
      let issued = try await connection.call(
        "assets.createUrl",
        payload: .object([
          "resource": .object([
            "_tag": .string("attachment"), "attachmentId": attachment["id"],
            "fileName": attachment["name"], "mimeType": attachment["mimeType"],
          ])
        ]))
      let url = try AttachmentHTTP.signedURL(
        issued.requiredString("relativeUrl"), endpoint: settings.endpoint, prefix: "/api/assets/")
      try await AttachmentHTTP.download(url, to: destination)
    }
  }
}

private final class PreviewDirectory: Sendable {
  let url: URL
  init(_ url: URL) { self.url = url }
  deinit { try? FileManager.default.removeItem(at: url) }
}

/// A visible preview keeps its private file alive even after cache eviction.
public final class AttachmentPreviewFile: Sendable {
  public let url: URL
  public let sizeBytes: Int
  private let directory: PreviewDirectory
  private let root: PreviewDirectory
  fileprivate init(url: URL, sizeBytes: Int, directory: PreviewDirectory, root: PreviewDirectory) {
    self.url = url
    self.sizeBytes = sizeBytes
    self.directory = directory
    self.root = root
  }

  public func save(to destination: URL) async throws {
    try Data(contentsOf: url, options: .mappedIfSafe).write(to: destination, options: .atomic)
  }
}

public actor AttachmentPreviewCache {
  private struct Entry {
    var file: AttachmentPreviewFile
    var thumbnail: CGImage?
    var used: UInt64
  }
  private let root: PreviewDirectory
  private let byteLimit: Int
  private let countLimit: Int
  private var entries: [AttachmentPreviewRequest.Key: Entry] = [:]
  private var jobs: [AttachmentPreviewRequest.Key: Task<AttachmentPreviewFile, Error>] = [:]
  private var clock: UInt64 = 0
  private var active = 0
  private var waiting: [CheckedContinuation<Void, Never>] = []

  public init(directory: URL? = nil, byteLimit: Int = 128 * 1024 * 1024, countLimit: Int = 64) {
    root = PreviewDirectory(
      (directory ?? FileManager.default.temporaryDirectory)
        .appendingPathComponent("t3-previews-" + UUID().uuidString))
    self.byteLimit = max(AttachmentPolicy.fileLimit, byteLimit)
    self.countLimit = max(1, countLimit)
  }

  public func file(for request: AttachmentPreviewRequest) async throws -> AttachmentPreviewFile {
    try Task.checkCancellation()
    clock &+= 1
    if var entry = entries[request.key] {
      entry.used = clock
      entries[request.key] = entry
      return entry.file
    }
    if let job = jobs[request.key] { return try await job.value }
    guard jobs.count < 32 else { throw T3Error("Other previews are loading. Try again shortly.") }
    let job = Task { try await self.load(request) }
    jobs[request.key] = job
    return try await job.value
  }

  public func thumbnail(for request: AttachmentPreviewRequest) async throws -> CGImage {
    let file = try await file(for: request)
    try Task.checkCancellation()
    if let thumbnail = entries[request.key]?.thumbnail { return thumbnail }
    guard
      let source = CGImageSourceCreateWithURL(
        file.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceShouldCacheImmediately: true,
          kCGImageSourceThumbnailMaxPixelSize: 512,
        ] as CFDictionary)
    else { throw T3Error("This image could not be previewed. You can still download the file.") }
    entries[request.key]?.thumbnail = image
    return image
  }

  private func load(_ request: AttachmentPreviewRequest) async throws -> AttachmentPreviewFile {
    if active >= 2 {
      await withCheckedContinuation { waiting.append($0) }
    } else {
      active += 1
    }
    defer {
      jobs.removeValue(forKey: request.key)
      if waiting.isEmpty { active -= 1 } else { waiting.removeFirst().resume() }
    }
    try Task.checkCancellation()
    let directory = PreviewDirectory(root.url.appendingPathComponent(UUID().uuidString))
    try FileManager.default.createDirectory(
      at: root.url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.createDirectory(
      at: directory.url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let component = (request.name as NSString).lastPathComponent
    let cleaned = String(
      component.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
    let name =
      cleaned.isEmpty || cleaned == "." || cleaned == ".."
      ? "Attachment" : String(cleaned.prefix(240))
    let url = directory.url.appendingPathComponent(name)
    try await request.load(url)
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true, let size = values.fileSize,
      size > 0, size <= AttachmentPolicy.fileLimit
    else {
      throw T3Error("This file cannot be previewed. It must contain between 1 byte and 50 MiB.")
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    let file = AttachmentPreviewFile(url: url, sizeBytes: size, directory: directory, root: root)
    clock &+= 1
    entries[request.key] = Entry(file: file, used: clock)
    var bytes = entries.values.reduce(0) { $0 + $1.file.sizeBytes }
    while entries.count > countLimit || bytes > byteLimit {
      guard let oldest = entries.min(by: { $0.value.used < $1.value.used }) else { break }
      bytes -= oldest.value.file.sizeBytes
      entries.removeValue(forKey: oldest.key)
    }
    return file
  }
}
