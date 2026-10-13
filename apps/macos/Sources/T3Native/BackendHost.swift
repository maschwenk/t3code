import Combine
import Darwin
import Foundation
import T3Core

@MainActor final class BackendHost: ObservableObject {
  static let shared = BackendHost()
  @Published private(set) var state = "Stopped"
  @Published private(set) var settings: ConnectionSettings?
  @Published private(set) var error: String?
  @Published private(set) var configuration: BackendConfiguration
  private var child: OwnedBackendProcess?
  private var generation = UUID()
  private var starting = false
  private let preferences: UserDefaults
  private let runtime: BackendRuntime?
  var isRunning: Bool { child?.isRunning ?? false }

  init(runtime: BackendRuntime? = nil, preferences: UserDefaults = .standard) {
    self.preferences = preferences
    self.runtime = runtime ?? Bundle.main.resourceURL.map(BackendRuntime.bundled(resources:))
    if let data = preferences.data(forKey: "native.backendConfiguration.v1"),
      let saved = try? JSONDecoder().decode(BackendConfiguration.self, from: data)
    {
      configuration = saved
    } else {
      configuration = BackendConfiguration(home: BackendConfiguration.defaultHome)
    }
  }
  func configure(_ value: BackendConfiguration) throws {
    guard !isRunning, !starting else {
      throw T3Error("Stop the native server before changing its data directory or port.")
    }
    try value.validate()
    preferences.set(try JSONEncoder().encode(value), forKey: "native.backendConfiguration.v1")
    configuration = value
  }
  /// Parent calls at startup only when the selected environment is local (or on first launch).
  func start() async throws -> ConnectionSettings {
    if let settings, isRunning { return settings }
    guard !starting, !isRunning else {
      throw T3Error("The local server is already starting. Wait for it to finish.")
    }
    guard let runtime else { throw T3Error("The bundled backend runtime is unavailable.") }
    try runtime.validate()
    try configuration.validate()
    try Self.checkPort(configuration.port)
    let current = UUID()
    generation = current
    starting = true
    state = "Starting…"
    error = nil
    defer { starting = false }
    let token = ConnectionProof.base64url(ConnectionProof().rawRepresentation)
    let child = OwnedBackendProcess()
    self.child = child
    do {
      try FileManager.default.createDirectory(
        at: configuration.home, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try child.start(
        executable: runtime.node,
        arguments: [runtime.serverEntry.path, "--bootstrap-fd", "0"],
        directory: configuration.home,
        environment: BackendConfiguration.childEnvironment(
          ProcessInfo.processInfo.environment,
          home: configuration.home, bundledNode: runtime.node),
        input: configuration.bootstrap(token: token))
      let deadline = Date().addingTimeInterval(60)
      while Date() < deadline {
        try Task.checkCancellation()
        guard generation == current, child.isRunning else {
          throw T3Error(
            "The local server exited during startup\(child.exitStatus.map { " (exit \($0))" } ?? "")."
          )
        }
        do {
          // Successful exchange of this child's random secret proves ownership, unlike /health.
          let session = try await ConnectionHTTP.exchange(
            endpoint: configuration.endpoint, credential: token)
          guard generation == current, child.isRunning else { throw CancellationError() }
          settings = session
          state = "Running"
          Task { [weak self] in
            await child.waitForExit()
            guard let self, self.generation == current else { return }
            self.settings = nil
            self.child = nil
            self.state = "Stopped"
            self.error =
              "The local server exited (\(child.exitStatus ?? -1)). Start it again to reconnect."
          }
          return session
        } catch let failure as T3Error where failure.authentication {
          throw failure
        } catch is CancellationError { throw CancellationError() } catch {}
        try await Task.sleep(for: .milliseconds(250))
      }
      throw T3Error(
        "The local server did not become ready within 60 seconds. Check its runtime assets and data directory."
      )
    } catch {
      child.terminate()
      self.settings = nil
      state = "Stopped"
      self.error = error.localizedDescription
      throw error
    }
  }
  /// Stop only our child; the server's normal SIGTERM cleanup closes its managed tunnel.
  func stop() async throws {
    generation = UUID()
    settings = nil
    guard let child else {
      state = "Stopped"
      return
    }
    state = "Stopping…"
    child.terminate()
    let deadline = Date().addingTimeInterval(15)
    while child.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
    guard !child.isRunning else {
      state = "Still running"
      throw T3Error("The local server has not stopped. Keep the app open and try Stop again.")
    }
    self.child = nil
    state = "Stopped"
  }
  private static func checkPort(_ port: Int) throws {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw T3Error("Could not check the local server port.") }
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(port).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard result == 0 else {
      throw T3Error(
        "Port \(port) is already in use. Choose another port; the existing server will not be stopped."
      )
    }
  }
}
