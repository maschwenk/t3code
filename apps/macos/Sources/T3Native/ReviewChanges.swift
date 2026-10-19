import Foundation
import T3Core

@MainActor final class ReviewChanges {
  private let store: ClientStore
  private var active = false
  private var connected = false
  private var mutation: String?
  private var context = UUID()
  private var selection = UUID()
  private var previewTask: Task<Void, Never>?
  private var fileTask: Task<Void, Never>?
  private var refreshTask: Task<Void, Never>?
  private var contextTask: Task<Void, Never>?
  private var contextRequest = UUID()
  private var fileContentsInput: [String: JSON]?
  private var fileContext: DiffContext?
  private var expandedContext: [Int: Int] = [:]
  private var contextView: DiffFile?
  private var checkpointRevision: UUID?
  private var loadedCheckpoint: CheckpointDiffRequest?
  private var checkpointPatches: [String: DiffFile] = [:]
  private var checkpointRoot: String?
  private(set) var checkpoints: [TurnCheckpoint] = []
  private(set) var location: WorkspaceLocation?
  private(set) var snapshot: ReviewSnapshot?
  private(set) var sourceKind = "working-tree"
  private(set) var selectedPath: String?
  private(set) var baseRef = ""
  private(set) var ignoreWhitespace = false
  private(set) var loading = false
  private(set) var loadingFile = false
  private(set) var error: String?
  private(set) var fileError: String?
  private(set) var patch: DiffFile?
  private(set) var rawPatch = ""
  private(set) var truncated = false
  private(set) var patchRevision = UUID()
  private(set) var fileRevision = UUID()
  private(set) var loadingContext = false
  private(set) var contextError: String?
  private(set) var contextLimited = false
  var displayPatch: DiffFile? { contextView ?? patch }
  var canExpandContext: Bool { connected && fileContentsInput != nil && !loadingFile }
  var hasExpandedContext: Bool { expandedContext.values.contains { $0 > 0 } }
  var onChange: (() -> Void)?
  var source: ReviewSource? { snapshot?.sources.first { $0.kind == sourceKind } }
  var file: ReviewFile? { source?.files.first { $0.path == selectedPath } }
  var canRefresh: Bool { connected && location != nil }
  var isCheckpoint: Bool {
    sourceKind == "latest-turn" || sourceKind == "full-thread" || sourceKind.hasPrefix("turn:")
  }
  var comparisons: [(id: String, title: String)] {
    [
      ("working-tree", "Uncommitted"), ("branch-range", "Changes vs branch"),
      ("latest-turn", "Latest turn"), ("full-thread", "Full thread"),
    ]
      + checkpoints.map {
        ("turn:" + $0.id, "Turn \($0.turnCount)" + ($0.status == "ready" ? "" : " · \($0.status)"))
      }
  }

  init(store: ClientStore) { self.store = store }

  func refreshContext(active: Bool) {
    let changed = location != store.workspaceLocation
    let wasActive = self.active && connected
    let reopened = active && (!self.active || !connected && store.ready)
    self.active = active
    connected = store.ready
    if reopened { checkpointRoot = nil }
    let index =
      store.thread?.id == store.workspaceLocation?.threadID ? store.thread?.checkpoints : nil
    let checkpointsChanged = checkpointRevision != index?.revision
    if checkpointsChanged {
      checkpointRevision = index?.revision
      checkpoints = index?.items ?? []
    }
    if changed {
      invalidate()
      location = store.workspaceLocation
      snapshot = nil
      selectedPath = nil
      baseRef = ""
      error = nil
      mutation = nil
      sourceKind = "working-tree"
      checkpointPatches = [:]
      loadedCheckpoint = nil
      checkpointRoot = nil
      onChange?()
    }
    guard active, connected else {
      if wasActive || changed {
        invalidate()
        onChange?()
      }
      return
    }
    let nextMutation = store.thread?.workspaceMutationToken
    if changed || reopened {
      mutation = nextMutation
      refresh()
    } else if isCheckpoint, checkpointsChanged {
      let request = try? checkpointRequest()
      if request != loadedCheckpoint || request == nil { refresh() } else { onChange?() }
    } else if nextMutation != mutation {
      mutation = nextMutation
      guard !isCheckpoint else { return }
      // Coalesce completed tool events without postponing the read on every token.
      if refreshTask == nil {
        refreshTask = Task { [weak self] in
          do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
          self?.refreshTask = nil
          self?.refresh()
        }
      }
    } else if checkpointsChanged {
      onChange?()
    }
  }

