import Foundation

public struct ConnectionSettings: Codable, Sendable {
  public let endpoint: URL
  public let token: String
  public let proofKey: Data?

  public init(endpoint: URL, token: String, proofKey: Data? = nil) throws {
    guard let parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
      let host = parts.host, parts.user == nil, parts.password == nil,
      parts.query == nil, parts.fragment == nil,
      parts.path.isEmpty || parts.path == "/",
      parts.scheme == "https"
        || (parts.scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host))
    else { throw T3Error("Use an HTTPS server address, or HTTP on localhost.") }
    guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw T3Error("Enter a pairing token or saved access token.", authentication: true)
    }
    self.endpoint = endpoint
    self.token = token
    if let proofKey { _ = try ConnectionProof(rawRepresentation: proofKey) }
    self.proofKey = proofKey
  }

  public static func load(_ file: URL) throws -> Self {
    let decoded = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
    return try Self(endpoint: decoded.endpoint, token: decoded.token, proofKey: decoded.proofKey)
  }

  public func request(_ path: String, method: String = "GET", query: [URLQueryItem] = [])
    -> URLRequest
  {
    var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
    parts.path = path
    parts.queryItems = query.isEmpty ? nil : query
    var request = URLRequest(url: parts.url!)
    request.httpMethod = method
    request.timeoutInterval = 25
    if let proofKey {
      // Invalid keys fail closed: never downgrade a proof-bound token to bearer auth.
      if let proof = try? ConnectionProof(rawRepresentation: proofKey),
        let jwt = try? proof.jwt(method: method, url: request.url!, token: token)
      {
        request.setValue("DPoP \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(jwt, forHTTPHeaderField: "DPoP")
      }
    } else {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    request.setValue("2", forHTTPHeaderField: "x-t3-orchestration-protocol")
    return request
  }
}

public enum EnvironmentHTTP {
  public static func read(_ request: URLRequest, session: URLSession? = nil) async throws -> JSON {
    let (data, response) = try await (session ?? ConnectionHTTP.shared.session!).data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw T3Error("Invalid server response.")
    }
    guard (200..<300).contains(response.statusCode) else {
      let reason = (try? JSON.decode(data))?["reason"].string ?? "request_failed"
      throw T3Error(
        "Server returned \(response.statusCode): \(reason)",
        authentication: response.statusCode == 401 || response.statusCode == 403)
    }
    return try JSON.decode(data)
  }

  public static func pair(endpoint: URL, credential: String) async throws -> ConnectionSettings {
    let settings = try ConnectionSettings(endpoint: endpoint, token: credential)
    var request = settings.request("/oauth/token", method: "POST")
    request.setValue(nil, forHTTPHeaderField: "Authorization")
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    let fields = [
      "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
      "subject_token": credential,
      "subject_token_type": "urn:t3:params:oauth:token-type:environment-bootstrap",
      "requested_token_type": "urn:ietf:params:oauth:token-type:access_token",
      "scope": "orchestration:read orchestration:operate terminal:operate review:write",
      "client_label": "T3 Native", "client_device_type": "desktop", "client_os": "macOS",
    ]
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    request.httpBody = fields.sorted(by: { $0.key < $1.key }).map {
      "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
    }.joined(separator: "&").data(using: .utf8)
    let result = try await read(request)
    guard result["token_type"].string == "Bearer" else {
      throw T3Error("This prototype requires a bearer session.")
    }
    return try ConnectionSettings(endpoint: endpoint, token: result.requiredString("access_token"))
  }
}

public struct RPCSubscription: Sendable {
  public let id: String
  public let values: AsyncThrowingStream<JSON, any Error>
}

