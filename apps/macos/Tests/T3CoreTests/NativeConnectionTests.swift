import CryptoKit
import Foundation
import Testing

@testable import T3Core

@Suite struct NativeConnectionTests {
  @Test func canonicalEndpointsShareCredentialAndDraftIdentity() throws {
    let equivalents = [
      "https://MAC.Example/", "https://mac.example:443", "wss://mac.example", "mac.example",
    ]
    for value in equivalents {
      #expect(try ConnectionEndpoint.normalize(value).absoluteString == "https://mac.example")
      #expect(
        try ConnectionEndpoint.credentialAccount(
          URL(string: value.contains("://") ? value : "https://" + value)!) == "https://mac.example"
      )
    }
    #expect(
      try ConnectionEndpoint.normalize("http://[::1]:3774/").absoluteString == "http://[::1]:3774")
    for value in [
      "http://remote.example", "https://user:secret@host", "https://host/ws",
      "https://host?token=secret",
      "https://host#secret", "file:///tmp/file", "https://host:0", "https://host:65536",
      "http://127.1",
    ] {
      #expect(throws: (any Error).self) { try ConnectionEndpoint.normalize(value) }
    }
  }
  @Test func pairingLinksExtractSecretsWithoutSavingThemInEndpoint() throws {
    let direct = try RemotePairingTarget(
      address: "https://mac.example/#token=a%2Bb%26c", credential: "unused")
    #expect(direct.endpoint.absoluteString == "https://mac.example")
    #expect(direct.credential == "a+b&c")
    let hosted = try RemotePairingTarget(
      address: "https://app.t3.codes/?host=https%3A%2F%2Fmac.example&label=Mac#token=secret",
      credential: "")
    #expect(hosted.endpoint == direct.endpoint)
    #expect(hosted.credential == "secret")
    #expect(throws: (any Error).self) {
      try RemotePairingTarget(
        address: "https://app.t3.codes/?host=http%3A%2F%2Fremote.example#token=secret",
        credential: "")
    }
  }
  @Test func legacyMigrationRetainsSelectionAndNeverSerializesCredentials() throws {
    let legacy = try ConnectionSettings(
      endpoint: URL(string: "https://MAC.example:443/")!, token: "sensitive-access-token")
    var catalog = SavedConnections()
    try catalog.migrateLegacy(legacy)
    #expect(catalog.selectedID == "https://mac.example")
    #expect(catalog.environments.count == 1)
    let encoded = try JSONEncoder().encode(catalog)
    #expect(!String(decoding: encoded, as: UTF8.self).contains(legacy.token))
    let decoded = try SavedConnections.decode(encoded)
    #expect(decoded == catalog)
    try catalog.migrateLegacy(
      ConnectionSettings(endpoint: URL(string: "https://other.example")!, token: "other-token"))
    #expect(catalog == decoded)
    catalog.remove("https://mac.example")
    #expect(catalog.selectedID == nil)
  }
  @Test func legacyConnectionFilesRemainReadable() throws {
    let value = try JSONDecoder().decode(
      ConnectionSettings.self,
      from: Data(#"{"endpoint":"https://mac.example","token":"secret"}"#.utf8))
    #expect(value.proofKey == nil)
    #expect(
      value.request("/api/auth/session").value(forHTTPHeaderField: "Authorization")
        == "Bearer secret")
  }
  @Test func proofSignatureAndTokenBindingAreReal() throws {
    let key = ConnectionProof()
    let token = "example-token"
    let url = URL(string: "https://mac.example/oauth/token?ignored=yes#fragment")!
    let jwt = try key.jwt(
      method: "post", url: url, token: token, now: Date(timeIntervalSince1970: 1000))
    let fields = jwt.split(separator: ".").map(String.init)
    func decode(_ text: String) throws -> Data {
      let value = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(
        of: "_", with: "/")
      return try #require(
        Data(base64Encoded: value + String(repeating: "=", count: (4 - value.count % 4) % 4)))
    }
    let signature = try P256.Signing.ECDSASignature(rawRepresentation: decode(fields[2]))
    let publicKey = try P256.Signing.PrivateKey(rawRepresentation: key.rawRepresentation).publicKey
    #expect(publicKey.isValidSignature(signature, for: Data((fields[0] + "." + fields[1]).utf8)))
    let payload = try JSON.decode(decode(fields[1]))
    #expect(payload["htu"].string == "https://mac.example/oauth/token")
    #expect(payload["htm"].string == "POST")
    #expect(payload["iat"].int == 1000)
    #expect(
      payload["ath"].string == ConnectionProof.base64url(Data(SHA256.hash(data: Data(token.utf8)))))
    let restored = try ConnectionProof(rawRepresentation: key.rawRepresentation)
    #expect(restored.thumbprint == key.thumbprint)
    let settings = try ConnectionSettings(
      endpoint: URL(string: "https://mac.example")!, token: token, proofKey: key.rawRepresentation)
    #expect(
      settings.request("/api/auth/websocket-ticket", method: "POST").value(
        forHTTPHeaderField: "Authorization") == "DPoP " + token)
    #expect(
      settings.request("/api/auth/websocket-ticket", method: "POST").value(
        forHTTPHeaderField: "DPoP") != nil)
  }
  @Test func oauthUsesHostedFragmentAndRejectsForeignCallbacks() throws {
    let config = try ConnectConfiguration(
      relay: "https://relay.example",
      publishableKey: "pk_test_" + Data("clerk.example$".utf8).base64EncodedString(),
      clientID: "cli-client")
    let auth = ConnectAuthorization(configuration: config)
    #expect(auth.url.path == "/connect")
    #expect(auth.url.query == nil)
    #expect(auth.url.fragment?.contains("port=34338") == true)
    #expect(config.tokenEndpoint.absoluteString == "https://clerk.example/oauth/token")
    let url = URL(string: "http://127.0.0.1:34338/callback?state=\(auth.state)&code=code")!
    #expect(try auth.code(from: url) == "code")
    for input in [
      "http://127.0.0.1:34338/callback?state=wrong&code=code",
      "https://remote.example/callback?state=\(auth.state)&code=code",
      "http://127.0.0.1:34338/callback?state=\(auth.state)&code=code&code=other",
    ] {
      #expect(throws: (any Error).self) { try auth.code(from: URL(string: input)!) }
    }
  }
  @Test func relayPairingRejectsChangedEnvironmentOrEndpoint() throws {
    let environment: JSON = .object([
      "environmentId": .string("env-1"), "label": .string("Mac"),
      "endpoint": .object(["httpBaseUrl": .string("https://mac.example")]),
    ])
    let target = try ConnectEnvironment(environment)
    #expect(try ConnectClient.pairingEndpoint(environment, expected: target) == target.endpoint)
    #expect(throws: (any Error).self) {
      try ConnectClient.pairingEndpoint(
        .object(["environmentId": .string("env-2"), "endpoint": environment["endpoint"]]),
        expected: target)
    }
    #expect(throws: (any Error).self) {
      try ConnectClient.pairingEndpoint(
        .object([
          "environmentId": .string("env-1"),
          "endpoint": .object(["httpBaseUrl": .string("https://foreign.example")]),
        ]), expected: target)
    }
  }
  @Test func startupCannotUseLiveHomeIncludingSymlinkAliases() throws {
    let root = URL(fileURLWithPath: "/tmp/t3-native-evidence/connections-home-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent(".t3/userdata"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let alias = root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(
      at: alias, withDestinationURL: root.appendingPathComponent(".t3"))
    for home in [
      root.appendingPathComponent(".t3"), root.appendingPathComponent(".t3/userdata"), alias,
      alias.appendingPathComponent("userdata"),
    ] {
      #expect(throws: (any Error).self) {
        try BackendConfiguration(home: home).validate(userHome: root)
      }
    }
    try BackendConfiguration(home: root.appendingPathComponent("native")).validate(userHome: root)
  }
  @Test func bootstrapUsesExistingDesktopContractAndExplicitIsolation() throws {
    let home = URL(fileURLWithPath: "/tmp/t3-native-evidence/connection-config")
    let configuration = BackendConfiguration(home: home, port: 3779)
    let data = try configuration.bootstrap(token: "bootstrap-secret")
    let json = try JSON.decode(data)
    #expect(json["mode"].string == "desktop")
    #expect(json["host"].string == "127.0.0.1")
    #expect(json["t3Home"].string == home.path)
    #expect(json["noBrowser"].bool)
    #expect(!json["tailscaleServeEnabled"].bool)
    let env = BackendConfiguration.childEnvironment(
      [
        "T3CODE_HOME": "/live", "T3CODE_HOST": "0.0.0.0",
        "T3CODE_DEV_AUTH_TOKEN": "secret", "NODE_OPTIONS": "--inspect",
        "T3CODE_DEV_ALLOWED_ORIGINS": "https://app.t3.codes",
        "HTTPS_PROXY": "https://proxy.example",
        "PATH": "/usr/bin:/opt/homebrew/bin:/custom/cli:/usr/bin",
      ],
      home: home,
      bundledNode: URL(
        fileURLWithPath: "/Applications/T3 Native.app/Contents/Resources/backend/node/bin/node"),
      userHome: URL(fileURLWithPath: "/Users/provider"))
    #expect(env["T3CODE_HOME"] == home.path)
    #expect(env["T3CODE_HOST"] == nil)
    #expect(env["T3CODE_DEV_AUTH_TOKEN"] == nil)
    #expect(env["NODE_OPTIONS"] == nil)
    #expect(env["HTTPS_PROXY"] == "https://proxy.example")
    #expect(env["T3CODE_DEV_ALLOWED_ORIGINS"] == "https://app.t3.codes")
    let path = (env["PATH"] ?? "").split(separator: ":").map(String.init)
    #expect(path.first == "/Applications/T3 Native.app/Contents/Resources/backend/node/bin")
    for directory in [".local/bin", ".bun/bin", ".local/share/mise/shims", ".npm-global/bin"] {
      #expect(path.contains("/Users/provider/" + directory))
    }
    #expect(path.contains("/custom/cli"))
    #expect(path.contains("/bin"))
    #expect(path.filter { $0 == "/usr/bin" }.count == 1)
    #expect(path.filter { $0 == "/opt/homebrew/bin" }.count == 1)
    #expect(!path.contains(home.appendingPathComponent(".local/bin").path))
  }
  @Test func bundledRuntimeRequiresArm64AndPreservesServerTreeLayout() throws {
    let root = URL(
      fileURLWithPath: "/tmp/t3-native-evidence/connections-assets-" + UUID().uuidString)
    let runtime = BackendRuntime.bundled(resources: root)
    #expect(runtime.node.path.hasSuffix("/backend/node/bin/node"))
    #expect(runtime.serverEntry.path.hasSuffix("/backend/server/apps/server/dist/bin.mjs"))
    try FileManager.default.createDirectory(
      at: runtime.node.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: runtime.serverEntry.deletingLastPathComponent(), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data().write(to: runtime.serverEntry)
    try Data([0xcf, 0xfa, 0xed, 0xfe, 0x07, 0x00, 0x00, 0x01]).write(to: runtime.node)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: runtime.node.path)
    #expect(throws: (any Error).self) { try runtime.validate() }
    try Data([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0x00, 0x00, 0x01]).write(to: runtime.node)
    try runtime.validate()
  }
  @Test func reconnectAtSameEndpointInvalidatesOldOperations() throws {
    let settings = try ConnectionSettings(
      endpoint: URL(string: "https://mac.example")!, token: "token")
    let original = RPCConnection(settings: settings)
    let replacement = RPCConnection(settings: settings)
    let operation = ConnectionOperation(
      environment: settings.endpoint.absoluteString, connection: original)
    try operation.requireCurrent(
      environment: settings.endpoint.absoluteString, connection: original)
    #expect(throws: (any Error).self) {
      try operation.requireCurrent(
        environment: settings.endpoint.absoluteString, connection: replacement)
    }
    #expect(throws: (any Error).self) {
      try operation.requireCurrent(environment: settings.endpoint.absoluteString, connection: nil)
    }
    #expect(throws: (any Error).self) {
      try operation.requireCurrent(environment: "https://other.example", connection: original)
    }
  }
  @Test func migrationKeepsRealDraftsAndPendingSubmissions() throws {
    let directory = URL(
      fileURLWithPath: "/tmp/t3-native-evidence/connections-drafts-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = DraftRepository(directory: directory)
    let legacy = try ConnectionSettings(
      endpoint: URL(string: "https://MAC.example:443/")!, token: "token")
    let drafts = SavedDrafts(
      messages: ["thread": "unsent message"],
      submissions: ["thread": PendingSubmission(text: "pending message")])
    try repository.save(drafts, for: legacy.endpoint)
    var catalog = SavedConnections()
    try catalog.migrateLegacy(legacy)
    #expect(try repository.load(for: catalog.environments[0].endpoint) == drafts)
  }
  @Test @MainActor func processOwnershipOnlyStopsTheCapturedChild() async throws {
    let owned = OwnedBackendProcess()
    let other = OwnedBackendProcess()
    let executable = URL(fileURLWithPath: "/bin/sleep")
    let directory = URL(fileURLWithPath: "/tmp")
    try owned.start(
      executable: executable, arguments: ["30"], directory: directory, environment: [:])
    try other.start(
      executable: executable, arguments: ["30"], directory: directory, environment: [:])
    defer {
      owned.terminate()
      other.terminate()
    }
    #expect(owned.processIdentifier != other.processIdentifier)
    #expect(other.isRunning)
    owned.terminate()
    await owned.waitForExit()
    #expect(!owned.isRunning)
    #expect(other.isRunning)
    #expect(throws: (any Error).self) {
      try owned.start(executable: executable, arguments: [], directory: directory, environment: [:])
    }
    other.terminate()
    await other.waitForExit()
  }
}
