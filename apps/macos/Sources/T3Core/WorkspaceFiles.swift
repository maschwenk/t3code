import Foundation

public struct WorkspaceEntry: Equatable, Sendable {
  public let path: String
  public let isDirectory: Bool
  public let ignored: Bool
  public var name: String { (path as NSString).lastPathComponent }
  public var parent: String { path.split(separator: "/").dropLast().joined(separator: "/") }

  public init(_ value: JSON) throws {
    path = try value.requiredString("path")
    isDirectory = value["kind"].string == "directory"
    ignored = value["ignored"].bool
  }

  public static func entries(_ result: JSON, directory: String? = nil) throws -> [Self] {
    var seen: Set<String> = []
    return try result["entries"].array.map(Self.init)
      .filter { (directory == nil || $0.parent == directory) && seen.insert($0.path).inserted }
      .sorted {
        if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
        return $0.path.localizedStandardCompare($1.path) == .orderedAscending
      }
  }
}

public struct WorkspaceFileID: Codable, Hashable, Sendable {
  public let environment: String
  public let root: String
  public let path: String
  public init(location: WorkspaceLocation, path: String) {
    environment = location.environment
    root = location.root
    self.path = path
  }
}

public enum WorkspaceTreeNavigation {
  public static func directories(for path: String, isDirectory: Bool) -> [String] {
    guard !path.hasPrefix("/") else { return [] }
    let parts = path.split(separator: "/").filter { $0 != "." }
    guard !parts.contains("..") else { return [] }
    let count = isDirectory ? parts.count : max(0, parts.count - 1)
    return [""] + (0..<count).map { parts.prefix($0 + 1).joined(separator: "/") }
  }
}

public struct WorkspaceFileDocument: Codable, Equatable, Sendable {
  public let path: String
  public private(set) var original: String
  public var contents: String
  public let byteLength: Int
  public let truncated: Bool
  public private(set) var uncertainSaveContents: String?
  public var requiresRecovery: Bool { isDirty || uncertainSaveContents != nil }
  public var isDirty: Bool { contents != original }
  public var canEdit: Bool {
    !truncated && !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
  }

  public init(_ result: JSON) throws {
    path = try result.requiredString("relativePath")
    original = try result.requiredString("contents")
    contents = original
    byteLength = try result.requiredInt("byteLength")
    truncated = result["truncated"].bool
  }

  public func validateSave(against latest: Self) throws {
    guard canEdit, latest.canEdit, latest.path == path else {
      throw T3Error("This preview is read-only. Open the complete workspace file to edit it.")
    }
    guard
      latest.contents == original || latest.contents == contents
        || latest.contents == uncertainSaveContents
    else {
      throw T3Error("This file changed on the server. Copy your edits, then reload before saving.")
    }
  }

  public mutating func recordSaveAttempt(_ contents: String) { uncertainSaveContents = contents }
  public mutating func acknowledgeSave(_ saved: String) {
    original = saved
    if uncertainSaveContents == saved { uncertainSaveContents = nil }
  }
}

public struct WorkspaceDraftRepository: Sendable {
  public let file: URL
  public init(directory: URL) { file = directory.appendingPathComponent("workspace-files.json") }
  public func load() throws -> [WorkspaceFileID: WorkspaceFileDocument] {
    guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
    return try JSONDecoder().decode(
      [WorkspaceFileID: WorkspaceFileDocument].self, from: Data(contentsOf: file))
  }
  public func save(_ documents: [WorkspaceFileID: WorkspaceFileDocument]) throws {
    let directory = file.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let dirty = documents.filter { $0.value.requiresRecovery && $0.value.canEdit }
    try JSONEncoder().encode(dirty).write(to: file, options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  }
}
