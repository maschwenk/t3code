import Foundation
import T3Core

@MainActor final class WorkspaceFiles {
  private let store: ClientStore
  private let repository: WorkspaceDraftRepository
  private var documents: [WorkspaceFileID: WorkspaceFileDocument]
  private var context = UUID()
  private var directoryTask: Task<Void, Never>?
  private var fileTask: Task<Void, Never>?
  private var searchTask: Task<Void, Never>?
  private var persistTask: Task<Void, Never>?
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
  private(set) var saving: Set<WorkspaceFileID> = []
  private(set) var loadingFile = false
  private(set) var loadingTree = false
  private(set) var message = ""
  private(set) var storageError: String?
  var onChange: (() -> Void)?
  var document: WorkspaceFileDocument? { selected.flatMap { documents[$0] } }
  var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  var canSave: Bool {
    connected && !loadingFile && document?.isDirty == true && document?.canEdit == true
      && selected.map { !saving.contains($0) } == true
  }
  var drafts: [WorkspaceFileID] {
    documents.keys.filter {
      $0.environment == location?.environment && $0.root == location?.root
        && documents[$0]?.isDirty == true
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

  func refreshContext() {
    let next = store.workspaceLocation
    let connectionChanged = connected != store.ready
    let reconnect = !connected && store.ready
    connected = store.ready
    guard next != location else {
      if reconnect { refresh() } else if connectionChanged { onChange?() }
      return
    }
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
    directories = [:]
    searchResults = []
    query = ""
    pendingDirectories = []
    requestedDirectories = []
    loadingTree = false
    loadingFile = false
    message = ""
    treeRevision += 1
    pruneCleanDocuments()
    if next != nil && connected { loadDirectory("") }
    onChange?()
  }

  func loadDirectory(_ path: String) {
    guard connected, location != nil, directories[path] == nil,
      requestedDirectories.insert(path).inserted
    else { return }
    pendingDirectories.append(path)
    runDirectories()
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
    guard location != nil, connected else { return }
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

  func open(_ path: String, reload: Bool = false) {
    guard let location else { return }
    fileTask?.cancel()
    let id = WorkspaceFileID(location: location, path: path)
    selected = id
    message = ""
    if !reload, documents[id]?.isDirty == true {
      loadingFile = false
      onChange?()
      return
    }
    let context = context
    loadingFile = true
    onChange?()
    fileTask = Task { [weak self] in
      guard let self else { return }
      do {
        let document = try await store.readWorkspaceFile(path, at: location)
        guard !Task.isCancelled, self.context == context, selected == id else { return }
        documents[id] = document
        pruneCleanDocuments()
        _ = flush()
      } catch {
        guard !Task.isCancelled, self.context == context, selected == id else { return }
        message = error.localizedDescription
      }
      loadingFile = false
      onChange?()
    }
  }

  func edit(_ contents: String) {
    guard let selected, var document = documents[selected], document.canEdit, !loadingFile else {
      return
    }
    document.contents = contents
    documents[selected] = document
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
    guard canSave, let selected, let document, let location else { return }
    // Persist recovery content before sending a write whose reply may be lost.
    guard flush() else { throw T3Error(storageError ?? "The file draft could not be saved.") }
    saving.insert(selected)
    onChange?()
    defer {
      saving.remove(selected)
      onChange?()
    }
    do {
      try await store.saveWorkspaceFile(document, at: location)
      documents[selected]?.acknowledgeSave(document.contents)
      guard flush() else { throw T3Error(storageError ?? "The file draft could not be saved.") }
      if self.selected == selected {
        message =
          documents[selected]?.isDirty == true
          ? "Previous edits saved • New changes unsaved" : "Saved"
      }
    } catch {
      if self.selected == selected { message = error.localizedDescription }
      throw error
    }
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
      $0.key == selected || $0.value.isDirty || saving.contains($0.key)
    }
  }
}
