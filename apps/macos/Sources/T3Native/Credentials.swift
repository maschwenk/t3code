import Foundation
import Security
import T3Core

enum Credentials {
  private static let legacyService = "app.t3.native-prototype"
  private static let sessionService = "app.t3.native-prototype.environment.v1"
  private static let accountService = "app.t3.native-prototype.connect.v1"

  // Retain the original entry points for Main.swift and the connection dialog.
  @MainActor static func save(_ settings: ConnectionSettings) throws {
    let repository = try ConnectionRepository()
    let id = try ConnectionEndpoint.credentialAccount(settings.endpoint)
    let existing = repository.values.environments.first { $0.id == id }
    let environment = try repository.remember(
      settings, label: existing?.label ?? settings.endpoint.host ?? "Server",
      local: existing?.local ?? false, cloudEnvironmentID: existing?.cloudEnvironmentID)
    try repository.select(environment)
  }
  @MainActor static func load() throws -> ConnectionSettings? {
    try ConnectionRepository().selectedSettings()
  }
  static func saveSession(_ settings: ConnectionSettings) throws {
    let endpoint = try ConnectionEndpoint.normalize(settings.endpoint.absoluteString)
    let normalized = try ConnectionSettings(
      endpoint: endpoint, token: settings.token, proofKey: settings.proofKey)
    try write(
      try JSONEncoder().encode(normalized), service: sessionService,
      account: endpoint.absoluteString)
  }
  static func loadSession(endpoint: URL) throws -> ConnectionSettings? {
    let account = try ConnectionEndpoint.credentialAccount(endpoint)
    guard let data = try read(service: sessionService, account: account) else { return nil }
    let value = try JSONDecoder().decode(ConnectionSettings.self, from: data)
    guard try ConnectionEndpoint.credentialAccount(value.endpoint) == account else {
      throw T3Error("The saved credential belongs to another server.")
    }
    return try ConnectionSettings(
      endpoint: URL(string: account)!, token: value.token, proofKey: value.proofKey)
  }
  static func removeSession(endpoint: URL) throws {
    let account = try ConnectionEndpoint.credentialAccount(endpoint)
    try remove(service: sessionService, account: account)
    // Legacy accounts included a trailing slash/default port. Remove all equivalent legacy entries.
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: legacyService, kSecReturnAttributes as String: true,
      kSecMatchLimit as String: kSecMatchLimitAll,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw failure("inspect", status)
    }
    for item in result as? [[String: Any]] ?? [] {
      if let name = item[kSecAttrAccount as String] as? String,
        (try? ConnectionEndpoint.normalize(name).absoluteString) == account
      {
        try remove(service: legacyService, account: name)
      }
    }
  }
  static func loadLegacy(preferences: UserDefaults = .standard) throws -> ConnectionSettings? {
    guard let account = preferences.string(forKey: "endpoint"), let endpoint = URL(string: account),
      let data = try read(service: legacyService, account: account)
    else { return nil }
    guard let token = String(data: data, encoding: .utf8) else {
      throw T3Error("The legacy token is unreadable.")
    }
    return try ConnectionSettings(endpoint: endpoint, token: token)
  }
  static func saveAccount(_ account: ConnectAccountToken, configuration: ConnectConfiguration)
    throws
  {
    try write(
      try JSONEncoder().encode(account), service: accountService,
      account: configuration.credentialAccount)
  }
  static func loadAccount(configuration: ConnectConfiguration) throws -> ConnectAccountToken? {
    guard let data = try read(service: accountService, account: configuration.credentialAccount)
    else { return nil }
    return try JSONDecoder().decode(ConnectAccountToken.self, from: data)
  }
  static func removeAccount(configuration: ConnectConfiguration) throws {
    try remove(service: accountService, account: configuration.credentialAccount)
  }
  private static func query(service: String, account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }
  private static func write(_ data: Data, service: String, account: String) throws {
    let query = query(service: service, account: account)
    var status = SecItemUpdate(
      query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
      var item = query
      item[kSecValueData as String] = data
      item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      status = SecItemAdd(item as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw failure("save", status) }
  }
  private static func read(service: String, account: String) throws -> Data? {
    var query = query(service: service, account: account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else { throw failure("read", status) }
    return data
  }
  private static func remove(service: String, account: String) throws {
    let status = SecItemDelete(query(service: service, account: account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw failure("remove", status)
    }
  }
  private static func failure(_ action: String, _ status: OSStatus) -> T3Error {
    T3Error("Could not \(action) the credential in Keychain (\(status)).")
  }
}
