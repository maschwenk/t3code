import Foundation
import T3Core

@MainActor final class ConnectionRepository {
  private let preferences: UserDefaults
  private let key = "native.savedConnections.v1"
  private(set) var values: SavedConnections

  init(preferences: UserDefaults = .standard) throws {
    self.preferences = preferences
    if let data = preferences.data(forKey: key) {
      values = try SavedConnections.decode(data)
    } else {
      values = SavedConnections()
    }
    // Keep a legacy selection even when Keychain access is missing. Never replace a
    // saved remote server with an implicitly-created local environment on launch.
    if values.environments.isEmpty, let address = preferences.string(forKey: "endpoint") {
      let endpoint = try ConnectionEndpoint.normalize(address)
      if let old = try Credentials.loadLegacy(preferences: preferences) {
        try Credentials.saveSession(old)
        try values.migrateLegacy(old)
      } else {
        values.upsert(
          try SavedEnvironment(label: endpoint.host ?? "Saved server", endpoint: endpoint),
          selecting: true)
      }
      let canonical = endpoint.absoluteString
      if var selections = preferences.dictionary(forKey: "selectedThreadByEndpoint"),
        selections[canonical] == nil, let previous = selections[address]
      {
        selections[canonical] = previous
        preferences.set(selections, forKey: "selectedThreadByEndpoint")
      }
      try persist()
    }
  }
  func settings(for environment: SavedEnvironment) throws -> ConnectionSettings {
    guard let settings = try Credentials.loadSession(endpoint: environment.endpoint) else {
      throw T3Error(
        "This environment has no saved access token. Pair it again.", authentication: true)
    }
    return settings
  }
  /// Main calls this asynchronously unless --connection-file explicitly overrides the saved selection.
  /// First launch creates an isolated native host; later launches honor the saved environment.
  func connectionForLaunch(host: BackendHost = .shared) async throws -> ConnectionSettings? {
    values = try readCatalog()
    if let environment = values.environments.first(where: { $0.id == values.selectedID }) {
      if environment.local {
        guard environment.endpoint == host.configuration.endpoint else {
          throw T3Error("The saved local endpoint differs from the configured native server port.")
        }
        let session = try await host.start()
        try requireLaunchSelection(environment)
        _ = try remember(session, label: environment.label, local: true)
        return session
      }
      if let id = environment.cloudEnvironmentID,
        let configuration = try? ConnectConfiguration.bundled(
          info: Bundle.main.infoDictionary ?? [:]),
        let account = try Credentials.loadAccount(configuration: configuration)
      {
        let refreshed = try await account.refreshed(configuration: configuration)
        try requireLaunchSelection(environment)
        try Credentials.saveAccount(refreshed, configuration: configuration)
        let client = ConnectClient(configuration: configuration, account: refreshed)
        let catalog = try await client.environments()
        try requireLaunchSelection(environment)
        guard let target = catalog.first(where: { $0.id == id }) else {
          throw T3Error(
            "The saved environment is no longer registered with your T3 Connect account.")
        }
        let session = try await client.pair(target)
        try requireLaunchSelection(environment)
        let saved = try remember(session, label: environment.label, cloudEnvironmentID: id)
        try select(saved)
        return session
      }
      return try settings(for: environment)
    }
    guard values.environments.isEmpty else { return nil }
    let session = try await host.start()
    try requireLaunchSelection(nil)
    let environment = try remember(session, label: "This Mac", local: true)
    try select(environment)
    return session
  }
  /// An async launch may finish after another repository or process selected an environment.
  /// Merge unrelated catalog edits, but never persist a result for a stale selection.
  func requireLaunchSelection(_ expected: SavedEnvironment?) throws {
    try Task.checkCancellation()
    let latest = try readCatalog()
    if let expected {
      guard latest.selectedID == expected.id,
        latest.environments.first(where: { $0.id == expected.id }) == expected
      else {
        throw CancellationError()
      }
      if let legacy = preferences.string(forKey: "endpoint"),
        (try? ConnectionEndpoint.normalize(legacy)) != expected.endpoint
      {
        throw CancellationError()
      }
    } else {
      guard latest.environments.isEmpty, latest.selectedID == nil,
        preferences.string(forKey: "endpoint") == nil
      else { throw CancellationError() }
    }
    values = latest
  }
  private func readCatalog() throws -> SavedConnections {
    if let data = preferences.data(forKey: key) { return try SavedConnections.decode(data) }
    return SavedConnections()
  }
  func selectedSettings() throws -> ConnectionSettings? {
    guard let selected = values.environments.first(where: { $0.id == values.selectedID }) else {
      return nil
    }
    return try settings(for: selected)
  }
  func remember(
    _ settings: ConnectionSettings, label: String, local: Bool = false,
    cloudEnvironmentID: String? = nil
  ) throws -> SavedEnvironment {
    let environment = try SavedEnvironment(
      label: label, endpoint: settings.endpoint, local: local,
      cloudEnvironmentID: cloudEnvironmentID)
    try Credentials.saveSession(settings)
    values.upsert(environment)
    try persist()
    return environment
  }
  func select(_ environment: SavedEnvironment) throws {
    guard values.environments.contains(where: { $0.id == environment.id }) else {
      throw T3Error("The environment was removed.")
    }
    values.selectedID = environment.id
    try persist()
    preferences.set(environment.endpoint.absoluteString, forKey: "endpoint")
  }
  func remove(_ environment: SavedEnvironment) throws {
    try Credentials.removeSession(endpoint: environment.endpoint)
    values.remove(environment.id)
    try persist()
    if let old = preferences.string(forKey: "endpoint"),
      (try? ConnectionEndpoint.normalize(old)) == environment.endpoint
    {
      preferences.removeObject(forKey: "endpoint")
    }
  }
  private func persist() throws { preferences.set(try JSONEncoder().encode(values), forKey: key) }
}
