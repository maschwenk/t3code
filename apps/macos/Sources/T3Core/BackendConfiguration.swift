import Foundation

public struct BackendConfiguration: Codable, Equatable, Sendable {
  public var home: URL
  public var port: Int
  public init(home: URL, port: Int = 3774) {
    self.home = home
    self.port = port
  }
  public static var defaultHome: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("T3Native/server", isDirectory: true)
  }
  public var endpoint: URL { URL(string: "http://127.0.0.1:\(port)")! }
  public func validate(userHome: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
    guard (1...65535).contains(port), home.isFileURL, home.path.hasPrefix("/") else {
      throw T3Error("Use an absolute data directory and a port between 1 and 65535.")
    }
    let actual = home.standardizedFileURL.resolvingSymlinksInPath().path
    let live = userHome.appendingPathComponent(".t3").standardizedFileURL.resolvingSymlinksInPath()
      .path
    // A fresh native host must never contend with the running Electron install's database.
    guard actual != live, !actual.hasPrefix(live + "/"), actual != userHome.path, actual != "/"
    else {
      throw T3Error(
        "Choose a separate native server directory. The live ~/.t3 directory is in use.")
    }
  }
  public func bootstrap(token: String) throws -> Data {
    try validate()
    return try JSON.object([
      "mode": .string("desktop"), "noBrowser": .bool(true),
      "port": .number(Double(port)), "t3Home": .string(home.path), "host": .string("127.0.0.1"),
      "desktopBootstrapToken": .string(token), "tailscaleServeEnabled": .bool(false),
      "tailscaleServePort": .number(443),
    ]).data() + Data([10])
  }
  public static func childEnvironment(
    _ inherited: [String: String], home: URL,
    bundledNode: URL? = nil, userHome: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> [String: String] {
    var env = inherited
    for key in [
      "T3CODE_PORT", "T3CODE_MODE", "T3CODE_NO_BROWSER", "T3CODE_HOST",
      "T3CODE_HOME", "T3CODE_BOOTSTRAP_FD", "T3CODE_DESKTOP_WS_URL", "T3CODE_DESKTOP_LAN_ACCESS",
      "T3CODE_DESKTOP_LAN_HOST", "T3CODE_DESKTOP_HTTPS_ENDPOINTS", "T3CODE_TAILSCALE_SERVE",
      "T3CODE_TAILSCALE_SERVE_PORT", "T3CODE_DEV_AUTH_TOKEN", "VITE_DEV_SERVER_URL",
      "VITE_HTTP_URL", "VITE_WS_URL", "NODE_OPTIONS", "ELECTRON_RUN_AS_NODE",
    ] { env.removeValue(forKey: key) }
    env["T3CODE_HOME"] = home.path
    // Finder does not load shell profiles. Provider scripts using /usr/bin/env node
    // must also resolve the packaged Node rather than require a separate install.
    var candidates = bundledNode.map { [$0.deletingLastPathComponent().path] } ?? []
    candidates += [".local/bin", ".bun/bin", ".local/share/mise/shims", ".npm-global/bin"]
      .map { userHome.appendingPathComponent($0).path }
    candidates += ["/opt/homebrew/bin", "/usr/local/bin"]
    candidates += (env["PATH"] ?? "").split(separator: ":").map(String.init)
    candidates += ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    var seen = Set<String>()
    let entries = candidates.filter { seen.insert($0).inserted }
    env["PATH"] = entries.joined(separator: ":")
    return env
  }
}

public struct BackendRuntime: Sendable {
  public let node: URL
  public let serverEntry: URL
  public init(node: URL, serverEntry: URL) {
    self.node = node
    self.serverEntry = serverEntry
  }
  public static func bundled(resources: URL) -> Self {
    Self(
      node: resources.appendingPathComponent("backend/node/bin/node"),
      serverEntry: resources.appendingPathComponent("backend/server/apps/server/dist/bin.mjs"))
  }
  public func validate() throws {
    #if !arch(arm64)
      throw T3Error("T3 Native requires Apple Silicon.")
    #else
      guard FileManager.default.isExecutableFile(atPath: node.path),
        FileManager.default.fileExists(atPath: serverEntry.path)
      else {
        throw T3Error(
          "The bundled Node/server runtime is missing. Rebuild the app with its backend assets.")
      }
      let handle = try FileHandle(forReadingFrom: node)
      defer { try? handle.close() }
      let header = try handle.read(upToCount: 8) ?? Data()
      guard header == Data([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0x00, 0x00, 0x01]) else {
        throw T3Error("Package the Apple Silicon arm64 Node runtime for this native app.")
      }
    #endif
  }
}
