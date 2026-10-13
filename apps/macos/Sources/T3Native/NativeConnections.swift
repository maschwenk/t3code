import AppKit
import Combine
import SwiftUI
import T3Core

@MainActor final class NativeConnections: ObservableObject {
  let store: ClientStore
  let host: BackendHost
  @Published private(set) var environments: [SavedEnvironment] = []
  @Published private(set) var discovered: [ConnectEnvironment] = []
  @Published private(set) var clients: [JSON] = []
  @Published private(set) var pairingLinks: [JSON] = []
  @Published private(set) var cloudState: JSON = .null
  @Published private(set) var error: String?
  @Published private(set) var notice: String?
  @Published private(set) var busy = false
  @Published private(set) var signedIn = false
  @Published private(set) var signInPending = false
  @Published private(set) var relayStatus: JSON = .null
  @Published private(set) var pairingURL: URL?
  @Published private(set) var accountAvailable = false
  private let preferences: UserDefaults
  private let credentials: Credentials.Access
  private var loading = false
  private var accountLoaded = false
  private var repository: ConnectionRepository?
  private var accountConfiguration: ConnectConfiguration?
  private var account: ConnectAccountToken?
  private var accessConnection: RPCConnection?
  private var accessEndpoint: URL?
  private let callback = ConnectCallback()
  private var operation: Task<Void, Never>?
  private var generation = UUID()
  private var accountGeneration = UUID()

