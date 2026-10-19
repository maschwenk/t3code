import AppKit
import T3Core

@MainActor final class ProjectPicker: NSWindowController, NSTableViewDataSource, NSTableViewDelegate
{
  private let store: ClientStore
  private let session: UUID
  private let opened: (JSON, String?) -> Void
  private let closed: () -> Void
  private let mode = NSSegmentedControl(
    labels: ["Open folder", "New project"], trackingMode: .selectOne, target: nil, action: nil)
  private let path = ActionTextField()
  private let name = ActionTextField()
  private let table = NSTableView()
  private let scroll = NSScrollView()
  private let detail = NSTextField(wrappingLabelWithString: "")
  private let errorLabel = NSTextField(wrappingLabelWithString: "")
  private let openButton = NSButton(title: "Open", target: nil, action: nil)
  private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
  private let browseButton = NSButton(title: "Go", target: nil, action: nil)
  private let upButton = NSButton(title: "Up", target: nil, action: nil)
  private let homeButton = NSButton(title: "Home", target: nil, action: nil)
  private var entries: [JSON] = []
  private var directory: String?
  private var browsing: Task<Void, Never>?
  private var browseID = UUID()
  private var saving = false
  private var creationFailed = false
  private var pathRow: NSStackView!

  init(
    store: ClientStore, create: Bool, opened: @escaping (JSON, String?) -> Void,
    closed: @escaping () -> Void
  ) {
    self.store = store
    session = store.projectSessionID
    self.opened = opened
    self.closed = closed
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 470), styleMask: [.titled],
      backing: .buffered, defer: false)
    panel.title = "Open project"
    super.init(window: panel)
    mode.selectedSegment = create ? 1 : 0
    mode.target = self
    mode.action = #selector(changeProjectAction)
    mode.setAccessibilityLabel("Project action")
    path.stringValue = "~"
    path.placeholderString = "Folder on the connected server"
    path.setAccessibilityLabel("Project folder path")
    path.target = self
    path.action = #selector(go)
    path.changed = { [weak self] _ in
      self?.table.deselectAll(nil)
      self?.updateControls()
    }
    name.placeholderString = "Project name"
    name.setAccessibilityLabel("New project name")
    name.changed = { [weak self] _ in self?.updateControls() }
    name.target = self
    name.action = #selector(save)
    for (button, action) in [
      (browseButton, #selector(go)), (upButton, #selector(up)), (homeButton, #selector(home)),
      (openButton, #selector(save)), (cancelButton, #selector(cancel)),
    ] {
      button.target = self
      button.action = action
      button.bezelStyle = .rounded
    }
    openButton.keyEquivalent = "\r"
    cancelButton.keyEquivalent = "\u{1b}"
    table.addTableColumn(NSTableColumn(identifier: .init("folder")))
    table.headerView = nil
    table.dataSource = self
    table.delegate = self
    table.target = self
    table.doubleAction = #selector(enterFolder)
    table.rowHeight = 28
    table.setAccessibilityLabel("Server folders")
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.borderType = .bezelBorder
    detail.font = .systemFont(ofSize: 12)
    detail.textColor = .secondaryLabelColor
    errorLabel.font = .systemFont(ofSize: 12)
    errorLabel.textColor = .systemRed
    errorLabel.isSelectable = true
    pathRow = NSStackView(views: [upButton, homeButton, path, browseButton])
    pathRow.spacing = 6
    let actions = NSStackView(views: [NSView(), cancelButton, openButton])
    actions.spacing = 8
    let stack = NSStackView(views: [
      mode, detail, pathRow, name, scroll, errorLabel, NSView(), actions,
    ])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    let content = NSView()
    panel.contentView = content
    content.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
      stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
      stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
      stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
      scroll.heightAnchor.constraint(equalToConstant: 240),
    ])
    for view in [detail, pathRow!, name, scroll, errorLabel, actions] {
      view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    updateControls()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func present(on parent: NSWindow) {
    guard let window else { return }
    parent.beginSheet(window) { [weak self] _ in
      self?.browsing?.cancel()
      self?.closed()
    }
    window.makeFirstResponder(mode.selectedSegment == 1 ? name : path)
    if mode.selectedSegment == 0 { browse("~") }
  }

  func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    let label = NSTextField(labelWithString: entries[row]["name"].string ?? "Folder")
    label.lineBreakMode = .byTruncatingMiddle
    let icon = NSImageView(
      image: NSImage(systemSymbolName: "folder", accessibilityDescription: nil)!)
    let cell = NSStackView(views: [icon, label])
    cell.spacing = 8
    return cell
  }
  func tableViewSelectionDidChange(_ notification: Notification) { updateControls() }

  private func updateControls() {
    let creating = mode.selectedSegment == 1
    let height: CGFloat = creating ? 260 : 470
    if window?.contentView?.frame.height != height {
      window?.setContentSize(NSSize(width: 600, height: height))
    }
    let connected = session == store.projectSessionID && store.ready
    mode.isEnabled = !saving
    pathRow.isHidden = creating
    scroll.isHidden = creating
    name.isHidden = !creating
    detail.stringValue =
      creating
      ? "Create a project on the connected server in \(store.catalog.newProjectsRoot ?? "its projects folder")."
      : "Choose a folder on \(store.browserEndpoint?.host ?? "the connected server"). Double-click a folder to browse inside."
    errorLabel.isHidden = errorLabel.stringValue.isEmpty
    openButton.title =
      saving ? (creating ? "Creating…" : "Opening…") : (creating ? "Create" : "Open")
    openButton.isEnabled =
      connected && !saving && browsing == nil
      && (creating
        ? !name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          && !creationFailed : !path.stringValue.isEmpty)
    cancelButton.isEnabled = !saving
    browseButton.isEnabled = connected && !saving && browsing == nil && !path.stringValue.isEmpty
    upButton.isEnabled =
      connected && !saving && browsing == nil && directory != nil && directory != "/"
    homeButton.isEnabled = connected && !saving && browsing == nil
    path.isEditable = !saving
    name.isEditable = !saving && !creationFailed
    table.isEnabled = !saving && browsing == nil
  }

  private func browse(_ value: String) {
    browsing?.cancel()
    browseID = UUID()
    let request = browseID
    errorLabel.stringValue = ""
    directory = nil
    entries = []
    table.deselectAll(nil)
    table.reloadData()
    browsing = Task { [weak self] in
      guard let self else { return }
      defer {
        if request == browseID {
          browsing = nil
          updateControls()
        }
      }
      do {
        let result = try await store.browseProjectFolders(value, session: session)
        guard request == browseID, !Task.isCancelled else { return }
        directory = try result.requiredString("parentPath")
        path.stringValue = directory ?? value
        entries = result["entries"].array
        table.deselectAll(nil)
        table.reloadData()
      } catch {
        guard request == browseID, !Task.isCancelled else { return }
        errorLabel.stringValue = error.localizedDescription
      }
    }
    updateControls()
  }

  @objc private func changeProjectAction() {
    browsing?.cancel()
    browsing = nil
    browseID = UUID()
    errorLabel.stringValue = ""
    updateControls()
    window?.makeFirstResponder(mode.selectedSegment == 1 ? name : path)
    if mode.selectedSegment == 0, directory == nil { browse(path.stringValue) }
  }
  @objc private func go() { browse(path.stringValue) }
  @objc private func home() { browse("~") }
  @objc private func up() {
    if let directory { browse((directory as NSString).deletingLastPathComponent) }
  }
  @objc private func enterFolder() {
    guard entries.indices.contains(table.clickedRow), !saving else { return }
    browse(entries[table.clickedRow]["fullPath"].string ?? path.stringValue)
  }
  @objc private func save() {
    guard openButton.isEnabled else { return }
    let creating = mode.selectedSegment == 1
    let value =
      creating
      ? name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      : entries.indices.contains(table.selectedRow)
        ? entries[table.selectedRow]["fullPath"].string ?? path.stringValue : path.stringValue
    saving = true
    errorLabel.stringValue = ""
    updateControls()
    Task { [self] in
      defer {
        saving = false
        updateControls()
      }
      do {
        if creating {
          let result = try await store.createProject(value, session: session)
          opened(result.project, result.warning)
        } else {
          let project = try await store.openProject(value, session: session)
          opened(project, nil)
        }
        if let window { window.sheetParent?.endSheet(window, returnCode: .OK) }
      } catch {
        creationFailed = creating
        errorLabel.stringValue =
          error.localizedDescription
          + (creating
            ? " Check the project list before creating again; the request may already have completed."
            : "")
      }
    }
  }
  @objc private func cancel() {
    guard !saving, let window else { return }
    browsing?.cancel()
    window.sheetParent?.endSheet(window, returnCode: .cancel)
  }
}
