import Foundation
import T3Core
import Testing

@testable import T3Native

@Suite @MainActor struct ConnectionRepositoryTests {
  @Test func missingLegacyCredentialPreservesRemote4773AndNeverStartsLocalHost() async throws {
    let suite = "app.t3.connection-tests." + UUID().uuidString
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    // A unique endpoint guarantees this test cannot read an actual user's credential.
    let address = "https://missing-" + UUID().uuidString.lowercased() + ".invalid:4773/"
    preferences.set(address, forKey: "endpoint")
    preferences.set([address: "existing-thread"], forKey: "selectedThreadByEndpoint")
    let repository = try await ConnectionRepository(preferences: preferences)
    let expected = try ConnectionEndpoint.normalize(address)
    #expect(repository.values.selectedID == expected.absoluteString)
    #expect(repository.values.environments.count == 1)
    #expect(repository.values.environments[0].endpoint.port == 4773)
    #expect(!repository.values.environments[0].local)
    #expect(
      preferences.dictionary(forKey: "selectedThreadByEndpoint")?[expected.absoluteString]
        as? String == "existing-thread")
    let host = BackendHost(
      runtime: BackendRuntime(
        node: URL(fileURLWithPath: "/missing-node"),
        serverEntry: URL(fileURLWithPath: "/missing-server")), preferences: preferences)
    do {
      _ = try await repository.connectionForLaunch(host: host)
      Issue.record(
        "Missing remote auth must require pairing rather than switching to a local server.")
    } catch let error as T3Error { #expect(error.authentication) }
    #expect(!host.isRunning)
    #expect(host.state == "Stopped")
    #expect(repository.values.selectedID == expected.absoluteString)
    let reopened = try await ConnectionRepository(preferences: preferences)
    #expect(reopened.values == repository.values)
  }
}
