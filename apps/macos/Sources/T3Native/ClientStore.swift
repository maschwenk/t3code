import Foundation
import T3Core

@MainActor final class ClientStore {
  var shell = ShellState()
  private(set) var archives = ShellState(archived: true)
  private(set) var showingArchives = false
  private(set) var archiveError: String?
  private(set) var sortedThreads: [ThreadSummary] = []
  var thread: ThreadState?
  var selectedID: String?
  var status = "Connect to your T3 server"
  var error: String?
  var ready = false
  var loadingHistory = false
  var sending: Set<String> = []
  var drafts: [String: String] = [:] { didSet { scheduleDraftSave() } }
  private(set) var attachmentDrafts: [String: [DraftAttachment]] = [:] {
    didSet { scheduleDraftSave() }
  }
  enum UploadState: Equatable {
    case uploading(Int)
    case ready
    case failed(String)
  }
  private(set) var attachmentUploads: [String: UploadState] = [:]
  private(set) var importingAttachments: Set<String> = []
  private var uploadJobs: [String: (token: UUID, task: Task<Void, Never>)] = [:]
  var catalog = ProviderCatalog()
  private(set) var catalogReady = false
  var questionDrafts: [String: [String: QuestionDraft]] = [:] { didSet { scheduleDraftSave() } }
  private(set) var storageError: String?
  private(set) var commandsInFlight: Set<String> = []
  var onChange: (() -> Void)?
  private var connection: RPCConnection?
  private var settings: ConnectionSettings?
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
  private let draftRepository: DraftRepository
  private var draftEndpoint: URL?
  private var draftSave: Task<Void, Never>?

  init(draftDirectory: URL? = nil) {
    let directory =
      draftDirectory
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("T3 Native/Drafts", isDirectory: true)
    draftRepository = DraftRepository(directory: directory)
  }

