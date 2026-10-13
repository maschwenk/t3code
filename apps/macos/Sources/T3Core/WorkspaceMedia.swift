import Foundation

public enum WorkspaceMediaKind: String, Sendable {
  case image, audio, video, pdf, html
  public init?(path: String) {
    switch (path as NSString).pathExtension.lowercased() {
    case "avif", "gif", "ico", "jpeg", "jpg", "png", "svg", "webp": self = .image
    case "mp3", "wav", "ogg", "oga", "flac", "aac", "m4a", "opus", "aiff": self = .audio
    case "avi", "m4v", "mkv", "mov", "mp4", "ogv", "webm": self = .video
    case "pdf": self = .pdf
    case "htm", "html": self = .html
    default: return nil
    }
  }
  public var playable: Bool { self == .audio || self == .video }
}

public struct WorkspaceMediaRequest: Sendable {
  public struct Key: Equatable, Sendable {
    public let file: WorkspaceFileID
    public let threadID: String
    public let connection: UUID
    public let revision: UInt64
    public init(file: WorkspaceFileID, threadID: String, connection: UUID, revision: UInt64) {
      self.file = file
      self.threadID = threadID
      self.connection = connection
      self.revision = revision
    }
  }
  public let key: Key
  public let kind: WorkspaceMediaKind
  public let load: @Sendable () async throws -> URL
  public var name: String { (key.file.path as NSString).lastPathComponent }

  public init(key: Key, kind: WorkspaceMediaKind, load: @escaping @Sendable () async throws -> URL)
  {
    self.key = key
    self.kind = kind
    self.load = load
  }
  public func save(to destination: URL) async throws {
    try await AttachmentHTTP.download(load(), to: destination, maximumBytes: nil)
  }

  public static func resource(path: String, at location: WorkspaceLocation) -> JSON {
    let absolute = FileOpenCapabilities.absolutePath(path, root: location.root)
    let root = (location.root as NSString).standardizingPath
    let inside = absolute == root || absolute.hasPrefix(root == "/" ? "/" : root + "/")
    let singleFile = !inside || WorkspaceMediaKind(path: absolute)?.playable == true
    return .object([
      "_tag": .string(singleFile ? "media-file" : "workspace-file"),
      "threadId": .string(location.threadID), "path": .string(absolute),
    ])
  }

  public static func freshURL(_ issued: JSON, endpoint: URL, revision: UInt64) throws -> URL {
    let signed = try AttachmentHTTP.signedURL(
      issued.requiredString("relativeUrl"), endpoint: endpoint, prefix: "/api/assets/")
    guard var parts = URLComponents(url: signed, resolvingAgainstBaseURL: false) else {
      throw T3Error("The preview address is invalid.")
    }
    var query = parts.queryItems ?? []
    query.append(URLQueryItem(name: "workspace-revision", value: String(revision)))
    parts.queryItems = query
    guard let url = parts.url else { throw T3Error("The preview address is invalid.") }
    return url
  }
}

public enum WorkspaceMediaDocument {
  public static func html(kind: WorkspaceMediaKind, url: URL, title: String, nonce: String)
    -> String
  {
    let source = escape(url.absoluteString)
    let title = escape(title)
    let body: String
    if kind == .image {
      body = "<img id=\"preview\" src=\"\(source)\" alt=\"\(title)\">"
    } else {
      body =
        "<iframe id=\"preview\" src=\"\(source)\" title=\"\(title)\" sandbox=\"allow-scripts allow-forms allow-popups\"></iframe>"
    }
    return """
      <!doctype html><html><head><meta charset="utf-8">
      <meta name="viewport" content="width=device-width,initial-scale=1">
      <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src http: https:; frame-src http: https:; style-src 'unsafe-inline'; script-src 'nonce-\(escape(nonce))'">
      <style>html,body{margin:0;width:100%;height:100%;overflow:hidden;background:transparent}body{display:flex;align-items:center;justify-content:center}img{max-width:100%;max-height:100%;object-fit:contain}iframe{width:100%;height:100%;border:0;background:white}</style>
      </head><body>\(body)<script nonce="\(escape(nonce))">
      const preview = document.getElementById('preview');
      const report = status => window.webkit.messageHandlers.filePreview.postMessage({status});
      preview.addEventListener('load', () => report('ready'));
      preview.addEventListener('error', () => report('failed'));
      if (preview.tagName === 'IMG' && preview.complete) report(preview.naturalWidth ? 'ready' : 'failed');
      </script></body></html>
      """
  }

  private static func escape(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
  }
}

public struct MediaPlaybackRecovery: Sendable {
  public private(set) var position: Double = 0
  public private(set) var rate: Float = 0
  public private(set) var attemptedRefresh = false
  public init() {}
  public mutating func capture(position: Double, rate: Float) {
    if position.isFinite && position > self.position + 1 { attemptedRefresh = false }
    if position.isFinite { self.position = max(0, position) }
    self.rate = rate.isFinite ? max(0, rate) : 0
  }
  public mutating func refreshAfterFailure() -> Bool {
    guard !attemptedRefresh else { return false }
    attemptedRefresh = true
    return true
  }
  public mutating func retry() { attemptedRefresh = false }
}
