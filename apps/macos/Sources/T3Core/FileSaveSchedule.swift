import Foundation

/// One file's debounce and single-write state. Times are monotonic seconds.
public struct FileSaveSchedule: Sendable {
  public private(set) var revision = 0
  public private(set) var confirmedRevision = 0
  public private(set) var inFlight: Int?
  public private(set) var deadline: TimeInterval?
  private var lastChange: TimeInterval = 0
  private var urgent = false
  public var pending: Bool { revision > confirmedRevision }
  public init() {}

  public mutating func change(at now: TimeInterval) {
    revision += 1
    lastChange = now
    deadline = urgent ? now : now + 0.5
  }

  public mutating func flush(at now: TimeInterval) {
    guard pending else { return }
    urgent = true
    deadline = now
  }

  public mutating func begin(at now: TimeInterval) -> Int? {
    guard inFlight == nil, pending, let deadline, deadline <= now else { return nil }
    inFlight = revision
    self.deadline = nil
    return revision
  }

  public mutating func complete(_ savedRevision: Int, succeeded: Bool, at now: TimeInterval) {
    guard inFlight == savedRevision else { return }
    inFlight = nil
    if succeeded { confirmedRevision = savedRevision }
    if revision > savedRevision {
      deadline = urgent ? now : max(now, lastChange + 0.5)
    } else {
      // A failed latest write waits for another edit or an explicit retry.
      deadline = nil
      urgent = false
    }
  }
}

/// Captures the connection and root before navigation. A delayed save cannot target the next workspace.
public struct WorkspaceFileAccess: Sendable {
  private let connection: RPCConnection
  public let location: WorkspaceLocation
  public init(connection: RPCConnection, location: WorkspaceLocation) {
    self.connection = connection
    self.location = location
  }
  public func read(_ path: String) async throws -> WorkspaceFileDocument {
    try await WorkspaceFileDocument(
      connection.call(
        "projects.readFile",
        payload: .object([
          "cwd": .string(location.root), "relativePath": .string(path),
        ])))
  }
  public func save(
    _ document: WorkspaceFileDocument,
    beforeWrite: @Sendable (String) async throws -> Void = { _ in }
  ) async throws {
    let latest = try await read(document.path)
    try document.validateSave(against: latest)
    if latest.contents == document.contents { return }
    try await beforeWrite(latest.contents)
    _ = try await connection.call(
      "projects.writeFile",
      payload: .object([
        "cwd": .string(location.root), "relativePath": .string(document.path),
        "contents": .string(document.contents),
      ]))
  }
}
