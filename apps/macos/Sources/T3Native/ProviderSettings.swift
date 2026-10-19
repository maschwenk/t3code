import AppKit
import SwiftUI
import T3Core

@MainActor final class ManagementSettingsSession: ObservableObject {
  let store: ClientStore
  @Published var config: JSON = .null
  @Published var tasks: [ScheduledPrompt] = []
  @Published var login: ProviderLoginState?
  @Published var preferences = ModelPickerPreferences()
  @Published var error: String?
  @Published var busy = false
  @Published var loaded = false
  @Published var schedulesLoaded = false
  @Published var pendingProviderCreate: ProviderInstanceDraft?
  @Published var pendingScheduleCreate: ScheduledPromptDraft?
  private(set) var loginRevision = 0
  private(set) var loginInstanceID: String?
  private var connection: RPCConnection?
  private var endpoint: URL?
  private var generation = UUID()
  private var operation: Task<Void, Never>?

  init(store: ClientStore) { self.store = store }
  var connected: Bool {
    connection != nil && connection === store.browserConnection && endpoint == store.browserEndpoint
  }
  var environment: String { endpoint?.absoluteString ?? "" }
  var providers: [ManagedProvider] {
    config["providers"].array.compactMap {
      try? ManagedProvider(snapshot: $0, settings: config["settings"])
    }
  }

  func observe(schedules: Bool = false) async {
    operation?.cancel()
    let changedEndpoint = endpoint != store.browserEndpoint
    generation = UUID()
    let token = generation
    connection = store.browserConnection
    endpoint = store.browserEndpoint
    if changedEndpoint {
      pendingProviderCreate = UserDefaults.standard.data(
        forKey: "pendingProviderCreate:" + environment
      )
      .flatMap { try? JSONDecoder().decode(ProviderInstanceDraft.self, from: $0) }
      pendingScheduleCreate = UserDefaults.standard.data(
        forKey: "pendingScheduleCreate:" + environment
      )
      .flatMap { try? JSONDecoder().decode(ScheduledPromptDraft.self, from: $0) }
    }
    loaded = false
    schedulesLoaded = false
    busy = false
    config = .null
    tasks = []
    login = nil
    loginInstanceID = nil
    error = nil
    preferences = ModelPickerPreferences(environment: environment)
    guard let connection else { return }
    defer {
      if token == generation {
        operation?.cancel()
        self.connection = nil
        busy = false
      }
    }
    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await self.watchConfiguration(connection, token: token) }
        if schedules { group.addTask { try await self.watchSchedules(connection, token: token) } }
        try await group.waitForAll()
      }
    } catch {
      guard token == generation, connected, !Task.isCancelled else { return }
      self.error = "Settings could not be loaded. Refresh to reconnect."
    }
  }

  private func valid(_ connection: RPCConnection, token: UUID) throws {
    try Task.checkCancellation()
    guard token == generation, connection === self.connection,
      connection === store.browserConnection, endpoint == store.browserEndpoint
    else {
      throw CancellationError()
    }
  }
  private func watchConfiguration(_ connection: RPCConnection, token: UUID) async throws {
    let subscription = try await connection.subscribe("subscribeServerConfig")
    defer { Task { await connection.cancel(subscription.id) } }
    for try await value in subscription.values {
      try valid(connection, token: token)
      switch value["type"].string {
      case "snapshot":
        config = value["config"]
        loaded = true
      case "providerStatuses":
        if case .object(var fields) = config {
          fields["providers"] = value["payload"]["providers"]
          config = .object(fields)
        }
      case "settingsUpdated":
        if case .object(var fields) = config {
          fields["settings"] = value["payload"]["settings"]
          config = .object(fields)
        }
      default: break
      }
    }
  }
  private func watchSchedules(_ connection: RPCConnection, token: UUID) async throws {
    let subscription = try await connection.subscribe("scheduledTasks.subscribe")
    defer { Task { await connection.cancel(subscription.id) } }
    for try await value in subscription.values {
      try valid(connection, token: token)
      tasks = value["tasks"].array.compactMap { try? ScheduledPrompt($0) }
      schedulesLoaded = true
    }
  }
  func observeLogin(_ id: String) async {
    guard let connection, connected else { return }
    let token = generation
    login = nil
    loginInstanceID = id
    loginRevision += 1
    do {
      let subscription = try await connection.subscribe(
        "provider.auth.subscribe", payload: .object(["instanceId": .string(id)]))
      defer { Task { await connection.cancel(subscription.id) } }
      for try await value in subscription.values {
        try valid(connection, token: token)
        let next = try ProviderLoginState(value)
        guard next.instanceID == id, loginInstanceID == id else { continue }
        login = next
        loginRevision += 1
      }
    } catch {
      guard token == generation, connected, !Task.isCancelled else { return }
      self.error = "Account status could not be loaded."
    }
  }
  func request(_ method: String, _ payload: JSON) async throws -> JSON {
    guard let connection, connected else { throw T3Error("Connect to a server first.") }
    let token = generation
    let result = try await connection.call(method, payload: payload)
    try valid(connection, token: token)
    return result
  }
  func perform(_ action: @escaping @MainActor () async throws -> Void) {
    guard !busy, connected else { return }
    busy = true
    error = nil
    let token = generation
    operation = Task {
      defer {
        if token == generation {
          busy = false
          operation = nil
        }
      }
      do { try await action() } catch {
        guard token == generation, connected else { return }
        self.error =
          "The action did not finish. Its server result may be unknown. Refresh to check before retrying; the editor keeps the same account or task ID."
      }
    }
  }
  func cancelOperation() { operation?.cancel() }
  func persistPendingCreates() throws {
    guard connected else { throw CancellationError() }
    let defaults = UserDefaults.standard
    if let pendingProviderCreate {
      defaults.set(
        try JSONEncoder().encode(pendingProviderCreate),
        forKey: "pendingProviderCreate:" + environment)
    } else {
      defaults.removeObject(forKey: "pendingProviderCreate:" + environment)
    }
    if let pendingScheduleCreate {
      defaults.set(
        try JSONEncoder().encode(pendingScheduleCreate),
        forKey: "pendingScheduleCreate:" + environment)
    } else {
      defaults.removeObject(forKey: "pendingScheduleCreate:" + environment)
    }
  }
  func persistPreferences() {
    guard connected else { return }
    do { try preferences.save(environment: environment) } catch {
      self.error = "Model preferences could not be saved."
    }
  }
}

