import Darwin
import Foundation
import T3Core
import Testing

@testable import T3Native

@Suite @MainActor struct ConnectionLaunchSelectionTests {
  private func preferences() throws -> UserDefaults {
    try #require(UserDefaults(suiteName: "app.t3.launch-selection-tests." + UUID().uuidString))
  }
  private func environment(_ name: String) throws -> SavedEnvironment {
    try SavedEnvironment(label: name, endpoint: URL(string: "https://\(name).invalid:4773")!)
  }
  private func write(_ catalog: SavedConnections, to preferences: UserDefaults) throws {
    preferences.set(try JSONEncoder().encode(catalog), forKey: "native.savedConnections.v1")
  }

  @Test func externallyChangedSelectionCancelsWithoutRollingPreferencesBack() async throws {
    let prefs = try preferences()
    defer {
      prefs.removeObject(forKey: "native.savedConnections.v1")
      prefs.removeObject(forKey: "endpoint")
    }
    let first = try environment("first")
    let second = try environment("second")
    var catalog = SavedConnections()
    catalog.upsert(first, selecting: true)
    catalog.upsert(second)
    try write(catalog, to: prefs)
    let pending = try await ConnectionRepository(preferences: prefs)
    let external = try await ConnectionRepository(preferences: prefs)
    try external.select(second)
    #expect(throws: CancellationError.self) { try pending.requireLaunchSelection(first) }
    #expect(
      try SavedConnections.decode(prefs.data(forKey: "native.savedConnections.v1")!).selectedID
        == second.id)
    #expect(prefs.string(forKey: "endpoint") == second.endpoint.absoluteString)
  }

  @Test func unrelatedEnvironmentEditsArePreservedBeforeLaunchPersistence() async throws {
    let prefs = try preferences()
    defer { prefs.removeObject(forKey: "native.savedConnections.v1") }
    let first = try environment("first")
    let added = try environment("added")
    var catalog = SavedConnections()
    catalog.upsert(first, selecting: true)
    try write(catalog, to: prefs)
    let pending = try await ConnectionRepository(preferences: prefs)
    catalog.upsert(added)
    try write(catalog, to: prefs)
    try pending.requireLaunchSelection(first)
    #expect(pending.values.environments == catalog.environments)
    try pending.select(first)
    #expect(
      try SavedConnections.decode(prefs.data(forKey: "native.savedConnections.v1")!).environments
        == catalog.environments)
    prefs.removeObject(forKey: "endpoint")
  }

  @Test func firstLaunchCannotReplaceASelectionSavedDuringStartup() async throws {
    let prefs = try preferences()
    defer { prefs.removeObject(forKey: "native.savedConnections.v1") }
    let pending = try await ConnectionRepository(preferences: prefs)
    var latest = SavedConnections()
    latest.upsert(try environment("remote"), selecting: true)
    try write(latest, to: prefs)
    #expect(throws: CancellationError.self) { try pending.requireLaunchSelection(nil) }
    #expect(
      try SavedConnections.decode(prefs.data(forKey: "native.savedConnections.v1")!) == latest)
  }

  @Test func legacyEndpointChangeAlsoCancelsPendingLaunch() async throws {
    let prefs = try preferences()
    defer {
      prefs.removeObject(forKey: "native.savedConnections.v1")
      prefs.removeObject(forKey: "endpoint")
    }
    let first = try environment("first")
    var catalog = SavedConnections()
    catalog.upsert(first, selecting: true)
    try write(catalog, to: prefs)
    let pending = try await ConnectionRepository(preferences: prefs)
    let address = try environment("second").endpoint.absoluteString
    prefs.set(address, forKey: "endpoint")
    #expect(throws: CancellationError.self) { try pending.requireLaunchSelection(first) }
    #expect(prefs.string(forKey: "endpoint") == address)
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["T3_NATIVE_SMOKE_RESOURCES"] != nil))
  func selectionChangedDuringRealLocalStartupNeverRestoresOldSelection() async throws {
    let prefs = try preferences()
    defer {
      for key in ["native.savedConnections.v1", "native.backendConfiguration.v1", "endpoint"] {
        prefs.removeObject(forKey: key)
      }
    }
    let resources = URL(
      fileURLWithPath: ProcessInfo.processInfo.environment["T3_NATIVE_SMOKE_RESOURCES"]!)
    let home = URL(
      fileURLWithPath: "/tmp/t3-native-evidence/backend-selection-test-" + UUID().uuidString)
    let configuration = BackendConfiguration(home: home, port: try freePort())
    let local = try SavedEnvironment(
      label: "This Mac", endpoint: configuration.endpoint, local: true)
    let remote = try environment("selected-during-startup")
    var catalog = SavedConnections()
    catalog.upsert(local, selecting: true)
    catalog.upsert(remote)
    try write(catalog, to: prefs)
    let pending = try await ConnectionRepository(preferences: prefs)
    let external = try await ConnectionRepository(preferences: prefs)
    let host = BackendHost(
      runtime: BackendRuntime.bundled(resources: resources), preferences: prefs)
    try host.configure(configuration)
    let launch = Task { try await pending.connectionForLaunch(host: host) }
    let startingDeadline = Date().addingTimeInterval(5)
    while host.state == "Stopped", Date() < startingDeadline { await Task.yield() }
    try external.select(remote)
    do {
      _ = try await launch.value
      Issue.record("A stale local startup must cancel before saving its credential or selection.")
    } catch is CancellationError {} catch { Issue.record(error) }
    let latest = try SavedConnections.decode(prefs.data(forKey: "native.savedConnections.v1")!)
    #expect(latest.selectedID == remote.id)
    #expect(prefs.string(forKey: "endpoint") == remote.endpoint.absoluteString)
    #expect(latest.environments == catalog.environments)
    try await host.stop()
    #expect(!host.isRunning)
  }

  private func freePort() throws -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw T3Error("Cannot allocate a test port.") }
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let result = withUnsafeMutablePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
        guard bind(fd, socketAddress, length) == 0 else { return Int32(-1) }
        return getsockname(fd, socketAddress, &length)
      }
    }
    guard result == 0 else { throw T3Error("Cannot find a free test port.") }
    return Int(UInt16(bigEndian: address.sin_port))
  }
}
