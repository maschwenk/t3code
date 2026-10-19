import CryptoKit
import Foundation

public struct ConnectConfiguration: Sendable {
  public let relay: URL
  public let hostedApp: URL
  public let tokenEndpoint: URL
  public let clientID: String
  public let callbackPort = 34338
  public var redirectURI: URL { URL(string: "http://127.0.0.1:\(callbackPort)/callback")! }
  public var credentialAccount: String {
    relay.absoluteString + "|" + tokenEndpoint.absoluteString + "|" + clientID
  }
  public init(
    relay: String, publishableKey: String, clientID: String,
    hostedApp: String = "https://app.t3.codes"
  ) throws {
    self.relay = try ConnectionEndpoint.normalize(relay)
    self.hostedApp = try ConnectionEndpoint.normalize(hostedApp)
    guard self.relay.scheme == "https", self.hostedApp.scheme == "https", !clientID.isEmpty,
      publishableKey.hasPrefix("pk_live_") || publishableKey.hasPrefix("pk_test_")
    else {
      throw T3Error(
        "T3 Connect requires its relay URL, Clerk publishable key, and CLI OAuth client ID.")
    }
    let encoded = publishableKey.split(separator: "_").dropFirst(2).joined(separator: "_")
    let padded = encoded + String(repeating: "=", count: (4 - encoded.count % 4) % 4)
    guard let data = Data(base64Encoded: padded), var host = String(data: data, encoding: .utf8)
    else {
      throw T3Error("The T3 Connect publishable key is invalid.")
    }
    if host.hasSuffix("$") { host.removeLast() }
    guard !host.isEmpty, !host.contains("/"), !host.contains("@"), !host.contains(":"),
      !host.contains("?")
    else {
      throw T3Error("The T3 Connect account host is invalid.")
    }
    let origin = try ConnectionEndpoint.normalize("https://" + host)
    self.tokenEndpoint = origin.appendingPathComponent("oauth/token")
    self.clientID = clientID
  }
  public static func bundled(
    info: [String: Any], environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> Self {
    func value(_ name: String, _ key: String) -> String {
      environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines)
        ?? (info[key] as? String ?? "")
    }
    return try Self(
      relay: value("T3CODE_RELAY_URL", "T3ConnectRelayURL"),
      publishableKey: value("T3CODE_CLERK_PUBLISHABLE_KEY", "T3ConnectClerkPublishableKey"),
      clientID: value("T3CODE_CLERK_CLI_OAUTH_CLIENT_ID", "T3ConnectOAuthClientID"),
      hostedApp: environment["T3CODE_HOSTED_APP_URL"] ?? info["T3ConnectHostedAppURL"] as? String
        ?? "https://app.t3.codes")
  }
}

public struct ConnectAuthorization: Sendable {
  public let verifier: String
  public let state: String
  public let configuration: ConnectConfiguration
  public init(configuration: ConnectConfiguration) {
    self.configuration = configuration
    verifier = ConnectionProof.base64url(ConnectionProof().rawRepresentation)
    state = ConnectionProof.base64url(ConnectionProof().rawRepresentation)
  }
  public var url: URL {
    var parts = URLComponents(url: configuration.hostedApp, resolvingAgainstBaseURL: false)!
    parts.path = "/connect"
    var fragment = URLComponents()
    fragment.queryItems = [
      URLQueryItem(name: "state", value: state),
      URLQueryItem(
        name: "challenge",
        value: ConnectionProof.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))),
      URLQueryItem(name: "port", value: String(configuration.callbackPort)),
    ]
    parts.percentEncodedFragment = fragment.percentEncodedQuery
    return parts.url!
  }
  public func code(from callback: URL) throws -> String {
    guard let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false),
      parts.scheme == "http", parts.host == "127.0.0.1", parts.port == configuration.callbackPort,
      parts.path == "/callback", parts.user == nil, parts.password == nil, parts.fragment == nil,
      parts.queryItems?.filter({ $0.name == "state" }).count == 1,
      parts.queryItems?.first(where: { $0.name == "state" })?.value == state,
      parts.queryItems?.filter({ $0.name == "code" }).count == 1,
      let code = parts.queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty
    else {
      throw T3Error("Invalid T3 Connect callback. Restart sign-in from Connections.")
    }
    return code
  }
  public func exchange(_ callback: URL) async throws -> ConnectAccountToken {
    try await ConnectAccountToken.exchange(
      configuration: configuration,
      fields: [
        "grant_type": "authorization_code", "code": code(from: callback),
        "redirect_uri": configuration.redirectURI.absoluteString,
        "client_id": configuration.clientID, "code_verifier": verifier,
      ])
  }
}