public actor RPCConnection {
  public let settings: ConnectionSettings
  private let session: URLSession
  private var socket: URLSessionWebSocketTask?
  private var receiver: Task<Void, Never>?
  private var heartbeat: Task<Void, Never>?
  private var streams: [String: AsyncThrowingStream<JSON, any Error>.Continuation] = [:]
  private var calls: [String: CheckedContinuation<JSON, any Error>] = [:]
  private var timeouts: [String: Task<Void, Never>] = [:]
  private var lastResponse = Date()

  public init(settings: ConnectionSettings) {
    self.settings = settings
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 25
    self.session = URLSession(
      configuration: config, delegate: ConnectionHTTP.shared, delegateQueue: nil)
  }

  public func open() async throws {
    let ticket = try await EnvironmentHTTP.read(
      settings.request("/api/auth/websocket-ticket", method: "POST"), session: session)
    try Task.checkCancellation()
    var url = URLComponents(url: settings.endpoint, resolvingAgainstBaseURL: false)!
    url.scheme = url.scheme == "https" ? "wss" : "ws"
    url.path = "/ws"
    url.queryItems = [
      URLQueryItem(name: "wsTicket", value: try ticket.requiredString("ticket")),
      URLQueryItem(name: "orchestrationProtocol", value: "2"),
    ]
    let task = session.webSocketTask(with: url.url!)
    task.maximumMessageSize = 32 * 1024 * 1024
    socket = task
    task.resume()
    receiver = Task { [weak self] in
      do {
        while !Task.isCancelled {
          let message = try await task.receive()
          try await self?.receive(message)
        }
      } catch { await self?.close(error: T3Error("Connection lost. Reconnecting…")) }
    }
    heartbeat = Task { [weak self] in
      do {
        while !Task.isCancelled {
          try await Task.sleep(for: .seconds(15))
          try await self?.ping()
        }
      } catch { await self?.close(error: T3Error("Server stopped responding. Reconnecting…")) }
    }
  }

  private func ping() async throws {
    guard Date().timeIntervalSince(lastResponse) < 45 else { throw T3Error("Heartbeat expired.") }
    try await send(.object(["_tag": .string("Ping")]))
  }

  private func send(_ value: JSON) async throws {
    guard let socket else { throw T3Error("Not connected.") }
    try await socket.send(.string(String(decoding: try value.data(), as: UTF8.self)))
  }

  public static func request(id: String, method: String, payload: JSON) -> JSON {
    .object([
      "_tag": .string("Request"), "id": .string(id), "tag": .string(method),
      "payload": payload, "headers": .array([]),
    ])
  }

  public func subscribe(_ method: String, payload: JSON = .object([:])) async throws
    -> RPCSubscription
  {
    let id = UUID().uuidString
    let (values, continuation) = AsyncThrowingStream<JSON, any Error>.makeStream(
      bufferingPolicy: .bufferingOldest(256))
    streams[id] = continuation
    do { try await send(Self.request(id: id, method: method, payload: payload)) } catch {
      streams.removeValue(forKey: id)?.finish(throwing: error)
      throw error
    }
    return RPCSubscription(id: id, values: values)
  }

  public func cancel(_ id: String) async {
    streams.removeValue(forKey: id)?.finish()
    try? await send(.object(["_tag": .string("Interrupt"), "requestId": .string(id)]))
  }

  public func call(_ method: String, payload: JSON) async throws -> JSON {
    try Task.checkCancellation()
    let id = UUID().uuidString
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        calls[id] = continuation
        timeouts[id] = Task { [weak self] in
          do { try await Task.sleep(for: .seconds(25)) } catch { return }
          await self?.failCall(
            id,
            error: T3Error(
              "Request timed out; its result is unknown. Check the conversation before retrying."))
        }
        Task {
          guard calls[id] != nil else { return }
          do { try await send(Self.request(id: id, method: method, payload: payload)) } catch {
            failCall(id, error: error)
          }
        }
      }
    } onCancel: {
      Task { await self.failCall(id, error: CancellationError()) }
    }
  }

  private func failCall(_ id: String, error: any Error) {
    timeouts.removeValue(forKey: id)?.cancel()
    calls.removeValue(forKey: id)?.resume(throwing: error)
  }

  private func receive(_ message: URLSessionWebSocketTask.Message) async throws {
    let data: Data
    switch message {
    case .data(let bytes): data = bytes
    case .string(let text): data = Data(text.utf8)
    @unknown default: throw T3Error("Unsupported WebSocket frame.")
    }
    let json = try JSON.decode(data)
    let frames: [JSON] = if case .array(let batch) = json { batch } else { [json] }
    lastResponse = Date()
    for frame in frames {
      let id = frame["requestId"].string ?? ""
      switch frame["_tag"].string {
      case "Chunk":
        if let stream = streams[id] {
          for value in frame["values"].array {
            if case .dropped = stream.yield(value) {
              throw T3Error("Live updates exceeded the client buffer. Reloading the snapshot.")
            }
          }
        }
        try await send(.object(["_tag": .string("Ack"), "requestId": .string(id)]))
      case "Exit":
        timeouts.removeValue(forKey: id)?.cancel()
        let exit = frame["exit"]
        if exit["_tag"].string == "Success" {
          calls.removeValue(forKey: id)?.resume(returning: exit["value"])
          streams.removeValue(forKey: id)?.finish()
        } else {
          let error = Self.requestError(exit)
          calls.removeValue(forKey: id)?.resume(throwing: error)
          streams.removeValue(forKey: id)?.finish(throwing: error)
        }
      case "Pong": break
      case "Defect", "ClientProtocolError":
        throw T3Error("The server rejected this protocol session.")
      default: break
      }
    }
  }

  public static func failureMessage(_ value: JSON) -> String {
    if let message = value["message"].string { return message }
    if let detail = value["detail"].string { return detail }
    if case .object(let fields) = value {
      for key in ["cause", "error", "failure", "defect", "reasons"] {
        if let child = fields[key] {
          let result = failureMessage(child)
          if result != "Server rejected the request." { return result }
        }
      }
    }
    for child in value.array {
      let result = failureMessage(child)
      if result != "Server rejected the request." { return result }
    }
    return "Server rejected the request."
  }

  public static func failureCode(_ value: JSON) -> String? {
    failureDetails(value)?["_tag"].string
  }

  public static func requestError(_ value: JSON) -> T3Error {
    let details = failureDetails(value)
    return T3Error(
      details?["message"].string ?? details?["detail"].string ?? failureMessage(value),
      remoteCode: details?["_tag"].string, remoteFailure: details?["failure"].string)
  }

  private static func failureDetails(_ value: JSON) -> JSON? {
    if let tag = value["_tag"].string, tag.hasSuffix("Error") { return value }
    if case .object(let fields) = value {
      for key in ["cause", "error", "failure", "defect", "reasons"] {
        if let child = fields[key], let details = failureDetails(child) { return details }
      }
    }
    return value.array.lazy.compactMap(failureDetails).first
  }

  public func close(error: any Error = CancellationError()) {
    receiver?.cancel()
    receiver = nil
    heartbeat?.cancel()
    heartbeat = nil
    socket?.cancel(with: .goingAway, reason: nil)
    socket = nil
    for stream in streams.values { stream.finish(throwing: error) }
    streams.removeAll()
    for call in calls.values { call.resume(throwing: error) }
    calls.removeAll()
    for timeout in timeouts.values { timeout.cancel() }
    timeouts.removeAll()
    session.invalidateAndCancel()
  }
}