  func compare(baseRef: String, ignoreWhitespace: Bool) {
    self.baseRef = baseRef.trimmingCharacters(in: .whitespacesAndNewlines)
    self.ignoreWhitespace = ignoreWhitespace
    refresh()
  }

  func refresh() {
    guard active, connected, let location else { return }
    invalidate()
    let context = context
    loading = true
    error = nil
    if isCheckpoint {
      refreshCheckpoint(at: location, context: context)
      return
    }
    checkpointPatches = [:]
    loadedCheckpoint = nil
    var fields: [String: JSON] = ["ignoreWhitespace": .bool(ignoreWhitespace)]
    if !baseRef.isEmpty { fields["baseRef"] = .string(baseRef) }
    previewTask = Task { [weak self] in
      guard let self, !Task.isCancelled else { return }
      defer {
        if self.context == context {
          loading = false
          previewTask = nil
          onChange?()
        }
      }
      do {
        let result = try await store.workspaceCall(
          "review.getDiffPreview", at: location, fields: fields)
        let snapshot = try await Task.detached { try ReviewSnapshot(result) }.value
        guard self.context == context, !Task.isCancelled else { return }
        self.snapshot = snapshot
        if source == nil { sourceKind = snapshot.sources.first?.kind ?? "working-tree" }
        if !((source?.files ?? []).contains { $0.path == selectedPath }) {
          selectedPath = source?.files.first?.path
        }
        loadFile()
      } catch {
        guard self.context == context, !Task.isCancelled else { return }
        self.error = Self.message(error)
        snapshot = nil
      }
    }
    onChange?()
  }

  func selectSource(_ kind: String) {
    guard kind != sourceKind else { return }
    let wasCheckpoint = isCheckpoint
    sourceKind = kind
    selectedPath = source?.files.first?.path
    if wasCheckpoint || isCheckpoint || source == nil {
      refresh()
      return
    }
    loadFile()
    onChange?()
  }

  func selectFile(_ path: String) {
    guard path != selectedPath, source?.files.contains(where: { $0.path == path }) == true else {
      return
    }
    selectedPath = path
    loadFile()
    onChange?()
  }

  func loadFile() {
    resetFile()
    guard active, connected, let location, let file, let source else {
      onChange?()
      return
    }
    if isCheckpoint {
      patch = checkpointPatches[file.path]
      rawPatch = patch?.rawPatch ?? ""
      truncated = patch?.incomplete ?? false
      onChange?()
      return
    }
    let context = context
    let selection = selection
    var fields: [String: JSON] = [
      "ignoreWhitespace": .bool(ignoreWhitespace),
      "file": .object(file.input.merging(["sourceKind": .string(source.kind)]) { _, new in new }),
    ]
    // Pin the resolved comparison even when the user left the base automatic.
    if source.kind == "branch-range", let ref = source.baseRef { fields["baseRef"] = .string(ref) }
    loadingFile = true
    fileTask = Task { [weak self] in
      guard let self, !Task.isCancelled else { return }
      defer {
        if self.context == context, self.selection == selection {
          fileTask = nil
          loadingFile = false
          onChange?()
        }
      }
      do {
        let result = try await store.workspaceCall(
          "review.getDiffPreview", at: location, fields: fields)
        guard
          let resultSource = result["sources"].array.first(where: {
            $0["kind"].string == source.kind
          })
        else { throw T3Error("This comparison is no longer available. Refresh Changes.") }
        let raw = resultSource["diff"].string ?? ""
        let parsed = await Task.detached { UnifiedDiff.parse(raw) }.value
        guard self.context == context, self.selection == selection, !Task.isCancelled else {
          return
        }
        guard let patch = parsed.first(where: { $0.path == file.path }) else {
          throw T3Error("This file no longer has a patch in this comparison. Refresh Changes.")
        }
        self.patch = patch
        rawPatch = raw
        truncated = resultSource["truncated"].bool || patch.incomplete
        prepareContext(source: resultSource)
        patchRevision = UUID()
      } catch {
        guard self.context == context, self.selection == selection, !Task.isCancelled else {
          return
        }
        fileError = Self.message(error)
      }
    }
    onChange?()
  }

