import Foundation
import T3Core

struct WorkspaceFileReveal {
  let id = UUID()
  let file: WorkspaceFileID
  let position: FileSourcePosition
}

@MainActor final class WorkspaceFiles {
  private let store: ClientStore
  private let repository: WorkspaceDraftRepository
  private let writeQueue = WorkspaceWriteQueue()
  private var documents: [WorkspaceFileID: WorkspaceFileDocument]
  private var context = UUID()
  private var directoryTask: Task<Void, Never>?
  private var fileTask: Task<Void, Never>?
  private var readingFile = false
  private var searchTask: Task<Void, Never>?
  private var persistTask: Task<Void, Never>?
  private var saveSchedules: [WorkspaceFileID: FileSaveSchedule] = [:]
  private var saveTimers: [WorkspaceFileID: Task<Void, Never>] = [:]
  private var writes: [WorkspaceFileID: Task<Void, Never>] = [:]
  private var saveAccess: [WorkspaceFileID: WorkspaceFileAccess] = [:]
  private var finishSignals: [UUID: AsyncStream<Void>.Continuation] = [:]
  private(set) var saveErrors: [WorkspaceFileID: String] = [:]
  private var active = true
  private var failedReads: Set<WorkspaceFileID> = []
  private var mediaFile: WorkspaceFileID?
  private var mediaRevision: UInt64 = 0
  private var requestedReveal: WorkspaceFileReveal?
  private var mutationToken: String?
  private var refreshedTreeToken: String?
  private var refreshedFileTokens: [WorkspaceFileID: String] = [:]
  private var pendingDirectories: [String] = []
  private var requestedDirectories: Set<String> = []
  private var connected = false
  private var recoveryUnreadable = false
  private(set) var location: WorkspaceLocation?
  private(set) var directories: [String: [WorkspaceEntry]] = [:]
  private(set) var searchResults: [WorkspaceEntry] = []
  private(set) var query = ""
  private(set) var treeRevision = 0
  private(set) var selected: WorkspaceFileID?
  private(set) var selectedDirectory: String?
  private(set) var saving: Set<WorkspaceFileID> = []
  private(set) var loadingFile = false
  private(set) var loadingTree = false
  private(set) var message = ""
  private(set) var storageError: String?
  var onChange: (() -> Void)?
  var document: WorkspaceFileDocument? { selected.flatMap { documents[$0] } }
  var mediaRequest: WorkspaceMediaRequest? {
    guard let selected, selected == mediaFile, let location, !loadingFile,
      selectedDirectory == nil
    else { return nil }
    return store.workspaceMediaRequest(selected.path, at: location, revision: mediaRevision)
  }
  var revealRequest: WorkspaceFileReveal? {
    guard let requestedReveal, requestedReveal.file == selected, document != nil,
      !loadingFile, !failedReads.contains(requestedReveal.file)
    else { return nil }
    return requestedReveal
  }
  var canEditDocument: Bool {
    document?.canEdit == true && !loadingFile && selected.map { !failedReads.contains($0) } == true
      && selected.map { WorkspaceMediaKind(path: $0.path).map { $0 == .html } ?? true } == true
  }
  var pendingSave: Bool {
    document?.requiresRecovery == true
      || selected.map { saveSchedules[$0]?.pending == true } == true
  }
  var isConnected: Bool { connected }
  var selectedSaveError: String? { selected.flatMap { saveErrors[$0] } }
  var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  var canSave: Bool {
    connected && !loadingFile && pendingSave && document?.canEdit == true
      && selected.map { !saving.contains($0) } == true
  }
  var drafts: [WorkspaceFileID] {
    documents.keys.filter {
      $0.environment == location?.environment && $0.root == location?.root
        && (documents[$0]?.requiresRecovery == true || saveSchedules[$0]?.pending == true)
    }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
  }

