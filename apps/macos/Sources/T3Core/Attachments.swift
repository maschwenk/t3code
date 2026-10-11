import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct DraftAttachment: Codable, Sendable, Equatable, Identifiable {
  public let id: String
  public let name: String
  public let mimeType: String
  public let sizeBytes: Int
  public let type: String
  public var uploadedID: String?

  public var uploadInput: JSON {
    .object([
      "type": .string(type), "name": .string(name), "mimeType": .string(mimeType),
      "sizeBytes": .number(Double(sizeBytes)),
    ])
  }
  public var wire: JSON? {
    guard let uploadedID, case .object(var fields) = uploadInput else { return nil }
    fields["id"] = .string(uploadedID)
    return .object(fields)
  }
}

public struct AttachmentPolicy: Sendable, Equatable {
  public static let imageLimit = 10 * 1024 * 1024
  public static let fileLimit = 50 * 1024 * 1024
  public var uploads = false
  public var questions = false
  public var fileBytes: Int?
  public init(_ capabilities: JSON = .null) {
    uploads = capabilities["attachmentUploads"].bool
    questions = capabilities["questionAttachments"].bool
    fileBytes = capabilities["fileAttachments"]["maxUploadBytes"].int.map {
      min($0, Self.fileLimit)
    }
  }
  public func validate(
    _ attachments: [DraftAttachment], requireServer: Bool = true, retained: [JSON] = []
  ) throws {
    let newCount = attachments.count
    let attachments =
      attachments
      + retained.map {
        DraftAttachment(
          id: $0["id"].string ?? "", name: $0["name"].string ?? "Attachment",
          mimeType: $0["mimeType"].string ?? "", sizeBytes: $0["sizeBytes"].int ?? 0,
          type: $0["type"].string ?? "file")
      }
    guard attachments.count <= 100 else {
      throw T3Error("You can attach up to 100 files per message.")
    }
    guard
      attachments.filter({ $0.type == "image" }).reduce(0, { $0 + $1.sizeBytes }) <= 80 * 1024
        * 1024
    else {
      throw T3Error("Images can total up to 80 MiB per message. Send fewer or smaller images.")
    }
    if requireServer, newCount > 0, !uploads {
      throw T3Error("This server does not accept attachment uploads right now.")
    }
    for (index, attachment) in attachments.enumerated() {
      let requiresUpload = requireServer && index < newCount
      if requiresUpload, attachment.type == "file", fileBytes == nil {
        throw T3Error(
          "This server does not accept file attachments right now. Remove the files to send.")
      }
      let limit =
        attachment.type == "image"
        ? Self.imageLimit : requiresUpload ? fileBytes ?? 0 : Self.fileLimit
      guard attachment.sizeBytes > 0, attachment.sizeBytes <= limit else {
        throw T3Error(
          "\(attachment.name) exceeds the attachment limit (\(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)))."
        )
      }
    }
  }
}

/// Immutable private copies keep drafts independent of moved or edited source files.
public struct AttachmentRepository: Sendable {
  public let directory: URL
  public init(directory: URL) { self.directory = directory }

  public func file(_ attachment: DraftAttachment) throws -> URL {
    guard UUID(uuidString: attachment.id) != nil else {
      throw T3Error("Invalid local attachment ID.")
    }
    return directory.appendingPathComponent(attachment.id)
  }