  init(
    store: ClientStore, host: BackendHost = .shared, preferences: UserDefaults = .standard,
    credentials: Credentials.Access = .keychain
  ) {
    self.store = store
    self.host = host
    self.credentials = credentials
    self.preferences = preferences
    do {
      accountConfiguration = try ConnectConfiguration.bundled(
        info: Bundle.main.infoDictionary ?? [:])
      accountAvailable = true
    } catch { accountAvailable = false }
    run { _ in }
  }
  private func load(_ current: UUID) async throws {
    if repository == nil {
      let loaded = try await ConnectionRepository(
        preferences: preferences, credentials: credentials
      ) {
        try self.requireGeneration(current)
      }
      try requireGeneration(current)
      repository = loaded
      environments = loaded.values.environments
    }
    if !accountLoaded {
      let accountID = accountGeneration
      if let configuration = accountConfiguration {
        do {
          let loaded = try await Credentials.loadAccount(
            configuration: configuration, access: credentials)
          try requireGeneration(current)
          guard accountGeneration == accountID else { throw CancellationError() }
          account = loaded
          signedIn = loaded != nil
        } catch is CancellationError { throw CancellationError() } catch {
          try requireGeneration(current)
          accountLoaded = true
          throw error
        }
      }
      try requireGeneration(current)
      accountLoaded = true
    }
  }
  private func requireGeneration(_ current: UUID) throws {
    try Task.checkCancellation()
    guard generation == current else { throw CancellationError() }
  }
  private func run(_ body: @escaping @MainActor (UUID) async throws -> Void) {
    if busy {
      guard loading else { return }
      // An action replaces initialization; retry loading inside its tracked task so
      // cancelling or superseding a Keychain prompt cannot lose the first action.
      cancel()
    }
    let current = UUID()
    generation = current
    busy = true
    loading = repository == nil || !accountLoaded
    error = nil
    notice = nil
    pairingURL = nil
    operation = Task { [weak self] in
      guard let self else { return }
      defer {
        if self.generation == current {
          self.busy = false
          self.loading = false
          self.operation = nil
        }
      }
      do {
        try await self.load(current)
        try self.requireGeneration(current)
        self.loading = false
        try await body(current)
      } catch is CancellationError {
        if self.generation == current, self.repository == nil, !Task.isCancelled {
          self.error =
            "Saved connections changed while loading. Reopen Connections or retry your action to reload."
        }
      } catch {
        if self.generation == current { self.error = error.localizedDescription }
      }
    }
  }
  func cancel() {
    generation = UUID()
    operation?.cancel()
    operation = nil
    callback.cancel()
    busy = false
    loading = false
    signInPending = false
  }
  private func check(_ current: UUID, environment: String, connection: RPCConnection?) throws {
    try requireGeneration(current)
    try ConnectionOperation(environment: environment, connection: connection)
      .requireCurrent(environment: store.environmentKey, connection: store.browserConnection)
  }
  private func connected() throws -> (RPCConnection, URL) {
    guard let connection = store.browserConnection, let endpoint = store.browserEndpoint else {
      throw T3Error("Connect to an environment first.")
    }
    return (connection, endpoint)
  }
  private func verify(_ connection: RPCConnection, _ endpoint: URL, _ current: UUID) throws {
    try check(current, environment: endpoint.absoluteString, connection: connection)
  }
  private func http(
    _ path: String, method: String = "GET", payload: JSON? = nil,
    connection: RPCConnection, endpoint: URL, generation: UUID
  ) async throws -> JSON {
    try verify(connection, endpoint, generation)
    let settings = await connection.settings
    try verify(connection, endpoint, generation)
    var request = settings.request(path, method: method)
    if let payload {
      request.httpBody = try payload.data()
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let result = try await ConnectionHTTP.shared.read(request)
    try verify(connection, endpoint, generation)
    return result
  }
  private func rpc(
    _ method: String, payload: JSON = .object([:]), connection: RPCConnection,
    endpoint: URL, generation: UUID
  ) async throws -> JSON {
    try verify(connection, endpoint, generation)
    let result = try await connection.call(method, payload: payload)
    try verify(connection, endpoint, generation)
    return result
  }
  private func use(
    _ settings: ConnectionSettings, label: String, local: Bool = false, cloudID: String? = nil,
    generation current: UUID, origin: String, connection: RPCConnection?
  ) async throws {
    try check(current, environment: origin, connection: connection)
    guard store.saveDraftsBeforeExit() else {
      throw T3Error(store.storageError ?? "Save your drafts before switching environments.")
    }
    guard let repository else {
      throw T3Error("Saved connections are unavailable. Resolve the catalog error first.")
    }
    let environment = try await repository.remember(
      settings, label: label, local: local, cloudEnvironmentID: cloudID
    ) {
      try self.check(current, environment: origin, connection: connection)
    }
    try check(current, environment: origin, connection: connection)
    store.connect(settings)
    guard store.environmentKey == settings.endpoint.absoluteString else {
      throw T3Error(
        store.error ?? "The environment could not be selected. Your drafts are preserved.")
    }
    try repository.select(environment)
    environments = repository.values.environments
    clearAccess()
  }
  private func clearAccess() {
    accessConnection = nil
    accessEndpoint = nil
    clients = []
    pairingLinks = []
    cloudState = .null
    relayStatus = .null
    pairingURL = nil
  }
  func select(_ environment: SavedEnvironment) {
    let origin = store.environmentKey
    let connection = store.browserConnection
    run { [self] current in
      let settings: ConnectionSettings
      if environment.local {
        guard environment.endpoint == host.configuration.endpoint else {
          throw T3Error("This saved local endpoint differs from the native host's configured port.")
        }
        settings = try await host.start()
      } else if let id = environment.cloudEnvironmentID, signedIn {
        let client = try await cloudClient()
        let catalog = try await client.environments()
        guard let discovered = catalog.first(where: { $0.id == id }) else {
          throw T3Error("This environment is no longer registered with your T3 Connect account.")
        }
        settings = try await client.pair(discovered)
      } else {
        guard let repository else { throw T3Error("The connection catalog is unavailable.") }
        settings = try await repository.settings(for: environment)
      }
      try check(current, environment: origin, connection: connection)
      try await use(
        settings, label: environment.label, local: environment.local,
        cloudID: environment.cloudEnvironmentID, generation: current, origin: origin,
        connection: connection)
    }
  }
  func pair(address: String, credential: String, label: String, savedToken: Bool) {
    let origin = store.environmentKey
    let connection = store.browserConnection
    run { [self] current in
      let target = try RemotePairingTarget(address: address, credential: credential)
      let settings =
        savedToken
        ? try ConnectionSettings(endpoint: target.endpoint, token: target.credential)
        : try await ConnectionHTTP.exchange(
          endpoint: target.endpoint, credential: target.credential)
      // Validate a pasted access token before overwriting a known good saved credential.
      let session = try await ConnectionHTTP.shared.read(settings.request("/api/auth/session"))
      guard session["authenticated"].bool else {
        throw T3Error("The server did not authenticate this session.")
      }
      try check(current, environment: origin, connection: connection)
      try await use(
        settings, label: label, generation: current, origin: origin, connection: connection)
    }
  }
  func startLocal(home: String, port: String) {
    let origin = store.environmentKey
    let connection = store.browserConnection
    run { [self] current in
      guard let value = Int(port), home.hasPrefix("/") else {
        throw T3Error("Enter an absolute data directory and a valid port.")
      }
      let config = BackendConfiguration(home: URL(fileURLWithPath: home), port: value)
      if config != host.configuration { try host.configure(config) }
      let settings = try await host.start()
      try check(current, environment: origin, connection: connection)
      try await use(
        settings, label: "This Mac", local: true, generation: current,
        origin: origin, connection: connection)
    }
  }
  func stopLocal() {
    run { [self] _ in
      if store.browserEndpoint == host.configuration.endpoint {
        guard store.saveDraftsBeforeExit() else {
          throw T3Error("Save your drafts before stopping the native server.")
        }
        store.disconnect()
        clearAccess()
      }
      try await host.stop()
    }
  }
  func forget(_ environment: SavedEnvironment) {
    run { [self] current in
      guard let repository else { throw T3Error("Saved connections are unavailable.") }
      if store.environmentKey == environment.id {
        guard store.saveDraftsBeforeExit() else {
          throw T3Error("Save your drafts before removing this environment.")
        }
        store.disconnect()
        clearAccess()
      }
      let origin = store.environmentKey
      let connection = store.browserConnection
      try await repository.remove(environment) {
        try self.check(current, environment: origin, connection: connection)
      }
      try check(current, environment: origin, connection: connection)
      environments = repository.values.environments
      notice =
        "Removed from this Mac. Server sessions and T3 Connect registration are managed separately."
    }
  }
  func refreshAccess() {
    clearAccess()
    run { [self] current in
      let (connection, endpoint) = try connected()
      let session = try await http(
        "/api/auth/session", connection: connection, endpoint: endpoint, generation: current)
      accessConnection = connection
      accessEndpoint = endpoint
      let scopes = session["scopes"].array.compactMap(\.string)
      if scopes.contains("access:read") {
        clients = try await http(
          "/api/auth/clients", connection: connection, endpoint: endpoint, generation: current
        ).array
        pairingLinks = try await http(
          "/api/auth/pairing-links", connection: connection, endpoint: endpoint, generation: current
        ).array
      } else {
        notice =
          "This session cannot manage other clients. Pair with an administrator link to manage access."
      }
      if scopes.contains("relay:read") {
        cloudState = try await http(
          "/api/connect/link-state", connection: connection, endpoint: endpoint, generation: current
        )
        relayStatus = try await rpc(
          "cloud.getRelayClientStatus", connection: connection, endpoint: endpoint,
          generation: current)
      }
    }
  }
  func createPairingLink() {
    run { [self] current in
      let (connection, endpoint) = try connected()
      let result = try await http(
        "/api/auth/pairing-token", method: "POST",
        payload: .object(["label": .string("Phone or iPad")]), connection: connection,
        endpoint: endpoint, generation: current)
      let configuration = try await rpc(
        "server.getConfig", connection: connection, endpoint: endpoint, generation: current)
      let remote = configuration["directEndpoints"].array.first?["httpBaseUrl"].string
      let environmentID = configuration["environment"]["environmentId"].string
      let cloud = discovered.first(where: { $0.id == environmentID })?.endpoint.absoluteString
      let address = cloud ?? remote ?? endpoint.absoluteString
      let base = try ConnectionEndpoint.normalize(address)
      var url = URLComponents(url: base, resolvingAgainstBaseURL: false)!
      var fragment = URLComponents()
      fragment.queryItems = [
        URLQueryItem(name: "token", value: try result.requiredString("credential"))
      ]
      url.percentEncodedFragment = fragment.percentEncodedQuery
      pairingURL = url.url
      notice =
        ["127.0.0.1", "localhost"].contains(base.host ?? "")
        ? "This address only works on this Mac. Link this host with T3 Connect for phone/iPad access."
        : "Open this one-time link on the device you want to pair. It grants standard client access."
    }
  }
  func revoke(id: String, pairing: Bool) {
    run { [self] current in
      let (connection, endpoint) = try connected()
      guard accessConnection === connection, accessEndpoint == endpoint else {
        throw T3Error(
          "The access list belongs to a previous connection. Refresh access before revoking anything."
        )
      }
      let result = try await http(
        pairing ? "/api/auth/pairing-links/revoke" : "/api/auth/clients/revoke", method: "POST",
        payload: .object([pairing ? "id" : "sessionId": .string(id)]), connection: connection,
        endpoint: endpoint, generation: current)
      guard result["revoked"].bool else {
        throw T3Error("The server did not confirm revocation. Refresh access before retrying.")
      }
      if pairing {
        pairingLinks.removeAll { $0["id"].string == id }
      } else {
        clients.removeAll { $0["sessionId"].string == id }
      }
      notice = pairing ? "Pairing link revoked." : "Client session revoked."
    }
  }
  private func cloudClient() async throws -> ConnectClient {
    let current = accountGeneration
    let operationID = generation
    guard let configuration = accountConfiguration, let account else {
      throw T3Error("Sign in to T3 Connect first.")
    }
    let refreshed = try await account.refreshed(configuration: configuration)
    try requireGeneration(operationID)
    guard current == accountGeneration else { throw CancellationError() }
    try await Credentials.saveAccount(refreshed, configuration: configuration, access: credentials)
    try requireGeneration(operationID)
    guard current == accountGeneration else { throw CancellationError() }
    self.account = refreshed
    return ConnectClient(configuration: configuration, account: refreshed)
  }
  func signIn() {
    run { [self] current in
      guard let configuration = accountConfiguration else {
        throw T3Error("T3 Connect public configuration is missing from this app bundle.")
      }
      let accountID = accountGeneration
      signInPending = true
      defer { if generation == current { signInPending = false } }
      let authorization = ConnectAuthorization(configuration: configuration)
      let callbackURL = try await callback.authorize(authorization) { NSWorkspace.shared.open($0) }
      try requireGeneration(current)
      guard accountGeneration == accountID else { throw CancellationError() }
      let token = try await authorization.exchange(callbackURL)
      try requireGeneration(current)
      guard accountGeneration == accountID else { throw CancellationError() }
      try await Credentials.saveAccount(token, configuration: configuration, access: credentials)
      try requireGeneration(current)
      guard accountGeneration == accountID else { throw CancellationError() }
      accountGeneration = UUID()
      account = token
      signedIn = true
      let signedInID = accountGeneration
      let catalog = try await cloudClient().environments()
      try Task.checkCancellation()
      guard generation == current, accountGeneration == signedInID else {
        throw CancellationError()
      }
      discovered = catalog
    }
  }
  func signOut() {
    cancel()
    accountGeneration = UUID()
    let accountID = accountGeneration
    accountLoaded = true
    account = nil
    signedIn = false
    discovered = []
    run { [self] current in
      if let configuration = accountConfiguration {
        try await Credentials.removeAccount(configuration: configuration, access: credentials)
      }
      try requireGeneration(current)
      guard accountGeneration == accountID else { throw CancellationError() }
      notice = "Signed out on this Mac. Existing server sessions and host links remain active."
    }
  }
  func discover() {
    run { [self] current in
      let accountID = accountGeneration
      let result = try await cloudClient().environments()
      try Task.checkCancellation()
      guard generation == current, accountGeneration == accountID else { throw CancellationError() }
      discovered = result
    }
  }
  func pairCloud(_ environment: ConnectEnvironment) {
    let origin = store.environmentKey
    let connection = store.browserConnection
    run { [self] current in
      let settings = try await cloudClient().pair(environment)
      try check(current, environment: origin, connection: connection)
      try await use(
        settings, label: environment.label, cloudID: environment.id,
        generation: current, origin: origin, connection: connection)
    }
  }
  func linkHost() {
    run { [self] current in
      let (connection, endpoint) = try connected()
      guard host.isRunning, endpoint == host.configuration.endpoint else {
        throw T3Error("Start and select this Mac's native server before linking its host.")
      }
      let status = try await rpc(
        "cloud.getRelayClientStatus", connection: connection, endpoint: endpoint,
        generation: current)
      guard status["status"].string == "available" else {
        throw T3Error("Install the relay connector using Install connector, then link this Mac.")
      }
      let client = try await cloudClient()
      try verify(connection, endpoint, current)
      let configuration = try await rpc(
        "server.getConfig", connection: connection, endpoint: endpoint, generation: current)
      let id = try configuration["environment"].requiredString("environmentId")
      let preferences: JSON = .object([
        "notificationsEnabled": .bool(true), "liveActivitiesEnabled": .bool(true),
        "managedTunnelsEnabled": .bool(true),
      ])
      let challenge = try await client.request(
        "/v1/client/environment-link-challenges", method: "POST", payload: preferences)
      try verify(connection, endpoint, current)
      var ws = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
      ws.scheme = "ws"
      let proof = try await http(
        "/api/connect/link-proof", method: "POST",
        payload: .object([
          "challenge": challenge["challenge"],
          "relayIssuer": .string(client.configuration.relay.absoluteString),
          "endpoint": .object([
            "httpBaseUrl": .string(endpoint.absoluteString),
            "wsBaseUrl": .string(ws.url!.absoluteString),
            "providerKind": .string("cloudflare_tunnel"),
          ]),
          "origin": .object([
            "localHttpHost": .string("127.0.0.1"),
            "localHttpPort": .number(Double(host.configuration.port)),
          ]),
        ]),
        connection: connection, endpoint: endpoint, generation: current)
      let link = try await client.request(
        "/v1/client/environment-links", method: "POST",
        payload: .object([
          "proof": proof, "notificationsEnabled": .bool(true), "liveActivitiesEnabled": .bool(true),
          "managedTunnelsEnabled": .bool(true),
        ]))
      try verify(connection, endpoint, current)
      guard link["environmentId"].string == id,
        link["endpoint"]["providerKind"].string == "cloudflare_tunnel"
      else {
        throw T3Error(
          "T3 Connect returned a different host. The host was not configured; refresh the account catalog to remove the link."
        )
      }
      let configured = try await http(
        "/api/connect/relay-config", method: "POST",
        payload: .object([
          "relayUrl": .string(client.configuration.relay.absoluteString),
          "relayIssuer": link["relayIssuer"],
          "cloudUserId": link["cloudUserId"],
          "environmentCredential": link["environmentCredential"],
          "cloudMintPublicKey": link["cloudMintPublicKey"],
          "endpointRuntime": link["endpointRuntime"],
        ]),
        connection: connection, endpoint: endpoint, generation: current)
      guard configured["ok"].bool, configured["endpointRuntimeStatus"]["status"].string == "running"
      else {
        throw T3Error(
          "The host link was saved but the tunnel did not report running. Refresh its status before retrying."
        )
      }
      cloudState = try await http(
        "/api/connect/link-state", connection: connection, endpoint: endpoint, generation: current)
      let catalog = try await client.environments()
      try verify(connection, endpoint, current)
      discovered = catalog
      notice =
        "This Mac is linked. Keep its native server running and select it from T3 Account on your phone or iPad."
    }
  }
  func installConnector() {
    run { [self] current in
      let (connection, endpoint) = try connected()
      guard endpoint == host.configuration.endpoint, host.isRunning else {
        throw T3Error("Select this Mac to install its connector.")
      }
      let stream = try await connection.subscribe("cloud.installRelayClient")
      defer { Task { await connection.cancel(stream.id) } }
      var complete = false
      for try await event in stream.values {
        try verify(connection, endpoint, current)
        if event["type"].string == "complete" {
          relayStatus = event["status"]
          complete = event["status"]["status"].string == "available"
        }
      }
      guard complete else {
        throw T3Error("The relay connector did not report a completed installation.")
      }
      notice = "Connector installed. Link this Mac to enable T3 Connect."
    }
  }
  func unlinkHost() {
    run { [self] current in
      let (connection, endpoint) = try connected()
      let configuration = try await rpc(
        "server.getConfig", connection: connection, endpoint: endpoint, generation: current)
      _ = try await http(
        "/api/connect/unlink", method: "POST", connection: connection, endpoint: endpoint,
        generation: current)
      cloudState = .null
      do {
        try await cloudClient().unlink(configuration["environment"].requiredString("environmentId"))
        try verify(connection, endpoint, current)
        let catalog = try await cloudClient().environments()
        try verify(connection, endpoint, current)
        discovered = catalog
        notice = "T3 Connect host access disabled and its account registration removed."
      } catch {
        throw T3Error(
          "The local host link was disabled, but account removal failed: "
            + error.localizedDescription
            + " Refresh the account catalog and remove its registration.")
      }
    }
  }
  func removeCloud(_ environment: ConnectEnvironment) {
    run { [self] current in
      let accountID = accountGeneration
      try await cloudClient().unlink(environment.id)
      try Task.checkCancellation()
      guard generation == current, accountGeneration == accountID else { throw CancellationError() }
      discovered.removeAll { $0.id == environment.id }
      notice =
        "Environment removed from this T3 Connect account. Saved direct connections remain on this Mac."
    }
  }
}

@MainActor struct ConnectionsSettingsView: View {
  @StateObject private var model: NativeConnections
  @ObservedObject private var host: BackendHost
  @State private var address = ""
  @State private var credential = ""
  @State private var label = ""
  @State private var savedToken = false
  @State private var home: String
  @State private var port: String
  @State private var confirmation: ConnectionConfirmation?

