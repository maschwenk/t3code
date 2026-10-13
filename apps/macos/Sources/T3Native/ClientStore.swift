import Foundation
import T3Core

@MainActor final class ClientStore {
  var shell = ShellState()
  private(set) var archives = ShellState(archived: true)
  private(set) var showingArchives = false
  private(set) var archiveError: String?
  private(set) var sortedThreads: [ThreadSummary] = []
  var thread: ThreadState? { didSet { questionProgressCache = nil } }
  var selectedID: String? { didSet { questionProgressCache = nil } }
  var status = "Connect to your T3 server"
  var error: String?
  var ready = false
  var loadingHistory = false
  var sending: Set<String> = []
  var drafts: [String: String] = [:] { didSet { scheduleDraftSave() } }
  private(set) var queuedEdits: [String: QueuedEdit] = [:] { didSet { scheduleDraftSave() } }
  private var deliveries: [String: MessageDelivery] = [:] { didSet { scheduleDraftSave() } }
  private(set) var attachmentDrafts: [String: [DraftAttachment]] = [:] {
    didSet {
      questionProgressCache = nil
      scheduleDraftSave()
    }
  }
  enum UploadState: Equatable {
    case uploading(Int)
    case ready
    case failed(String)
  }
  private(set) var attachmentUploads: [String: UploadState] = [:] {
    didSet { questionProgressCache = nil }
  }
  private(set) var importingAttachments: Set<String> = [] { didSet { questionProgressCache = nil } }
  private var uploadJobs: [String: (token: UUID, task: Task<Void, Never>)] = [:]
  var catalog = ProviderCatalog() { didSet { questionProgressCache = nil } }
  private(set) var catalogReady = false
  private(set) var usageLimits = UsageLimitsSnapshot()
  private(set) var usageSessionID = UUID()
  var questionDrafts: [String: [String: QuestionDraft]] = [:] {
    didSet {
      questionProgressCache = nil
      scheduleDraftSave()
    }
  }
  private var questionPages: [String: Int] = [:] {
    didSet {
      questionProgressCache = nil
      scheduleDraftSave()
    }
  }
  private var questionResponses: [String: PendingQuestionResponse] = [:] {
    didSet { scheduleDraftSave() }
  }
  private var selectedRequestID: String?
  private var questionProgressCache:
    (request: PendingRequest, progress: QuestionProgress, attachments: [String: [DraftAttachment]])?
  private(set) var storageError: String?
  private(set) var commandsInFlight: Set<String> = []
  private(set) var creatingThread = false
  private(set) var conversationDrafts: [String: NewConversationDraft] = [:] {
    didSet { scheduleDraftSave() }
  }
  var selectedDraft: NewConversationDraft? { selectedID.flatMap { conversationDrafts[$0] } }
  var isNewConversation: Bool { selectedDraft != nil }
  var onChange: (() -> Void)?
  var onShellEvent: ((JSON, RPCConnection, URL) -> Void)?
  private var connection: RPCConnection?
  var terminalConnection: RPCConnection? { ready ? connection : nil }
  private(set) var browserEnvironmentID: String?
  var browserConnection: RPCConnection? { ready ? connection : nil }
  var browserEndpoint: URL? { ready ? settings?.endpoint : nil }
  var hasConnection: Bool { settings != nil }
  private var settings: ConnectionSettings?
  private var cachedWorkspaceMedia: WorkspaceMediaRequest?
  private var lifetime: Task<Void, Never>?
  private var detail: Task<Void, Never>?
  private var configuration: Task<Void, Never>?
  private var archiveSubscription: Task<Void, Never>?
  private var visibleVisit: (id: String, stamp: String)?
  private var suppressVisit: String?
  private var notification: Task<Void, Never>?
  private var generation = UUID()
  private var selectionGeneration = UUID()
  private var pending: [String: PendingSubmission] = [:] { didSet { scheduleDraftSave() } }
  private var planSubmissions: [String: PendingPlanSubmission] = [:] {
    didSet { scheduleDraftSave() }
  }
  private let draftRepository: DraftRepository
  private let preferences: UserDefaults
  private var draftEndpoint: URL?
  private var draftSave: Task<Void, Never>?

  init(draftDirectory: URL? = nil, preferences: UserDefaults = .standard) {
    self.preferences = preferences
    catalog = ProviderCatalog(planModeEnabled: preferences.bool(forKey: "planModeEnabled"))
    let directory =
      draftDirectory
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("T3 Native/Drafts", isDirectory: true)
    draftRepository = DraftRepository(directory: directory)
  }

  func connect(_ settings: ConnectionSettings, selecting threadID: String? = nil) {
    if let current = self.settings, current.endpoint != settings.endpoint,
      !drafts.isEmpty || !questionDrafts.isEmpty || !pending.isEmpty || !attachmentDrafts.isEmpty
        || !queuedEdits.isEmpty || !questionResponses.isEmpty || !deliveries.isEmpty
        || !planSubmissions.isEmpty || !conversationDrafts.isEmpty,
      !flushDrafts()
    {
      error = "Save the current drafts before switching servers."
      notify()
      return
    }
    disconnect()
    if self.settings?.endpoint != settings.endpoint || draftEndpoint == nil {
      draftEndpoint = nil
      shell = ShellState()
      archives = ShellState(archived: true)
      sortedThreads = []
      thread = nil
      selectedID = nil
      drafts = [:]
      attachmentDrafts = [:]
      questionDrafts = [:]
      pending = [:]
      queuedEdits = [:]
      deliveries = [:]
      questionPages = [:]
      questionResponses = [:]
      planSubmissions = [:]
      conversationDrafts = [:]
      selectedRequestID = nil
      catalog = ProviderCatalog(planModeEnabled: preferences.bool(forKey: "planModeEnabled"))
      do {
        let saved = try draftRepository.load(for: settings.endpoint)
        drafts = saved.messages
        pending = saved.submissions
        questionDrafts = saved.questions
        attachmentDrafts = saved.attachments ?? [:]
        queuedEdits = saved.queuedEdits ?? [:]
        deliveries = saved.deliveries ?? [:]
        questionPages = saved.questionPages ?? [:]
        questionResponses = saved.questionResponses ?? [:]
        planSubmissions = saved.planSubmissions ?? [:]
        conversationDrafts = saved.conversations ?? [:]
        draftEndpoint = settings.endpoint
        storageError = nil
      } catch {
        storageError = "Saved drafts could not be loaded: " + error.localizedDescription
      }
    }
    self.settings = settings
    selectedID =
      threadID ?? selectedID
      ?? (preferences.dictionary(forKey: "selectedThreadByEndpoint")?[
        settings.endpoint.absoluteString] as? String)
    status = "Connecting…"
    error = nil
    let generation = self.generation
    lifetime = Task {
      var attempt = 0
      while !Task.isCancelled && self.generation == generation {
        status = attempt == 0 ? "Connecting…" : "Reconnecting…"
        ready = false
        catalogReady = false
        notify()
        let connection = RPCConnection(settings: settings)
        usageSessionID = UUID()
        creatingThread = false
        usageLimits = UsageLimitsSnapshot()
        browserEnvironmentID = nil
        self.connection = connection
        let started = Date()
        do {
          try await connection.open()
          try Task.checkCancellation()
          subscribeConfiguration(connection, generation: generation)
          if showingArchives { subscribeArchives(connection, generation: generation) }
          let subscription = try await connection.subscribe(
            "orchestration.subscribeShell",
            payload: .object(["requestCompletionMarker": .bool(true)]))
          for try await value in subscription.values {
            guard self.generation == generation else { break }
            try shell.apply(value)
            sortedThreads = ThreadGroup.sorted(Array(shell.threads.values), in: .active)
            if shell.synchronized {
              if !ready {
                ready = true
                status = "Connected · \(settings.endpoint.host ?? "T3")"
                error = nil
                startAttachmentUploads()
                if let selectedID,
                  shell.threads[selectedID] != nil || archives.threads[selectedID] != nil
                    || conversationDrafts[selectedID] != nil
                {
                  select(selectedID, force: true)
                } else if let requested = Arguments.value("--thread-id"),
                  shell.threads[requested] != nil
                {
                  select(requested)
                } else if let first = sortedThreads.first {
                  select(first.id)
                }
              }
            }
            onShellEvent?(value, connection, settings.endpoint)
            notify()
          }
          throw T3Error("Live connection ended.")
        } catch {
          guard self.generation == generation && !Task.isCancelled else {
            await connection.close()
            return
          }
          ready = false
          detail?.cancel()
          configuration?.cancel()
          archiveSubscription?.cancel()
          self.error = error.localizedDescription
          await connection.close()
          if (error as? T3Error)?.authentication == true {
            status = "Pair again to reconnect"
            notify()
            return
          }
          if Date().timeIntervalSince(started) > 30 { attempt = 0 }
          attempt += 1
          status = "Connection lost · retrying"
          notify()
          do {
            try await Task.sleep(
              for: .seconds(
                min(300, pow(2, Double(min(attempt, 9)))) * Double.random(in: 0.8...1.2)))
          } catch { return }
        }
      }
    }
  }

