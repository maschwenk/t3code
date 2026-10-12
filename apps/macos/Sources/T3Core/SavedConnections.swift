import Foundation

public enum ConnectionEndpoint {
  public static func normalize(_ text: String) throws -> URL {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw T3Error("Enter a server address.") }
    var parts = URLComponents(string: text.contains("://") ? text : "https://" + text)
    if parts?.scheme == "wss" { parts?.scheme = "https" }
    if parts?.scheme == "ws" { parts?.scheme = "http" }
    guard var value = parts, let host = value.host, !host.isEmpty,
      value.user == nil, value.password == nil, value.query == nil, value.fragment == nil,
      value.path.isEmpty || value.path == "/", value.port.map({ (1...65535).contains($0) }) ?? true
    else { throw T3Error("Enter a server origin without a path, password, query, or fragment.") }
    value.scheme = value.scheme?.lowercased()
    value.host = host.lowercased()
    if (value.scheme == "https" && value.port == 443)
      || (value.scheme == "http" && value.port == 80)
    {
      value.port = nil
    }
    value.path = ""
    guard let url = value.url else { throw T3Error("Invalid server address.") }
    _ = try ConnectionSettings(endpoint: url, token: "validation")
    return url
  }

  public static func credentialAccount(_ endpoint: URL) throws -> String {
    try normalize(endpoint.absoluteString).absoluteString
  }
}

public struct SavedEnvironment: Codable, Identifiable, Equatable, Sendable {
  public let id: String
  public var label: String
  public let endpoint: URL
  public var local: Bool
  public var cloudEnvironmentID: String?

  public init(label: String, endpoint: URL, local: Bool = false, cloudEnvironmentID: String? = nil)
    throws
  {
    self.endpoint = try ConnectionEndpoint.normalize(endpoint.absoluteString)
    self.id = self.endpoint.absoluteString
    self.label =
      label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? self.endpoint.host ?? "Environment" : label.trimmingCharacters(in: .whitespacesAndNewlines)
    self.local = local
    self.cloudEnvironmentID = cloudEnvironmentID
  }
}

public struct SavedConnections: Codable, Equatable, Sendable {
  public var environments: [SavedEnvironment] = []
  public var selectedID: String?
  public init() {}

  public mutating func upsert(_ environment: SavedEnvironment, selecting: Bool = false) {
    if let index = environments.firstIndex(where: { $0.id == environment.id }) {
      environments[index] = environment
    } else {
      environments.append(environment)
    }
    if selecting { selectedID = environment.id }
  }
  public mutating func remove(_ id: String) {
    environments.removeAll { $0.id == id }
    if selectedID == id { selectedID = nil }
  }
  public mutating func migrateLegacy(_ settings: ConnectionSettings) throws {
    guard environments.isEmpty else { return }
    upsert(
      try SavedEnvironment(
        label: settings.endpoint.host ?? "Saved server", endpoint: settings.endpoint),
      selecting: true)
  }
  public static func decode(_ data: Data) throws -> Self {
    let decoded = try JSONDecoder().decode(Self.self, from: data)
    var result = Self()
    for value in decoded.environments {
      result.upsert(
        try SavedEnvironment(
          label: value.label, endpoint: value.endpoint,
          local: value.local, cloudEnvironmentID: value.cloudEnvironmentID))
    }
    if let selected = decoded.selectedID,
      let url = try? ConnectionEndpoint.normalize(selected),
      result.environments.contains(where: { $0.id == url.absoluteString })
    {
      result.selectedID = url.absoluteString
    }
    return result
  }
}

public struct RemotePairingTarget: Sendable {
  public let endpoint: URL
  public let credential: String
  public init(address: String, credential: String) throws {
    guard var parts = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines))
    else {
      throw T3Error("Invalid pairing address.")
    }
    let fragment =
      URLComponents(string: "https://pair.invalid/?" + (parts.percentEncodedFragment ?? ""))?
      .queryItems ?? []
    let query = parts.queryItems ?? []
    let parameters = fragment + query
    let embedded = parameters.first(where: { $0.name == "token" })?.value
    let hosted = parameters.first(where: { $0.name == "host" })?.value
    if let hosted {
      guard parts.scheme == "https",
        parts.path == "/pair" || parts.path == "/" || parts.path.isEmpty
      else { throw T3Error("Invalid hosted pairing link.") }
      self.endpoint = try ConnectionEndpoint.normalize(hosted)
    } else {
      parts.query = nil
      parts.fragment = nil
      // Direct pairing URLs use the server origin, just as the web/mobile parser does.
      if embedded != nil { parts.path = "" }
      self.endpoint = try ConnectionEndpoint.normalize(parts.string ?? address)
    }
    self.credential = (embedded ?? credential).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !self.credential.isEmpty else { throw T3Error("Enter a pairing code.") }
  }
}