  init(store: ClientStore) {
    let host = BackendHost.shared
    _model = StateObject(wrappedValue: NativeConnections(store: store, host: host))
    _host = ObservedObject(wrappedValue: host)
    _home = State(initialValue: host.configuration.home.path)
    _port = State(initialValue: String(host.configuration.port))
  }
  var body: some View {
    Form {
      if let error = model.error ?? host.error {
        Text(error).foregroundStyle(.red).textSelection(.enabled)
      }
      if let notice = model.notice {
        Text(notice).foregroundStyle(.secondary).textSelection(.enabled)
      }
      Section("Saved environments") {
        if model.environments.isEmpty { Text("No saved environments").foregroundStyle(.secondary) }
        ForEach(model.environments) { environment in
          HStack {
            VStack(alignment: .leading) {
              Text(environment.label)
              Text(environment.endpoint.absoluteString).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Connect") { model.select(environment) }.disabled(model.busy)
            Button("Remove…") { confirmation = .forget(environment) }.disabled(model.busy)
          }
        }
      }
      Section("This Mac") {
        LabeledContent("Native server", value: host.state)
        TextField("Data directory", text: $home).disabled(host.isRunning || model.busy)
        TextField("Port", text: $port).disabled(host.isRunning || model.busy)
        HStack {
          Button(host.isRunning ? "Connect to this Mac" : "Start native server") {
            model.startLocal(home: home, port: port)
          }
          .disabled(model.busy)
          if host.isRunning { Button("Stop server…") { confirmation = .stop }.disabled(model.busy) }
        }
        Text(
          "The native server owns its data in this directory. Keep it running for phone and iPad access through T3 Connect."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      Section("Add a remote environment") {
        TextField("Server address or pairing link", text: $address)
        TextField("Name", text: $label)
        SecureField(savedToken ? "Access token" : "Pairing code", text: $credential)
        Toggle("Use an existing access token", isOn: $savedToken)
        Button("Pair and connect") {
          model.pair(address: address, credential: credential, label: label, savedToken: savedToken)
          credential = ""
        }
        .disabled(model.busy || address.isEmpty)
      }
      Section("T3 Connect account") {
        if !model.accountAvailable {
          Text(
            "T3 Connect is not configured in this build. Package the relay URL, Clerk publishable key, and CLI OAuth client ID to enable sign-in."
          )
          .foregroundStyle(.secondary)
        } else if model.signedIn {
          HStack {
            Button("Refresh environments") { model.discover() }.disabled(model.busy)
            Button("Sign out") { model.signOut() }.disabled(model.busy && !model.signInPending)
          }
          ForEach(model.discovered) { environment in
            HStack {
              VStack(alignment: .leading) {
                Text(environment.label)
                Text(environment.endpoint.absoluteString).font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              Button("Connect") { model.pairCloud(environment) }.disabled(model.busy)
              Button("Remove from account…") { confirmation = .cloud(environment) }.disabled(
                model.busy)
            }
          }
        } else {
          Button("Sign in with browser…") { model.signIn() }.disabled(model.busy)
          if model.signInPending { Button("Cancel sign-in") { model.cancel() } }
        }
        HStack {
          Button("Link this Mac…") { confirmation = .link }.disabled(
            model.busy || !model.signedIn || !host.isRunning)
          Button("Unlink selected host…") { confirmation = .unlink }.disabled(model.busy)
          Button("Install connector…") { confirmation = .install }.disabled(
            model.busy || !host.isRunning)
        }
        if model.cloudState != .null {
          LabeledContent(
            "Host link", value: model.cloudState["linked"].bool ? "Linked" : "Not linked")
          LabeledContent(
            "Managed tunnel",
            value: model.cloudState["managedTunnelActive"].bool ? "Active" : "Inactive")
        }
      }
      Section("Clients and pairing links") {
        HStack {
          Button("Refresh access") { model.refreshAccess() }.disabled(model.busy)
          Button("Create phone/iPad pairing link") { model.createPairingLink() }.disabled(
            model.busy)
        }
        if let url = model.pairingURL {
          Text("One-time pairing link ready").font(.caption)
          Button("Copy pairing link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
          }
        }
        ForEach(model.clients, id: \.displayText) { client in
          HStack {
            Text(client["client"]["label"].string ?? "Client")
            Text(client["connected"].bool ? "Connected" : "Offline").font(.caption).foregroundStyle(
              .secondary)
            Spacer()
            if client["current"].bool {
              Text("This session").font(.caption)
            } else {
              Button("Revoke…") { confirmation = .revoke(client["sessionId"].string ?? "", false) }
                .disabled(model.busy)
            }
          }
        }
        ForEach(model.pairingLinks, id: \.displayText) { link in
          HStack {
            Text(link["label"].string ?? "Pairing link")
            Spacer()
            Button("Revoke…") { confirmation = .revoke(link["id"].string ?? "", true) }.disabled(
              model.busy)
          }
        }
      }
      if model.busy {
        HStack {
          ProgressView().controlSize(.small)
          Text("Working…")
          Button("Cancel") { model.cancel() }
        }
      }
    }
    .formStyle(.grouped)
    .alert(item: $confirmation) { confirmation in
      Alert(
        title: Text(confirmation.title), message: Text(confirmation.message),
        primaryButton: .default(Text(confirmation.action)) { perform(confirmation) },
        secondaryButton: .cancel())
    }
    .onDisappear { model.cancel() }
  }
  private func perform(_ action: ConnectionConfirmation) {
    switch action {
    case .forget(let environment): model.forget(environment)
    case .cloud(let environment): model.removeCloud(environment)
    case .stop: model.stopLocal()
    case .link: model.linkHost()
    case .unlink: model.unlinkHost()
    case .install: model.installConnector()
    case .revoke(let id, let pairing): model.revoke(id: id, pairing: pairing)
    }
  }
}

private enum ConnectionConfirmation: Identifiable {
  case forget(SavedEnvironment)
  case cloud(ConnectEnvironment)
  case stop, link, unlink, install
  case revoke(String, Bool)
  var id: String { title }
  var title: String {
    switch self {
    case .forget: "Remove saved environment?"
    case .cloud: "Remove environment from account?"
    case .stop: "Stop this Mac's server?"
    case .link: "Enable T3 Connect on this Mac?"
    case .unlink: "Disable T3 Connect on the selected host?"
    case .install: "Install the relay connector?"
    case .revoke: "Revoke access?"
    }
  }
  var message: String {
    switch self {
    case .forget:
      "This removes its saved credential from this Mac. Drafts are preserved. Server sessions remain active."
    case .cloud:
      "T3 Connect access and its managed tunnel will be revoked for all devices. Direct saved connections remain."
    case .stop: "Phone and iPad access to this native host will stop until you start it again."
    case .link:
      "This links the native server to your signed-in T3 account and starts its managed tunnel for remote devices."
    case .unlink: "The selected host's managed tunnel and T3 Connect registration will be removed."
    case .install:
      "The server will download and install its supported relay connector. This does not enable the tunnel until you link this Mac."
    case .revoke: "The selected client session or pairing link will lose access immediately."
    }
  }
  var action: String {
    switch self {
    case .forget, .cloud: "Remove"
    case .stop: "Stop"
    case .link: "Link this Mac"
    case .unlink: "Unlink"
    case .install: "Install"
    case .revoke: "Revoke"
    }
  }
}
