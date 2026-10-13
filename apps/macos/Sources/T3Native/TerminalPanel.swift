import AppKit
import T3Core

@MainActor final class TerminalPanel: NSViewController {
  var onClose: (() -> Void)?
  var onOpenLink: ((URL, WorkspaceLocation) -> Void)?
  private let store: ClientStore
  private let tabs = NSStackView()
  private let content = NSView()
  private let status = NSTextField(wrappingLabelWithString: "")
  private let retry = NSButton(title: "Reconnect", target: nil, action: nil)
  private let add = NSButton(title: "+", target: nil, action: nil)
  private let clear = NSButton(title: "Clear", target: nil, action: nil)
  private let restart = NSButton(title: "Restart", target: nil, action: nil)
  private let close = NSButton(title: "Close Terminal", target: nil, action: nil)
  private var location: WorkspaceLocation?
  private var connection: RPCConnection?
  private var directory = TerminalDirectory(threadID: "")
  private var remembered: [String: String] = [:]
  private var provisionalID: String?
  private var metadata: Task<Void, Never>?
  private var operation: Task<Void, Never>?
  private var generation = UUID()
  private var remote: RemoteTerminal?
  private var surface: TerminalSurface?
  private var error: String?
  private var renderedTabs: [TerminalSummary] = []
  private var renderedSelection: String?
  private var busy = false
  private var shouldFocus = false

