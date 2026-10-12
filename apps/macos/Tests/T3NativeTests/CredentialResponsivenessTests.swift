import Foundation
import T3Core
import Testing

@testable import T3Native

// Only the blocking credential boundary is substituted; catalog operations use the real repository.
private final class BlockingCredentialBoundary: @unchecked Sendable {
  enum Kind { case read, write, remove }
  let started: AsyncStream<Void>
  private let continuation: AsyncStream<Void>.Continuation
  private let release = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private let kind: Kind
  private let response: Data?
  private var blocked = false
  private var writes = 0
  private var offMain = true

  init(_ kind: Kind, response: Data? = nil) {
    self.kind = kind
    self.response = response
    (started, continuation) = AsyncStream.makeStream()
  }
  var access: Credentials.Access { Credentials.Access { [self] in try execute($0) } }
  var writeCount: Int { lock.withLock { writes } }
  var ranOffMain: Bool { lock.withLock { offMain } }
  func unblock() { release.signal() }
  func waitUntilBlocked() async {
    for await _ in started { return }
  }
  private func execute(_ operation: Credentials.Operation) throws -> Data? {
    let operationKind: Kind
    switch operation {
    case .read: operationKind = .read
    case .write: operationKind = .write
    case .remove, .removeSession: operationKind = .remove
    }
    let shouldBlock = lock.withLock {
      offMain = offMain && !Thread.isMainThread
      if operationKind == .write { writes += 1 }
      guard operationKind == kind, !blocked else { return false }
      blocked = true
      return true
    }
    if shouldBlock {
      continuation.yield(())
      release.wait()
    }
    if operationKind == .read { return response }
    return nil
  }
}

