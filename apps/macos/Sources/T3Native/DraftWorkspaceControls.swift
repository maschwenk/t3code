import AppKit
import T3Core

struct DraftBranchFetchState {
  struct Key: Equatable {
    let environment: String
    let session: UUID
    let draftID: String
    let root: String
    let ready: Bool
    let retry: Int
  }
  private(set) var key: Key?
  private(set) var loading = false
  private(set) var failure: String?
  mutating func select(_ next: Key?) -> Bool {
    guard key != next else { return false }
    key = next
    failure = nil
    loading = next?.ready == true && next?.root.isEmpty == false
    return true
  }
  func accepts(_ request: Key, current: Key?) -> Bool {
    loading && key == request && current == request && request.ready
  }
  @discardableResult mutating func finish(_ request: Key, current: Key?, error: String? = nil)
    -> Bool
  {
    guard accepts(request, current: current) else { return false }
    loading = false
    failure = error
    return true
  }
}

@MainActor final class DraftWorkspaceControls: NSStackView {
  private let store: ClientStore
  private let mode = ComposerPill("Current checkout", symbol: "folder", action: {})
  private let branch = ComposerPill("Select branch", symbol: "arrow.triangle.branch", action: {})
  private var popover: NSPopover?
  private var fetch = DraftBranchFetchState()
  private var retryGeneration = 0
  private let retry = ComposerPill("", symbol: "arrow.clockwise", action: {})
  private var refs: [JSON] = []
  private var load: Task<Void, Never>?
  init(store: ClientStore) {
    self.store = store
    super.init(frame: .zero)
    orientation = .horizontal
    spacing = 8
    edgeInsets = NSEdgeInsets(top: 3, left: 14, bottom: 3, right: 14)
    addArrangedSubview(mode)
    addArrangedSubview(NSView())
    addArrangedSubview(branch)
    addArrangedSubview(retry)
    retry.setAccessibilityLabel("Retry loading branches")
    retry.isHidden = true
    retry.invoke = { [weak self] in
      guard let self, store.ready, fetch.failure != nil else { return }
      retryGeneration += 1
      refresh()
    }
    mode.invoke = { [weak self] in self?.chooseWorkspace() }
    branch.invoke = { [weak self] in self?.chooseBranch() }
    branch.widthAnchor.constraint(lessThanOrEqualToConstant: 280).isActive = true
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  private var currentKey: DraftBranchFetchState.Key? {
    guard let draft = store.selectedDraft else { return nil }
    return .init(
      environment: store.environmentKey, session: store.projectSessionID,
      draftID: draft.id, root: draft.project["workspaceRoot"].string ?? "",
      ready: store.ready && store.catalogReady, retry: retryGeneration)
  }
  func refresh() {
    let key = currentKey
    if fetch.select(key) {
      load?.cancel()
      load = nil
      refs = []
      popover?.performClose(nil)
      if let key, fetch.loading { loadBranches(key) }
    }
    isHidden = store.selectedDraft == nil
    guard let draft = store.selectedDraft else { return }
    mode.displayLabel(draft.workspaceMode == "worktree" ? "New worktree" : "Current checkout")
    mode.isEnabled = store.canEditThread && !store.composerBusy
    branch.isEnabled = mode.isEnabled && !refs.isEmpty && key?.ready == true
    let branchLabel =
      fetch.loading
      ? "Loading branches…"
      : fetch.failure != nil
        ? "Branches unavailable" : key?.ready != true ? "Connect to load branches" : "Select branch"
    branch.displayLabel(draft.branch ?? branchLabel)
    branch.toolTip = fetch.failure ?? draft.branch
    retry.isHidden = fetch.failure == nil
    retry.isEnabled = mode.isEnabled && key?.ready == true
    retry.toolTip = fetch.failure.map { "Retry loading branches: " + $0 }
  }
  private func loadBranches(_ key: DraftBranchFetchState.Key) {
    load = Task { [weak self] in
      guard let self else { return }
      do {
        var fetched: [JSON] = []
        var cursor: JSON = .null
        repeat {
          var payload: [String: JSON] = ["cwd": .string(key.root), "limit": .number(100)]
          if cursor != .null { payload["cursor"] = cursor }
          if key.retry > 0 { payload["refresh"] = .bool(true) }
          let result = try await store.usageCall(
            "vcs.listRefs", payload: .object(payload), session: key.session)
          try Task.checkCancellation()
          guard fetch.accepts(key, current: currentKey) else { return }
          fetched += result["refs"].array
          cursor = result["nextCursor"]
        } while cursor != .null && fetched.count < 500
        guard fetch.finish(key, current: currentKey) else { return }
        refs = fetched
        load = nil
        if store.selectedDraft?.id == key.draftID, store.selectedDraft?.branch == nil,
          let current = refs.first(where: { $0["current"].bool })?["name"].string
        {
          store.updateConversationDraft { $0.branch = current }
        }
        refresh()
      } catch {
        guard !Task.isCancelled,
          fetch.finish(key, current: currentKey, error: error.localizedDescription)
        else { return }
        load = nil
        refresh()
      }
    }
  }
  private func chooseWorkspace() {
    guard mode.isEnabled, let draft = store.selectedDraft else { return }
    show(
      "Workspace",
      options: [
        ComposerOption(
          title: "Current checkout", symbol: "folder", selected: draft.workspaceMode != "worktree"
        ) { [weak store] in store?.updateConversationDraft { $0.workspaceMode = "local" } },
        ComposerOption(
          title: "New worktree", symbol: "arrow.triangle.branch",
          selected: draft.workspaceMode == "worktree"
        ) { [weak store] in store?.updateConversationDraft { $0.workspaceMode = "worktree" } },
      ], width: 240, anchor: mode)
  }
  private func chooseBranch() {
    guard branch.isEnabled, let draft = store.selectedDraft else { return }
    show(
      "Base branch",
      options: refs.compactMap { ref in
        guard let name = ref["name"].string else { return nil }
        return ComposerOption(
          title: name, selected: draft.branch == name, badge: ref["current"].bool ? "Current" : nil
        ) { [weak store] in store?.updateConversationDraft { $0.branch = name } }
      }, width: 320, anchor: branch)
  }
  private func show(_ heading: String, options: [ComposerOption], width: CGFloat, anchor: NSView) {
    guard !options.isEmpty else { return }
    popover?.performClose(nil)
    let next = NSPopover()
    next.behavior = .transient
    let controller = ComposerOptionsPopover(heading, options: options, width: width) {
      [weak self] in self?.popover?.performClose(nil)
    }
    next.contentViewController = controller
    next.contentSize = controller.contentSize
    popover = next
    next.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
  }
}

@MainActor final class RoundSendButton: NSButton {
  override func draw(_ dirtyRect: NSRect) {
    guard imagePosition != .noImage else {
      super.draw(dirtyRect)
      return
    }
    let rect = NSRect(
      x: (bounds.width - 32) / 2, y: (bounds.height - 32) / 2, width: 32, height: 32)
    (isEnabled
      ? NSColor(srgbRed: 0.2, green: 0.36, blue: 0.78, alpha: 1)
      : NSColor.labelColor.withAlphaComponent(0.06)).setFill()
    NSBezierPath(ovalIn: rect).fill()
    guard let image else { return }
    let tinted =
      image.withSymbolConfiguration(
        NSImage.SymbolConfiguration(pointSize: 17, weight: .semibold).applying(
          .init(paletteColors: [.white]))) ?? image
    tinted.draw(
      in: rect.insetBy(dx: 7, dy: 7), from: .zero, operation: .sourceOver,
      fraction: isEnabled ? 1 : 0.45, respectFlipped: true, hints: nil)
  }
}