  func disconnect() {
    _ = flushDrafts()
    generation = UUID()
    usageSessionID = UUID()
    usageLimits = UsageLimitsSnapshot()
    selectionGeneration = UUID()
    lifetime?.cancel()
    lifetime = nil
    detail?.cancel()
    detail = nil
    configuration?.cancel()
    configuration = nil
    archiveSubscription?.cancel()
    archiveSubscription = nil
    visibleVisit = nil
    if let connection { Task { await connection.close() } }
    connection = nil
    cachedWorkspaceMedia = nil
    ready = false
    catalogReady = false
    commandsInFlight = []
    creatingThread = false
    sending = []
    for job in uploadJobs.values { job.task.cancel() }
    uploadJobs = [:]
    attachmentUploads = [:]
    importingAttachments = []
  }

  func retry() { if let settings { connect(settings) } }

  func showArchives(_ value: Bool) {
    showingArchives = value
    if value, archiveSubscription == nil, let connection, ready {
      subscribeArchives(connection, generation: generation)
    }
    notify()
  }

  private func subscribeArchives(_ connection: RPCConnection, generation: UUID) {
    archiveSubscription?.cancel()
    archiveError = nil
    archives = ShellState(archived: true)
    archiveSubscription = Task {
      do {
        let stream = try await connection.subscribe("orchestration.subscribeArchivedShell")
        defer { Task { await connection.cancel(stream.id) } }
        for try await event in stream.values {
          try Task.checkCancellation()
          guard self.generation == generation else { return }
          try archives.apply(event)
          notify()
        }
        throw T3Error("Archive updates ended. Reconnect to refresh.")
      } catch {
        guard !Task.isCancelled, self.generation == generation else { return }
        archiveError = error.localizedDescription
        archiveSubscription = nil
        notify()
      }
    }
  }

  func lifecycleBusy(_ id: String) -> Bool { commandsInFlight.contains(id + ":lifecycle") }

  func rename(_ id: String, to title: String) {
    let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { return }
    performThreadCommand(
      "thread.metadata.update", fields: ["title": .string(title)], key: "lifecycle", threadID: id)
  }

  func setPinned(_ id: String, _ pinned: Bool) {
    performThreadCommand(
      pinned ? "thread.pin" : "thread.unpin", fields: [:], key: "lifecycle", threadID: id)
  }

  func setSettled(_ id: String, _ settled: Bool) {
    performThreadCommand(
      settled ? "thread.settle" : "thread.unsettle",
      fields: settled ? [:] : ["reason": .string("user")], key: "lifecycle", threadID: id)
  }

  func setAutoSettle(_ id: String, enabled: Bool) {
    performThreadCommand(
      "thread.auto-settle.set", fields: ["enabled": .bool(enabled)], key: "lifecycle", threadID: id)
  }

  func snooze(_ id: String, until date: Date?) {
    if let date {
      guard date > Date(), shell.threads[id]?.lifecycle.canSnooze(at: Date()) == true else {
        return
      }
      performThreadCommand(
        "thread.snooze", fields: ["snoozedUntil": .string(ThreadDates.string(date))],
        key: "lifecycle", threadID: id)
    } else {
      performThreadCommand(
        "thread.unsnooze", fields: ["reason": .string("user")], key: "lifecycle", threadID: id)
    }
  }

  func setArchived(_ id: String, _ archived: Bool) {
    performThreadCommand(
      archived ? "thread.archive" : "thread.unarchive", fields: [:], key: "lifecycle", threadID: id
    ) { [weak self] in
      guard let self else { return }
      if archived, selectedID == id {
        if let next = sortedThreads.first(where: {
          $0.id != id && !$0.lifecycle.settled && !$0.lifecycle.snoozed(at: Date())
        }) {
          select(next.id)
        } else {
          detail?.cancel()
          selectionGeneration = UUID()
          selectedID = nil
          thread = nil
        }
      }
    }
  }

  func markUnread(_ id: String) {
    if selectedID == id { suppressVisit = id }
    performThreadCommand("thread.mark-unread", fields: [:], key: "lifecycle", threadID: id)
  }

  func markVisibleThreadRead() {
    guard ready, thread?.synchronized == true, let current = selectedThread,
      suppressVisit != current.id, ThreadDates.parse(current.updatedAt) != nil,
      !commandsInFlight.contains(current.id + ":visit"),
      visibleVisit?.id != current.id || visibleVisit?.stamp != current.updatedAt
    else { return }
    visibleVisit = (current.id, current.updatedAt)
    if let visited = current.lifecycle.lastVisitedAt, let updated = current.lifecycle.updatedAt,
      visited >= updated
    {
      return
    }
    performThreadCommand(
      "thread.visit", fields: ["visitedAt": .string(current.updatedAt)], key: "visit",
      threadID: current.id)
  }

  func saveDraftsBeforeExit() -> Bool {
    guard importingAttachments.isEmpty else {
      storageError = "Wait for the selected files to finish copying before quitting."
      return false
    }
    return flushDrafts()
  }

  private func scheduleDraftSave() {
    guard draftEndpoint != nil else { return }
    draftSave?.cancel()
    draftSave = Task {
      do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
      _ = flushDrafts()
    }
  }

  @discardableResult private func flushDrafts() -> Bool {
    draftSave?.cancel()
    draftSave = nil
    guard let draftEndpoint else { return storageError == nil }
    do {
      try draftRepository.save(
        SavedDrafts(
          messages: drafts.filter { !$0.value.isEmpty }, submissions: pending,
          questions: questionDrafts, attachments: attachmentDrafts.filter { !$0.value.isEmpty },
          queuedEdits: queuedEdits, deliveries: deliveries,
          questionPages: questionPages, questionResponses: questionResponses,
          planSubmissions: planSubmissions, conversations: conversationDrafts),
        for: draftEndpoint)
      storageError = nil
      return true
    } catch {
      storageError = "Drafts could not be saved: " + error.localizedDescription
      notify()
      return false
    }
  }

  private func subscribeConfiguration(_ connection: RPCConnection, generation: UUID) {
    configuration?.cancel()
    configuration = Task {
      do {
        let stream = try await connection.subscribe(
          "subscribeServerConfig", payload: .object(["usageLimitSources": .bool(true)]))
        defer { Task { await connection.cancel(stream.id) } }
        for try await event in stream.values {
          try Task.checkCancellation()
          guard self.generation == generation else { return }
          try catalog.apply(event)
          usageLimits.apply(event)
          if event["type"].string == "snapshot" {
            browserEnvironmentID = event["config"]["environment"]["environmentId"].string
            catalogReady = true
          }
          startAttachmentUploads()
          notify()
        }
        throw T3Error("Provider updates ended. Reconnect to refresh.")
      } catch {
        guard !Task.isCancelled, self.generation == generation else { return }
        catalogReady = false
        self.error = "Provider configuration: " + error.localizedDescription
        notify()
      }
    }
  }

  var selectedThread: ThreadSummary? {
    selectedID.flatMap {
      shell.threads[$0] ?? archives.threads[$0] ?? conversationDrafts[$0]?.summary
    }
  }
  var activeSidebarThreads: [String: ThreadSummary] {
    var result = shell.threads
    for draft in conversationDrafts.values where result[draft.id] == nil {
      if let summary = draft.summary { result[draft.id] = summary }
    }
    return result
  }
  var environmentKey: String { settings?.endpoint.absoluteString ?? "disconnected" }
  func usageCall(_ method: String, payload: JSON = .object([:]), session: UUID) async throws -> JSON
  {
    guard ready, catalogReady, let connection, session == usageSessionID else {
      throw T3Error("Connect to load usage.")
    }
    let result = try await connection.call(method, payload: payload)
    try Task.checkCancellation()
    guard ready, session == usageSessionID else { throw T3Error("The usage connection changed.") }
    return result
  }
  var fileOpenCapabilities: FileOpenCapabilities {
    ready && catalogReady ? catalog.fileOpen : FileOpenCapabilities()
  }
  func openFileExternally(
    _ path: String, position: FileSourcePosition? = nil,
    editor: String, reveal: Bool, at location: WorkspaceLocation
  ) {
    guard ready, catalogReady, let connection, workspaceLocation == location else { return }
    let payload: JSON
    do {
      payload = try fileOpenCapabilities.launchInput(
        path: path, root: location.root, editor: editor, reveal: reveal, position: position)
    } catch {
      self.error = error.localizedDescription
      notify()
      return
    }
    let generation = generation
    Task {
      do { _ = try await connection.call("shell.openInEditor", payload: payload) } catch {
        guard self.generation == generation, workspaceLocation == location else { return }
        self.error = error.localizedDescription
        notify()
      }
    }
  }
  var workspaceLocation: WorkspaceLocation? {
    guard let selectedThread else { return nil }
    return WorkspaceLocation(
      environment: environmentKey, thread: selectedThread,
      project: shell.projectDetails[selectedThread.projectID] ?? archives.projectDetails[
        selectedThread.projectID] ?? .null)
  }
  func savePlan(_ document: PlanDocument, at location: WorkspaceLocation, relativePath: String)
    async throws -> String
  {
    guard ready, let connection else { throw T3Error("Connect before saving to the workspace.") }
    guard workspaceLocation == location else {
      throw T3Error("The workspace changed. Reopen Save to workspace for the current thread.")
    }
    let result = try await connection.call(
      "projects.writeFile",
      payload: location.writeInput(relativePath: relativePath, contents: document.contents))
    return try result.requiredString("relativePath")
  }
  func workspaceCall(_ method: String, at location: WorkspaceLocation, fields: [String: JSON])
    async throws -> JSON
  {
    guard ready, let connection else { throw T3Error("Connect to load workspace files.") }
    guard workspaceLocation == location else { throw T3Error("The workspace changed.") }
    let generation = generation
    var payload = fields
    payload["cwd"] = .string(location.root)
    let result = try await connection.call(method, payload: .object(payload))
    guard self.generation == generation, workspaceLocation == location else {
      throw T3Error("The workspace changed while the file operation was running.")
    }
    return result
  }