@Suite(.serialized) @MainActor struct CredentialResponsivenessTests {
  private let key = "native.savedConnections.v1"
  private func environment(_ name: String) throws -> SavedEnvironment {
    try SavedEnvironment(label: name, endpoint: URL(string: "https://\(name).invalid:4773")!)
  }
  private func write(_ catalog: SavedConnections, to preferences: UserDefaults) throws {
    preferences.set(try JSONEncoder().encode(catalog), forKey: key)
  }
  private func catalog(_ preferences: UserDefaults) throws -> SavedConnections {
    try SavedConnections.decode(try #require(preferences.data(forKey: key)))
  }
  private func isolatedPreferences() throws -> (String, UserDefaults) {
    let name = "app.t3.credential-responsiveness." + UUID().uuidString
    return (name, try #require(UserDefaults(suiteName: name)))
  }
  private func expectCancelled<T>(_ task: Task<T, Error>) async {
    do {
      _ = try await task.value
      Issue.record(
        "Stale credential work must be discarded before committing or returning a session.")
    } catch is CancellationError {} catch { Issue.record(error) }
  }

  @Test func mainActorRespondsWhileLegacyReadIsBlockedAndMigrationKeepsCanonicalThreadKey()
    async throws
  {
    let (suite, prefs) = try isolatedPreferences()
    defer { prefs.removePersistentDomain(forName: suite) }
    let address = "https://Legacy-" + UUID().uuidString + ".invalid:443/"
    prefs.set(address, forKey: "endpoint")
    prefs.set([address: "selected-thread"], forKey: "selectedThreadByEndpoint")
    let boundary = BlockingCredentialBoundary(.read, response: Data("synthetic-token".utf8))
    defer { boundary.unblock() }
    let loading = Task {
      try await ConnectionRepository(preferences: prefs, credentials: boundary.access)
    }
    await boundary.waitUntilBlocked()
    // This task must run before the blocked Security operation is released.
    let response = await Task { @MainActor in "main actor responded" }.value
    #expect(response == "main actor responded")
    #expect(prefs.data(forKey: key) == nil)
    #expect(boundary.ranOffMain)
    boundary.unblock()
    let repository = try await loading.value
    let endpoint = try ConnectionEndpoint.normalize(address)
    #expect(repository.values.selectedID == endpoint.absoluteString)
    #expect(repository.values.environments.map(\.endpoint) == [endpoint])
    #expect(boundary.writeCount == 1)
    #expect(
      prefs.dictionary(forKey: "selectedThreadByEndpoint")?[endpoint.absoluteString] as? String
        == "selected-thread")
  }

  @Test func connectionsInitializationReturnsImmediatelyAndPublishesAfterCredentialLoad()
    async throws
  {
    let (suite, prefs) = try isolatedPreferences()
    defer { prefs.removePersistentDomain(forName: suite) }
    let endpoint = try environment("settings").endpoint
    prefs.set(endpoint.absoluteString, forKey: "endpoint")
    let boundary = BlockingCredentialBoundary(.read)
    defer { boundary.unblock() }
    let drafts = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: drafts) }
    let store = ClientStore(draftDirectory: drafts, preferences: prefs)
    let host = BackendHost(preferences: prefs)
    let model = NativeConnections(
      store: store, host: host, preferences: prefs, credentials: boundary.access)
    #expect(model.busy)
    #expect(model.environments.isEmpty)
    await boundary.waitUntilBlocked()
    #expect(model.busy)
    #expect(boundary.ranOffMain)
    let completed = Task { @MainActor in
      for await busy in model.$busy.values {
        if !busy { return }
      }
    }
    boundary.unblock()
    await completed.value
    #expect(model.error == nil)
    #expect(model.environments.map(\.endpoint) == [endpoint])
    #expect(!model.signedIn)
    #expect(!host.isRunning)
    #expect(!store.hasConnection)
  }

  @Test(arguments: [false, true])
  func firstActionSurvivesPendingOrCancelledInitialization(cancelFirst: Bool) async throws {
    let (suite, prefs) = try isolatedPreferences()
    defer { prefs.removePersistentDomain(forName: suite) }
    let endpoint = try environment("pending-settings").endpoint
    let environment = try SavedEnvironment(label: endpoint.host!, endpoint: endpoint)
    prefs.set(environment.endpoint.absoluteString, forKey: "endpoint")
    let boundary = BlockingCredentialBoundary(.read)
    defer { boundary.unblock() }
    let drafts = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: drafts) }
    let store = ClientStore(draftDirectory: drafts, preferences: prefs)
    let host = BackendHost(preferences: prefs)
    let model = NativeConnections(
      store: store, host: host, preferences: prefs, credentials: boundary.access)
    await boundary.waitUntilBlocked()
    if cancelFirst {
      model.cancel()
      #expect(!model.busy)
    }
    model.forget(environment)
    #expect(model.busy)
    let completed = Task { @MainActor in
      for await busy in model.$busy.values {
        if !busy { return }
      }
    }
    boundary.unblock()
    await completed.value
    #expect(model.error == nil)
    #expect(model.notice?.hasPrefix("Removed from this Mac.") == true)
    #expect(model.environments.isEmpty)
    #expect(try catalog(prefs).environments.isEmpty)
    #expect(prefs.string(forKey: "endpoint") == nil)
    #expect(!host.isRunning)
  }

  @Test func concurrentLegacyInitializersAdoptTheSameCompletedMigration() async throws {
    let (suite, prefs) = try isolatedPreferences()
    defer { prefs.removePersistentDomain(forName: suite) }
    let address = "https://Concurrent.invalid:443/"
    prefs.set(address, forKey: "endpoint")
    prefs.set([address: "thread"], forKey: "selectedThreadByEndpoint")
    let boundary = BlockingCredentialBoundary(.write, response: Data("synthetic-token".utf8))
    defer { boundary.unblock() }
    let first = Task {
      try await ConnectionRepository(preferences: prefs, credentials: boundary.access)
    }
    await boundary.waitUntilBlocked()
    let secondStarted = AsyncStream<Void>.makeStream()
    let second = Task {
      try await ConnectionRepository(preferences: prefs, credentials: boundary.access) {
        secondStarted.continuation.yield(())
      }
    }
    // The second initializer has captured the empty catalog before the first write resumes.
    for await _ in secondStarted.stream { break }
    boundary.unblock()
    let firstRepository = try await first.value
    let secondRepository = try await second.value
    let latest = try catalog(prefs)
    let endpoint = try ConnectionEndpoint.normalize(address)
    #expect(firstRepository.values == latest)
    #expect(secondRepository.values == latest)
    #expect(latest.selectedID == endpoint.absoluteString)
    #expect(latest.environments.map(\.endpoint) == [endpoint])
    #expect(
      prefs.dictionary(forKey: "selectedThreadByEndpoint")?[endpoint.absoluteString] as? String
        == "thread")
  }

  @Test func legacyReadCannotOverwriteSelectionMadeWhileSecurityWaits() async throws {
    let (suite, prefs) = try isolatedPreferences()
    defer { prefs.removePersistentDomain(forName: suite) }
    let original = try environment("legacy")
    let selected = try environment("latest")
    prefs.set(original.endpoint.absoluteString, forKey: "endpoint")
    let boundary = BlockingCredentialBoundary(.read, response: Data("synthetic-token".utf8))
    defer { boundary.unblock() }
    let loading = Task {
      try await ConnectionRepository(preferences: prefs, credentials: boundary.access)
    }
    await boundary.waitUntilBlocked()
    var latest = SavedConnections()
    latest.upsert(selected, selecting: true)
    try write(latest, to: prefs)
    let external = try await ConnectionRepository(preferences: prefs, credentials: boundary.access)
    try external.select(selected)
    boundary.unblock()
    await expectCancelled(loading)
    #expect(try catalog(prefs) == latest)
    #expect(prefs.string(forKey: "endpoint") == selected.endpoint.absoluteString)
    #expect(boundary.writeCount == 0)
  }

  @Test func legacyEndpointChangeWithoutCatalogDiscardsOldCredential() async throws {
    let (suite, prefs) = try isolatedPreferences()
    defer { prefs.removePersistentDomain(forName: suite) }
    prefs.set(try environment("old").endpoint.absoluteString, forKey: "endpoint")
    let boundary = BlockingCredentialBoundary(.read, response: Data("synthetic-token".utf8))
    defer { boundary.unblock() }
    let loading = Task {
      try await ConnectionRepository(preferences: prefs, credentials: boundary.access)
    }
    await boundary.waitUntilBlocked()
    let address = try environment("new").endpoint.absoluteString
    prefs.set(address, forKey: "endpoint")
    boundary.unblock()
    await expectCancelled(loading)
    #expect(prefs.string(forKey: "endpoint") == address)
    #expect(prefs.data(forKey: key) == nil)
    #expect(boundary.writeCount == 0)
  }

  @Test func cancelledMigrationWriteCannotCommitCatalogOrThreadMigration() async throws {
    let (suite, prefs) = try isolatedPreferences()
    defer { prefs.removePersistentDomain(forName: suite) }
    let address = "https://cancelled.invalid:443/"
    prefs.set(address, forKey: "endpoint")
    prefs.set([address: "thread"], forKey: "selectedThreadByEndpoint")
    let boundary = BlockingCredentialBoundary(.write, response: Data("synthetic-token".utf8))
    defer { boundary.unblock() }
    let loading = Task {
      try await ConnectionRepository(preferences: prefs, credentials: boundary.access)
    }
    await boundary.waitUntilBlocked()
    loading.cancel()
    boundary.unblock()
    await expectCancelled(loading)
    #expect(prefs.data(forKey: key) == nil)
    #expect(
      (prefs.dictionary(forKey: "selectedThreadByEndpoint") as? [String: String]) == [
        address: "thread"
      ])
    #expect(prefs.string(forKey: "endpoint") == address)
  }

  @Test func plainRemoteLaunchRejectsSelectionChangedDuringCredentialRead() async throws {
    let (suite, prefs) = try isolatedPreferences()
    defer { prefs.removePersistentDomain(forName: suite) }
    let first = try environment("first")
    let second = try environment("second")
    var initial = SavedConnections()
    initial.upsert(first, selecting: true)
    initial.upsert(second)
    try write(initial, to: prefs)
    let settings = try ConnectionSettings(endpoint: first.endpoint, token: "synthetic-token")
    let boundary = BlockingCredentialBoundary(.read, response: try JSONEncoder().encode(settings))
    defer { boundary.unblock() }
    let repository = try await ConnectionRepository(
      preferences: prefs, credentials: boundary.access)
    let external = try await ConnectionRepository(preferences: prefs, credentials: boundary.access)
    let host = BackendHost(preferences: prefs)
    let launch = Task { try await repository.connectionForLaunch(host: host) }
    await boundary.waitUntilBlocked()
    try external.select(second)
    boundary.unblock()
    await expectCancelled(launch)
    #expect(try catalog(prefs).selectedID == second.id)
    #expect(!host.isRunning)
    #expect(boundary.writeCount == 0)
  }

  @Test(arguments: [false, true])
  func rememberCannotCommitAfterSelectionChangeOrCancellation(cancel: Bool) async throws {
    let (suite, prefs) = try isolatedPreferences()
    defer { prefs.removePersistentDomain(forName: suite) }
    let first = try environment("first")
    let second = try environment("second")
    var initial = SavedConnections()
    initial.upsert(first, selecting: true)
    initial.upsert(second)
    try write(initial, to: prefs)
    let boundary = BlockingCredentialBoundary(.write)
    defer { boundary.unblock() }
    let repository = try await ConnectionRepository(
      preferences: prefs, credentials: boundary.access)
    let external = try await ConnectionRepository(preferences: prefs, credentials: boundary.access)
    let settings = try ConnectionSettings(endpoint: first.endpoint, token: "synthetic-token")
    let remembering = Task { try await repository.remember(settings, label: "stale label") }
    await boundary.waitUntilBlocked()
    if cancel { remembering.cancel() } else { try external.select(second) }
    let expected = try catalog(prefs)
    boundary.unblock()
    await expectCancelled(remembering)
    #expect(try catalog(prefs) == expected)
    #expect(try catalog(prefs).environments.first(where: { $0.id == first.id })?.label == "first")
  }

  @Test func invalidatedCallerCannotCommitAfterCredentialWrite() async throws {
    let (suite, prefs) = try isolatedPreferences()
    defer { prefs.removePersistentDomain(forName: suite) }
    let first = try environment("first")
    var initial = SavedConnections()
    initial.upsert(first, selecting: true)
    try write(initial, to: prefs)
    let boundary = BlockingCredentialBoundary(.write)
    defer { boundary.unblock() }
    let repository = try await ConnectionRepository(
      preferences: prefs, credentials: boundary.access)
    let settings = try ConnectionSettings(endpoint: first.endpoint, token: "synthetic-token")
    var current = true
    let remembering = Task {
      try await repository.remember(settings, label: "stale") {
        guard current else { throw CancellationError() }
      }
    }
    await boundary.waitUntilBlocked()
    current = false
    boundary.unblock()
    await expectCancelled(remembering)
    #expect(try catalog(prefs) == initial)
  }

  @Test func rememberMergesUnrelatedCatalogEditsAfterCredentialWrite() async throws {
    let (suite, prefs) = try isolatedPreferences()
    defer { prefs.removePersistentDomain(forName: suite) }
    let first = try environment("first")
    let added = try environment("added")
    var initial = SavedConnections()
    initial.upsert(first, selecting: true)
    try write(initial, to: prefs)
    let boundary = BlockingCredentialBoundary(.write)
    defer { boundary.unblock() }
    let repository = try await ConnectionRepository(
      preferences: prefs, credentials: boundary.access)
    let settings = try ConnectionSettings(endpoint: first.endpoint, token: "synthetic-token")
    let remembering = Task { try await repository.remember(settings, label: "updated") }
    await boundary.waitUntilBlocked()
    initial.upsert(added)
    try write(initial, to: prefs)
    boundary.unblock()
    let remembered = try await remembering.value
    let latest = try catalog(prefs)
    #expect(latest.selectedID == first.id)
    #expect(latest.environments == [remembered, added])
  }

  @Test func cancelledRemovalCannotCommitCatalog() async throws {
    let (suite, prefs) = try isolatedPreferences()
    defer { prefs.removePersistentDomain(forName: suite) }
    let first = try environment("first")
    var initial = SavedConnections()
    initial.upsert(first, selecting: true)
    try write(initial, to: prefs)
    prefs.set(first.endpoint.absoluteString, forKey: "endpoint")
    let boundary = BlockingCredentialBoundary(.remove)
    defer { boundary.unblock() }
    let repository = try await ConnectionRepository(
      preferences: prefs, credentials: boundary.access)
    let removal = Task { try await repository.remove(first) }
    await boundary.waitUntilBlocked()
    removal.cancel()
    boundary.unblock()
    await expectCancelled(removal)
    #expect(try catalog(prefs) == initial)
    #expect(prefs.string(forKey: "endpoint") == first.endpoint.absoluteString)
  }
}
