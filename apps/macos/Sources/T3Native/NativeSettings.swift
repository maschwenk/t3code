import AppKit
import Combine
import SwiftUI
import T3Core

/// Identity, rather than URL alone, rejects responses from a replaced connection to the same server.
struct NativeSettingsResponseGate {
  let connectionID: ObjectIdentifier
  let endpoint: URL
  let revision: UUID
  init(connection: RPCConnection, endpoint: URL, revision: UUID) {
    connectionID = ObjectIdentifier(connection)
    self.endpoint = endpoint
    self.revision = revision
  }
  func accepts(connection: RPCConnection?, endpoint: URL?, revision: UUID) -> Bool {
    guard let connection else { return false }
    return ObjectIdentifier(connection) == connectionID && endpoint == self.endpoint
      && revision == self.revision
  }
}

enum NativeServerSettingsPatch {
  case model(JSON)
  case modelOption(selection: JSON, id: String, value: JSON)
  case permission(String)
  case workspace(String?)
  case restartContinuation(Bool)
  case usageLimitContinuation(Bool)
  case settleOnMerge(Bool)
  case settleAfterDays(Int?)
  case worktreesDirectory(String)

  func payload() throws -> JSON {
    let key: String
    let value: JSON
    switch self {
    case .model(let selection):
      key = "defaultModelSelection"
      value = selection
    case .modelOption(let selection, let id, let option):
      guard case .object(var fields) = selection, selection["instanceId"].string != nil,
        selection["model"].string != nil, !id.isEmpty
      else { throw T3Error("Choose a model first.") }
      var options = selection["options"].array.filter { $0["id"].string != id }
      if option != .null { options.append(.object(["id": .string(id), "value": option])) }
      fields["options"] = .array(options)
      key = "defaultModelSelection"
      value = .object(fields)
    case .permission(let mode):
      guard ["approval-required", "auto-accept-edits", "auto", "full-access"].contains(mode) else {
        throw T3Error("Choose a supported permission mode.")
      }
      key = "defaultRuntimeMode"
      value = .string(mode)
    case .workspace(let mode):
      guard mode == nil || ["local", "worktree"].contains(mode!) else {
        throw T3Error("Choose a supported workspace mode.")
      }
      key = "defaultThreadEnvMode"
      value = mode.map(JSON.string) ?? .null
    case .restartContinuation(let enabled):
      key = "continueThreadsAfterServerUpdate"
      value = .bool(enabled)
    case .usageLimitContinuation(let enabled):
      key = "autoResumeLimitedThreads"
      value = .bool(enabled)
    case .settleOnMerge(let enabled):
      key = "sidebarAutoSettleOnMerge"
      value = .bool(enabled)
    case .settleAfterDays(let days):
      guard days == nil || (1...90).contains(days!) else {
        throw T3Error("Choose 1 to 90 days, or Never.")
      }
      key = "sidebarAutoSettleAfterDays"
      value = days.map { .number(Double($0)) } ?? .null
    case .worktreesDirectory(let directory):
      key = "worktreesDirectory"
      value = .string(directory.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return .object(["patch": .object([key: value])])
  }
}

@MainActor final class NativeSettingsModel: ObservableObject {
  let store: ClientStore
  @Published private(set) var settings: JSON = .null
  @Published private(set) var config: JSON = .null
  @Published private(set) var catalog = ProviderCatalog()
  @Published private(set) var endpoint: URL?
  @Published private(set) var busy = false
  @Published private(set) var error: String?
  @Published private(set) var connectionError: String?
  @Published private(set) var threadCount = 0
  @Published private(set) var projectCount = 0
  private var connection: RPCConnection?
  private var revision = UUID()
  private var subscription: Task<Void, Never>?
  private var mutation: Task<Void, Never>?
  var canEdit: Bool {
    settings != .null && !busy && connection != nil
      && connection === store.browserConnection && endpoint == store.browserEndpoint
  }

  init(store: ClientStore) { self.store = store }

  func refresh() {
    connectionError = store.error ?? store.storageError
    threadCount = store.shell.threads.count
    projectCount = store.shell.projects.count
    if store.catalogReady { catalog = store.catalog }
    guard connection !== store.browserConnection || endpoint != store.browserEndpoint else {
      return
    }
    stop()
    connection = store.browserConnection
    endpoint = store.browserEndpoint
    settings = .null
    config = .null
    error = nil
    guard let connection, let endpoint else { return }
    let gate = NativeSettingsResponseGate(
      connection: connection, endpoint: endpoint, revision: revision)
    busy = true
    subscription = Task { [weak self] in
      guard let self, !Task.isCancelled, accepts(gate) else { return }
      do {
        let result = try await connection.call("server.getSettings", payload: .object([:]))
        guard accepts(gate) else { return }
        try applySettings(result)
        busy = false
        let stream = try await connection.subscribe("subscribeServerConfig")
        defer { Task { await connection.cancel(stream.id) } }
        for try await event in stream.values {
          try Task.checkCancellation()
          guard accepts(gate) else { return }
          if event["type"].string == "snapshot" {
            config = event["config"]
            try applySettings(config["settings"])
          } else if event["type"].string == "settingsUpdated" {
            try applySettings(event["payload"]["settings"])
          }
          try catalog.apply(event)
        }
        throw T3Error("Settings updates ended. Reconnect or refresh Settings.")
      } catch {
        guard !Task.isCancelled, accepts(gate) else { return }
        busy = false
        self.error = error.localizedDescription
      }
    }
  }

  func reload() {
    stop()
    connection = nil
    endpoint = nil
    refresh()
  }

  func stop() {
    revision = UUID()
    subscription?.cancel()
    subscription = nil
    mutation?.cancel()
    mutation = nil
    busy = false
  }

  func save(_ patch: NativeServerSettingsPatch) {
    guard canEdit, let connection, let endpoint else {
      error = "Connect to the current server and wait for Settings to load before saving."
      return
    }
    let payload: JSON
    do { payload = try patch.payload() } catch {
      self.error = error.localizedDescription
      return
    }
    let gate = NativeSettingsResponseGate(
      connection: connection, endpoint: endpoint, revision: revision)
    busy = true
    error = nil
    mutation = Task { [weak self] in
      guard let self, !Task.isCancelled, accepts(gate) else { return }
      do {
        let result = try await connection.call("server.updateSettings", payload: payload)
        guard accepts(gate) else { return }
        try applySettings(result)
        busy = false
      } catch {
        guard !Task.isCancelled, accepts(gate) else { return }
        busy = false
        self.error = error.localizedDescription
      }
    }
  }

  private func accepts(_ gate: NativeSettingsResponseGate) -> Bool {
    gate.accepts(
      connection: store.browserConnection, endpoint: store.browserEndpoint, revision: revision)
  }
  private func applySettings(_ value: JSON) throws {
    guard case .object = value else {
      throw T3Error("The server returned an invalid settings response.")
    }
    settings = value
  }
}

@MainActor final class NativeSettingsWindow: NSWindowController {
  private let model: NativeSettingsModel
  private let preferences: NativePreferences
  private var observation: AnyCancellable?
  private var closeObservation: AnyCancellable?
  var onAppearanceChange: (() -> Void)?

  init(store: ClientStore, preferences: NativePreferences = .shared) {
    self.preferences = preferences
    model = NativeSettingsModel(store: store)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 730),
      styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false
    )
    super.init(window: window)
    window.title = "Settings"
    window.isReleasedWhenClosed = false
    window.minSize = NSSize(width: 760, height: 560)
    window.appearance = preferences.appearance.appearance.appKitAppearance
    window.contentView = NSHostingView(
      rootView: NativeSettingsPages(model: model, preferences: preferences))
    window.center()
    var previous = preferences.appearance
    observation = preferences.observeChanges { [weak self] values in
      guard previous != values.appearance else { return }
      previous = values.appearance
      self?.window?.appearance = values.appearance.appearance.appKitAppearance
      self?.onAppearanceChange?()
    }
    closeObservation = NotificationCenter.default.publisher(
      for: NSWindow.willCloseNotification, object: window
    )
    .sink { [weak self] _ in Task { @MainActor in self?.model.stop() } }
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func showWindow(_ sender: Any?) {
    let wasVisible = window?.isVisible == true
    super.showWindow(sender)
    if wasVisible { model.refresh() } else { model.reload() }
  }
  /// Parent calls from its existing store change callback to follow disconnects and server switches.
  func refresh() { if window?.isVisible == true { model.refresh() } }
}

private enum NativeSettingsPage: String, CaseIterable, Identifiable {
  case general = "General"
  case appearance = "Appearance"
  case providers = "Providers"
  case scheduledTasks = "Scheduled Tasks"
  case connections = "Connections"
  case storage = "Storage"
  var id: String { rawValue }
  var symbol: String {
    switch self {
    case .general: "gearshape"
    case .appearance: "paintpalette"
    case .providers: "cpu"
    case .scheduledTasks: "calendar.badge.clock"
    case .connections: "network"
    case .storage: "internaldrive"
    }
  }
}

private struct NativeSettingsPages: View {
  @ObservedObject var model: NativeSettingsModel
  @ObservedObject var preferences: NativePreferences
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var contrast
  @State private var selected: NativeSettingsPage = .general
  @State private var permissionResult: String?
  @State private var worktreeDirectory = ""
  @State private var worktreeDirty = false
  @State private var interfaceFont = ""
  @State private var codeFont = ""
  @State private var requestingPermission = false
  private let fontFamilies = NSFontManager.shared.availableFontFamilies.sorted()

