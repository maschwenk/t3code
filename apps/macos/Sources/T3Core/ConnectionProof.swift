import CryptoKit
import Foundation

public struct ConnectionProof: Sendable {
  private let key: P256.Signing.PrivateKey
  public init() { key = P256.Signing.PrivateKey() }
  public init(rawRepresentation: Data) throws {
    key = try P256.Signing.PrivateKey(rawRepresentation: rawRepresentation)
  }
  public var rawRepresentation: Data { key.rawRepresentation }
  public var publicJWK: [String: JSON] {
    let bytes = key.publicKey.x963Representation
    return [
      "kty": .string("EC"), "crv": .string("P-256"),
      "x": .string(Self.base64url(bytes.subdata(in: 1..<33))),
      "y": .string(Self.base64url(bytes.subdata(in: 33..<65))),
    ]
  }
  public var thumbprint: String {
    Self.base64url(Data(SHA256.hash(data: try! Self.canonical(.object(publicJWK)))))
  }
  public func jwt(method: String, url: URL, token: String? = nil, now: Date = Date()) throws
    -> String
  {
    var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    parts.query = nil
    parts.fragment = nil
    var payload: [String: JSON] = [
      "jti": .string(UUID().uuidString),
      "htm": .string(method.uppercased()), "htu": .string(parts.url!.absoluteString),
      "iat": .number(floor(now.timeIntervalSince1970)),
    ]
    if let token {
      payload["ath"] = .string(Self.base64url(Data(SHA256.hash(data: Data(token.utf8)))))
    }
    let header = JSON.object([
      "typ": .string("dpop+jwt"), "alg": .string("ES256"), "jwk": .object(publicJWK),
    ])
    let input =
      Self.base64url(try Self.canonical(header)) + "."
      + Self.base64url(try Self.canonical(.object(payload)))
    return input + "." + Self.base64url(try key.signature(for: Data(input.utf8)).rawRepresentation)
  }
  public static func base64url(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }
  public static func canonical(_ json: JSON) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(json)
  }
}

/// All account and connection-management requests reject redirects rather than forwarding credentials.
public final class ConnectionHTTP: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  public static let shared = ConnectionHTTP()
  public private(set) var session: URLSession!
  public override init() {
    super.init()
    let config = URLSessionConfiguration.ephemeral
    config.httpCookieAcceptPolicy = .never
    config.httpShouldSetCookies = false
    session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
  }
  public func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) { completionHandler(nil) }
  public func read(_ request: URLRequest) async throws -> JSON {
    try await EnvironmentHTTP.read(request, session: session)
  }
  public static func form(_ fields: [String: String]) -> Data {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    return Data(
      fields.sorted { $0.key < $1.key }.map {
        $0.key + "=" + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)!
      }.joined(separator: "&").utf8)
  }
  public static func request(
    endpoint: URL, path: String, method: String = "GET", token: String? = nil,
    payload: JSON? = nil, proof: ConnectionProof? = nil
  ) throws -> URLRequest {
    let origin = try ConnectionEndpoint.normalize(endpoint.absoluteString)
    var parts = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
    parts.path = path
    var request = URLRequest(url: parts.url!)
    request.httpMethod = method
    request.timeoutInterval = 25
    if let token {
      request.setValue(
        (proof == nil ? "Bearer " : "DPoP ") + token, forHTTPHeaderField: "Authorization")
    }
    if let proof {
      request.setValue(
        try proof.jwt(method: method, url: request.url!, token: token), forHTTPHeaderField: "DPoP")
    }
    if let payload {
      request.httpBody = try payload.data()
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    return request
  }
  public static func exchange(
    endpoint: URL, credential: String, proof: ConnectionProof? = nil,
    scopes: String? = nil
  ) async throws -> ConnectionSettings {
    var request = try Self.request(
      endpoint: endpoint, path: "/oauth/token", method: "POST", proof: proof)
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    var fields = [
      "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
      "subject_token": credential,
      "subject_token_type": "urn:t3:params:oauth:token-type:environment-bootstrap",
      "requested_token_type": "urn:ietf:params:oauth:token-type:access_token",
      "client_label": "T3 Native", "client_device_type": "desktop", "client_os": "macOS",
    ]
    if let scopes { fields["scope"] = scopes }
    request.httpBody = form(fields)
    let result = try await shared.read(request)
    guard result["token_type"].string == (proof == nil ? "Bearer" : "DPoP") else {
      throw T3Error("The server returned an unsupported authentication session.")
    }
    return try ConnectionSettings(
      endpoint: endpoint, token: result.requiredString("access_token"),
      proofKey: proof?.rawRepresentation)
  }
}