  init(store: ClientStore, directory: URL? = nil) {
    self.store = store
    repository = WorkspaceDraftRepository(
      directory: directory
        ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("T3 Native/Workspace Drafts", isDirectory: true))
    do { documents = try repository.load() } catch {
      documents = [:]
      recoveryUnreadable = true
      storageError = error.localizedDescription
    }
  }

  func refreshContext(active: Bool = true) {
    self.active = active
    let next = store.workspaceLocation
    let connectionChanged = connected != store.ready
    let reconnect = !connected && store.ready
    connected = store.ready
    guard next != location else {
      if reconnect {
        refresh()
        if let selected, let location, saveSchedules[selected]?.pending == true {
          saveAccess[selected] = try? store.workspaceFileAccess(at: location)
        }
      } else if connectionChanged {
        onChange?()
      }
      receiveWorkspaceMutation(store.thread?.workspaceMutationToken)
      return
    }
    if let selected { requestSave(selected) }
    _ = flush()
    context = UUID()
    directoryTask?.cancel()
    directoryTask = nil
    fileTask?.cancel()
    fileTask = nil
    searchTask?.cancel()
    searchTask = nil
    location = next
    selected = nil
    selectedDirectory = nil
    mediaFile = nil
    requestedReveal = nil
    directories = [:]
    searchResults = []
    query = ""
    pendingDirectories = []
    requestedDirectories = []
    loadingTree = false
    loadingFile = false
    readingFile = false
    message = ""
    mutationToken = nil
    refreshedTreeToken = nil
    refreshedFileTokens = [:]
    treeRevision += 1
    pruneCleanDocuments()
    if next != nil && connected && active { loadDirectory("") }
    receiveWorkspaceMutation(store.thread?.workspaceMutationToken)
    onChange?()
  }

  func loadDirectory(_ path: String) {
    guard connected, location != nil, directories[path] == nil,
      requestedDirectories.insert(path).inserted
    else { return }
    pendingDirectories.append(path)
    runDirectories()
  }

  private func revealInTree(_ path: String, isDirectory: Bool) {
    let ancestors = WorkspaceTreeNavigation.directories(for: path, isDirectory: isDirectory)
    guard !ancestors.isEmpty else { return }
    let children = Array(ancestors.dropFirst()) + (isDirectory ? [] : [path])
    for child in children {
      let parent = child.split(separator: "/").dropLast().joined(separator: "/")
      if let entries = directories[parent], !entries.contains(where: { $0.path == child }) {
        directories.removeValue(forKey: parent)
        requestedDirectories.remove(parent)
        treeRevision += 1
        loadDirectory(parent)
      }
    }
    for directory in ancestors { loadDirectory(directory) }
  }

  private func runDirectories() {
    guard directoryTask == nil, let location else { return }
    let context = context
    loadingTree = true
    directoryTask = Task { [weak self] in
      guard let self else { return }
      defer {
        if self.context == context {
          directoryTask = nil
          loadingTree = false
          onChange?()
        }
      }
      while !pendingDirectories.isEmpty && !Task.isCancelled && self.context == context {
        let path = pendingDirectories.removeFirst()
        if !path.isEmpty {
          let parent = path.split(separator: "/").dropLast().joined(separator: "/")
          if let entries = directories[parent],
            !entries.contains(where: { $0.path == path && $0.isDirectory })
          {
            requestedDirectories.remove(path)
            continue
          }
        }
        do {
          let result = try await store.workspaceCall(
            "projects.listEntries", at: location,
            fields: ["directoryPath": .string(path)])
          guard self.context == context, !Task.isCancelled else { return }
          directories[path] = try WorkspaceEntry.entries(result, directory: path)
          treeRevision += 1
          if result["truncated"].bool { message = "This folder listing is truncated." }
        } catch {
          guard self.context == context, !Task.isCancelled else { return }
          requestedDirectories.remove(path)
          message = error.localizedDescription
        }
        onChange?()
      }
    }
  }