  var absolutePath: String? {
    guard let root = snapshot?.root, let file else { return nil }
    return FileOpenCapabilities.absolutePath(file.path, root: root)
  }

  private func prepareContext(source: JSON) {
    guard let patch, !truncated, !patch.isBinary, !patch.isNew, !patch.isDeleted else { return }
    fileContentsInput = [
      "sourceKind": .string(sourceKind), "baseRef": source["baseRef"], "headRef": source["headRef"],
      "changeType": .string(
        patch.previousPath == nil
          ? "change" : patch.additions + patch.deletions == 0 ? "rename-pure" : "rename-changed"),
      "oldPath": .string(patch.previousPath ?? patch.path), "newPath": .string(patch.path),
    ]
    contextView = DiffContext.preview(patch)
  }

  func expandContext(_ id: Int? = nil) {
    guard active, canExpandContext, !loadingContext, let location, let patch,
      let input = fileContentsInput
    else { return }
    contextRequest = UUID()
    let request = contextRequest
    let selection = selection
    let context = context
    let cached = fileContext
    let expanded = expandedContext
    let ignoreWhitespace = ignoreWhitespace
    loadingContext = true
    contextError = nil
    contextTask = Task { [weak self] in
      guard let self, !Task.isCancelled else { return }
      defer {
        if self.contextRequest == request {
          loadingContext = false
          contextTask = nil
          onChange?()
        }
      }
      do {
        let loaded: DiffContext
        if let cached {
          loaded = cached
        } else {
          let contents = try await store.workspaceCall(
            "review.getDiffFileContents", at: location, fields: input)
          let old = try contents.requiredString("oldContents")
          let new = try contents.requiredString("newContents")
          loaded = try await Task.detached {
            try DiffContext(
              patch, oldContents: old, newContents: new, ignoreWhitespace: ignoreWhitespace)
          }.value
        }
        var counts = expanded
        for gap in loaded.gaps where id == nil || gap.id == id {
          counts[gap.id] = id == nil ? gap.count : min(gap.count, (counts[gap.id] ?? 0) + 20)
        }
        let next = counts
        let rendered = await Task.detached { loaded.render(expanded: next) }.value
        guard self.context == context, self.selection == selection, contextRequest == request,
          !Task.isCancelled
        else { return }
        fileContext = loaded
        expandedContext = next
        contextView = rendered.file
        contextLimited = rendered.limited
        patchRevision = UUID()
      } catch {
        guard self.context == context, self.selection == selection, contextRequest == request,
          !Task.isCancelled
        else { return }
        contextError = error.localizedDescription
      }
    }
    onChange?()
  }

  func collapseContext() {
    contextRequest = UUID()
    contextTask?.cancel()
    contextTask = nil
    loadingContext = false
    expandedContext = [:]
    contextError = nil
    if let fileContext {
      let rendered = fileContext.render(expanded: [:])
      contextView = rendered.file
      contextLimited = rendered.limited
    }
    patchRevision = UUID()
    onChange?()
  }

  func openCheckpoint(_ id: String, filePath: String? = nil) {
    if sourceKind == "turn:" + id, loadedCheckpoint != nil, snapshot != nil, error == nil {
      if let filePath { selectFile(filePath) }
      return
    }
    sourceKind = "turn:" + id
    selectedPath = filePath
    refresh()
  }