  var body: some View {
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 5) {
        Text("Settings").font(.system(size: 15, weight: .semibold))
          .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 20)
        ForEach(NativeSettingsPage.allCases) { page in
          Button {
            selected = page
          } label: {
            HStack(spacing: 10) {
              Image(systemName: page.symbol)
                .frame(width: 18).foregroundStyle(.secondary)
                .accessibilityHidden(true)
              Text(page.rawValue)
              Spacer(minLength: 0)
            }
            .font(.system(size: 13, weight: selected == page ? .medium : .regular))
            .foregroundStyle(selected == page ? .primary : .secondary)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .background(
              selected == page ? selectionColor : .clear,
              in: RoundedRectangle(cornerRadius: 7))
          }.buttonStyle(.plain).accessibilityAddTraits(selected == page ? .isSelected : [])
        }
        Spacer()
        Label(
          model.endpoint?.host ?? "Not connected",
          systemImage: model.endpoint == nil ? "wifi.slash" : "server.rack"
        )
        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).padding(12)
      }.padding(12).frame(width: 200).background(sidebarColor)
      Divider()
      VStack(alignment: .leading, spacing: 0) {
        VStack(alignment: .leading, spacing: 14) {
          HStack {
            VStack(alignment: .leading, spacing: 5) {
              Text(selected.rawValue).font(.system(size: 22, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
              Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if model.busy {
              ProgressView().controlSize(.small).accessibilityLabel("Saving or loading settings")
            }
            if selected != .appearance {
              Button {
                model.reload()
              } label: {
                Image(systemName: "arrow.clockwise")
              }
              .buttonStyle(.borderless).help("Reload settings from the current server")
              .accessibilityLabel("Reload settings").disabled(model.busy)
            }
          }
          if let error = preferences.error { errorRow(error) }
          if let error = model.error { errorRow(error) }
          if let error = model.connectionError { errorRow(error) }
          if model.endpoint == nil && selected != .appearance {
            Label("Connect to a T3 server to edit its settings.", systemImage: "wifi.slash")
              .font(.callout).foregroundStyle(.secondary)
          }
        }.padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 24)
        switch selected {
        case .providers:
          ProviderSettingsView(store: model.store).scrollContentBackground(.hidden)
        case .scheduledTasks:
          ScheduledTasksView(store: model.store).scrollContentBackground(.hidden)
        case .connections:
          ConnectionsSettingsView(store: model.store).scrollContentBackground(.hidden)
        case .general, .appearance, .storage:
          ScrollView {
            VStack(alignment: .leading, spacing: 22) {
              switch selected {
              case .general: general
              case .appearance: appearance
              case .storage: storage
              default: EmptyView()
              }
            }.padding(.horizontal, 28).padding(.bottom, 32)
              .frame(maxWidth: 850, alignment: .leading).frame(maxWidth: .infinity)
          }
        }
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(pageColor)
    }
    .onAppear {
      syncLocalFields()
      worktreeDirectory = model.settings["worktreesDirectory"].string ?? ""
    }
    .onChange(of: preferences.appearance) { _, _ in syncLocalFields() }
    .onChange(of: model.settings["worktreesDirectory"]) { _, value in
      let saved = value.string ?? ""
      if worktreeDirectory.trimmingCharacters(in: .whitespacesAndNewlines) == saved {
        worktreeDirty = false
      }
      if !worktreeDirty { worktreeDirectory = saved }
    }
    .onChange(of: model.endpoint) { _, _ in
      worktreeDirty = false
      worktreeDirectory = model.settings["worktreesDirectory"].string ?? ""
    }
  }

  // Match SurfaceView while following the window's effective appearance, including System.
  private var pageColor: Color { Color(white: colorScheme == .dark ? 0.045 : 0.99) }
  private var sidebarColor: Color { Color(white: colorScheme == .dark ? 0.035 : 0.95) }
  private var cardColor: Color { Color(white: colorScheme == .dark ? 0.075 : 1) }
  private var selectionColor: Color {
    Color.primary.opacity(contrast == .increased ? 0.18 : 0.08)
  }
  private var separatorColor: Color {
    Color.primary.opacity(contrast == .increased ? 0.28 : 0.08)
  }

  private var subtitle: String {
    switch selected {
    case .general: "Thread defaults and automation for the connected server."
    case .appearance: "Make this Mac feel like your workspace."
    case .providers: "Models, accounts and provider configuration."
    case .scheduledTasks: "Work that runs on a schedule."
    case .connections: "Manage your server connections."
    case .storage: "Workspace locations and diagnostics."
    }
  }

  private var general: some View {
    VStack(alignment: .leading, spacing: 22) {
      group(
        "New threads",
        footer:
          "One global default for this server. Existing threads keep their settings; existing project overrides still apply."
      ) {
        row("Model", detail: "Choose from this server’s available providers") {
          Menu {
            Button("Use server fallback") { model.save(.model(.null)) }
            ForEach(model.catalog.providers) { provider in
              Section(provider.name) {
                ForEach(provider.models) { candidate in
                  Button(candidate.name) {
                    model.save(
                      .model(
                        candidate.selection(
                          instanceID: provider.id,
                          preserving: model.settings["defaultModelSelection"],
                          planModeEnabled: model.catalog.planModeEnabled)))
                  }.disabled(!provider.available)
                }
              }
            }
          } label: {
            Text(modelLabel).lineLimit(1).frame(maxWidth: 250, alignment: .trailing)
          }
        }
        ForEach(reasoningDescriptors, id: \.displayText) { descriptor in
          descriptorRow(descriptor)
        }
        row("Permissions", detail: "Access allowed for new threads") {
          Picker(
            "Permissions",
            selection: Binding(
              get: { model.settings["defaultRuntimeMode"].string ?? "full-access" },
              set: { model.save(.permission($0)) })
          ) {
            ForEach(permissionModes, id: \.self) { Text(permissionName($0)).tag($0) }
          }.labelsHidden().frame(width: 205)
        }
        row("Workspace", detail: "Where new threads start") {
          Picker(
            "Workspace",
            selection: Binding(
              get: { model.settings["defaultThreadEnvMode"].string ?? "inherit" },
              set: { model.save(.workspace($0 == "inherit" ? nil : $0)) })
          ) {
            Text("Use repository default").tag("inherit")
            Text("Local checkout").tag("local")
            Text("New worktree").tag("worktree")
          }.labelsHidden().frame(width: 205)
        }
      }.disabled(!model.canEdit)
      group(
        "Recovery",
        footer:
          "The server resumes eligible work. These choices apply even when this Mac is offline."
      ) {
        toggleRow(
          "Resume interrupted threads", detail: "Continue eligible threads after a server restart",
          key: "continueThreadsAfterServerUpdate",
          patch: NativeServerSettingsPatch.restartContinuation)
        toggleRow(
          "Continue after usage limits reset",
          detail: "Automatically resume threads paused by a usage limit",
          key: "autoResumeLimitedThreads", patch: NativeServerSettingsPatch.usageLimitContinuation)
      }.disabled(!model.canEdit)
      group(
        "Automatic settling",
        footer:
          "Settled threads stay available in the sidebar. The server manages eligibility and timing."
      ) {
        toggleRow(
          "Settle after merging", detail: "Settle eligible threads when their pull request merges",
          key: "sidebarAutoSettleOnMerge", patch: NativeServerSettingsPatch.settleOnMerge)
        row("Settle inactive threads", detail: "Days since the last activity") {
          HStack(spacing: 8) {
            Toggle(
              "Enable automatic settling",
              isOn: Binding(
                get: { model.settings["sidebarAutoSettleAfterDays"] != .null },
                set: { model.save(.settleAfterDays($0 ? 3 : nil)) })
            ).labelsHidden().toggleStyle(.switch).controlSize(.small)
            if let days = model.settings["sidebarAutoSettleAfterDays"].int {
              Stepper(
                "\(days) days",
                value: Binding(get: { days }, set: { model.save(.settleAfterDays($0)) }), in: 1...90
              )
              .frame(width: 120)
            } else {
              Text("Never").foregroundStyle(.secondary)
            }
          }
        }
      }.disabled(!model.canEdit)
      notifications
    }
  }

  private var modelLabel: String {
    let selection = model.settings["defaultModelSelection"]
    if selection == .null { return "Use server fallback" }
    guard let candidate = model.catalog.model(for: selection) else {
      return (selection["model"].string ?? "Saved model") + " (unavailable)"
    }
    return candidate.name
  }
  private var reasoningDescriptors: [JSON] {
    model.catalog.descriptors(for: model.settings["defaultModelSelection"]).filter {
      let id = $0["id"].string?.lowercased() ?? ""
      return id.contains("reason") || id.contains("effort") || id == "thinking"
    }
  }
  private var permissionModes: [String] {
    let supported =
      model.catalog.provider(for: model.settings["defaultModelSelection"])?.runtimeModes ?? []
    return ["approval-required", "auto-accept-edits", "auto", "full-access"].filter {
      supported.isEmpty || supported.contains($0)
        || model.settings["defaultRuntimeMode"].string == $0
    }
  }
  private func permissionName(_ mode: String) -> String {
    switch mode {
    case "approval-required": "Ask for approval"
    case "auto-accept-edits": "Accept edits"
    case "auto": "Auto"
    case "full-access": "Full access"
    default: mode
    }
  }
  @ViewBuilder private func descriptorRow(_ descriptor: JSON) -> some View {
    if let id = descriptor["id"].string {
      row(descriptor["label"].string ?? "Reasoning", detail: descriptor["description"].string) {
        let selection = model.settings["defaultModelSelection"]
        let saved =
          selection["options"].array.first { $0["id"].string == id }?["value"]
          ?? descriptor["currentValue"]
        if descriptor["type"].string == "boolean" {
          Toggle(
            "Reasoning",
            isOn: Binding(
              get: { saved.bool },
              set: {
                model.save(.modelOption(selection: selection, id: id, value: .bool($0)))
              })
          ).labelsHidden().toggleStyle(.switch).controlSize(.small)
        } else {
          Picker(
            "Reasoning",
            selection: Binding(
              get: { saved.string ?? "" },
              set: {
                model.save(
                  .modelOption(
                    selection: selection, id: id, value: $0.isEmpty ? .null : .string($0)))
              })
          ) {
            Text("Provider default").tag("")
            ForEach(descriptor["options"].array, id: \.displayText) { option in
              Text(option["label"].string ?? option["id"].string ?? "Option").tag(
                option["id"].string ?? "")
            }
          }.labelsHidden().frame(width: 205)
        }
      }
    }
  }

  private var notifications: some View {
    group(
      "Notifications",
      footer: "Notification choices apply to this Mac. Permission is managed by macOS."
    ) {
      row("Notify me", detail: "When a thread finishes or needs attention") {
        Picker("Notification mode", selection: localBinding(\.notifications.mode)) {
          ForEach(NativeNotificationMode.allCases, id: \.self) { Text($0.name).tag($0) }
        }.labelsHidden().frame(width: 205)
      }
      localToggle("Thread completed", key: \.notifications.completion)
      localToggle("Input, approvals and usage limits", key: \.notifications.attention)
      localToggle("Thread failed", key: \.notifications.failure)
      localToggle("Notify while this app is active", key: \.notifications.whileAppActive)
      row("macOS permission", detail: permissionResult ?? "Allow banners and sounds for T3 Native")
      {
        Button(requestingPermission ? "Requesting…" : "Enable notifications…") {
          requestingPermission = true
          Task { @MainActor in
            defer { requestingPermission = false }
            do {
              let granted = try await NativeNotificationPresenter.requestAuthorization()
              permissionResult =
                granted
                ? "Notifications are allowed." : "Notifications are disabled in System Settings."
            } catch { permissionResult = error.localizedDescription }
          }
        }.disabled(requestingPermission)
      }
    }
  }

  private var appearance: some View {
    VStack(alignment: .leading, spacing: 22) {
      group("Theme") {
        row("Appearance", detail: "Follow macOS or choose a light or dark workspace") {
          Picker("Appearance", selection: localBinding(\.appearance.appearance)) {
            ForEach(NativeAppearance.allCases, id: \.self) { Text($0.name).tag($0) }
          }.labelsHidden().pickerStyle(.segmented).frame(width: 220)
        }
      }
      group(
        "Typography",
        footer:
          "Empty font names use the system interface font and the system monospaced code font."
      ) {
        fontRow("Interface font", text: $interfaceFont, key: \.appearance.interfaceFont)
        row("Interface size") {
          Stepper(
            "\(preferences.appearance.interfaceFontSize) pt",
            value: localBinding(\.appearance.interfaceFontSize), in: 12...20
          )
          .frame(width: 120)
        }
        fontRow("Code font", text: $codeFont, key: \.appearance.codeFont)
        row("Code size") {
          Stepper(
            "\(preferences.appearance.codeFontSize) pt",
            value: localBinding(\.appearance.codeFontSize), in: 10...18
          )
          .frame(width: 120)
        }
        VStack(alignment: .leading, spacing: 10) {
          Text("The quick brown fox jumps over the lazy dog.").font(
            Font(preferences.appearance.resolvedInterfaceFont))
          Text("let workspace = thread.project").font(Font(preferences.appearance.resolvedCodeFont))
            .foregroundStyle(.secondary)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
      }
      group("Conversation") {
        row("Chat width", detail: "Maximum width on larger windows") {
          Picker("Chat width", selection: localBinding(\.appearance.chatWidth)) {
            ForEach(NativeChatWidth.allCases, id: \.self) { Text($0.name).tag($0) }
          }.labelsHidden().frame(width: 205)
        }
        localToggle("Wrap code and diffs", key: \.appearance.wordWrap)
      }
    }
  }

  private var storage: some View {
    VStack(alignment: .leading, spacing: 22) {
      group("This Mac") {
        row("Preferences", detail: preferences.file.path) {
          Text(preferenceSize).font(.caption).foregroundStyle(.secondary)
          copyButton(preferences.file.path)
        }
      }
      group(
        "Connected server",
        footer:
          "Paths belong to the connected server. Changing the worktree location affects new worktrees."
      ) {
        row("Environment", detail: model.endpoint?.absoluteString ?? "Not connected") {
          Text(model.config["environment"]["platform"]["os"].string ?? "").foregroundStyle(
            .secondary)
        }
        row("Workspace records") {
          Text("\(model.projectCount) projects · \(model.threadCount) threads in sidebar")
            .foregroundStyle(.secondary)
        }
        VStack(alignment: .leading, spacing: 10) {
          Text("Worktree location").font(.system(size: 13, weight: .medium))
          HStack {
            TextField(
              "Use the server’s default worktrees directory",
              text: Binding(
                get: { worktreeDirectory },
                set: {
                  worktreeDirectory = $0
                  worktreeDirty = true
                })
            )
            .textFieldStyle(.roundedBorder)
            .onSubmit(saveWorktreeDirectory)
            Button("Save", action: saveWorktreeDirectory).disabled(!worktreeDirty)
          }
          Text("Leave empty to use <T3 home>/worktrees.").font(.caption).foregroundStyle(.secondary)
        }.padding(16).disabled(!model.canEdit)
        if let path = model.config["observability"]["logsDirectoryPath"].string {
          row("Server logs", detail: path) { copyButton(path) }
        }
      }
      let issues = model.config["issues"].array.compactMap { $0["message"].string }
      if !issues.isEmpty {
        group("Server configuration issues") {
          ForEach(issues, id: \.self) { issue in errorRow(issue).padding(12) }
        }
      }
    }
  }

  private var preferenceSize: String {
    guard
      let bytes = (try? FileManager.default.attributesOfItem(atPath: preferences.file.path)[.size])
        as? NSNumber
    else {
      return "Not saved yet"
    }
    return ByteCountFormatter.string(fromByteCount: bytes.int64Value, countStyle: .file)
  }
  private func saveWorktreeDirectory() {
    model.save(.worktreesDirectory(worktreeDirectory))
  }
  private func syncLocalFields() {
    interfaceFont = preferences.appearance.interfaceFont
    codeFont = preferences.appearance.codeFont
  }
  private func localBinding<Value>(_ key: WritableKeyPath<NativePreferenceValues, Value>)
    -> Binding<Value>
  {
    Binding(
      get: { preferences.values[keyPath: key] },
      set: { value in
        try? preferences.update { $0[keyPath: key] = value }
      })
  }
  private func localToggle(_ title: String, key: WritableKeyPath<NativePreferenceValues, Bool>)
    -> some View
  {
    row(title) {
      Toggle(title, isOn: localBinding(key)).labelsHidden().toggleStyle(.switch).controlSize(.small)
    }
  }
  private func toggleRow(
    _ title: String, detail: String, key: String,
    patch: @escaping (Bool) -> NativeServerSettingsPatch
  ) -> some View {
    row(title, detail: detail) {
      Toggle(
        title, isOn: Binding(get: { model.settings[key].bool }, set: { model.save(patch($0)) })
      )
      .labelsHidden().toggleStyle(.switch).controlSize(.small)
    }
  }
  private func fontRow(
    _ title: String, text: Binding<String>, key: WritableKeyPath<NativePreferenceValues, String>
  ) -> some View {
    row(title) {
      HStack(spacing: 6) {
        TextField("System default", text: text).textFieldStyle(.roundedBorder).frame(width: 170)
          .onSubmit { try? preferences.update { $0[keyPath: key] = text.wrappedValue } }
        Menu {
          Button("System default") { try? preferences.update { $0[keyPath: key] = "" } }
          ForEach(fontFamilies, id: \.self) { family in
            Button(family) { try? preferences.update { $0[keyPath: key] = family } }
          }
        } label: {
          Image(systemName: "chevron.down")
        }.menuStyle(.borderlessButton).fixedSize()
          .accessibilityLabel("Choose " + title.lowercased())
        Button("Apply") { try? preferences.update { $0[keyPath: key] = text.wrappedValue } }
      }
    }
  }
  private func copyButton(_ value: String) -> some View {
    Button {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(value, forType: .string)
    } label: {
      Image(systemName: "doc.on.doc")
    }.buttonStyle(.borderless).help("Copy path")
      .accessibilityLabel("Copy path")
  }
  private func errorRow(_ message: String) -> some View {
    Label(message, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
      .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
  }
  private func group<Content: View>(
    _ title: String, footer: String? = nil,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 9) {
      Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
        .padding(.leading, 16).accessibilityAddTraits(.isHeader)
      VStack(spacing: 0) { content() }
        .background(cardColor, in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
          RoundedRectangle(cornerRadius: 10).strokeBorder(separatorColor, lineWidth: 1))
      if let footer {
        Text(footer).font(.system(size: 11)).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 16)
      }
    }
  }
  private func row<Control: View>(
    _ title: String, detail: String? = nil,
    @ViewBuilder control: () -> Control
  ) -> some View {
    VStack(spacing: 0) {
      HStack(spacing: 18) {
        VStack(alignment: .leading, spacing: 4) {
          Text(title).font(.system(size: 13, weight: .medium))
          if let detail {
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
          }
        }
        Spacer(minLength: 8)
        control().controlSize(.regular)
      }.padding(.horizontal, 16).padding(.vertical, 14)
      separatorColor.frame(height: 1).padding(.horizontal, 16).accessibilityHidden(true)
    }
  }
}