  public func stage(_ source: URL) throws -> DraftAttachment {
    let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard source.isFileURL, values.isRegularFile == true else {
      throw T3Error("Choose files, not folders.")
    }
    guard let size = values.fileSize, size > 0, size <= AttachmentPolicy.fileLimit else {
      throw T3Error("\(source.lastPathComponent) must contain between 1 byte and 50 MiB.")
    }
    var name = String(source.lastPathComponent.prefix(255))
    let contentType = UTType(filenameExtension: source.pathExtension)
    var mime = contentType?.preferredMIMEType ?? "application/octet-stream"
    let isImage = contentType?.conforms(to: .image) == true
    let supported = ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(mime)
    let convertible = ["heic", "heif", "tif", "tiff"].contains(source.pathExtension.lowercased())
    if isImage && !supported && !convertible {
      throw T3Error("\(name) is not a supported image. Use PNG, JPEG, GIF, WebP, HEIC, or TIFF.")
    }
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let id = UUID().uuidString
    let destination = directory.appendingPathComponent(id)
    do {
      if isImage && (convertible || size > AttachmentPolicy.imageLimit) {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(
            imageSource, 0,
            [
              kCGImageSourceCreateThumbnailFromImageAlways: true,
              kCGImageSourceCreateThumbnailWithTransform: true,
              kCGImageSourceThumbnailMaxPixelSize: 2048,
            ] as CFDictionary),
          let output = CGImageDestinationCreateWithURL(
            destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw T3Error("Could not read \(name) as an image.") }
        CGImageDestinationAddImage(
          output, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(output) else {
          throw T3Error("Could not convert \(name).")
        }
        mime = "image/jpeg"
        name = String(source.deletingPathExtension().lastPathComponent.prefix(250)) + ".jpg"
      } else {
        try FileManager.default.copyItem(at: source, to: destination)
      }
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: destination.path)
      let copiedSize = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      let result = DraftAttachment(
        id: id, name: name, mimeType: mime, sizeBytes: copiedSize,
        type: isImage ? "image" : "file")
      try AttachmentPolicy().validate([result], requireServer: false)
      return result
    } catch {
      try? FileManager.default.removeItem(at: destination)
      throw error
    }
  }

  public func remove(_ attachment: DraftAttachment) {
    if let url = try? file(attachment) { try? FileManager.default.removeItem(at: url) }
  }
}

private final class AttachmentTransferDelegate: NSObject, URLSessionTaskDelegate,
  @unchecked Sendable
{
  let progress: @Sendable (Double) -> Void
  private let lock = NSLock()
  private var lastProgress = -1
  init(progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }
  func urlSession(
    _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
    totalBytesSent: Int64, totalBytesExpectedToSend: Int64
  ) {
    guard totalBytesExpectedToSend > 0 else { return }
    let step = Int(Double(totalBytesSent) / Double(totalBytesExpectedToSend) * 20)
    let changed = lock.withLock {
      guard step != lastProgress else { return false }
      lastProgress = step
      return true
    }
    if changed { progress(Double(step) / 20) }
  }
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

public enum AttachmentHTTP {
  public static func signedURL(_ relative: String, endpoint: URL, prefix: String) throws -> URL {
    guard let parts = URLComponents(string: relative), parts.scheme == nil, parts.host == nil,
      parts.user == nil, parts.password == nil, parts.fragment == nil,
      parts.path.hasPrefix(prefix), !parts.path.contains(".."),
      let url = URL(string: relative, relativeTo: endpoint)?.absoluteURL,
      url.scheme == endpoint.scheme, url.host == endpoint.host, url.port == endpoint.port
    else { throw T3Error("The server returned an invalid attachment address.") }
    return url
  }
  public static func upload(
    _ attachment: DraftAttachment, from file: URL, to url: URL,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws {
    guard try file.resourceValues(forKeys: [.fileSizeKey]).fileSize == attachment.sizeBytes else {
      throw T3Error("The saved attachment is missing or changed. Remove it and attach it again.")
    }
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 120
    request.setValue(attachment.mimeType, forHTTPHeaderField: "Content-Type")
    let (_, response) = try await session.upload(
      for: request, fromFile: file,
      delegate: AttachmentTransferDelegate(progress: progress))
    guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode)
    else {
      throw T3Error("Attachment upload failed. Retry the upload or remove the file.")
    }
  }

  public static func download(
    _ url: URL, to destination: URL, maximumBytes: Int? = AttachmentPolicy.fileLimit
  ) async throws {
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let (temporary, response) = try await session.download(
      for: URLRequest(url: url),
      delegate: AttachmentTransferDelegate(progress: { _ in }))
    guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode)
    else {
      throw T3Error("The attachment could not be downloaded. Try again when connected.")
    }
    defer { try? FileManager.default.removeItem(at: temporary) }
    guard let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize,
      maximumBytes.map({ size <= $0 }) ?? true
    else { throw T3Error("The attachment exceeds the download limit.") }
    let staging = destination.deletingLastPathComponent().appendingPathComponent(
      ".t3-download-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: staging) }
    try FileManager.default.copyItem(at: temporary, to: staging)
    if FileManager.default.fileExists(atPath: destination.path) {
      _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
    } else {
      try FileManager.default.moveItem(at: staging, to: destination)
    }
  }
}