  var reviewRepositoryRoot: String? {
    guard let selectedThread else { return nil }
    let project =
      shell.projectDetails[selectedThread.projectID]
      ?? archives.projectDetails[selectedThread.projectID] ?? .null
    return selectedThread.worktreePath ?? project["repositoryIdentity"]["rootPath"].string
      ?? workspaceLocation?.root
  }

  func checkpointDiff(_ request: CheckpointDiffRequest, at location: WorkspaceLocation)
    async throws -> String
  {
    guard ready, let connection else { throw T3Error("Connect to review saved changes.") }
    guard workspaceLocation == location, request.threadID == location.threadID else {
      throw T3Error("The selected thread changed.")
    }
    let generation = generation
    let result = try await connection.call(request.method, payload: request.input)
    guard self.generation == generation, workspaceLocation == location else {
      throw T3Error("The selected thread changed while loading its saved diff.")
    }
    return try request.validate(result)
  }

  func readWorkspaceFile(_ path: String, at location: WorkspaceLocation) async throws
    -> WorkspaceFileDocument
  {
    try await WorkspaceFileDocument(
      workspaceCall(
        "projects.readFile", at: location, fields: ["relativePath": .string(path)]))
  }

  func workspaceMediaRequest(_ path: String, at location: WorkspaceLocation, revision: UInt64)
    -> WorkspaceMediaRequest?
  {
    guard let connection, let settings, workspaceLocation == location,
      let kind = WorkspaceMediaKind(path: path)
    else { return nil }
    let key = WorkspaceMediaRequest.Key(
      file: WorkspaceFileID(location: location, path: path), threadID: location.threadID,
      connection: generation, revision: revision)
    if let cachedWorkspaceMedia, cachedWorkspaceMedia.key == key { return cachedWorkspaceMedia }
    let resource = WorkspaceMediaRequest.resource(path: path, at: location)
    let request = WorkspaceMediaRequest(key: key, kind: kind) {
      let issued = try await connection.call(
        "assets.createUrl", payload: .object(["resource": resource]))
      return try WorkspaceMediaRequest.freshURL(
        issued, endpoint: settings.endpoint, revision: revision)
    }
    cachedWorkspaceMedia = request
    return request
  }

  func workspaceFileAccess(at location: WorkspaceLocation) throws -> WorkspaceFileAccess {
    guard ready, let connection else { throw T3Error("Connect to save workspace files.") }
    guard workspaceLocation == location else { throw T3Error("The workspace changed.") }
    return WorkspaceFileAccess(connection: connection, location: location)
  }

  func saveWorkspaceFile(_ document: WorkspaceFileDocument, at location: WorkspaceLocation)
    async throws
  {
    try await workspaceFileAccess(at: location).save(document)
  }

  var changingSettings: Bool { commandsInFlight.contains((selectedID ?? "") + ":settings") }
  var canEditThread: Bool {
    ready && (isNewConversation || thread?.synchronized == true)
      && selectedThread?.archived == false && !changingSettings
  }

  func setModel(_ selection: JSON) {
    guard catalogReady, let selectedThread, let provider = catalog.provider(for: selection),
      provider.available,
      catalog.model(for: selection) != nil
    else { return }
    if isNewConversation {
      updateConversationDraft { $0.model = selection }
      return
    }
    let changingModel =
      selection["model"] != selectedThread.model["model"]
      || selection["instanceId"] != selectedThread.model["instanceId"]
    if changingModel, selection["instanceId"] == selectedThread.model["instanceId"],
      !(thread?.rows.isEmpty ?? true),
      provider.requiresNewThreadForModelChange
        || catalog.provider(for: selectedThread.model)?.requiresNewThreadForModelChange == true
    {
      error = "This provider requires a new thread to change models."
      notify()
      return
    }
    performThreadCommand(
      "thread.model-selection.set", fields: ["modelSelection": selection], key: "settings")
  }

  func modelDisabledReason(_ choice: ModelChoice) -> String? {
    guard catalogReady, canEditThread else {
      return "Wait for the thread to connect and finish updating."
    }
    if isNewConversation, pending[selectedID ?? ""]?.launch != nil {
      return "Retry the pending first message before changing its model."
    }
    guard choice.provider.available else {
      return choice.provider.unavailableReason ?? "This provider is unavailable."
    }
    guard let selectedThread else { return "Select a thread first." }
    if choice.provider.id == selectedThread.model["instanceId"].string,
      choice.model.id != selectedThread.model["model"].string,
      !(thread?.rows.isEmpty ?? true), choice.provider.requiresNewThreadForModelChange
    {
      return "Start a new thread to change this provider’s model."
    }
    return nil
  }

  func setModelOption(_ optionID: String, value: JSON) {
    guard let selectedThread, case .object(var selection) = selectedThread.model,
      let descriptor = catalog.descriptors(for: selectedThread.model).first(where: {
        $0["id"].string == optionID
      })
    else { return }
    if descriptor["type"].string == "boolean" {
      guard case .bool = value else { return }
    } else {
      guard descriptor["options"].array.contains(where: { $0["id"] == value }) else { return }
    }
    var options = selectedThread.model["options"].array.filter { $0["id"].string != optionID }
    options.append(.object(["id": .string(optionID), "value": value]))
    selection["options"] = .array(options)
    setModel(.object(selection))
  }

  func setRuntimeMode(_ mode: String) {
    guard catalogReady, let selectedThread else { return }
    let supported = catalog.provider(for: selectedThread.model)?.runtimeModes ?? []
    guard
      supported.contains(mode)
        || (supported.isEmpty && ["approval-required", "full-access"].contains(mode))
    else { return }
    if isNewConversation {
      updateConversationDraft { $0.runtimeMode = mode }
      return
    }
    performThreadCommand(
      "thread.runtime-mode.set", fields: ["runtimeMode": .string(mode)], key: "settings")
  }

  func setInteractionMode(_ mode: String) {
    guard catalogReady, catalog.planModeEnabled, let selectedThread,
      catalog.provider(for: selectedThread.model)?.showInteractionMode == true,
      ["default", "plan"].contains(mode)
    else { return }
    if isNewConversation {
      updateConversationDraft { $0.interactionMode = mode }
      return
    }
    performThreadCommand(
      "thread.interaction-mode.set", fields: ["interactionMode": .string(mode)], key: "settings")
  }

  func setPlanModeEnabled(_ enabled: Bool) {
    preferences.set(enabled, forKey: "planModeEnabled")
    catalog.setPlanModeEnabled(enabled)
    notify()
  }

  func respond(_ request: PendingRequest, decision: String? = nil) {
    guard request.canRespond, thread?.pendingRequests.contains(request) == true else { return }
    var fields: [String: JSON] = ["requestId": .string(request.id)]
    if request.isQuestion {
      respondToQuestions(request)
      return
    } else {
      guard let decision, request.options.contains(where: { $0["decision"].string == decision })
      else { return }
      fields["decision"] = .string(decision)
    }
    performThreadCommand("runtime-request.respond", fields: fields, key: "request:" + request.id)
  }

  func dismiss(_ request: PendingRequest) {
    guard request.dismissible, thread?.pendingRequests.contains(request) == true,
      let id = selectedID, !questionBusy(request),
      !request.questions.contains(where: {
        guard let questionID = $0["id"].string else { return false }
        return importingAttachments.contains(
          QuestionDraft.attachmentKey(threadID: id, requestID: request.id, questionID: questionID))
      })
    else { return }
    performThreadCommand(
      "thread.user-input.dismiss", fields: ["requestId": .string(request.id)],
      key: "request:" + request.id,
      completion: { [weak self] in self?.clearQuestionDrafts(request, threadID: id) })
  }

