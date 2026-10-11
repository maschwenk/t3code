import Foundation
import T3Core

@MainActor final class ClientStore {
  var shell = ShellState()
  private(set) var sortedThreads: [ThreadSummary] = []
  var thread: ThreadState?
  var selectedID: String?
  var status = "Connect to your T3 server"
  var error: String?
  var ready = false
  var loadingHistory = false
  var sending: Set<String> = []
  var drafts: [String: String] = [:] { didSet { scheduleDraftSave() } }
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
      !drafts.isEmpty || !questionDrafts.isEmpty || !pending.isEmpty,
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
      sortedThreads = []
      thread = nil
      selectedID = nil
      drafts = [:]
      questionDrafts = [:]
      pending = [:]
      catalog = ProviderCatalog()
      do {
        let saved = try draftRepository.load(for: settings.endpoint)
        drafts = saved.messages
        pending = saved.submissions
        questionDrafts = saved.questions
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
          let subscription = try await connection.subscribe(
            "orchestration.subscribeShell",
            payload: .object(["requestCompletionMarker": .bool(true)]))
          for try await value in subscription.values {
            guard self.generation == generation else { break }
            try shell.apply(value)
            sortedThreads = shell.threads.values.sorted { $0.updatedAt > $1.updatedAt }
            if shell.synchronized {
              if !ready {
                ready = true
                status = "Connected · \(settings.endpoint.host ?? "T3")"
                error = nil
                if let selectedID, shell.threads[selectedID] != nil {
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
    if let connection { Task { await connection.close() } }
    connection = nil
    ready = false
    catalogReady = false
    commandsInFlight = []
    sending = []
  }

  func retry() { if let settings { connect(settings) } }

  func saveDraftsBeforeExit() -> Bool { flushDrafts() }

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
          questions: questionDrafts), for: draftEndpoint)
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

  var selectedThread: ThreadSummary? { selectedID.flatMap { shell.threads[$0] } }
  var changingSettings: Bool { commandsInFlight.contains((selectedID ?? "") + ":settings") }
  var canEditThread: Bool { ready && thread?.synchronized == true && !changingSettings }

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

  private func performThreadCommand(_ type: String, fields: [String: JSON], key: String) {
    guard canEditThread, let id = selectedID, let connection else { return }
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
      } catch {
        guard self.generation == generation else { return }
        self.error = error.localizedDescription
      }
    }
  }

  func select(_ id: String, force: Bool = false) {
    guard id != selectedID || force else { return }
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

  func send() {
    guard let id = selectedID, let connection, ready, thread?.synchronized == true,
      let text = drafts[id], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !sending.contains(id)
    else { return }
    let command =
      pending[id].flatMap { $0.text == text ? $0 : nil } ?? PendingSubmission(text: text)
    pending[id] = command
    guard flushDrafts() else { return }
    let generation = generation
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
            threadID: id, text: text, commandID: command.command, messageID: command.message))
        guard self.generation == generation else { return }
        if drafts[id] == text { drafts[id] = "" }
        pending.removeValue(forKey: id)
      } catch {
        guard self.generation == generation else { return }
        self.error =
          error.localizedDescription
          + " Your draft is preserved. Retrying unchanged text reuses the same command."
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