  func refresh() {
    guard location != nil, connected, active else { return }
    // Reload visited folders sequentially; never recursively crawl a repository.
    let paths = Set(directories.keys).union([""])
    directories = [:]
    requestedDirectories = Set(pendingDirectories)
    for path in paths.sorted() where requestedDirectories.insert(path).inserted {
      pendingDirectories.append(path)
    }
    message = ""
    treeRevision += 1
    onChange?()
    runDirectories()
    if isSearching { search(query) }
  }

  func search(_ value: String) {
    query = String(decoding: value.utf16.prefix(256), as: UTF16.self)
    searchTask?.cancel()
    searchResults = []
    treeRevision += 1
    onChange?()
    guard isSearching, connected, let location else { return }
    let query = query
    let context = context
    searchTask = Task { [weak self] in
      guard let self else { return }
      do {
        try await Task.sleep(for: .milliseconds(200))
        let result = try await store.workspaceCall(
          "projects.searchEntries", at: location,
          fields: ["query": .string(query), "limit": .number(200)])
        guard !Task.isCancelled, self.context == context, self.query == query else { return }
        searchResults = try WorkspaceEntry.entries(result)
        treeRevision += 1
        message =
          result["truncated"].bool ? "Showing the first 200 matches. Refine your search." : ""
        onChange?()
      } catch {
        guard !Task.isCancelled, self.context == context else { return }
        message = error.localizedDescription
        onChange?()
      }
    }
  }

  func open(
    _ path: String, position: FileSourcePosition? = nil,
    reload: Bool = false, background: Bool = false
  ) {
    guard let location else { return }
    fileTask?.cancel()
    readingFile = false
    let id = WorkspaceFileID(location: location, path: path)
    if mediaFile != id { mediaFile = nil }
    if !background || selected != id { selectedDirectory = nil }
    if !background {
      requestedReveal = position.map { WorkspaceFileReveal(file: id, position: $0) }
    }
    if let selected, selected != id { requestSave(selected) }
    if reload && !saving.contains(id) {
      saveTimers.removeValue(forKey: id)?.cancel()
      saveSchedules.removeValue(forKey: id)
      saveErrors.removeValue(forKey: id)
    }
    selected = id
    for directory in WorkspaceTreeNavigation.directories(for: path, isDirectory: false) {
      loadDirectory(directory)
    }
    if !saving.contains(id) { saveAccess[id] = try? store.workspaceFileAccess(at: location) }
    message = ""
    if !reload, documents[id]?.requiresRecovery == true || saveSchedules[id]?.pending == true {
      loadingFile = false
      if WorkspaceMediaKind(path: path) != nil { mediaFile = id }
      revealInTree(path, isDirectory: false)
      onChange?()
      return
    }
    let context = context
    let requestedMutation = mutationToken
    let readRevision = saveSchedules[id]?.revision ?? 0
    loadingFile = !background
    readingFile = true
    onChange?()
    fileTask = Task { [weak self] in
      guard let self else { return }
      do {
        let document = try await store.readWorkspaceFile(path, at: location)
        guard !Task.isCancelled, self.context == context, selected == id else { return }
        if !background
          || ((saveSchedules[id]?.revision ?? 0) == readRevision
            && documents[id]?.requiresRecovery != true)
        {
          documents[id] = document
          selectedDirectory = nil
          mediaFile = WorkspaceMediaKind(path: path) == nil ? nil : id
          mediaRevision &+= 1
          revealInTree(path, isDirectory: false)
          if let requestedMutation { refreshedFileTokens[id] = requestedMutation }
          failedReads.remove(id)
          pruneCleanDocuments()
          _ = flush()
        }
      } catch {
        guard !Task.isCancelled, self.context == context, selected == id else { return }
        if let requestedMutation { refreshedFileTokens[id] = requestedMutation }
        if documents[id]?.requiresRecovery != true { failedReads.insert(id) }
        mediaFile = nil
        if let error = error as? T3Error, error.remoteCode == "ProjectReadFileError",
          error.remoteFailure == "path_not_file", !path.hasPrefix("/"),
          documents[id]?.requiresRecovery != true
        {
          documents.removeValue(forKey: id)
          selectedDirectory = path
          requestedReveal = nil
          if isSearching { search("") }
          revealInTree(path, isDirectory: true)
          message = "Folder · " + path
        } else if let error = error as? T3Error, error.remoteCode == "ProjectReadFileError",
          error.remoteFailure == "binary_file", WorkspaceMediaKind(path: path) != nil
        {
          mediaFile = id
          mediaRevision &+= 1
          revealInTree(path, isDirectory: false)
          message = ""
        } else {
          message = error.localizedDescription
        }
      }
      readingFile = false
      loadingFile = false
      applyPendingMutation()
      onChange?()
    }
  }

