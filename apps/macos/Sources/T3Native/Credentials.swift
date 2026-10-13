import Foundation
import Security
import T3Core

enum Credentials {
  private static let legacyService = "app.t3.native-prototype"
  private static let sessionService = "app.t3.native-prototype.environment.v1"
  private static let accountService = "app.t3.native-prototype.connect.v1"

  private static let queue = DispatchQueue(label: "app.t3.native.credentials")

  enum Operation: Sendable {
    case read(service: String, account: String)
    case write(Data, service: String, account: String)
    case remove(service: String, account: String)
    case removeSession(account: String)
  }

  // One boundary for tests to hold a Security operation without touching a real vault.
  struct Access: Sendable {
    let execute: @Sendable (Operation) throws -> Data?
    static let keychain = Access(execute: Credentials.securityOperation)

    func perform(_ operation: Operation) async throws -> Data? {
      try Task.checkCancellation()
      let cancellation = Cancellation()
      let result: Data? = try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          queue.async {
            do {
              try cancellation.check()
              continuation.resume(returning: try execute(operation))
            } catch { continuation.resume(throwing: error) }
          }
        }
      } onCancel: {
        cancellation.cancel()
      }
      // Security cannot cancel an operation that has already entered SecurityAgent.
      // Discard its result and prevent subsequent writes/catalog commits instead.
      try Task.checkCancellation()
      return result
    }
  }

  private final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    func check() throws {
      if lock.withLock({ cancelled }) { throw CancellationError() }
    }
  }

  @MainActor static func save(
    _ settings: ConnectionSettings, validating: @escaping @MainActor () throws -> Void = {}
  ) async throws {
    let repository = try await ConnectionRepository(validating: validating)
    try validating()
    let id = try ConnectionEndpoint.credentialAccount(settings.endpoint)
    let existing = repository.values.environments.first { $0.id == id }
    let environment = try await repository.remember(
      settings, label: existing?.label ?? settings.endpoint.host ?? "Server",
      local: existing?.local ?? false, cloudEnvironmentID: existing?.cloudEnvironmentID,
      validating: validating)
    try Task.checkCancellation()
    try validating()
    try repository.select(environment)
  }
  @MainActor static func load() async throws -> ConnectionSettings? {
    try await ConnectionRepository().selectedSettings()
  }
  static func saveSession(_ settings: ConnectionSettings, access: Access = .keychain) async throws {
    let endpoint = try ConnectionEndpoint.normalize(settings.endpoint.absoluteString)
    let normalized = try ConnectionSettings(
      endpoint: endpoint, token: settings.token, proofKey: settings.proofKey)
    _ = try await access.perform(
      .write(
        try JSONEncoder().encode(normalized), service: sessionService,
        account: endpoint.absoluteString))
  }
  static func loadSession(endpoint: URL, access: Access = .keychain) async throws
    -> ConnectionSettings?
  {
    let account = try ConnectionEndpoint.credentialAccount(endpoint)
    guard let data = try await access.perform(.read(service: sessionService, account: account))
    else { return nil }
    let value = try JSONDecoder().decode(ConnectionSettings.self, from: data)
    guard try ConnectionEndpoint.credentialAccount(value.endpoint) == account else {
      throw T3Error("The saved credential belongs to another server.")
    }
    return try ConnectionSettings(
      endpoint: URL(string: account)!, token: value.token, proofKey: value.proofKey)
  }
  static func removeSession(endpoint: URL, access: Access = .keychain) async throws {
    let account = try ConnectionEndpoint.credentialAccount(endpoint)
    _ = try await access.perform(.removeSession(account: account))
  }
  static func loadLegacy(address: String?, access: Access = .keychain) async throws
    -> ConnectionSettings?
  {
    guard let account = address, let endpoint = URL(string: account),
      let data = try await access.perform(.read(service: legacyService, account: account))
    else { return nil }
    guard let token = String(data: data, encoding: .utf8) else {
      throw T3Error("The legacy token is unreadable.")
    }
    return try ConnectionSettings(endpoint: endpoint, token: token)
  }
  static func saveAccount(
    _ account: ConnectAccountToken, configuration: ConnectConfiguration, access: Access = .keychain
  )
    async throws
  {
    _ = try await access.perform(
      .write(
        try JSONEncoder().encode(account), service: accountService,
        account: configuration.credentialAccount))
  }
  static func loadAccount(configuration: ConnectConfiguration, access: Access = .keychain)
    async throws -> ConnectAccountToken?
  {
    guard
      let data = try await access.perform(
        .read(service: accountService, account: configuration.credentialAccount))
    else { return nil }
    return try JSONDecoder().decode(ConnectAccountToken.self, from: data)
  }
  static func removeAccount(configuration: ConnectConfiguration, access: Access = .keychain)
    async throws
  {
    _ = try await access.perform(
      .remove(service: accountService, account: configuration.credentialAccount))
  }

  private static func securityOperation(_ operation: Operation) throws -> Data? {
    switch operation {
    case .read(let service, let account): return try read(service: service, account: account)
    case .write(let data, let service, let account):
      try write(data, service: service, account: account)
    case .remove(let service, let account): try remove(service: service, account: account)
    case .removeSession(let account):
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
    return nil
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