  func connect(_ settings: ConnectionSettings, selecting threadID: String? = nil) {
    if let current = self.settings, current.endpoint != settings.endpoint,
      !drafts.isEmpty || !questionDrafts.isEmpty || !pending.isEmpty || !attachmentDrafts.isEmpty,
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
      catalog = ProviderCatalog()
      do {
        let saved = try draftRepository.load(for: settings.endpoint)
        drafts = saved.messages
        pending = saved.submissions
        questionDrafts = saved.questions
        attachmentDrafts = saved.attachments ?? [:]
        draftEndpoint = settings.endpoint
        storageError = nil
      } catch {
        storageError = "Saved drafts could not be loaded: " + error.localizedDescription
      }
    }
    self.settings = settings
    if let threadID { selectedID = threadID }
    let generation = self.generation
    lifetime = Task {
      var attempt = 0
      while !Task.isCancelled && self.generation == generation {
        status = attempt == 0 ? "Connecting…" : "Reconnecting…"
        ready = false
        catalogReady = false
        notify()
        let connection = RPCConnection(settings: settings)
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
    ready = false
    catalogReady = false
    commandsInFlight = []
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
          questions: questionDrafts, attachments: attachmentDrafts.filter { !$0.value.isEmpty }),
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
        let stream = try await connection.subscribe("subscribeServerConfig", payload: .object([:]))
        defer { Task { await connection.cancel(stream.id) } }
        for try await event in stream.values {
          try Task.checkCancellation()
          guard self.generation == generation else { return }
          try catalog.apply(event)
          if event["type"].string == "snapshot" { catalogReady = true }
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
    selectedID.flatMap { shell.threads[$0] ?? archives.threads[$0] }
  }
  var environmentKey: String { settings?.endpoint.absoluteString ?? "disconnected" }
  var changingSettings: Bool { commandsInFlight.contains((selectedID ?? "") + ":settings") }
  var canEditThread: Bool {
    ready && thread?.synchronized == true && selectedThread?.archived == false && !changingSettings
  }

  func setModel(_ selection: JSON) {
    guard catalogReady, let selectedThread, let provider = catalog.provider(for: selection),
      provider.available,
      catalog.model(for: selection) != nil
    else { return }
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
    performThreadCommand(
      "thread.runtime-mode.set", fields: ["runtimeMode": .string(mode)], key: "settings")
  }

  func setInteractionMode(_ mode: String) {
    guard catalogReady, catalog.planModeEnabled, let selectedThread,
      catalog.provider(for: selectedThread.model)?.showInteractionMode == true,
      ["default", "plan"].contains(mode)
    else { return }
    performThreadCommand(
      "thread.interaction-mode.set", fields: ["interactionMode": .string(mode)], key: "settings")
  }

  func respond(_ request: PendingRequest, decision: String? = nil) {
    guard request.canRespond, thread?.pendingRequests.contains(request) == true else { return }
    var fields: [String: JSON] = ["requestId": .string(request.id)]
    if request.isQuestion {
      guard let answers = request.answers(from: questionDrafts[request.id] ?? [:]) else { return }
      fields["answers"] = answers
    } else {
      guard let decision, request.options.contains(where: { $0["decision"].string == decision })
      else { return }
      fields["decision"] = .string(decision)
    }
    performThreadCommand("runtime-request.respond", fields: fields, key: "request:" + request.id)
  }

  func dismiss(_ request: PendingRequest) {
    guard request.dismissible, thread?.pendingRequests.contains(request) == true else { return }
    performThreadCommand(
      "thread.user-input.dismiss", fields: ["requestId": .string(request.id)],
      key: "request:" + request.id)
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
    if thread?.id != id { thread = ThreadState(id: id) }
    thread?.markUnsynchronized()
    loadingHistory = false
    error = nil
    notify()
    guard let connection, ready else { return }
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
          if try thread?.apply(value) == true {
            select(id, force: true)
            return
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

  var selectedAttachments: [DraftAttachment] { selectedID.flatMap { attachmentDrafts[$0] } ?? [] }
  var canAttach: Bool {
    selectedThread?.archived == false && !importingAttachments.contains(selectedID ?? "")
  }
  var attachmentRepository: AttachmentRepository? {
    settings.map { draftRepository.attachmentRepository(for: $0.endpoint) }
  }
  func downloadAttachment(_ attachment: JSON, to destination: URL) async throws {
    guard let connection, let settings, ready else {
      throw T3Error("Connect before downloading attachments.")
    }
    let issued = try await connection.call(
      "assets.createUrl",
      payload: .object([
        "resource": .object([
          "_tag": .string("attachment"), "attachmentId": attachment["id"],
          "fileName": attachment["name"], "mimeType": attachment["mimeType"],
        ])
      ]))
    let url = try AttachmentHTTP.signedURL(
      issued.requiredString("relativeUrl"), endpoint: settings.endpoint, prefix: "/api/assets/")
    try await AttachmentHTTP.download(url, to: destination)
  }
  var sendBlockReason: String? {
    guard let id = selectedID, canEditThread else { return "Wait for the thread to connect." }
    if sending.contains(id) { return "Sending…" }
    if importingAttachments.contains(id) { return "Adding attachments…" }
    let attachments = attachmentDrafts[id] ?? []
    let text = drafts[id] ?? ""
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty {
      return "Write a message or attach a file."
    }
    if pending[id]?.matches(text: text, attachments: attachments) == true { return nil }
    do { try catalog.attachmentPolicy.validate(attachments) } catch {
      return error.localizedDescription
    }
    for attachment in attachments where attachmentUploads[attachment.id] != .ready {
      if case .failed(let reason) = attachmentUploads[attachment.id] { return reason }
      return "Wait for attachments to finish uploading."
    }
    return nil
  }

  func addAttachments(_ urls: [URL], deleteSources: Bool = false) {
    guard let id = selectedID, canAttach, let repository = attachmentRepository else { return }
    let generation = generation
    let remaining = max(0, 100 - (attachmentDrafts[id]?.count ?? 0))
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
      guard self.generation == generation else {
        result.0.forEach(repository.remove)
        return
      }
      importingAttachments.remove(id)
      var errors = result.1
      for attachment in result.0 {
        do {
          try catalog.attachmentPolicy.validate(
            (attachmentDrafts[id] ?? []) + [attachment], requireServer: catalogReady)
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
    guard let id = selectedID, !sending.contains(id), let repository = attachmentRepository else {
      return
    }
    uploadJobs.removeValue(forKey: attachment.id)?.task.cancel()
    attachmentUploads.removeValue(forKey: attachment.id)
    attachmentDrafts[id]?.removeAll { $0.id == attachment.id }
    // An uncertain send still owns its exact bytes and remote IDs until resolved.
    if !(pending[id]?.localAttachmentIDs ?? []).contains(attachment.id), flushDrafts() {
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
    for (threadID, attachments) in attachmentDrafts.sorted(by: { $0.key < $1.key }) {
      for attachment in attachments {
        if (pending[threadID]?.localAttachmentIDs ?? []).contains(attachment.id) {
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
    guard let id = selectedID, let connection, sendBlockReason == nil else { return }
    let text = drafts[id] ?? ""
    let attachments = attachmentDrafts[id] ?? []
    let command =
      pending[id].flatMap { $0.matches(text: text, attachments: attachments) ? $0 : nil }
      ?? PendingSubmission(
        text: text, attachments: attachments.compactMap(\.wire),
        localAttachmentIDs: attachments.map(\.id))
    pending[id] = command
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
          "orchestration.dispatchCommand",
          payload: Commands.message(
            threadID: id, text: command.text, commandID: command.command,
            messageID: command.message, attachments: command.attachments ?? []))
        guard self.generation == generation else { return }
        if drafts[id] == text { drafts[id] = "" }
        let sentIDs = Set(command.localAttachmentIDs ?? [])
        attachmentDrafts[id]?.removeAll { sentIDs.contains($0.id) }
        for id in sentIDs { attachmentUploads.removeValue(forKey: id) }
        pending.removeValue(forKey: id)
        if flushDrafts() {
          for attachment in attachments { repository?.remove(attachment) }
        }
      } catch {
        guard self.generation == generation else { return }
        self.error =
          error.localizedDescription
          + " Your draft is preserved. Retrying the unchanged message reuses the same command."
      }
    }
  }

  func newThread() {
    guard let connection, ready, let template = selectedID.flatMap({ shell.threads[$0] }) else {
      return
    }
    let generation = generation
    Task {
      do {
        let id = UUID().uuidString
        _ = try await connection.call(
          "orchestration.dispatchCommand", payload: Commands.newThread(template: template, id: id))
        guard self.generation == generation else { return }
        select(id)
      } catch {
        guard self.generation == generation else { return }
        self.error = error.localizedDescription
        notify()
      }
    }
  }

  func stop() {
    guard let connection, ready, let id = selectedID, let run = shell.threads[id]?.activeRunID
    else { return }
    let generation = generation
    Task {
      do {
        _ = try await connection.call(
          "orchestration.dispatchCommand",
          payload: .object([
            "type": .string("run.interrupt"), "commandId": .string(UUID().uuidString),
            "threadId": .string(id), "runId": .string(run), "holdQueue": .bool(true),
          ]))
      } catch {
        guard self.generation == generation else { return }
        self.error = error.localizedDescription
        notify()
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
