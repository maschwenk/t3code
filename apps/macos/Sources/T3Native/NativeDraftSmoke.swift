import Foundation
import T3Core

@MainActor enum NativeDraftSmoke {
  @discardableResult
  static func run(settings: ConnectionSettings, root: String, projectID: String? = nil) async throws
    -> URL
  {
    #if !arch(arm64)
      throw T3Error("New draft smoke requires Apple Silicon.")
    #endif
    let evidenceRoot = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath()
    guard ["localhost", "127.0.0.1"].contains(settings.endpoint.host),
      settings.endpoint.port == 4773,
      evidenceRoot.path == "/private/tmp/t3-native-evidence"
        || evidenceRoot.path.hasPrefix("/private/tmp/t3-native-evidence/")
        || evidenceRoot.path == "/tmp/t3-native-evidence"
        || evidenceRoot.path.hasPrefix("/tmp/t3-native-evidence/")
    else {
      throw T3Error("New draft smoke requires isolated localhost:4773 and /tmp/t3-native-evidence.")
    }
    let directory = evidenceRoot.appendingPathComponent("new-draft-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let suite = "T3Native.NewDraftSmoke." + UUID().uuidString
    guard let preferences = UserDefaults(suiteName: suite) else {
      throw T3Error("Could not isolate new draft smoke preferences.")
    }
    preferences.set(true, forKey: "planModeEnabled")
    defer { preferences.removePersistentDomain(forName: suite) }

    let observer = RPCConnection(settings: settings)
    let timeout = Task {
      try await Task.sleep(for: .seconds(90))
      await observer.close(error: T3Error("New draft smoke timed out."))
    }
    defer {
      timeout.cancel()
      Task { await observer.close() }
    }
    try await observer.open()
    let before = try await serverSnapshot(observer)
    let projects = before["active"]["projects"].array.sorted {
      ($0["id"].string ?? "") < ($1["id"].string ?? "")
    }
    guard
      let project = projects.first(where: {
        $0["workspaceRoot"].string != nil && (projectID == nil || $0["id"].string == projectID)
      })
    else { throw T3Error("New draft smoke needs an existing project with a workspace root.") }
    var catalog = ProviderCatalog(planModeEnabled: true)
    let configurationSnapshot = try await configuration(observer)
    try catalog.apply(configurationSnapshot)
    let workspaceSettings = configurationSnapshot["config"]["settings"]
    let initial = try catalog.newThreadConfiguration(project: project, carrying: nil)
    let seed = NewConversationDraft(project: project, configuration: initial)
    let draftsDirectory = directory.appendingPathComponent("drafts")
    let repository = DraftRepository(directory: draftsDirectory)
    try repository.save(
      SavedDrafts(messages: [seed.id: "Seed stays unsent"], conversations: [seed.id: seed]),
      for: settings.endpoint)
    preferences.set(
      [settings.endpoint.absoluteString: seed.id], forKey: "selectedThreadByEndpoint")

    // Keep startup on a local selection: selecting a real server thread can mark it visited.
    let store = ClientStore(draftDirectory: draftsDirectory, preferences: preferences)
    defer { store.disconnect() }
    store.connect(settings)
    try await wait(store) { store.ready && store.catalogReady && store.selectedID == seed.id }
    try check(
      store.isNewConversation && store.canEditThread, "Startup did not restore the local seed.")
    let expectedWorkspaceMode = try await store.resolveNewDraftWorkspaceMode(
      project: project, session: store.projectSessionID)
    let expected = try store.catalog.newThreadConfiguration(
      project: project, carrying: seed.summary)
    store.newThread(projectID: initial.projectID)
    store.newThread(projectID: initial.projectID)
    store.select(seed.id, force: true)
    try await wait(store) { !store.creatingThread && store.conversationDrafts.count == 2 }
    try check(store.selectedID == seed.id, "An awaited draft creation stole the current selection.")
    guard let created = store.conversationDrafts.values.first(where: { $0.id != seed.id }) else {
      throw T3Error("Missing new local conversation draft.")
    }
    try check(
      created.model == expected.model && created.runtimeMode == expected.runtimeMode
        && created.interactionMode == expected.interactionMode
        && created.workspaceMode == expectedWorkspaceMode,
      "New conversation did not use actual configured project/model defaults.")
    let stableID = created.id
    store.select(stableID)
    guard
      let provider = store.catalog.providers.first(where: {
        $0.available && $0.models.contains(where: { !$0.descriptors.isEmpty })
      }), let model = provider.models.first(where: { !$0.descriptors.isEmpty })
    else {
      throw T3Error("New draft smoke needs an available model with configurable parameters.")
    }
    store.setModel(model.selection(instanceID: provider.id))
    guard
      let descriptor = store.catalog.descriptors(for: store.selectedThread?.model ?? .null)
        .first(where: { $0["type"].string == "boolean" || !$0["options"].array.isEmpty }),
      let optionID = descriptor["id"].string
    else { throw T3Error("No usable model parameter in the actual provider catalog.") }
    let old =
      store.selectedDraft?.model["options"].array.first(where: {
        $0["id"].string == optionID
      }).map { $0["value"] } ?? .null
    let option: JSON
    if descriptor["type"].string == "boolean" {
      option = .bool(!old.bool)
    } else {
      option =
        descriptor["options"].array.first(where: { $0["id"] != old })?["id"]
        ?? descriptor["options"].array[0]["id"]
    }
    store.setModelOption(optionID, value: option)
    let runtime = provider.runtimeModes.last ?? "full-access"
    store.setRuntimeMode(runtime)
    store.updateConversationDraft {
      $0.workspaceMode = "worktree"
      $0.branch = "main"
    }
    let targetProject = projects.last(where: { $0["workspaceRoot"].string != nil }) ?? project
    store.setDraftProject(targetProject)
    try check(
      store.selectedDraft?.branch == nil, "Changing the project retained the old base branch.")
    store.updateConversationDraft { $0.branch = "release/native-smoke" }
    if provider.showInteractionMode { store.setInteractionMode("plan") }
    store.composerText = "Unsent body preserved by the actual ClientStore"
    guard let configured = store.selectedDraft else {
      throw T3Error("Lost the selected local draft.")
    }
    try check(
      store.selectedID == stableID && configured.id == stableID
        && configured.project == targetProject && configured.runtimeMode == runtime
        && configured.model["instanceId"].string == provider.id
        && configured.model["model"].string == model.id
        && configured.model["options"].array.contains(where: {
          $0["id"].string == optionID && $0["value"] == option
        }),
      "Project, model parameter or runtime edits changed the draft identity or were not applied.")
    try check(
      !provider.showInteractionMode || configured.interactionMode == "plan",
      "Local plan mode was not applied.")
    try await verifySidebarDrafts(store, seed: seed, created: configured, body: store.composerText)
    try check(store.saveDraftsBeforeExit(), "ClientStore could not save the local draft.")
    let saved = try repository.load(for: settings.endpoint)
    try check(
      saved.conversations?[stableID] == configured && saved.submissions.isEmpty
        && saved.messages[stableID] == store.composerText
        && saved.messages[seed.id] == "Seed stays unsent",
      "Saving the new draft lost configuration/body or created a submission.")
    let body = store.composerText
    store.disconnect()

    guard let reopenedPreferences = UserDefaults(suiteName: suite) else {
      throw T3Error("Could not reopen the isolated preferences.")
    }
    let reopened = ClientStore(draftDirectory: draftsDirectory, preferences: reopenedPreferences)
    defer { reopened.disconnect() }
    reopened.connect(settings)
    try await wait(reopened) {
      reopened.ready && reopened.catalogReady && reopened.selectedID == stableID
    }
    try check(
      reopened.selectedDraft == configured && reopened.composerText == body
        && reopened.canEditThread && reopened.catalog.planModeEnabled,
      "Reopening ClientStore did not restore selection, preferences, body and model parameters.")
    try await verifySidebarDrafts(reopened, seed: seed, created: configured, body: body)
    let previousSession = reopened.projectSessionID
    reopened.disconnect()
    reopened.connect(settings)
    try await wait(reopened) {
      reopened.ready && reopened.catalogReady && reopened.selectedID == stableID
    }
    try check(
      reopened.projectSessionID != previousSession && reopened.selectedDraft == configured
        && reopened.composerText == body,
      "Reconnect lost the local draft or reused the disconnected session.")
    try await verifySidebarDrafts(reopened, seed: seed, created: configured, body: body)
    do {
      _ = try await reopened.browseProjectFolders(
        targetProject.requiredString("workspaceRoot"), session: previousSession)
      throw T3Error("Disconnected project session was accepted.")
    } catch let error as T3Error where error.message.contains("connection changed") {}
    do {
      _ = try await reopened.resolveNewDraftWorkspaceMode(
        project: targetProject, session: previousSession)
      throw T3Error("Disconnected workspace-default session was accepted.")
    } catch let error as T3Error where error.message.contains("connection changed") {}
    reopened.disconnect()

    try legacyClientStores(settings: settings, directory: directory, preferences: preferences)
    let after = try await serverSnapshot(observer)
    try check(
      threadRecords(before["active"]) == threadRecords(after["active"])
        && threadRecords(before["archived"]) == threadRecords(after["archived"])
        && before["active"]["snapshotSequence"] == after["active"]["snapshotSequence"]
        && before["archived"]["snapshotSequence"] == after["archived"]["snapshotSequence"],
      "Server threads or orchestration sequence changed during the local-only smoke.")
    let report: JSON = .object([
      "passed": .bool(true), "serverPort": .number(4773), "selectedDraftID": .string(stableID),
      "serverThreadsBefore": .number(Double(threadRecords(before["active"]).count)),
      "serverThreadsAfter": .number(Double(threadRecords(after["active"]).count)),
      "archivedThreadsBefore": .number(Double(threadRecords(before["archived"]).count)),
      "archivedThreadsAfter": .number(Double(threadRecords(after["archived"]).count)),
      "sequenceBefore": before["active"]["snapshotSequence"],
      "sequenceAfter": after["active"]["snapshotSequence"],
      "modelParameter": .string(optionID), "projectChanged": .bool(project != targetProject),
      "resolvedInitialWorkspaceMode": .string(expectedWorkspaceMode),
      "initialWorkspaceModeNeedsRepositoryRead": .bool(
        WorkspaceDefaults.configuredMode(settings: workspaceSettings, project: project) == nil),
      "checks": .array(
        [
          "configured defaults", "duplicate-click guard", "selection during awaited creation",
          "project and model parameter editing", "stable draft identity", "save and reopen",
          "preference restoration", "connection restoration", "stale project session rejection",
          "stale workspace-default session rejection",
          "merged sidebar retains both local drafts during server thread selection",
          "sidebar draft reselection before save, after reopen and after reconnect",
          "legacy draft versions 1 through 5", "unchanged server threads and sequence",
        ].map(JSON.string)),
    ])
    let result = directory.appendingPathComponent("result.json")
    try report.data().write(to: result, options: .atomic)
    await observer.close()
    print("PASS: actual ClientStore local draft smoke. Evidence: \(result.path)")
    return result
  }

  private static func check(_ condition: Bool, _ message: String) throws {
    guard condition else { throw T3Error("New draft smoke: " + message) }
  }

  private static func verifySidebarDrafts(
    _ store: ClientStore, seed: NewConversationDraft, created: NewConversationDraft, body: String
  ) async throws {
    guard let serverThread = store.shell.threads.values.sorted(by: { $0.id < $1.id }).first else {
      throw T3Error("Sidebar draft smoke needs an existing server thread to navigate away to.")
    }
    store.select(serverThread.id)
    try await wait(store) {
      store.selectedID == serverThread.id && store.thread?.synchronized == true
    }
    // Headless selection reads the thread; no Window calls markVisibleThreadRead here.
    let sidebar = store.activeSidebarThreads
    try check(
      Set(sidebar.keys) == Set(store.shell.threads.keys).union([seed.id, created.id])
        && sidebar[seed.id] == seed.summary && sidebar[created.id] == created.summary
        && store.shell.threads.allSatisfy { sidebar[$0.key] == $0.value },
      "Navigating to a server thread hid a local sidebar draft or replaced its metadata.")
    guard let seedRow = sidebar[seed.id], let createdRow = sidebar[created.id] else {
      throw T3Error("The merged sidebar did not expose both local draft rows.")
    }
    store.select(seedRow.id)
    try check(
      store.isNewConversation && store.canEditThread && store.selectedID == seed.id
        && store.selectedDraft == seed && store.composerText == "Seed stays unsent",
      "Reselecting the seed sidebar row lost its saved body, configuration or identity.")
    store.select(createdRow.id)
    try check(
      store.isNewConversation && store.canEditThread && store.selectedID == created.id
        && store.selectedDraft == created && store.composerText == body
        && store.activeSidebarThreads[seed.id] == seed.summary
        && store.activeSidebarThreads[created.id] == created.summary,
      "Reselecting the created sidebar row lost either draft or its saved model/project metadata.")
  }

  private static func wait(_ store: ClientStore, until predicate: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(25)
    while !predicate() {
      try Task.checkCancellation()
      if let error = store.storageError ?? store.error { throw T3Error(error) }
      guard Date() < deadline else { throw T3Error("Timed out waiting for new draft ClientStore.") }
      try await Task.sleep(for: .milliseconds(25))
    }
  }

  private static func serverSnapshot(_ connection: RPCConnection) async throws -> JSON {
    let subscription = try await connection.subscribe(
      "orchestration.subscribeShell", payload: .object(["requestCompletionMarker": .bool(true)]))
    defer { Task { await connection.cancel(subscription.id) } }
    for try await event in subscription.values where event["kind"].string == "snapshot" {
      let archived = try await connection.call(
        "orchestration.getArchivedShellSnapshot", payload: .object([:]))
      return .object(["active": event["snapshot"], "archived": archived])
    }
    throw T3Error("Server did not return the actual shell snapshot.")
  }

  private static func configuration(_ connection: RPCConnection) async throws -> JSON {
    let subscription = try await connection.subscribe("subscribeServerConfig")
    defer { Task { await connection.cancel(subscription.id) } }
    for try await event in subscription.values where event["type"].string == "snapshot" {
      return event
    }
    throw T3Error("Server did not return its actual provider configuration.")
  }

  private static func threadRecords(_ snapshot: JSON) -> [JSON] {
    (snapshot["threads"].array + snapshot["archivedThreads"].array).sorted {
      ($0["id"].string ?? "") < ($1["id"].string ?? "")
    }
  }

  private static func legacyClientStores(
    settings: ConnectionSettings, directory: URL, preferences: UserDefaults
  ) throws {
    for version in 1...5 {
      let legacyDirectory = directory.appendingPathComponent("legacy-\(version)")
      try FileManager.default.createDirectory(
        at: legacyDirectory, withIntermediateDirectories: true)
      let repository = DraftRepository(directory: legacyDirectory)
      let legacy = Data(
        """
        {"version":\(version),"messages":{"older-thread":"Older unsent body"},"questions":{},
         "submissions":{"older-thread":{"text":"Older unsent body",
         "command":"older-command","message":"older-message"}}}
        """.utf8)
      try legacy.write(to: repository.file(for: settings.endpoint), options: .atomic)
      let store = ClientStore(draftDirectory: legacyDirectory, preferences: preferences)
      // Loading is synchronous. Disconnect before the connection task can select a server thread.
      store.connect(settings, selecting: "older-thread")
      defer { store.disconnect() }
      try check(
        store.storageError == nil && store.drafts["older-thread"] == "Older unsent body"
          && store.conversationDrafts.isEmpty && store.saveDraftsBeforeExit(),
        "ClientStore could not load and save legacy drafts version \(version).")
      let saved = try repository.load(for: settings.endpoint)
      try check(
        saved.submissions["older-thread"]?.command == "older-command"
          && saved.submissions["older-thread"]?.message == "older-message"
          && saved.submissions["older-thread"]?.launch == nil,
        "ClientStore changed an older draft's pending message identity.")
    }
  }
}