public struct ConnectAccountToken: Codable, Sendable {
  public let accessToken: String
  public let refreshToken: String
  public let expiresAt: Date
  public func refreshed(configuration: ConnectConfiguration) async throws -> Self {
    if expiresAt.timeIntervalSinceNow > 60 { return self }
    guard !refreshToken.isEmpty else {
      throw T3Error("T3 Connect sign-in expired. Sign in again.", authentication: true)
    }
    return try await Self.exchange(
      configuration: configuration,
      fields: [
        "grant_type": "refresh_token",
        "refresh_token": refreshToken, "client_id": configuration.clientID,
      ])
  }
  static func exchange(configuration: ConnectConfiguration, fields: [String: String]) async throws
    -> Self
  {
    var request = URLRequest(url: configuration.tokenEndpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = 25
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = ConnectionHTTP.form(fields)
    let result = try await ConnectionHTTP.shared.read(request)
    guard result["token_type"].string?.lowercased() == "bearer",
      let seconds = result["expires_in"].int, seconds > 0
    else { throw T3Error("Invalid T3 Connect account session.") }
    return Self(
      accessToken: try result.requiredString("access_token"),
      refreshToken: result["refresh_token"].string ?? fields["refresh_token"] ?? "",
      expiresAt: Date().addingTimeInterval(Double(seconds)))
  }
}

public struct ConnectEnvironment: Identifiable, Equatable, Sendable {
  public let id: String
  public let label: String
  public let endpoint: URL
  public init(_ json: JSON) throws {
    id = try json.requiredString("environmentId")
    label = try json.requiredString("label")
    endpoint = try ConnectionEndpoint.normalize(json["endpoint"].requiredString("httpBaseUrl"))
    guard endpoint.scheme == "https" else {
      throw T3Error("T3 Connect returned an insecure environment address.")
    }
  }
}

public struct ConnectClient: Sendable {
  public let configuration: ConnectConfiguration
  public let account: ConnectAccountToken
  public init(configuration: ConnectConfiguration, account: ConnectAccountToken) {
    self.configuration = configuration
    self.account = account
  }
  public func request(_ path: String, method: String = "GET", payload: JSON? = nil) async throws
    -> JSON
  {
    try await ConnectionHTTP.shared.read(
      ConnectionHTTP.request(
        endpoint: configuration.relay,
        path: path, method: method, token: account.accessToken, payload: payload))
  }
  public func environments() async throws -> [ConnectEnvironment] {
    let result = try await request("/v1/environments")
    guard case .array(let rows) = result["environments"] else {
      throw T3Error("Invalid T3 Connect environment catalog.")
    }
    return try rows.map(ConnectEnvironment.init)
  }
  public func pair(_ environment: ConnectEnvironment) async throws -> ConnectionSettings {
    let proof = ConnectionProof()
    var request = try ConnectionHTTP.request(
      endpoint: configuration.relay, path: "/v1/client/dpop-token",
      method: "POST", proof: proof)
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = ConnectionHTTP.form([
      "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
      "subject_token": account.accessToken,
      "subject_token_type": "urn:ietf:params:oauth:token-type:jwt",
      "requested_token_type": "urn:ietf:params:oauth:token-type:access_token",
      "resource": configuration.relay.absoluteString, "scope": "environment:connect",
      "client_id": "t3-web",
    ])
    let authorization = try await ConnectionHTTP.shared.read(request)
    guard authorization["token_type"].string == "DPoP",
      authorization["scope"].string == "environment:connect"
    else {
      throw T3Error("T3 Connect granted an unsupported authentication session.")
    }
    let id = environment.id.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
    let connected = try await ConnectionHTTP.shared.read(
      ConnectionHTTP.request(
        endpoint: configuration.relay,
        path: "/v1/environments/\(id)/connect", method: "POST",
        token: authorization.requiredString("access_token"),
        payload: .object(["clientProofKeyThumbprint": .string(proof.thumbprint)]), proof: proof))
    let target = try Self.pairingEndpoint(connected, expected: environment)
    return try await ConnectionHTTP.exchange(
      endpoint: target, credential: connected.requiredString("credential"), proof: proof)
  }
  public static func pairingEndpoint(_ response: JSON, expected: ConnectEnvironment) throws -> URL {
    let endpoint = try ConnectionEndpoint.normalize(
      response["endpoint"].requiredString("httpBaseUrl"))
    guard response["environmentId"].string == expected.id, endpoint == expected.endpoint else {
      throw T3Error(
        "T3 Connect returned a different environment. Refresh the catalog and try again.")
    }
    return endpoint
  }
  public func unlink(_ id: String) async throws {
    let id = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
    let result = try await request("/v1/client/environment-links/\(id)", method: "DELETE")
    guard result["ok"].bool else {
      throw T3Error("T3 Connect did not confirm removal of the environment.")
    }
  }
}