struct ProviderSettingsView: View {
  let store: ClientStore
  @StateObject private var session: ManagementSettingsSession
  @State private var draft: ProviderInstanceDraft?
  @State private var editingID: String?
  @State private var editor = false
  @State private var accountID: String?
  @State private var removing: ManagedProvider?
  @State private var draftEnvironment: String?
  @State private var refreshID = UUID()

  init(store: ClientStore) {
    self.store = store
    _session = StateObject(wrappedValue: ManagementSettingsSession(store: store))
  }
  var body: some View {
    Form {
      Section {
        HStack {
          Label("Providers & accounts", systemImage: "person.crop.circle.badge.checkmark").font(
            .headline)
          Spacer()
          Button("Refresh") { refreshID = UUID() }.disabled(
            session.busy || store.browserConnection == nil)
        }
        Text(
          "Accounts and CLI paths belong to \(store.browserEndpoint?.host ?? "the connected server")."
        )
        .font(.caption).foregroundStyle(.secondary)
        if !session.connected {
          Text("Connect to a server to manage accounts.").foregroundStyle(.secondary)
        } else if !session.loaded {
          ProgressView("Loading accounts…")
        }
        if let error = session.error { Text(error).foregroundStyle(.orange).font(.caption) }
        if session.busy {
          HStack {
            ProgressView().controlSize(.small)
            Button("Cancel action", action: session.cancelOperation)
          }
        }
      }
      ForEach(session.providers) { provider in
        Section {
          HStack {
            VStack(alignment: .leading, spacing: 4) {
              Text(provider.name).font(.headline)
              Text(
                provider.signedIn
                  ? (provider.account.isEmpty ? "Signed in" : provider.account) : "Not signed in"
              )
              .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(provider.status.capitalized).font(.caption).foregroundStyle(
              provider.status == "error" ? .orange : .secondary)
          }
          LabeledContent(
            "Runtime",
            value: provider.driver == "claudeAgent" ? "Claude Code" : provider.driver.capitalized)
          LabeledContent(
            "Home",
            value: provider.envelope["config"]["homePath"].string.flatMap { $0.isEmpty ? nil : $0 }
              ?? "Provider default")
          LabeledContent(
            "Binary",
            value: provider.envelope["config"]["binaryPath"].string.flatMap {
              $0.isEmpty ? nil : $0
            } ?? "Provider default")
          HStack {
            Button("Account…") { accountID = provider.id }
            if ["codex", "claudeAgent"].contains(provider.driver) {
              Button("Configure…") {
                draft = ProviderInstanceDraft(provider: provider)
                editingID = provider.id
                draftEnvironment = session.environment
                editor = true
              }
            }
            Spacer()
            if provider.explicit { Button("Remove…", role: .destructive) { removing = provider } }
          }.disabled(session.busy || !session.connected)
          ProviderModelPreferencesRows(session: session, provider: provider)
        } header: {
          Text(provider.name)
        }
      }
      Section {
        Button(
          session.pendingProviderCreate != nil || draft != nil && editingID == nil
            ? "Continue adding account…" : "Add account…"
        ) {
          if let pending = session.pendingProviderCreate {
            draft = pending
            editingID = nil
          } else if draft == nil || editingID != nil {
            draft = ProviderInstanceDraft()
            editingID = nil
          }
          draftEnvironment = session.environment
          editor = true
        }.disabled(!session.connected || !session.loaded || session.busy)
      } footer: {
        Text(
          "Claude and Codex accounts can use separate homes. Model visibility and favorites are saved on this Mac for this server."
        )
      }
    }
    .formStyle(.grouped)
    .task(
      id: (store.browserConnection.map { String(describing: ObjectIdentifier($0)) } ?? "")
        + refreshID.uuidString
    ) { await session.observe() }
    .onChange(of: session.environment) { _, next in
      if let draftEnvironment, draftEnvironment != next {
        draft = nil
        editor = false
        accountID = nil
        editingID = nil
      }
    }
    .sheet(isPresented: $editor) {
      if let draft {
        ProviderInstanceEditor(session: session, initial: draft, creating: editingID == nil) {
          value in
          self.draft = value
        } saved: {
          self.draft = nil
          editingID = nil
          editor = false
        } cancel: {
          editor = false
        }
      }
    }
    .sheet(isPresented: Binding(get: { accountID != nil }, set: { if !$0 { accountID = nil } })) {
      if let id = accountID { ProviderAccountSheet(session: session, id: id) { accountID = nil } }
    }
    .confirmationDialog(
      "Remove this account?",
      isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
      titleVisibility: .visible, presenting: removing
    ) { provider in
      Button("Remove \(provider.name)", role: .destructive) {
        session.perform {
          _ = try await session.request(
            "server.updateSettings",
            .object([
              "patch": .object([:]),
              "providerInstanceMutation": .object([
                "operation": .string("remove"), "instanceId": .string(provider.id),
              ]),
            ]))
          removing = nil
        }
      }
    } message: { _ in
      Text(
        "Threads using this account will need another provider. Credentials stay in the provider's home."
      )
    }
  }
}

private struct ProviderModelPreferencesRows: View {
  @ObservedObject var session: ManagementSettingsSession
  let provider: ManagedProvider
  @State private var expanded = false
  var body: some View {
    DisclosureGroup("Models", isExpanded: $expanded) {
      let models = session.preferences.models(
        provider.models, instanceID: provider.id, includingHidden: true)
      ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
        let identity = ModelIdentity(instanceID: provider.id, modelID: model.id)
        HStack {
          VStack(alignment: .leading) {
            Text(model.name)
            if model.custom { Text("Custom model").font(.caption).foregroundStyle(.secondary) }
          }
          Spacer()
          Button {
            if !session.preferences.favorites.insert(identity).inserted {
              session.preferences.favorites.remove(identity)
            }
            session.persistPreferences()
          } label: {
            Image(
              systemName: session.preferences.favorites.contains(identity) ? "star.fill" : "star")
          }
          .help("Favorite \(model.name)").accessibilityLabel("Favorite \(model.name)")
          Toggle(
            "Visible",
            isOn: Binding(
              get: { model.custom || !session.preferences.hidden.contains(identity) },
              set: { visible in
                if visible {
                  session.preferences.hidden.remove(identity)
                } else {
                  session.preferences.hidden.insert(identity)
                }
                session.persistPreferences()
              })
          ).disabled(model.custom).toggleStyle(.checkbox).fixedSize()
          Button {
            move(models, index, -1)
          } label: {
            Image(systemName: "chevron.up")
          }
          .disabled(index == 0).accessibilityLabel("Move \(model.name) up")
          Button {
            move(models, index, 1)
          } label: {
            Image(systemName: "chevron.down")
          }
          .disabled(index == models.count - 1).accessibilityLabel("Move \(model.name) down")
        }.buttonStyle(.borderless)
      }
    }.disabled(!session.connected)
  }
  private func move(_ models: [ProviderModel], _ index: Int, _ offset: Int) {
    var order = models.map(\.id)
    order.swapAt(index, index + offset)
    session.preferences.order[provider.id] = order
    session.persistPreferences()
  }
}

