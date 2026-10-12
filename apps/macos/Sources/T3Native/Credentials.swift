import Foundation
import Security
import T3Core

enum Credentials {
  private static let service = "app.t3.native-prototype"
  static func save(_ settings: ConnectionSettings) throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: settings.endpoint.absoluteString,
    ]
    let data = Data(settings.token.utf8)
    var result = SecItemUpdate(
      query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if result == errSecItemNotFound {
      var item = query
      item[kSecValueData as String] = data
      item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      result = SecItemAdd(item as CFDictionary, nil)
    }
    guard result == errSecSuccess else {
      throw T3Error("Could not save the access token in Keychain (\(result)).")
    }
    UserDefaults.standard.set(settings.endpoint.absoluteString, forKey: "endpoint")
  }

  static func load() throws -> ConnectionSettings? {
    guard let endpoint = UserDefaults.standard.string(forKey: "endpoint"),
      let url = URL(string: endpoint)
    else { return nil }
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service, kSecAttrAccount as String: endpoint,
      kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data,
      let token = String(data: data, encoding: .utf8)
    else { throw T3Error("Could not read the saved connection from Keychain (\(status)).") }
    return try ConnectionSettings(endpoint: url, token: token)
  }
}
