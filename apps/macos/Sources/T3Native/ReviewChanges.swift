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
  var onChange: (() -> Void)?
  var source: ReviewSource? { snapshot?.sources.first { $0.kind == sourceKind } }
  var file: ReviewFile? { source?.files.first { $0.path == selectedPath } }
  var canRefresh: Bool { connected && location != nil }

  init(store: ClientStore) { self.store = store }

  func refreshContext(active: Bool) {
    let changed = location != store.workspaceLocation
    let wasActive = self.active && connected
    let reopened = active && (!self.active || !connected && store.ready)
    self.active = active
    connected = store.ready
    if changed {
      invalidate()
      location = store.workspaceLocation
      snapshot = nil
      selectedPath = nil
      baseRef = ""
      error = nil
      mutation = nil
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
    } else if nextMutation != mutation {
      mutation = nextMutation
      // Coalesce completed tool events without postponing the read on every token.
      if refreshTask == nil {
        refreshTask = Task { [weak self] in
          do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
          self?.refreshTask = nil
          self?.refresh()
        }
      }
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
    var fields: [String: JSON] = ["ignoreWhitespace": .bool(ignoreWhitespace)]
    if !baseRef.isEmpty { fields["baseRef"] = .string(baseRef) }
    previewTask = Task { [weak self] in
      guard let self else { return }
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
    sourceKind = kind
    selectedPath = source?.files.first?.path
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
      guard let self else { return }
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