private struct ProviderInstanceEditor: View {
  @ObservedObject var session: ManagementSettingsSession
  @State var draft: ProviderInstanceDraft
  let creating: Bool
  let changed: (ProviderInstanceDraft) -> Void
  let saved: () -> Void
  let cancel: () -> Void
  @State private var modelID = ""
  @State private var modelName = ""
  @State private var validation: String?
  @State private var reconciled = false
  init(
    session: ManagementSettingsSession, initial: ProviderInstanceDraft, creating: Bool,
    changed: @escaping (ProviderInstanceDraft) -> Void, saved: @escaping () -> Void,
    cancel: @escaping () -> Void
  ) {
    self.session = session
    _draft = State(initialValue: initial)
    self.creating = creating
    self.changed = changed
    self.saved = saved
    self.cancel = cancel
  }
  var body: some View {
    VStack(spacing: 0) {
      Form {
        Section(creating && !reconciled ? "Add account" : "Account configuration") {
          if creating && !reconciled, session.pendingProviderCreate != nil,
            let existing = session.providers.first(where: { $0.id == draft.id })
          {
            Text(
              "This account is present on the server. Open its saved configuration to finish this edit."
            )
            .font(.caption).foregroundStyle(.secondary)
            Button("Open saved configuration") {
              draft = ProviderInstanceDraft(provider: existing)
              reconciled = true
            }
          }
          TextField("Account name", text: $draft.displayName)
          TextField("Account ID", text: $draft.id).disabled(
            !creating || session.pendingProviderCreate != nil)
          Picker("Provider", selection: $draft.driver) {
            Text("Codex").tag("codex")
            Text("Claude Code").tag("claudeAgent")
          }.disabled(!creating)
          Toggle("Enabled", isOn: $draft.enabled)
        }
        Section("CLI on the server") {
          TextField(
            draft.driver == "codex" ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR", text: $draft.homePath)
          if draft.driver == "codex" {
            TextField("Account shadow home", text: $draft.shadowHomePath)
          }
          TextField("Binary path", text: $draft.binaryPath)
          TextField("Launch arguments", text: $draft.launchArgs)
          Text("Leave paths empty to use provider defaults. Paths are resolved on the server.")
            .font(.caption).foregroundStyle(.secondary)
        }
        Section("Custom models") {
          ForEach(Array(draft.customModels.enumerated()), id: \.offset) { index, _ in
            HStack {
              VStack {
                TextField("Model ID", text: customField(index, "slug"))
                TextField("Display name", text: customField(index, "name"))
              }
              Button("Remove", role: .destructive) { draft.customModels.remove(at: index) }
            }
          }
          TextField("Model ID", text: $modelID)
          TextField("Display name (optional)", text: $modelName)
          Button("Add custom model") {
            let slug = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !slug.isEmpty else {
              validation = "Enter a custom model ID."
              return
            }
            var value: [String: JSON] = ["slug": .string(slug)]
            if !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
              value["name"] = .string(modelName.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            draft.customModels.append(.object(value))
            modelID = ""
            modelName = ""
          }
        }
        if let error = validation ?? session.error {
          Text(error).font(.caption).foregroundStyle(.orange)
        }
      }.formStyle(.grouped).disabled(session.busy || !session.connected)
      HStack {
        if session.busy {
          ProgressView().controlSize(.small)
          Button("Cancel action", action: session.cancelOperation)
        }
        Spacer()
        Button("Cancel") {
          changed(draft)
          cancel()
        }.keyboardShortcut(.cancelAction).disabled(session.busy)
        Button("Save") {
          do {
            _ = try draft.mutation(create: creating && !reconciled)
            changed(draft)
            validation = nil
            let value = draft
            let isCreate = creating && !reconciled
            if isCreate { session.pendingProviderCreate = value }
            try session.persistPendingCreates()
            session.perform {
              let settings = try await session.request("server.getSettings", .object([:]))
              let explicit = settings["providerInstances"][value.id]
              var latest = explicit
              if !isCreate, explicit == .null {
                guard value.id == value.driver, settings["providers"][value.driver] != .null else {
                  throw T3Error("This account no longer exists.")
                }
                latest = .object([
                  "driver": .string(value.driver), "config": settings["providers"][value.driver],
                ])
              }
              guard isCreate || latest["driver"].string == value.driver else {
                throw T3Error("This account changed on the server. Reopen its configuration.")
              }
              let payload = try value.mutation(
                create: isCreate, mergingLatest: isCreate ? nil : latest)
              _ = try await session.request("server.updateSettings", payload)
              if session.pendingProviderCreate?.id == value.id {
                session.pendingProviderCreate = nil
              }
              try session.persistPendingCreates()
              saved()
            }
          } catch { validation = error.localizedDescription }
        }.keyboardShortcut(.defaultAction).disabled(session.busy || !session.connected)
      }.padding(16)
    }.frame(width: 560, height: 670).interactiveDismissDisabled(true)
  }
  private func customField(_ index: Int, _ key: String) -> Binding<String> {
    Binding(
      get: {
        guard draft.customModels.indices.contains(index) else { return "" }
        let value = draft.customModels[index]
        return value[key].string ?? (key == "slug" ? value.string ?? "" : "")
      },
      set: { text in
        guard draft.customModels.indices.contains(index) else { return }
        let value = draft.customModels[index]
        var fields: [String: JSON] = ["slug": .string(value.string ?? "")]
        if case .object(let saved) = value { fields = saved }
        if key == "name", text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          fields.removeValue(forKey: key)
        } else {
          fields[key] = .string(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        draft.customModels[index] = .object(fields)
      })
  }
}

private struct ProviderAccountSheet: View {
  @ObservedObject var session: ManagementSettingsSession
  let id: String
  let close: () -> Void
  @State private var method = ""
  @State private var input = ""
  @State private var credentials: [String: String] = [:]
  @State private var callback = ""
  @State private var signOut = false
  var body: some View {
    VStack(spacing: 0) {
      Form {
        Section("Account") {
          Text(session.providers.first { $0.id == id }?.name ?? id).font(.headline)
          Text(session.login?.phase.capitalized ?? "Loading account status…").foregroundStyle(
            .secondary)
          if let auth = session.login {
            if !auth.active {
              Picker("Sign-in method", selection: $method) {
                Text("Provider default").tag("")
                ForEach(Array(auth.methods.enumerated()), id: \.offset) { _, value in
                  Text(value["name"].string ?? "Sign in").tag(value["id"].string ?? "")
                }
              }
              Button("Sign in") {
                var fields: [String: JSON] = [
                  "instanceId": .string(id), "callbackMode": .string("server"),
                ]
                if !method.isEmpty { fields["methodId"] = .string(method) }
                authenticate("provider.auth.start", .object(fields))
              }.disabled(session.providers.first { $0.id == id }?.canAuthenticate == false)
              if session.providers.first(where: { $0.id == id })?.signedIn == true {
                Button("Sign out…", role: .destructive) { signOut = true }
                  .disabled(session.providers.first { $0.id == id }?.canLogout == false)
              }
            } else {
              interaction(auth)
              Button("Cancel sign-in") {
                if let flow = auth.flowID {
                  authenticate(
                    "provider.auth.cancel",
                    .object(["instanceId": .string(id), "flowId": .string(flow)]))
                }
              }
            }
          }
          if let error = session.error { Text(error).font(.caption).foregroundStyle(.orange) }
        }
      }.formStyle(.grouped).disabled(session.busy || !session.connected)
      HStack {
        if session.busy {
          ProgressView().controlSize(.small)
          Button("Cancel action", action: session.cancelOperation)
        }
        Spacer()
        Button("Done", action: close).keyboardShortcut(.cancelAction)
      }.padding(16)
    }.frame(width: 560, height: 540)
      .task(id: id) { await session.observeLogin(id) }
      .onChange(of: session.login?.interaction["id"].string) { _, _ in
        credentials = [:]
        input = ""
        callback = ""
      }
      .onDisappear {
        credentials = [:]
        input = ""
        callback = ""
      }
      .confirmationDialog(
        "Sign out of this provider account?", isPresented: $signOut, titleVisibility: .visible
      ) {
        Button("Sign out", role: .destructive) {
          authenticate("provider.auth.logout", .object(["instanceId": .string(id)]))
        }
      }
  }
  @ViewBuilder private func interaction(_ auth: ProviderLoginState) -> some View {
    switch auth.interaction["type"].string {
    case "browser", "deviceCode":
      if let url = auth.url {
        if let code = auth.interaction["userCode"].string {
          SecureField("Device code", text: .constant(code))
          Button("Copy device code") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
          }
        }
        Button("Open sign-in page") {
          session.perform {
            if auth.interaction["requiresConsent"].bool {
              _ = try await session.request(
                "provider.auth.respond",
                auth.response(.object(["type": .string("browser"), "action": .string("accept")])))
            }
            guard session.connected, session.login?.flowID == auth.flowID else {
              throw CancellationError()
            }
            NSWorkspace.shared.open(url)
          }
        }
        if auth.interaction["acceptsCallback"].bool {
          Text(
            "For a remote server, paste the final redirect URL from your browser if sign-in does not finish automatically."
          ).font(.caption).foregroundStyle(.secondary)
          SecureField("Callback URL", text: $callback)
          Button("Complete sign-in") {
            guard let flow = auth.flowID, !callback.isEmpty, callback.utf16.count <= 16_384 else {
              return
            }
            let value = callback
            callback = ""
            authenticate(
              "provider.auth.complete",
              .object([
                "instanceId": .string(id), "flowId": .string(flow), "callbackUrl": .string(value),
              ]))
          }
        }
      }
    case "terminal":
      ScrollView {
        Text(auth.interaction["output"].string ?? "").font(.system(.caption, design: .monospaced))
          .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
      }.frame(height: 150)
      SecureField("Terminal input", text: $input).onSubmit { sendTerminal(auth) }
      HStack {
        Button("Send", action: { sendTerminal(auth) })
        Button("Interrupt") {
          respond(auth, .object(["type": .string("terminal"), "data": .string("\u{03}")]))
        }
      }
    case "credentials":
      ForEach(Array(auth.interaction["fields"].array.enumerated()), id: \.offset) { _, field in
        let name = field["name"].string ?? ""
        SecureField(
          field["label"].string ?? name,
          text: Binding(get: { credentials[name] ?? "" }, set: { credentials[name] = $0 }))
      }
      Button("Continue") {
        let values = credentials.mapValues(JSON.string)
        credentials = [:]
        respond(auth, .object(["type": .string("credentials"), "values": .object(values)]))
      }
    default: Text("Waiting for the provider’s sign-in workflow…").foregroundStyle(.secondary)
    }
  }
  private func sendTerminal(_ auth: ProviderLoginState) {
    let value = input + "\r"
    input = ""
    respond(auth, .object(["type": .string("terminal"), "data": .string(value)]))
  }
  private func respond(_ auth: ProviderLoginState, _ value: JSON) {
    do { authenticate("provider.auth.respond", try auth.response(value)) } catch {
      session.error = "This sign-in interaction is no longer active."
    }
  }
  private func authenticate(_ method: String, _ payload: JSON) {
    let revision = session.loginRevision
    session.perform {
      let next = try ProviderLoginState(await session.request(method, payload))
      guard next.instanceID == id, session.loginInstanceID == id, session.loginRevision == revision
      else { return }
      session.login = next
    }
  }
}