  func edit(_ contents: String) {
    guard let selected, var document = documents[selected], canEditDocument else {
      return
    }
    document.contents = contents
    documents[selected] = document
    saveErrors.removeValue(forKey: selected)
    saveSchedules[selected, default: FileSaveSchedule()].change(
      at: ProcessInfo.processInfo.systemUptime)
    if let location, !saving.contains(selected) {
      saveAccess[selected] = try? store.workspaceFileAccess(at: location)
    }
    scheduleSave(selected)
    message = ""
    persistTask?.cancel()
    persistTask = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
      guard let self else { return }
      _ = flush()
      onChange?()
    }
    onChange?()
  }

  func save() async throws {
    guard let selected, let document, document.canEdit, connected, !loadingFile else { return }
    if saveSchedules[selected]?.pending != true && document.requiresRecovery {
      saveSchedules[selected, default: FileSaveSchedule()].change(
        at: ProcessInfo.processInfo.systemUptime)
    }
    if let location, !saving.contains(selected) {
      saveAccess[selected] = try store.workspaceFileAccess(at: location)
    }
    requestSave(selected)
    await waitForWrites(selected)
    if let error = saveErrors[selected] { throw T3Error(error) }
  }

  func closeEditor() {
    active = false
    if let selected { requestSave(selected) }
    _ = flush()
  }

  func finishSaving() async -> Bool {
    active = false
    let id = UUID()
    let (events, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    finishSignals[id] = signal
    for id in Array(saveSchedules.keys) { requestSave(id) }
    let timeout = Task {
      do { try await Task.sleep(for: .seconds(5)) } catch { return }
      signal.finish()
    }
    defer {
      timeout.cancel()
      signal.finish()
      finishSignals.removeValue(forKey: id)
    }
    signal.yield(())
    for await _ in events where writes.isEmpty { break }
    // A slow or disconnected host must not prevent quitting. Uncertain writes remain recoverable.
    return flush()
  }

  private func waitForWrites(_ id: WorkspaceFileID) async {
    while let write = writes[id] { await write.value }
  }

  private func requestSave(_ id: WorkspaceFileID) {
    saveTimers.removeValue(forKey: id)?.cancel()
    saveSchedules[id]?.flush(at: ProcessInfo.processInfo.systemUptime)
    startSave(id)
  }

  private func scheduleSave(_ id: WorkspaceFileID) {
    saveTimers.removeValue(forKey: id)?.cancel()
    guard !saving.contains(id), let deadline = saveSchedules[id]?.deadline else { return }
    let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
    saveTimers[id] = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(delay)) } catch { return }
      guard let self else { return }
      saveTimers.removeValue(forKey: id)
      startSave(id)
    }
  }

  private func startSave(_ id: WorkspaceFileID) {
    guard writes[id] == nil, let document = documents[id], document.canEdit,
      let revision = saveSchedules[id]?.begin(at: ProcessInfo.processInfo.systemUptime)
    else { return }
    guard let access = saveAccess[id], flush() else {
      completeSave(
        id, revision: revision, contents: document.contents,
        error: storageError ?? "Connect and retry saving this file.")
      return
    }
    saving.insert(id)
    // Install the task before notifying observers, which may edit or navigate synchronously.
    writes[id] = Task { [weak self] in
      guard let self else { return }
      var failure: String?
      do {
        try await writeQueue.save(document, access: access) { [weak self] baseline in
          guard let self else { throw T3Error("The file editor closed before saving.") }
          try await self.prepareWrite(id, baseline: baseline, contents: document.contents)
        }
      } catch { failure = error.localizedDescription }
      writes.removeValue(forKey: id)
      completeSave(id, revision: revision, contents: document.contents, error: failure)
    }
    onChange?()
  }

  private func prepareWrite(_ id: WorkspaceFileID, baseline: String, contents: String) throws {
    documents[id]?.acknowledgeSave(baseline)
    documents[id]?.recordSaveAttempt(contents)
    guard flush() else { throw T3Error(storageError ?? "Recovery could not be saved.") }
  }

  private func completeSave(_ id: WorkspaceFileID, revision: Int, contents: String, error: String?)
  {
    saving.remove(id)
    if let error {
      saveErrors[id] = error
    } else {
      documents[id]?.acknowledgeSave(contents)
      saveErrors.removeValue(forKey: id)
      if mediaFile == id { mediaRevision &+= 1 }
    }
    saveSchedules[id]?.complete(
      revision, succeeded: error == nil, at: ProcessInfo.processInfo.systemUptime)
    _ = flush()
    if selected == id {
      message = error ?? (documents[id]?.isDirty == true ? "Saving changes…" : "Saved")
    }
    if let deadline = saveSchedules[id]?.deadline, deadline <= ProcessInfo.processInfo.systemUptime
    {
      startSave(id)
    } else {
      scheduleSave(id)
    }
    pruneCleanDocuments()
    applyPendingMutation()
    for signal in finishSignals.values { signal.yield(()) }
    onChange?()
  }

  func receiveWorkspaceMutation(_ token: String?) {
    mutationToken = token
    applyPendingMutation()
  }

  private func applyPendingMutation() {
    guard active, connected, location == store.workspaceLocation else { return }
    if directories.isEmpty && !loadingTree { loadDirectory("") }
    guard let token = mutationToken else { return }
    if refreshedTreeToken != token {
      refreshedTreeToken = token
      refresh()
    }
    guard let selected, document != nil || selectedDirectory != nil || selected == mediaFile,
      document?.requiresRecovery != true,
      saveSchedules[selected]?.pending != true, !saving.contains(selected), !readingFile,
      refreshedFileTokens[selected] != token
    else { return }
    open(selected.path, background: true)
  }

  @discardableResult func flush() -> Bool {
    persistTask?.cancel()
    persistTask = nil
    do {
      // Do not replace unreadable recovery data with an empty file.
      if recoveryUnreadable {
        throw T3Error(storageError ?? "The saved file drafts could not be read.")
      }
      try repository.save(documents)
      storageError = nil
      return true
    } catch {
      storageError = error.localizedDescription
      return false
    }
  }

  private func pruneCleanDocuments() {
    documents = documents.filter {
      $0.key == selected || $0.value.requiresRecovery || saveSchedules[$0.key]?.pending == true
        || saving.contains($0.key)
    }
    saveAccess = saveAccess.filter { documents[$0.key] != nil }
    saveSchedules = saveSchedules.filter { documents[$0.key] != nil }
    saveErrors = saveErrors.filter { documents[$0.key] != nil }
    failedReads = failedReads.filter { documents[$0] != nil || $0 == selected }
    refreshedFileTokens = refreshedFileTokens.filter {
      documents[$0.key] != nil || $0.key == selected
    }
  }
}

private actor WorkspaceWriteQueue {
  private var running = 0
  private var waiting: [CheckedContinuation<Void, Never>] = []

  func save(
    _ document: WorkspaceFileDocument, access: WorkspaceFileAccess,
    beforeWrite: @Sendable (String) async throws -> Void
  ) async throws {
    if running == 4 { await withCheckedContinuation { waiting.append($0) } } else { running += 1 }
    defer {
      if waiting.isEmpty { running -= 1 } else { waiting.removeFirst().resume() }
    }
    try await access.save(document, beforeWrite: beforeWrite)
  }
}
