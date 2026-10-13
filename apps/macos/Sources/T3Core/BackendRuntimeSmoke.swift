import Darwin
import Foundation

/// Explicit packaging validation. This never uses preferences or Keychain.
public enum BackendRuntimeSmoke {
  public struct Report: Codable, Sendable {
    public let home: String
    public let port: Int
    public let processID: Int32
    public let environmentID: String
    public let authenticatedSession: Bool
    public let webIndexMatchesBundle: Bool
    public let healthStatus: Int
    public let healthIsHTML: Bool
    public let childStopped: Bool
    public let exitStatus: Int32?
  }

  @MainActor public static func run(resources: URL, newHome: URL) async throws -> Report {
    let runtime = BackendRuntime.bundled(resources: resources)
    try runtime.validate()
    let root = newHome.standardizedFileURL.resolvingSymlinksInPath()
    let temporaryRoots = [NSTemporaryDirectory(), "/tmp"].map {
      URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
    }
    guard root.isFileURL, temporaryRoots.contains(where: { root.path.hasPrefix($0 + "/") }),
      !FileManager.default.fileExists(atPath: root.path)
    else {
      throw T3Error(
        "Runtime smoke validation requires a new directory under the system temporary directory.")
    }
    let configuration = BackendConfiguration(home: root, port: try freePort())
    try configuration.validate()
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let userHome = root.appendingPathComponent("probe-user", isDirectory: true)
    try FileManager.default.createDirectory(
      at: userHome, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    var environment = BackendConfiguration.childEnvironment(
      ProcessInfo.processInfo.environment,
      home: root, bundledNode: runtime.node)
    environment["HOME"] = userHome.path
    environment["XDG_CONFIG_HOME"] = userHome.appendingPathComponent(".config").path
    environment["XDG_DATA_HOME"] = userHome.appendingPathComponent(".local/share").path
    environment["XDG_CACHE_HOME"] = userHome.appendingPathComponent(".cache").path
    let child = OwnedBackendProcess()
    var connection: RPCConnection?
    do {
      let secret = ConnectionProof.base64url(ConnectionProof().rawRepresentation)
      try child.start(
        executable: runtime.node,
        arguments: [runtime.serverEntry.path, "--bootstrap-fd", "0"], directory: root,
        environment: environment, input: configuration.bootstrap(token: secret))
      let settings = try await waitForSession(
        child: child, endpoint: configuration.endpoint, secret: secret)
      let auth = try await ConnectionHTTP.shared.read(settings.request("/api/auth/session"))
      guard auth["authenticated"].bool else {
        throw T3Error("The runtime session was not authenticated.")
      }
      let rpc = RPCConnection(settings: settings)
      connection = rpc
      try await rpc.open()
      let config = try await rpc.call("server.getConfig", payload: .object([:]))
      let environmentID = try config["environment"].requiredString("environmentId")
      let keybindings = try config.requiredString("keybindingsConfigPath")
      guard keybindings.hasPrefix(root.path + "/") else {
        throw T3Error("The packaged server did not use the isolated data directory.")
      }
      let (index, response) = try await get(
        configuration.endpoint.appendingPathComponent("index.html"))
      let bundledIndex = try Data(
        contentsOf: runtime.serverEntry.deletingLastPathComponent()
          .appendingPathComponent("client/index.html"))
      guard response.statusCode == 200, index == bundledIndex else {
        throw T3Error("The packaged web index did not match the served index.")
      }
      let (health, healthResponse) = try await get(
        configuration.endpoint.appendingPathComponent("health"))
      await rpc.close()
      connection = nil
      let pid = child.processIdentifier!
      try await stop(child)
      return Report(
        home: root.path, port: configuration.port, processID: pid,
        environmentID: environmentID, authenticatedSession: true, webIndexMatchesBundle: true,
        healthStatus: healthResponse.statusCode,
        healthIsHTML: String(decoding: health.prefix(512), as: UTF8.self).lowercased().contains(
          "<html"),
        childStopped: !child.isRunning, exitStatus: child.exitStatus)
    } catch {
      if let connection { await connection.close() }
      try await stop(child)
      throw error
    }
  }

  @MainActor private static func waitForSession(
    child: OwnedBackendProcess, endpoint: URL,
    secret: String
  ) async throws -> ConnectionSettings {
    let deadline = Date().addingTimeInterval(60)
    while Date() < deadline {
      try Task.checkCancellation()
      guard child.isRunning else {
        throw T3Error(
          "The packaged backend exited before authentication (exit \(child.exitStatus ?? -1)).")
      }
      do {
        let session = try await ConnectionHTTP.exchange(endpoint: endpoint, credential: secret)
        try Task.checkCancellation()
        guard child.isRunning else {
          throw T3Error("The packaged backend exited after authentication.")
        }
        return session
      } catch is CancellationError { throw CancellationError() } catch let error as T3Error
        where error.authentication
      { throw error } catch {}
      try await Task.sleep(for: .milliseconds(200))
    }
    throw T3Error("The packaged backend did not authenticate within 60 seconds.")
  }

  private static func get(_ url: URL) async throws -> (Data, HTTPURLResponse) {
    var request = URLRequest(url: url)
    request.timeoutInterval = 10
    let (data, response) = try await ConnectionHTTP.shared.session.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw T3Error("Invalid runtime HTTP response.")
    }
    return (data, response)
  }

  @MainActor private static func stop(_ child: OwnedBackendProcess) async throws {
    child.terminate()
    let deadline = Date().addingTimeInterval(10)
    while child.isRunning, Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
    // Only the still-running captured Process may be escalated during a smoke probe.
    if child.isRunning, let pid = child.processIdentifier { _ = Darwin.kill(pid, SIGKILL) }
    let forcedDeadline = Date().addingTimeInterval(5)
    while child.isRunning, Date() < forcedDeadline {
      try? await Task.sleep(for: .milliseconds(100))
    }
    guard !child.isRunning else { throw T3Error("The owned runtime smoke child did not stop.") }
  }

  private static func freePort() throws -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw T3Error("Could not reserve a smoke probe port.") }
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let result = withUnsafeMutablePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
        guard bind(fd, socketAddress, length) == 0 else { return Int32(-1) }
        return getsockname(fd, socketAddress, &length)
      }
    }
    guard result == 0 else { throw T3Error("Could not allocate a free loopback smoke probe port.") }
    return Int(UInt16(bigEndian: address.sin_port))
  }
}