  var selectedRequest: PendingRequest? {
    let requests = thread?.pendingRequests ?? []
    return requests.first { $0.id == selectedRequestID } ?? requests.first
  }
  var questionRequest: PendingRequest? {
    guard queuedEdit == nil, let request = selectedRequest, request.isQuestion else { return nil }
    return request
  }
  func selectRequest(_ id: String) {
    guard !importingAttachments.contains(composerDraftID ?? "") else { return }
    selectedRequestID = id
    notify()
  }
  func questionBusy(_ request: PendingRequest) -> Bool {
    commandsInFlight.contains((selectedID ?? "") + ":request:" + request.id)
  }
  func questionIndex(_ request: PendingRequest) -> Int {
    min(max(0, questionPages[request.id] ?? 0), max(0, request.questions.count - 1))
  }
  var activeQuestion: JSON? {
    guard let request = questionRequest, !request.questions.isEmpty else { return nil }
    return request.questions[questionIndex(request)]
  }
  private func questionAttachments(_ request: PendingRequest) -> [String: [DraftAttachment]] {
    guard let threadID = selectedID else { return [:] }
    return Dictionary(
      request.questions.compactMap { question in
        guard let id = question["id"].string else { return nil }
        return (
          id,
          attachmentDrafts[
            QuestionDraft.attachmentKey(
              threadID: threadID, requestID: request.id, questionID: id)] ?? []
        )
      }, uniquingKeysWith: { _, new in new })
  }
  func questionProgress(_ request: PendingRequest) -> QuestionProgress {
    if let cached = questionProgressCache, cached.request == request { return cached.progress }
    let attachments = questionAttachments(request)
    var blocked = Set<String>()
    for question in request.questions {
      guard let id = question["id"].string, let threadID = selectedID else { continue }
      let key = QuestionDraft.attachmentKey(
        threadID: threadID, requestID: request.id, questionID: id)
      let files = attachments[id] ?? []
      if importingAttachments.contains(key)
        || (!files.isEmpty && !catalog.attachmentPolicy.questions)
        || files.contains(where: { attachmentUploads[$0.id] != .ready })
      {
        blocked.insert(id)
      }
    }
    let progress = QuestionProgress(
      questions: request.questions, drafts: questionDrafts[request.id] ?? [:],
      index: questionPages[request.id] ?? 0, attachmentCounts: attachments.mapValues(\.count),
      blocked: blocked)
    questionProgressCache = (request, progress, attachments)
    return progress
  }
  var activeQuestionProgress: QuestionProgress? { questionRequest.map(questionProgress) }
  var composerBusy: Bool {
    sending.contains(selectedID ?? "") || questionRequest.map(questionBusy) == true
  }
  func setQuestionPage(_ index: Int, request: PendingRequest) {
    guard !questionBusy(request), !importingAttachments.contains(composerDraftID ?? ""),
      thread?.pendingRequests.contains(request) == true
    else { return }
    questionPages[request.id] = min(max(0, index), max(0, request.questions.count - 1))
    notify()
  }
  func chooseQuestionOption(_ value: String, request: PendingRequest, question: JSON) {
    guard canEditThread, request.canRespond, !questionBusy(request), queuedEdit == nil,
      thread?.pendingRequests.contains(request) == true,
      let id = question["id"].string, request.questions.contains(question),
      question["options"].array.contains(where: {
        ($0["value"].string ?? $0["label"].string) == value
      })
    else { return }
    var draft = questionDrafts[request.id]?[id] ?? QuestionDraft()
    let custom = draft.custom.trimmingCharacters(in: .whitespacesAndNewlines)
    if !custom.isEmpty, let threadID = selectedID {
      let old = (drafts[threadID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      drafts[threadID] = old.isEmpty ? custom : old + "\n\n" + custom
    }
    draft.custom = ""
    if question["multiSelect"].bool {
      if draft.selected.contains(value) {
        draft.selected.removeAll { $0 == value }
      } else {
        draft.selected.append(value)
      }
    } else {
      draft.selected = [value]
    }
    questionDrafts[request.id, default: [:]][id] = draft
    notify()
  }
  func advanceQuestion(_ request: PendingRequest) {
    guard canEditThread, request.canRespond, !questionBusy(request), queuedEdit == nil,
      thread?.pendingRequests.contains(request) == true
    else { return }
    let progress = questionProgress(request)
    guard progress.answer != nil else { return }
    if progress.isLast {
      respondToQuestions(request)
    } else {
      setQuestionPage(progress.index + 1, request: request)
    }
  }
  func submitComposer() {
    guard sendBlockReason == nil else { return }
    switch composerAction {
    case .question: if let request = questionRequest { advanceQuestion(request) }
    case .plan: submitPlan()
    case .resume: resume()
    case .stop: stop()
    case .message: send()
    }
  }

  enum ComposerAction { case question, plan, resume, stop, message }
  var composerAction: ComposerAction {
    if questionRequest != nil { return .question }
    let plan = planFollowUp
    let hasContent =
      !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !selectedAttachments.isEmpty || importingAttachments.contains(composerDraftID ?? "")
    let canResume = execution.isHeld || execution.resumableRunID != nil
    if plan != nil && (pendingPlanSubmission != nil || hasContent || !canResume) { return .plan }
    if queuedEdit == nil && !hasContent {
      if execution.activeRunID != nil { return .stop }
      if canResume { return .resume }
    }
    return .message
  }

  var pendingPlanSubmission: PendingPlanSubmission? {
    selectedID.flatMap { planSubmissions[$0] }
  }
  var planFollowUp: ProposedPlan? {
    guard queuedEdit == nil, selectedAttachments.isEmpty,
      !importingAttachments.contains(selectedID ?? ""),
      thread?.pendingRequests.contains(where: \.isQuestion) != true
    else { return nil }
    if let pendingPlanSubmission { return pendingPlanSubmission.plan }
    guard catalog.planModeEnabled, selectedThread?.interactionMode == "plan",
      execution.latestRunSettled, let plan = thread?.latestProposedPlan,
      plan.status == "active",
      !plan.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    return plan
  }
  var planActionTitle: String {
    if let pendingPlanSubmission {
      return pendingPlanSubmission.isImplementation ? "Retry implementation" : "Retry refinement"
    }
    return composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? "Implement" : "Refine"
  }
  func discardPlanRetry() {
    guard let id = selectedID, let command = planSubmissions[id], !sending.contains(id) else {
      return
    }
    planSubmissions.removeValue(forKey: id)
    if !flushDrafts() { planSubmissions[id] = command }
    notify()
  }
  private var planSendBlockReason: String? {
    guard canEditThread, catalogReady else { return "Wait for the thread to connect." }
    if sending.contains(selectedID ?? "") { return "Sending…" }
    if queueBusy { return "Wait for the queue update." }
    if pendingPlanSubmission == nil,
      catalog.provider(for: selectedThread?.model ?? .null)?.available != true
    {
      return "The selected provider is unavailable."
    }
    return nil
  }
  func submitPlan(newThread: Bool = false) {
    guard let plan = planFollowUp, let template = selectedThread, let connection,
      planSendBlockReason == nil, !newThread || pendingPlanSubmission == nil
    else { return }
    let command =
      pendingPlanSubmission
      ?? PendingPlanSubmission(
        plan: plan, template: template, draft: drafts[template.id] ?? "", newThread: newThread,
        defaultRuntimeMode: catalog.defaultRuntimeMode(projectID: template.projectID))
    planSubmissions[template.id] = command
    guard flushDrafts() else { return }
    sending.insert(template.id)
    error = nil
    notify()
    let generation = generation
    Task {
      defer {
        if self.generation == generation {
          sending.remove(template.id)
          notify()
        }
      }
      do {
        for payload in [command.setup, command.message] {
          _ = try await connection.call("orchestration.dispatchCommand", payload: payload)
          guard self.generation == generation else { return }
        }
        if !command.isNewThread, drafts[template.id] == command.draft { drafts[template.id] = "" }
        planSubmissions.removeValue(forKey: template.id)
        _ = flushDrafts()
        if command.isNewThread, selectedID == template.id { select(command.targetThreadID) }
      } catch {
        guard self.generation == generation else { return }
        self.error =
          error.localizedDescription
          + " Your plan send is saved. Retry reuses the same thread and message."
      }
    }
  }
  private func respondToQuestions(_ request: PendingRequest) {
    guard canEditThread, request.canRespond, !questionBusy(request), let id = selectedID,
      let connection, let answers = questionProgress(request).answers
    else { return }
    let attachments = questionProgressCache?.attachments ?? [:]
    do { try catalog.attachmentPolicy.validate(attachments.values.flatMap { $0 }) } catch {
      self.error = error.localizedDescription
      notify()
      return
    }
    let command =
      questionResponses[request.id].flatMap {
        $0.matches(answers: answers, attachments: attachments) ? $0 : nil
      }
      ?? PendingQuestionResponse(
        threadID: id, requestID: request.id, answers: answers, attachments: attachments)
    questionResponses[request.id] = command
    guard flushDrafts() else { return }
    let operation = id + ":request:" + request.id
    commandsInFlight.insert(operation)
    error = nil
    notify()
    let generation = generation
    Task {
      defer {
        if self.generation == generation {
          commandsInFlight.remove(operation)
          notify()
        }
      }
      do {
        _ = try await connection.call("orchestration.dispatchCommand", payload: command.payload)
        guard self.generation == generation else { return }
        clearQuestionDrafts(request, threadID: id)
      } catch {
        guard self.generation == generation else { return }
        self.error = error.localizedDescription
      }
    }
  }
  private func clearQuestionDrafts(_ request: PendingRequest, threadID: String) {
    clearQuestionDrafts([request.id], threadID: threadID)
  }
  private func clearQuestionDrafts(_ requestIDs: Set<String>, threadID: String) {
    guard !requestIDs.isEmpty else { return }
    var files: [DraftAttachment] = []
    var changed = false
    for key in Set(attachmentDrafts.keys).union(importingAttachments) {
      guard let scope = QuestionDraft.attachmentScope(key), scope.threadID == threadID,
        requestIDs.contains(scope.requestID)
      else { continue }
      files += attachmentDrafts.removeValue(forKey: key) ?? []
      importingAttachments.remove(key)
      changed = true
    }
    for id in requestIDs {
      if let response = questionResponses.removeValue(forKey: id) {
        files += response.attachments.values.flatMap { $0 }
        changed = true
      }
      if questionDrafts.removeValue(forKey: id) != nil { changed = true }
      if questionPages.removeValue(forKey: id) != nil { changed = true }
    }
    guard changed else { return }
    files = Array(Dictionary(files.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new }).values)
    for file in files {
      uploadJobs.removeValue(forKey: file.id)?.task.cancel()
      attachmentUploads.removeValue(forKey: file.id)
    }
    if flushDrafts(), let repository = attachmentRepository {
      for file in files { repository.remove(file) }
    }
    startAttachmentUploads()
  }
  private func cleanResolvedQuestions(_ value: JSON, threadID: String) {
    let records: [JSON]
    if value["kind"].string == "snapshot" {
      records = value["projection"]["runtimeRequests"].array
    } else if value["event"]["type"].string == "runtime-request.updated" {
      records = [value["event"]["payload"]]
    } else {
      return
    }
    let ids = Set(
      records.compactMap { record -> String? in
        guard record["kind"].string == "user_input",
          ["resolved", "expired", "cancelled"].contains(record["status"].string ?? "")
        else { return nil }
        return record["id"].string
      })
    clearQuestionDrafts(ids, threadID: threadID)
  }

  private func performThreadCommand(
    _ type: String, fields: [String: JSON], key: String,
    threadID: String? = nil, completion: (() -> Void)? = nil
  ) {
    guard ready, threadID != nil || canEditThread,
      let id = threadID ?? selectedID, let connection
    else { return }
    let operation = id + ":" + key
    guard !commandsInFlight.contains(operation) else { return }
    let generation = generation
    var payload = fields
    payload["type"] = .string(type)
    payload["threadId"] = .string(id)
    payload["commandId"] = .string(UUID().uuidString)
    commandsInFlight.insert(operation)
    error = nil
    notify()
    Task {
      defer {
        if self.generation == generation {
          commandsInFlight.remove(operation)
          notify()
        }
      }
      do {
        _ = try await connection.call("orchestration.dispatchCommand", payload: .object(payload))
        guard self.generation == generation else { return }
        completion?()
      } catch {
        guard self.generation == generation else { return }
        self.error = error.localizedDescription
      }
    }
  }

  func select(_ id: String, force: Bool = false) {
    guard id != selectedID || force else { return }
    if id != selectedID {
      suppressVisit = nil
      visibleVisit = nil
    }
    detail?.cancel()
    selectionGeneration = UUID()
    let selection = selectionGeneration
    let generation = generation
    selectedID = id
    if let settings {
      var selections = preferences.dictionary(forKey: "selectedThreadByEndpoint") ?? [:]
      selections[settings.endpoint.absoluteString] = id
      preferences.set(selections, forKey: "selectedThreadByEndpoint")
    }
    if thread?.id != id { thread = ThreadState(id: id) }
    thread?.markUnsynchronized()
    loadingHistory = false
    error = nil
    notify()
    guard !isNewConversation, let connection, ready else { return }
    detail = Task {
      do {
        let subscription = try await connection.subscribe(
          "orchestration.subscribeThread",
          payload: .object([
            "threadId": .string(id), "requestCompletionMarker": .bool(true),
            "acceptBoundedSnapshot": .bool(true),
          ]))
        defer { Task { await connection.cancel(subscription.id) } }
        for try await value in subscription.values {
          try Task.checkCancellation()
          guard self.generation == generation && selectionGeneration == selection else { return }
          let previousSequence = thread?.sequence
          if try thread?.apply(value) == true {
            select(id, force: true)
            return
          }
          if value["kind"].string == "snapshot" || thread?.sequence != previousSequence {
            cleanResolvedQuestions(value, threadID: id)
          }
          notify()
        }
        guard !Task.isCancelled && selectionGeneration == selection && self.generation == generation
        else { return }
        thread?.markUnsynchronized()
        error = "Conversation updates ended. Reconnect to refresh."
        notify()
      } catch {
        guard !Task.isCancelled && selectionGeneration == selection && self.generation == generation
        else { return }
        thread?.markUnsynchronized()
        self.error = error.localizedDescription
        notify()
      }
    }
  }

  func loadOlder() {
    guard let settings, let thread, let cursor = thread.cursor, thread.hasMore, !loadingHistory
    else { return }
    loadingHistory = true
    let selection = selectionGeneration
    notify()
    Task {
      do {
        let page = try await EnvironmentHTTP.read(
          settings.request(
            "/api/orchestration/threads/\(thread.id)/history",
            query: [URLQueryItem(name: "cursor", value: cursor)]))
        guard selectionGeneration == selection else { return }
        try self.thread?.prependHistory(page)
      } catch {
        guard selectionGeneration == selection else { return }
        self.error = error.localizedDescription
      }
      guard selectionGeneration == selection else { return }
      loadingHistory = false
      notify()
    }
  }

  func loadOutput(_ row: TimelineRow) {
    let key = row.id + ":output"
    guard ready, let connection, row.item["outputOmitted"].bool,
      !commandsInFlight.contains(key)
    else { return }
    commandsInFlight.insert(key)
    let generation = generation
    let selection = selectionGeneration
    notify()
    Task {
      defer {
        if self.generation == generation {
          commandsInFlight.remove(key)
          notify()
        }
      }
      do {
        let response = try await connection.call(
          "orchestration.getTurnItem",
          payload: .object([
            "threadId": .string(row.sourceID), "itemId": row.item["id"],
            "revision": row.item["updatedAt"],
          ]))
        guard self.generation == generation, selectionGeneration == selection else { return }
        guard response["item"] != .null else {
          throw T3Error("This tool output is no longer available.")
        }
        try thread?.hydrateOutput(response["item"], replacing: row)
      } catch {
        guard self.generation == generation, selectionGeneration == selection else { return }
        self.error = "Tool output: " + error.localizedDescription
      }
    }
  }

  var queuedEdit: QueuedEdit? {
    queuedEdits.values.first { $0.threadID == selectedID && $0.active }
  }
  var savedQueuedEdits: [QueuedEdit] {
    queuedEdits.values.filter { $0.threadID == selectedID && !$0.active }.sorted {
      $0.runID < $1.runID
    }
  }
  var messageDraftID: String? { queuedEdit?.draftID ?? selectedID }
  var composerDraftID: String? {
    if let request = questionRequest, let id = selectedID,
      let questionID = activeQuestion?["id"].string
    {
      return QuestionDraft.attachmentKey(
        threadID: id, requestID: request.id, questionID: questionID)
    }
    return messageDraftID
  }
  var composerText: String {
    get {
      if let request = questionRequest, let id = activeQuestion?["id"].string {
        return questionDrafts[request.id]?[id]?.custom ?? ""
      }
      return messageDraftID.flatMap { drafts[$0] } ?? ""
    }
    set {
      if let request = questionRequest, let question = activeQuestion,
        let id = question["id"].string
      {
        guard question["allowCustomAnswer"] != .bool(false), !questionBusy(request) else { return }
        var draft = questionDrafts[request.id]?[id] ?? QuestionDraft()
        draft.custom = newValue
        if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { draft.selected = [] }
        questionDrafts[request.id, default: [:]][id] = draft
      } else if let id = messageDraftID {
        drafts[id] = newValue
      }
    }
  }
  var execution: ThreadExecution { thread?.execution ?? ThreadExecution() }
  var delivery: MessageDelivery {
    guard queuedEdit == nil else { return .auto }
    return selectedID.flatMap { deliveries[$0] } ?? .auto
  }
  func setDelivery(_ value: MessageDelivery) {
    guard let id = selectedID, !sending.contains(id), queuedEdit == nil else { return }
    deliveries[id] = value
    notify()
  }
  var queueBusy: Bool {
    !canEditThread || commandsInFlight.contains((selectedID ?? "") + ":queue")
      || sending.contains(selectedID ?? "")
  }
  func editQueuedMessage(_ message: QueuedMessage) {
    guard let id = selectedID, !queueBusy, queuedEdit == nil,
      !importingAttachments.contains(composerDraftID ?? ""), execution.queued.contains(message)
    else { return }
    if queuedEdits[message.id] != nil {
      queuedEdits[message.id]?.active = true
    } else {
      let edit = QueuedEdit(message, threadID: id)
      queuedEdits[message.id] = edit
      drafts[edit.draftID] = message.text
    }
    _ = flushDrafts()
    notify()
  }
  func cancelQueuedEdit() {
    guard let id = selectedID, let edit = queuedEdit, !sending.contains(id),
      !importingAttachments.contains(composerDraftID ?? "")
    else { return }
    queuedEdits[edit.runID]?.active = false
    _ = flushDrafts()
    notify()
  }
  func removeQueuedAttachment(_ attachment: JSON) {
    guard let id = selectedID, let edit = queuedEdit, !sending.contains(id) else { return }
    queuedEdits[edit.runID]?.attachments.removeAll { $0["id"] == attachment["id"] }
    notify()
  }
  func reopenQueuedEdit(_ runID: String) {
    guard let id = selectedID, !queueBusy, queuedEdit == nil, queuedEdits[runID]?.threadID == id,
      !importingAttachments.contains(composerDraftID ?? "")
    else { return }
    queuedEdits[runID]?.active = true
    _ = flushDrafts()
    notify()
  }
  func reorderQueuedMessage(_ id: String, before beforeID: String?) {
    guard !queueBusy, execution.canQueue, execution.queued.contains(where: { $0.id == id }),
      beforeID == nil || execution.queued.contains(where: { $0.id == beforeID })
    else { return }
    performThreadCommand(
      "queued-run.reorder",
      fields: ["runId": .string(id), "beforeRunId": beforeID.map(JSON.string) ?? .null],
      key: "queue")
  }
  func cancelQueuedMessage(_ id: String) {
    guard !queueBusy, execution.queued.contains(where: { $0.id == id }) else { return }
    performThreadCommand("queued-run.cancel", fields: ["runId": .string(id)], key: "queue")
  }
  func steerQueuedMessage(_ id: String) {
    guard !queueBusy, execution.canSteer, let target = execution.activeRunID,
      execution.queued.contains(where: { $0.id == id })
    else { return }
    performThreadCommand(
      "queued-message.promote-to-steer",
      fields: ["queuedRunId": .string(id), "targetRunId": .string(target)], key: "queue")
  }

  var canAddBrowserContext: Bool {
    selectedThread?.archived == false && questionRequest == nil && queuedEdit == nil
      && pendingPlanSubmission == nil && messageDraftID != nil
  }
  func addBrowserContext(_ context: JSON) {
    guard canAddBrowserContext else { return }
    let draft = composerText
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(context), let text = String(data: data, encoding: .utf8)
    else { return }
    // A fence longer than any run in the page keeps selected HTML inside the context block.
    let fence = String(
      repeating: "`",
      count: max(3, (text.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0) + 1))
    composerText =
      draft + (draft.isEmpty ? "" : "\n\n") + "Selected browser element:\n" + fence + "json\n"
      + text + "\n" + fence
    notify()
  }

  var selectedAttachments: [DraftAttachment] {
    composerDraftID.flatMap { attachmentDrafts[$0] } ?? []
  }
  var canAttach: Bool {
    guard selectedThread?.archived == false, !importingAttachments.contains(composerDraftID ?? ""),
      !(queuedEdit != nil && sending.contains(selectedID ?? "")), pendingPlanSubmission == nil
    else { return false }
    if let request = questionRequest {
      return request.canRespond && !questionBusy(request) && catalog.attachmentPolicy.questions
        && activeQuestion?["allowCustomAnswer"] != .bool(false)
    }
    return true
  }
  var attachmentRepository: AttachmentRepository? {
    settings.map { draftRepository.attachmentRepository(for: $0.endpoint) }
  }
  func attachmentPreviewRequest(_ attachment: JSON) throws -> AttachmentPreviewRequest {
    guard let connection, let settings, ready else {
      throw T3Error("Connect before downloading attachments.")
    }
    return try .remote(attachment, connection: connection, settings: settings)
  }
  func downloadAttachment(_ attachment: JSON, to destination: URL) async throws {
    try await attachmentPreviewRequest(attachment).load(destination)
  }
  var sendBlockReason: String? {
    if let request = questionRequest {
      guard canEditThread, request.canRespond else {
        return request.reason ?? "Wait for the question to reconnect."
      }
      if questionBusy(request) { return "Sending answers…" }
      let progress = questionProgress(request)
      return progress.answer == nil || (progress.isLast && progress.answers == nil)
        ? "Answer the question and finish its uploads before continuing." : nil
    }
    let action = composerAction
    if action == .plan { return planSendBlockReason }
    if action == .resume || action == .stop {
      guard canEditThread else { return "Wait for the thread to connect." }
      if sending.contains(selectedID ?? "") { return "Sending…" }
      if queueBusy { return "Wait for the queue update." }
      if commandsInFlight.contains((selectedID ?? "") + ":stop") { return "Stopping…" }
      return nil
    }
    return messageSendBlockReason
  }
  private var messageSendBlockReason: String? {
    guard let threadID = selectedID, let id = messageDraftID, canEditThread else {
      return "Wait for the thread to connect."
    }
    if sending.contains(threadID) { return "Sending…" }
    // An uncertain first launch must replay its original request, even if the user edits the draft.
    if pending[id]?.launch != nil { return nil }
    if let draft = selectedDraft, draft.workspaceMode == "worktree", draft.branch == nil {
      return "Select a base branch for the new worktree."
    }
    if let model = selectedDraft?.model, catalog.provider(for: model)?.available != true {
      return "Choose an available provider account."
    }
    if commandsInFlight.contains(threadID + ":queue") { return "Wait for the queue update." }
    if importingAttachments.contains(id) { return "Adding attachments…" }
    let attachments = attachmentDrafts[id] ?? []
    let text = drafts[id] ?? ""
    let edit = queuedEdit
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
      && (edit?.attachments.isEmpty ?? true)
    {
      return "Write a message or attach a file."
    }
    if pending[id]?.matches(text: text, attachments: attachments, delivery: delivery, edit: edit)
      == true
    {
      return nil
    }
    if let edit,
      !execution.queued.contains(where: { $0.id == edit.runID && $0.messageID == edit.messageID })
    {
      return
        "This queued message has started or was removed. Your edit is saved; return to your draft to continue."
    }
    if delivery == .queue && !execution.canQueue {
      return "This provider does not support queued messages. Choose Auto."
    }
    if delivery == .steer && !execution.canSteer {
      return "There is no provider turn available to steer. Choose Auto or Queue next."
    }
    if delivery == .restart && !execution.canRestart {
      return "This provider turn cannot be restarted. Choose Auto or Queue next."
    }
    do {
      try catalog.attachmentPolicy.validate(attachments, retained: edit?.attachments ?? [])
    } catch {
      return error.localizedDescription
    }
    for attachment in attachments where attachmentUploads[attachment.id] != .ready {
      if case .failed(let reason) = attachmentUploads[attachment.id] { return reason }
      return "Wait for attachments to finish uploading."
    }
    return nil
  }

  func addAttachments(_ urls: [URL], deleteSources: Bool = false) {
    guard let id = composerDraftID, canAttach, let repository = attachmentRepository else { return }
    let generation = generation
    let retained = queuedEdit?.attachments ?? []
    let questionFiles = questionRequest.map(questionAttachments) ?? [:]
    let otherFiles = questionFiles.filter {
      $0.key != activeQuestion?["id"].string
    }.values.flatMap { $0 }
    let remaining = max(
      0, 100 - (attachmentDrafts[id]?.count ?? 0) - retained.count - otherFiles.count)
    importingAttachments.insert(id)
    notify()
    Task {
      let result = await Task.detached {
        var files: [DraftAttachment] = []
        var errors: [String] =
          urls.count > remaining ? ["You can attach up to 100 files per message."] : []
        for url in urls.prefix(remaining) {
          do { files.append(try repository.stage(url)) } catch {
            errors.append(error.localizedDescription)
          }
        }
        if deleteSources {
          for url in urls {
            try? FileManager.default.removeItem(at: url)
            if url.deletingLastPathComponent().lastPathComponent.hasPrefix("t3-paste-") {
              try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
          }
        }
        return (files, errors)
      }.value
      guard self.generation == generation, importingAttachments.contains(id) else {
        result.0.forEach(repository.remove)
        return
      }
      importingAttachments.remove(id)
      var errors = result.1
      for attachment in result.0 {
        do {
          try catalog.attachmentPolicy.validate(
            otherFiles + (attachmentDrafts[id] ?? []) + [attachment], requireServer: catalogReady,
            retained: retained)
          attachmentDrafts[id, default: []].append(attachment)
        } catch {
          repository.remove(attachment)
          errors.append(error.localizedDescription)
        }
      }
      if !errors.isEmpty { error = errors.joined(separator: "\n") }
      if flushDrafts() { startAttachmentUploads() }
      notify()
    }
  }

  func removeAttachment(_ attachment: DraftAttachment) {
    guard let id = composerDraftID, !composerBusy,
      let repository = attachmentRepository
    else {
      return
    }
    uploadJobs.removeValue(forKey: attachment.id)?.task.cancel()
    attachmentUploads.removeValue(forKey: attachment.id)
    attachmentDrafts[id]?.removeAll { $0.id == attachment.id }
    // An uncertain send still owns its exact bytes and remote IDs until resolved.
    if !(pending[id]?.localAttachmentIDs ?? []).contains(attachment.id),
      !questionResponses.values.contains(where: { $0.localAttachmentIDs.contains(attachment.id) }),
      flushDrafts()
    {
      repository.remove(attachment)
      if let uploadedID = attachment.uploadedID, let connection {
        Task {
          _ = try? await connection.call(
            "attachments.delete", payload: .object(["attachmentId": .string(uploadedID)]))
        }
      }
    }
    startAttachmentUploads()
    notify()
  }

  func retryAttachment(_ attachment: DraftAttachment) {
    guard uploadJobs[attachment.id] == nil else { return }
    attachmentUploads.removeValue(forKey: attachment.id)
    startAttachmentUploads()
    notify()
  }

  private func startAttachmentUploads() {
    guard ready, catalogReady, catalog.attachmentPolicy.uploads,
      let connection, let settings, let repository = attachmentRepository
    else { return }
    let generation = generation
    let questionAttachmentIDs = questionResponses.values.reduce(into: Set<String>()) {
      $0.formUnion($1.localAttachmentIDs)
    }
    for (threadID, attachments) in attachmentDrafts.sorted(by: { $0.key < $1.key }) {
      for attachment in attachments {
        if (pending[threadID]?.localAttachmentIDs ?? []).contains(attachment.id)
          || questionAttachmentIDs.contains(attachment.id)
        {
          attachmentUploads[attachment.id] = .ready
          continue
        }
        guard uploadJobs.count < 2 else { return }
        guard attachmentUploads[attachment.id] == nil, uploadJobs[attachment.id] == nil else {
          continue
        }
        do { try catalog.attachmentPolicy.validate([attachment]) } catch {
          attachmentUploads[attachment.id] = .failed(error.localizedDescription)
          continue
        }
        let token = UUID()
        attachmentUploads[attachment.id] = .uploading(0)
        let task = Task { [self] in
          var mintedID: String?
          defer {
            if let mintedID {
              Task {
                _ = try? await connection.call(
                  "attachments.delete", payload: .object(["attachmentId": .string(mintedID)]))
              }
            }
            if self.generation == generation, uploadJobs[attachment.id]?.token == token {
              uploadJobs.removeValue(forKey: attachment.id)
              startAttachmentUploads()
              notify()
            }
          }
          do {
            var uploadedID = attachment.uploadedID
            if let previous = uploadedID {
              do {
                _ = try await connection.call(
                  "assets.createUrl",
                  payload: .object([
                    "resource": .object([
                      "_tag": .string("attachment"), "attachmentId": .string(previous),
                    ])
                  ]))
              } catch {
                guard (error as? T3Error)?.remoteCode == "AssetAttachmentNotFoundError" else {
                  throw error
                }
                uploadedID = nil
              }
            }
            if uploadedID == nil {
              try Task.checkCancellation()
              let issued = try await connection.call(
                "attachments.createUploadUrl", payload: attachment.uploadInput)
              mintedID = try issued.requiredString("attachmentId")
              try Task.checkCancellation()
              let url = try AttachmentHTTP.signedURL(
                issued.requiredString("relativeUrl"), endpoint: settings.endpoint,
                prefix: "/api/attachments/upload/")
              try await AttachmentHTTP.upload(
                attachment, from: repository.file(attachment), to: url
              ) { [weak self] progress in
                Task { @MainActor in
                  guard let self, self.generation == generation,
                    self.uploadJobs[attachment.id]?.token == token
                  else { return }
                  let value = Int(progress * 20) * 5
                  if self.attachmentUploads[attachment.id] != .uploading(value) {
                    self.attachmentUploads[attachment.id] = .uploading(value)
                    self.notify()
                  }
                }
              }
              uploadedID = mintedID
            }
            try Task.checkCancellation()
            guard self.generation == generation, uploadJobs[attachment.id]?.token == token,
              let index = attachmentDrafts[threadID]?.firstIndex(where: { $0.id == attachment.id })
            else { return }
            attachmentDrafts[threadID]?[index].uploadedID = uploadedID
            mintedID = nil
            attachmentUploads[attachment.id] = .ready
            _ = flushDrafts()
          } catch {
            guard self.generation == generation, uploadJobs[attachment.id]?.token == token else {
              return
            }
            attachmentUploads[attachment.id] = .failed(
              "\(attachment.name): " + error.localizedDescription)
          }
        }
        uploadJobs[attachment.id] = (token, task)
      }
    }
  }

  func send() {
    guard let id = selectedID, let draftID = messageDraftID, let connection,
      messageSendBlockReason == nil
    else { return }
    let text = drafts[draftID] ?? ""
    let attachments = attachmentDrafts[draftID] ?? []
    let edit = queuedEdit
    var command =
      pending[draftID].flatMap {
        if $0.launch != nil { return $0 }
        return $0.matches(text: text, attachments: attachments, delivery: delivery, edit: edit)
          ? $0 : nil
      }
      ?? PendingSubmission(
        text: text, attachments: (edit?.attachments ?? []) + attachments.compactMap(\.wire),
        localAttachmentIDs: attachments.map(\.id), delivery: delivery, queuedRunID: edit?.runID,
        retainedAttachmentIDs: edit?.attachments.compactMap { $0["id"].string },
        context: edit?.retainedContext)
    if let draft = selectedDraft, command.launch == nil {
      do {
        let launch = try draft.launch(command)
        command = PendingSubmission(
          text: command.text, command: command.command, message: command.message,
          attachments: command.attachments, localAttachmentIDs: command.localAttachmentIDs,
          delivery: command.delivery, launch: launch)
      } catch {
        self.error = error.localizedDescription
        notify()
        return
      }
    }
    pending[draftID] = command
    let submitted = command
    guard flushDrafts() else { return }
    let generation = generation
    let repository = attachmentRepository
    sending.insert(id)
    error = nil
    notify()
    Task {
      defer {
        if self.generation == generation {
          sending.remove(id)
          notify()
        }
      }
      do {
        _ = try await connection.call(
          submitted.launch == nil ? "orchestration.dispatchCommand" : "orchestration.launchThread",
          payload: submitted.launch ?? submitted.payload(threadID: id))
        guard self.generation == generation else { return }
        if submitted.launch != nil {
          conversationDrafts.removeValue(forKey: id)
          if selectedID == id { select(id, force: true) }
        }
        if drafts[draftID] == submitted.text { drafts[draftID] = "" }
        let sentIDs = Set(submitted.localAttachmentIDs ?? [])
        attachmentDrafts[draftID]?.removeAll { sentIDs.contains($0.id) }
        for id in sentIDs { attachmentUploads.removeValue(forKey: id) }
        pending.removeValue(forKey: draftID)
        if let edit { queuedEdits.removeValue(forKey: edit.runID) }
        if flushDrafts() {
          for attachment in attachments where sentIDs.contains(attachment.id) {
            repository?.remove(attachment)
          }
        }
      } catch {
        guard self.generation == generation, selectedID == id else { return }
        self.error =
          error.localizedDescription
          + (submitted.launch == nil
            ? " Your draft is preserved. Retrying the unchanged message reuses the same command."
            : " Retry sends the original first message. Any newer edits remain saved for the next message.")
      }
    }
  }

  var canCreateThread: Bool { ready && catalogReady && !creatingThread }
  var projectSessionID: UUID { usageSessionID }

  func browseProjectFolders(_ path: String, session: UUID) async throws -> JSON {
    let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty else { throw T3Error("Enter a folder path.") }
    return try await projectCall(
      "filesystem.browse",
      payload: .object(["partialPath": .string(path.hasSuffix("/") ? path : path + "/")]),
      session: session)
  }

  func openProject(_ path: String, session: UUID) async throws -> JSON {
    let result = try await browseProjectFolders(path, session: session)
    let root = try result.requiredString("parentPath")
    if let existing = shell.projectDetails.values.first(where: {
      $0["workspaceRoot"].string == root
    }) {
      return existing
    }
    let id = UUID().uuidString
    do {
      return try await projectCall(
        "projects.mutate",
        payload: .object([
          "type": .string("project.create"), "commandId": .string(UUID().uuidString),
          "projectId": .string(id), "workspaceRoot": .string(root),
          "title": .string(root == "/" ? "/" : (root as NSString).lastPathComponent),
        ]), session: session)
    } catch {
      // An accepted create may lose its response, or another client may open the same folder.
      if let existing = try? await serverProjects(session: session).first(where: {
        $0["workspaceRoot"].string == root
      }) {
        return existing
      }
      throw error
    }
  }

  func createProject(_ name: String, session: UUID) async throws -> (
    project: JSON, warning: String?
  ) {
    let result = try await projectCall(
      "projects.createNew", payload: .object(["name": .string(name)]), session: session)
    let id = try result.requiredString("projectId")
    let project = try await project(id: id, session: session)
    return (
      project,
      result["commitError"].string.map { "Project created. Its initial commit failed: " + $0 }
    )
  }

  private func projectCall(_ method: String, payload: JSON, session: UUID) async throws -> JSON {
    guard ready, let connection, session == projectSessionID else {
      throw T3Error("The connection changed. Reopen the project picker to use the current server.")
    }
    let result = try await connection.call(method, payload: payload)
    try Task.checkCancellation()
    guard ready, session == projectSessionID else {
      throw T3Error("The connection changed while the project operation was running.")
    }
    return result
  }

  private func serverProjects(session: UUID) async throws -> [JSON] {
    guard ready, let connection, session == projectSessionID else {
      throw T3Error("The project connection changed.")
    }
    let stream = try await connection.subscribe(
      "orchestration.subscribeShell", payload: .object(["requestCompletionMarker": .bool(true)]))
    defer { Task { await connection.cancel(stream.id) } }
    for try await value in stream.values {
      try Task.checkCancellation()
      guard ready, session == projectSessionID else {
        throw T3Error("The project connection changed.")
      }
      if value["kind"].string == "snapshot" {
        return value["snapshot"]["projects"].array
      }
    }
    throw T3Error("The server did not return its projects.")
  }

  private func project(id: String, session: UUID) async throws -> JSON {
    if let project = shell.projectDetails[id], session == projectSessionID { return project }
    guard
      let project = try await serverProjects(session: session).first(where: {
        $0["id"].string == id
      })
    else { throw T3Error("The project is no longer available.") }
    return project
  }

  func updateConversationDraft(_ edit: (inout NewConversationDraft) -> Void) {
    guard let id = selectedID, var draft = conversationDrafts[id],
      !sending.contains(id), pending[id]?.launch == nil
    else { return }
    edit(&draft)
    conversationDrafts[id] = draft
    error = nil
    notify()
  }

  func setDraftProject(_ project: JSON) {
    guard isNewConversation else { return }
    updateConversationDraft { draft in
      draft.project = project
      draft.branch = nil
    }
  }

  func startWithoutProject() {
    guard canCreateThread, catalog.scratchWorkspaceRoot != nil else { return }
    let session = projectSessionID
    let selection = selectionGeneration
    Task {
      do {
        let scratch = try await projectCall(
          "projects.ensureScratch", payload: .object([:]), session: session)
        let project = try await self.project(
          id: scratch.requiredString("projectId"), session: session)
        guard selectionGeneration == selection else { return }
        if isNewConversation { setDraftProject(project) } else { newThread(project: project) }
      } catch {
        guard session == projectSessionID, selectionGeneration == selection else { return }
        self.error = error.localizedDescription
        notify()
      }
    }
  }

  func compactContext() {
    guard canEditThread, !isNewConversation, !composerBusy, execution.activeRunID == nil,
      let id = selectedID, let connection
    else { return }
    let command = Commands.message(
      threadID: id, text: "/compact", commandID: UUID().uuidString, messageID: UUID().uuidString)
    let generation = generation
    sending.insert(id)
    notify()
    Task {
      defer {
        if self.generation == generation {
          sending.remove(id)
          notify()
        }
      }
      do { _ = try await connection.call("orchestration.dispatchCommand", payload: command) } catch
      { if self.generation == generation { self.error = error.localizedDescription } }
    }
  }

  func resolveNewDraftWorkspaceMode(project: JSON, session: UUID) async throws -> String {
    guard ready, session == projectSessionID else {
      throw T3Error("The project connection changed.")
    }
    if let configured = catalog.configuredWorkspaceMode(project: project) { return configured }
    let file = try? await projectCall(
      "projects.readFile",
      payload: .object([
        "cwd": project["workspaceRoot"], "relativePath": .string("t3.json"),
      ]), session: session)
    try Task.checkCancellation()
    guard ready, session == projectSessionID else {
      throw T3Error("The project connection changed.")
    }
    if let configured = catalog.configuredWorkspaceMode(project: project) { return configured }
    guard let file, !file["truncated"].bool, let contents = file["contents"].string,
      contents.utf8.count <= 1_048_576
    else { return "local" }
    return WorkspaceDefaults.fileMode(contents: contents) ?? "local"
  }

  func newThread(
    projectID: String? = nil, project openedProject: JSON? = nil, warning: String? = nil
  ) {
    guard canCreateThread else { return }
    let session = projectSessionID
    let selection = selectionGeneration
    let template = selectedThread
    let projectID = projectID ?? openedProject?["id"].string ?? template?.projectID
    creatingThread = true
    error = nil
    notify()
    Task {
      defer {
        if session == projectSessionID {
          creatingThread = false
          notify()
        }
      }
      do {
        let project: JSON
        if let openedProject {
          project = openedProject
        } else if let projectID {
          project = try await self.project(id: projectID, session: session)
        } else {
          let scratch = try await projectCall(
            "projects.ensureScratch", payload: .object([:]), session: session)
          project = try await self.project(
            id: scratch.requiredString("projectId"), session: session)
        }
        let workspaceMode = try await resolveNewDraftWorkspaceMode(
          project: project, session: session)
        let configuration = try catalog.newThreadConfiguration(project: project, carrying: template)
        let draft = NewConversationDraft(
          project: project, configuration: configuration, workspaceMode: workspaceMode)
        conversationDrafts[draft.id] = draft
        guard flushDrafts() else { return }
        if selectionGeneration == selection {
          showingArchives = false
          select(draft.id)
        }
        error = warning
      } catch {
        guard session == projectSessionID else { return }
        self.error = error.localizedDescription
        notify()
      }
    }
  }

  func stop() {
    guard let run = execution.activeRunID ?? selectedThread?.activeRunID else { return }
    performThreadCommand(
      "run.interrupt", fields: ["runId": .string(run), "holdQueue": .bool(true)], key: "stop")
  }

  func resume() {
    guard let id = selectedID, let connection, !queueBusy,
      execution.isHeld || execution.resumableRunID != nil
    else { return }
    let key = "resume:" + id
    let command =
      pending[key]
      ?? PendingSubmission(
        text: "Continue where you left off.", continuationOf: execution.resumableRunID)
    pending[key] = command
    guard flushDrafts() else { return }
    commandsInFlight.insert(id + ":queue")
    error = nil
    notify()
    let generation = generation
    Task {
      defer {
        if self.generation == generation {
          commandsInFlight.remove(id + ":queue")
          notify()
        }
      }
      do {
        if command.continuationOf != nil {
          _ = try await connection.call(
            "orchestration.dispatchCommand", payload: command.payload(threadID: id))
        }
        _ = try await connection.call(
          "orchestration.dispatchCommand",
          payload: .object([
            "type": .string("queue.resume"), "commandId": .string(command.command + ":queue"),
            "threadId": .string(id),
          ]))
        guard self.generation == generation else { return }
        pending.removeValue(forKey: key)
        _ = flushDrafts()
      } catch {
        guard self.generation == generation else { return }
        self.error = error.localizedDescription
      }
    }
  }

  private func notify() {
    guard notification == nil else { return }
    notification = Task {
      try? await Task.sleep(for: .milliseconds(33))
      notification = nil
      onChange?()
    }
  }
}
