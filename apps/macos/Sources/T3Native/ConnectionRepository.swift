import Foundation
import T3Core

@MainActor final class ConnectionRepository {
  private let preferences: UserDefaults
  private let credentials: Credentials.Access
  private let key = "native.savedConnections.v1"
  private(set) var values: SavedConnections

  init(
    preferences: UserDefaults = .standard, credentials: Credentials.Access = .keychain,
    validating: @escaping @MainActor () throws -> Void = {}
  ) async throws {
    self.preferences = preferences
    self.credentials = credentials
    try Task.checkCancellation()
    try validating()
    if let data = preferences.data(forKey: key) {
      values = try SavedConnections.decode(data)
    } else {
      values = SavedConnections()
    }
    // Keep a legacy selection even when Keychain access is missing. Never replace a
    // saved remote server with an implicitly-created local environment on launch.
    if values.environments.isEmpty, let address = preferences.string(forKey: "endpoint") {
      let endpoint = try ConnectionEndpoint.normalize(address)
      let initial = values
      let old = try await Credentials.loadLegacy(address: address, access: credentials)
      try validating()
      if try adoptLegacyMigration(endpoint) { return }
      try requireSelection(initial, legacyAddress: address)
      if let old {
        try await Credentials.saveSession(old, access: credentials)
        try validating()
        if try adoptLegacyMigration(endpoint) { return }
        try requireSelection(initial, legacyAddress: address)
      }
      // A different repository may have created the catalog while Security was waiting.
      if values.environments.isEmpty {
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
  // Startup and Connections can migrate together. Adopt a completed migration only
  // while the legacy endpoint and current selection still describe the same intent.
  private func adoptLegacyMigration(_ endpoint: URL) throws -> Bool {
    try Task.checkCancellation()
    let latest = try readCatalog()
    guard latest.selectedID == endpoint.absoluteString,
      latest.environments.contains(where: { $0.id == latest.selectedID && $0.endpoint == endpoint }
      ),
      let address = preferences.string(forKey: "endpoint"),
      (try? ConnectionEndpoint.normalize(address)) == endpoint
    else { return false }
    values = latest
    return true
  }
  func settings(for environment: SavedEnvironment) async throws -> ConnectionSettings {
    let initial = try readCatalog()
    let address = preferences.string(forKey: "endpoint")
    let settings = try await Credentials.loadSession(
      endpoint: environment.endpoint, access: credentials)
    try requireSelection(initial, legacyAddress: address)
    guard values.environments.contains(environment) else { throw CancellationError() }
    guard let settings else {
      throw T3Error(
        "This environment has no saved access token. Pair it again.", authentication: true)
    }
    return settings
  }
  /// Main calls this asynchronously unless --connection-file explicitly overrides the saved selection.
  /// First launch creates an isolated native host; later launches honor the saved environment.
  func connectionForLaunch(
    host: BackendHost = .shared, validating: @escaping @MainActor () throws -> Void = {}
  ) async throws -> ConnectionSettings? {
    try Task.checkCancellation()
    try validating()
    values = try readCatalog()
    if let environment = values.environments.first(where: { $0.id == values.selectedID }) {
      if environment.local {
        guard environment.endpoint == host.configuration.endpoint else {
          throw T3Error("The saved local endpoint differs from the configured native server port.")
        }
        let session = try await host.start()
        try validating()
        try requireLaunchSelection(environment)
        _ = try await remember(session, label: environment.label, local: true) {
          try validating()
          try self.requireLaunchSelection(environment)
        }
        return session
      }
      if let id = environment.cloudEnvironmentID,
        let configuration = try? ConnectConfiguration.bundled(
          info: Bundle.main.infoDictionary ?? [:])
      {
        let loaded = try await Credentials.loadAccount(
          configuration: configuration, access: credentials)
        try validating()
        try requireLaunchSelection(environment)
        if let account = loaded {
          let refreshed = try await account.refreshed(configuration: configuration)
          try validating()
          try requireLaunchSelection(environment)
          try await Credentials.saveAccount(
            refreshed, configuration: configuration, access: credentials)
          try validating()
          try requireLaunchSelection(environment)
          let client = ConnectClient(configuration: configuration, account: refreshed)
          let catalog = try await client.environments()
          try validating()
          try requireLaunchSelection(environment)
          guard let target = catalog.first(where: { $0.id == id }) else {
            throw T3Error(
              "The saved environment is no longer registered with your T3 Connect account.")
          }
          let session = try await client.pair(target)
          try validating()
          try requireLaunchSelection(environment)
          let saved = try await remember(session, label: environment.label, cloudEnvironmentID: id)
          {
            try validating()
            try self.requireLaunchSelection(environment)
          }
          try Task.checkCancellation()
          try validating()
          try select(saved)
          return session
        }
      }
      let session = try await settings(for: environment)
      try validating()
      try requireLaunchSelection(environment)
      return session
    }
    guard values.environments.isEmpty else { return nil }
    let session = try await host.start()
    try validating()
    try requireLaunchSelection(nil)
    let environment = try await remember(session, label: "This Mac", local: true) {
      try validating()
      try self.requireLaunchSelection(nil)
    }
    try Task.checkCancellation()
    try validating()
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
  func selectedSettings() async throws -> ConnectionSettings? {
    values = try readCatalog()
    guard let selected = values.environments.first(where: { $0.id == values.selectedID }) else {
      return nil
    }
    let settings = try await settings(for: selected)
    try requireLaunchSelection(selected)
    return settings
  }
  func remember(
    _ settings: ConnectionSettings, label: String, local: Bool = false,
    cloudEnvironmentID: String? = nil,
    validating: @escaping @MainActor () throws -> Void = {}
  ) async throws -> SavedEnvironment {
    let environment = try SavedEnvironment(
      label: label, endpoint: settings.endpoint, local: local,
      cloudEnvironmentID: cloudEnvironmentID)
    try Task.checkCancellation()
    try validating()
    let initial = try readCatalog()
    let address = preferences.string(forKey: "endpoint")
    let previous = initial.environments.first { $0.id == environment.id }
    try await Credentials.saveSession(settings, access: credentials)
    try validating()
    try requireSelection(initial, legacyAddress: address)
    guard values.environments.first(where: { $0.id == environment.id }) == previous else {
      throw CancellationError()
    }
    values.upsert(environment)
    try persist()
    return environment
  }
  func select(_ environment: SavedEnvironment) throws {
    try Task.checkCancellation()
    values = try readCatalog()
    guard values.environments.contains(where: { $0.id == environment.id }) else {
      throw T3Error("The environment was removed.")
    }
    values.selectedID = environment.id
    try persist()
    preferences.set(environment.endpoint.absoluteString, forKey: "endpoint")
  }
  func remove(
    _ environment: SavedEnvironment, validating: @escaping @MainActor () throws -> Void = {}
  ) async throws {
    try Task.checkCancellation()
    try validating()
    let initial = try readCatalog()
    let address = preferences.string(forKey: "endpoint")
    try await Credentials.removeSession(endpoint: environment.endpoint, access: credentials)
    try validating()
    try requireSelection(initial, legacyAddress: address)
    guard values.environments.first(where: { $0.id == environment.id }) == environment else {
      throw CancellationError()
    }
    values.remove(environment.id)
    try persist()
    if let old = preferences.string(forKey: "endpoint"),
      (try? ConnectionEndpoint.normalize(old)) == environment.endpoint
    {
      preferences.removeObject(forKey: "endpoint")
    }
  }
  private func requireSelection(_ initial: SavedConnections, legacyAddress: String?) throws {
    try Task.checkCancellation()
    let latest = try readCatalog()
    guard latest.selectedID == initial.selectedID,
      latest.environments.first(where: { $0.id == latest.selectedID })
        == initial.environments.first(where: { $0.id == initial.selectedID }),
      preferences.string(forKey: "endpoint") == legacyAddress
    else { throw CancellationError() }
    values = latest
  }
  private func persist() throws { preferences.set(try JSONEncoder().encode(values), forKey: key) }
}