  init(store: ClientStore) {
    self.store = store
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  isolated deinit { detach() }

  override func loadView() {
    view = SurfaceView()
    tabs.orientation = .horizontal
    tabs.spacing = 3
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasHorizontalScroller = true
    scroll.autohidesScrollers = true
    scroll.documentView = tabs
    tabs.translatesAutoresizingMaskIntoConstraints = false
    tabs.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor).isActive = true
    tabs.topAnchor.constraint(equalTo: scroll.contentView.topAnchor).isActive = true
    tabs.heightAnchor.constraint(equalToConstant: 28).isActive = true
    scroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
    for (button, action, help) in [
      (add, #selector(newTerminal), "New terminal (⌘N when the terminal is focused)"),
      (clear, #selector(clearTerminal), "Clear terminal output and saved history"),
      (restart, #selector(restartTerminal), "Restart the selected shell"),
      (close, #selector(closeTerminal), "Close the selected shell and delete its history (⌘W)"),
      (retry, #selector(reconnect), "Reconnect to the terminal"),
    ] {
      button.target = self
      button.action = action
      button.bezelStyle = .rounded
      button.controlSize = .small
      button.toolTip = help
    }
    add.setAccessibilityLabel("New terminal")
    let hide = NSButton(
      image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Hide terminal")!,
      target: self, action: #selector(hidePanel))
    hide.bezelStyle = .inline
    hide.toolTip = "Hide the drawer and keep shells running (⌘J)"
    let toolbar = NSStackView(views: [scroll, add, clear, restart, close, hide])
    toolbar.spacing = 6
    status.font = .systemFont(ofSize: 11)
    status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let footer = NSStackView(views: [status, retry])
    footer.spacing = 8
    let stack = NSStackView(views: [toolbar, content, footer])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 4
    view.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    for child in [toolbar, content, footer] {
      child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
      stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
      stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
      stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4),
      toolbar.heightAnchor.constraint(equalToConstant: 30),
      content.heightAnchor.constraint(greaterThanOrEqualToConstant: 70),
    ])
    render()
  }

  func refresh(active: Bool) {
    _ = view
    let nextLocation = active ? store.workspaceLocation : nil
    let nextConnection = active ? store.terminalConnection : nil
    guard nextLocation != location || nextConnection !== connection else { return }
    detach()
    location = nextLocation
    connection = nextConnection
    directory = TerminalDirectory(threadID: nextLocation?.threadID ?? "")
    error = nil
    render()
    guard let location, let connection else { return }
    subscribe(location: location, connection: connection)
  }

  private var selectionKey: String? {
    location.map { $0.environment + "\n" + $0.threadID }
  }
  private func detach() {
    generation = UUID()
    metadata?.cancel()
    metadata = nil
    operation?.cancel()
    operation = nil
    busy = false
    provisionalID = nil
    remote?.onChange = nil
    remote?.detach()
    remote = nil
    surface?.stop()
    surface?.removeFromSuperview()
    surface = nil
  }
  private func subscribe(location: WorkspaceLocation, connection: RPCConnection) {
    let generation = generation
    metadata = Task { [weak self] in
      var id: String?
      do {
        let stream = try await connection.subscribe("subscribeTerminalMetadata")
        id = stream.id
        for try await event in stream.values {
          guard !Task.isCancelled, let self, self.generation == generation else { break }
          let first = !directory.receivedSnapshot
          guard try directory.apply(event) else { continue }
          if let provisionalID, directory.terminals.contains(where: { $0.id == provisionalID }) {
            self.provisionalID = nil
          }
          if event["type"].string == "remove",
            event["terminalId"].string == remote?.state.target.terminalID
          {
            removeSurface()
          }
          if first && directory.receivedSnapshot && directory.terminals.isEmpty {
            newTerminal()
          } else if remote == nil, let selected = selectedExisting() {
            select(selected)
          }
          render()
        }
        if !Task.isCancelled, let self, self.generation == generation {
          throw T3Error("Terminal list disconnected. Reconnect to restore it.")
        }
      } catch {
        guard let self, self.generation == generation, !Task.isCancelled else {
          if let id { await connection.cancel(id) }
          return
        }
        self.error = error.localizedDescription
        self.render()
      }
      if let id { await connection.cancel(id) }
    }
  }
  private func selectedExisting() -> String? {
    if let key = selectionKey, let id = remembered[key],
      directory.terminals.contains(where: { $0.id == id })
    {
      return id
    }
    return directory.terminals.first?.id
  }
  private func removeSurface() {
    remote?.onChange = nil
    remote?.detach()
    remote = nil
    surface?.stop()
    surface?.removeFromSuperview()
    surface = nil
  }
  private func select(_ id: String) {
    guard let location, let connection, id != remote?.state.target.terminalID else { return }
    removeSurface()
    error = nil
    if let key = selectionKey { remembered[key] = id }
    var context: [String: JSON] = [
      "cwd": .string(location.root),
      "worktreePath": store.selectedThread?.worktreePath.map(JSON.string) ?? .null,
    ]
    if let instance = store.selectedThread?.model["instanceId"].string {
      context["providerInstanceId"] = .string(instance)
    }
    let remote = RemoteTerminal(
      target: TerminalTarget(
        environment: location.environment, threadID: location.threadID, terminalID: id),
      connection: connection, context: context)
    self.remote = remote
    let surface = TerminalSurface(frame: content.bounds)
    surface.autoresizingMask = [.width, .height]
    self.surface = surface
    surface.onInput = { [weak remote] in remote?.write($0) }
    surface.onResize = { [weak remote] in remote?.resize($0) }
    surface.onError = { [weak self] in
      self?.error = $0
      self?.render()
    }
    surface.onOpenLink = { [weak self] url in self?.onOpenLink?(url, location) }
    surface.onShortcut = { [weak self] event in self?.shortcut(event) == true }
    remote.onChange = { [weak self] in self?.render() }
    content.addSubview(surface)
    remote.attach()
    render()
  }

  func focus() {
    shouldFocus = true
    if let surface, remote?.attached == true {
      view.window?.makeFirstResponder(surface)
      shouldFocus = false
    }
  }
  private func shortcut(_ event: NSEvent) -> Bool {
    guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
      return false
    }
    switch event.charactersIgnoringModifiers {
    case "n":
      newTerminal()
      return true
    case "w":
      closeTerminal()
      return true
    default: return false
    }
  }

  private func render() {
    guard isViewLoaded else { return }
    var entries = directory.terminals
    if let provisionalID, !entries.contains(where: { $0.id == provisionalID }),
      let entry = try? TerminalSummary(
        .object([
          "terminalId": .string(provisionalID), "label": .string("Terminal"),
          "status": .string("starting"),
        ]))
    {
      entries.append(entry)
    }
    let selected = remote?.state.target.terminalID
    if entries != renderedTabs || selected != renderedSelection {
      renderedTabs = entries
      renderedSelection = selected
      for child in tabs.arrangedSubviews {
        tabs.removeArrangedSubview(child)
        child.removeFromSuperview()
      }
      for (index, entry) in entries.enumerated() {
        let label = entry.label + (entry.status == "exited" ? " (exited)" : "")
        let button = NSButton(title: label, target: self, action: #selector(selectTab(_:)))
        button.setButtonType(.toggle)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.tag = index
        button.state = entry.id == selected ? .on : .off
        button.toolTip =
          entry.hasRunningSubprocess ? "Command running: \(entry.label)" : entry.label
        tabs.addArrangedSubview(button)
      }
    }
    for button in tabs.arrangedSubviews.compactMap({ $0 as? NSButton }) { button.isEnabled = !busy }
    let failure = error ?? remote?.error ?? remote?.state.error
    status.textColor = failure == nil ? .secondaryLabelColor : .systemRed
    status.stringValue =
      failure
      ?? (busy
        ? "Working…"
        : remote.map {
          $0.attached
            ? ($0.state.status == "exited" ? "Shell exited. Restart to open a new shell." : "")
            : "Connecting to terminal…"
        }
          ?? (connection == nil
            ? "Connect and select a thread to use its terminal."
            : "No open terminals. Use + to open a shell."))
    status.isHidden = status.stringValue.isEmpty
    retry.isHidden = failure == nil
    retry.isEnabled = !busy && connection != nil
    add.isEnabled = !busy && connection != nil && directory.receivedSnapshot
    clear.isEnabled = !busy && remote?.attached == true
    restart.isEnabled = !busy && remote?.attached == true
    close.isEnabled = !busy && remote != nil
    if let remote, let surface {
      surface.inputEnabled = remote.attached && remote.state.status == "running" && !busy
      if remote.state.receivedSnapshot { surface.synchronize(remote.state.output) }
      if shouldFocus && remote.attached { focus() }
    }
  }
  @objc private func selectTab(_ sender: NSButton) {
    guard !busy, renderedTabs.indices.contains(sender.tag) else { return }
    shouldFocus = true
    select(renderedTabs[sender.tag].id)
  }
  @objc private func newTerminal() {
    guard !busy, directory.receivedSnapshot, connection != nil else { return }
    let id = "term-" + UUID().uuidString.lowercased()
    provisionalID = id
    shouldFocus = true
    select(id)
  }
  @objc private func hidePanel() { onClose?() }
  @objc private func reconnect() {
    let activeLocation = location
    let activeConnection = connection
    detach()
    error = nil
    directory = TerminalDirectory(threadID: activeLocation?.threadID ?? "")
    if let activeLocation, let activeConnection {
      subscribe(location: activeLocation, connection: activeConnection)
    }
    render()
  }
  private func run(
    _ action: @escaping @MainActor (RemoteTerminal) async throws -> Void, closing: Bool = false
  ) {
    guard !busy, let remote else { return }
    let generation = generation
    busy = true
    error = nil
    render()
    operation = Task { [weak self] in
      do {
        try await action(remote)
        guard let self, self.generation == generation, !Task.isCancelled else { return }
        if closing {
          _ = try directory.apply(remote.state.target.input(["type": .string("remove")]))
          if self.remote === remote { removeSurface() }
          if let selected = selectedExisting() { select(selected) }
        }
      } catch {
        guard let self, self.generation == generation, !Task.isCancelled else { return }
        self.error = error.localizedDescription
      }
      guard let self, self.generation == generation else { return }
      busy = false
      operation = nil
      render()
    }
  }
  @objc private func clearTerminal() { run { try await $0.clear() } }
  @objc private func restartTerminal() {
    confirmIfRunning("Restart terminal?") { [weak self] in self?.run { try await $0.restart() } }
  }
  @objc private func closeTerminal() {
    confirmIfRunning("Close terminal?") { [weak self] in
      self?.run({ try await $0.close() }, closing: true)
    }
  }
  private func confirmIfRunning(_ title: String, action: @escaping @MainActor () -> Void) {
    guard !busy, let remote else { return }
    let running =
      remote.state.hasRunningSubprocess
      || directory.terminals.first(where: { $0.id == remote.state.target.terminalID })?
        .hasRunningSubprocess == true
    guard running else {
      action()
      return
    }
    guard let window = view.window else { return }
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = "A command is running in this terminal. Continuing will stop it."
    alert.addButton(withTitle: "Continue")
    alert.addButton(withTitle: "Cancel")
    alert.beginSheetModal(for: window) { [weak self, weak remote] result in
      guard result == .alertFirstButtonReturn, let self, let remote, self.remote === remote else {
        return
      }
      action()
    }
  }
}