  private func checkpointRequest() throws -> CheckpointDiffRequest {
    let checkpoint =
      sourceKind.hasPrefix("turn:")
      ? checkpoints.first { "turn:" + $0.id == sourceKind } : checkpoints.first
    guard let checkpoint else {
      throw T3Error(
        sourceKind.hasPrefix("turn:")
          ? "This checkpoint is no longer in the thread. Select another comparison."
          : "This thread has no saved turn checkpoints yet.")
    }
    return try CheckpointDiffRequest(
      checkpoint, fullThread: sourceKind == "full-thread", ignoreWhitespace: ignoreWhitespace)
  }

  private func refreshCheckpoint(at location: WorkspaceLocation, context: UUID) {
    snapshot = nil
    checkpointPatches = [:]
    loadedCheckpoint = nil
    let request: CheckpointDiffRequest
    do { request = try checkpointRequest() } catch {
      loading = false
      self.error = error.localizedDescription
      onChange?()
      return
    }
    loadedCheckpoint = request
    let kind = sourceKind
    let fallbackRoot = store.reviewRepositoryRoot ?? location.root
    let knownRoot = checkpointRoot
    previewTask = Task { [weak self] in
      guard let self, !Task.isCancelled else { return }
      defer {
        if self.context == context {
          previewTask = nil
          loading = false
          onChange?()
        }
      }
      do {
        async let diff = store.checkpointDiff(request, at: location)
        let root: String
        if let knownRoot {
          root = knownRoot
        } else {
          // A thread may be rooted in a repository subfolder. Git patch paths are repository-relative.
          let refs = try? await store.workspaceCall(
            "vcs.listRefs", at: location,
            fields: ["limit": .number(1), "refKind": .string("local"), "refresh": .bool(true)])
          root =
            refs?["refs"].array.first(where: { $0["current"].bool })?["worktreePath"].string
            ?? fallbackRoot
        }
        let raw = try await diff
        let parsed = await Task.detached { UnifiedDiff.parse(raw) }.value
        guard self.context == context, !Task.isCancelled else { return }
        checkpointRoot = root
        // GitVcsDriver caps checkpoint patches at 10 MB without returning a truncation flag.
        let source = ReviewSource(
          kind: kind, title: request.title, hash: request.checkpointRef, patches: parsed,
          outputLimited: raw.utf8.count >= 10_000_000)
        snapshot = ReviewSnapshot(root: root, sources: [source])
        checkpointPatches = Dictionary(
          parsed.map { ($0.path, $0) }, uniquingKeysWith: { _, new in new })
        if !source.files.contains(where: { $0.path == selectedPath }) {
          selectedPath = source.files.first?.path
        }
        loadFile()
      } catch {
        guard self.context == context, !Task.isCancelled else { return }
        self.error = Self.message(error)
      }
    }
    onChange?()
  }

  private func invalidate() {
    context = UUID()
    previewTask?.cancel()
    previewTask = nil
    refreshTask?.cancel()
    refreshTask = nil
    loading = false
    resetFile()
  }

  private func resetFile() {
    fileRevision = UUID()
    contextRequest = UUID()
    contextTask?.cancel()
    contextTask = nil
    loadingContext = false
    contextError = nil
    contextLimited = false
    fileContext = nil
    contextView = nil
    fileContentsInput = nil
    expandedContext = [:]
    selection = UUID()
    fileTask?.cancel()
    fileTask = nil
    loadingFile = false
    patch = nil
    rawPatch = ""
    fileError = nil
    truncated = false
    patchRevision = UUID()
  }

  private static func message(_ error: any Error) -> String {
    if let error = error as? T3Error, error.remoteCode == "EnvironmentAuthorizationError" {
      return
        "This connection needs permission to review changes. Use Connect… to pair again with a new token."
    }
    return error.localizedDescription
  }
}
