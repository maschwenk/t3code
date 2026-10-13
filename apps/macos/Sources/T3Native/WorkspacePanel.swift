import AppKit
import T3Core

@MainActor private final class WorkspaceNode: NSObject {
  var entry: WorkspaceEntry
  init(_ entry: WorkspaceEntry) { self.entry = entry }
}

@MainActor
final class WorkspacePanel: NSViewController, NSOutlineViewDataSource,
  NSOutlineViewDelegate, NSTextViewDelegate, NSSearchFieldDelegate, NSMenuDelegate
{
  private let store: ClientStore
  let files: WorkspaceFiles
  var onClose: (() -> Void)?
  private let outline = WorkspaceOutlineView()
  private let actionsButton = NSPopUpButton(frame: .zero, pullsDown: true)
  private let search = NSSearchField()
  private let editor = NSTextView()
  private let editorScroll = NSScrollView()
  private let renderedPreview = WorkspaceRenderedPreview()
  private let mediaPreview = WorkspaceMediaPreview()
  private var previewActive = true
  private let previewPreferences = FilePreviewPreferences()
  private let mode = NSSegmentedControl(
    labels: ["Source", "Preview"], trackingMode: .selectOne, target: nil, action: nil)
  private var forcedSource: WorkspaceFileID?
  private var handledReveal: UUID?
  private let path = NSTextField(labelWithString: "Select a file")
  private let info = NSTextField(wrappingLabelWithString: "")
  private let saveButton = NSButton(title: "Save  ⌘S", target: nil, action: nil)
  private let reloadButton = NSButton(title: "Reload", target: nil, action: nil)
  private let draftsButton = NSPopUpButton(frame: .zero, pullsDown: false)
  private var nodes: [String: WorkspaceNode] = [:]
  private var treeRevision = -1
  private var displayedFile: WorkspaceFileID?
  private var displayedDirectory: String?
  private var pendingTreeSelection: WorkspaceFileID?
  private var expanded: Set<String> = []
  private var renderedLocation: WorkspaceLocation?
  private var updating = false

  init(store: ClientStore) {
    self.store = store
    files = WorkspaceFiles(store: store)
    super.init(nibName: nil, bundle: nil)
    files.onChange = { [weak self] in self?.refresh() }
    renderedPreview.onTask = { [weak self] id, source, offset, checked in
      guard let self, self.files.selected == id, self.files.document?.contents == source,
        self.files.canEditDocument
      else { return }
      self.files.edit(WorkspaceMarkdown.settingTask(source, offset: offset, checked: checked))
    }
    renderedPreview.onFileLink = { [weak self] id, url in
      guard let self, self.files.selected == id else { return }
      self.open(url)
    }
    renderedPreview.fileLinkMenu = { [weak self] id, url in
      guard let self, self.files.selected == id else { return nil }
      return FileContextMenu.forLink(url, at: self.files.location, store: self.store)
    }
    mediaPreview.onOpenLink = { url in NSWorkspace.shared.open(url) }
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func loadView() {
    let surface = SurfaceView(sidebar: true)
    view = surface
    let close = NSButton(title: "Close", target: self, action: #selector(closePanel))
    let refreshButton = NSButton(title: "Refresh", target: self, action: #selector(refreshFiles))
    let heading = NSTextField(labelWithString: "Files")
    heading.font = .systemFont(ofSize: 14, weight: .semibold)
    let top = NSStackView(views: [heading, NSView(), refreshButton, close])
    search.placeholderString = "Search files"
    search.setAccessibilityLabel("Search workspace files")
    search.delegate = self
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
    outline.addTableColumn(column)
    outline.outlineTableColumn = column
    outline.headerView = nil
    outline.rowHeight = 25
    outline.indentationPerLevel = 14
    outline.dataSource = self
    outline.delegate = self
    outline.setAccessibilityLabel("Workspace files")
    outline.target = self
    outline.action = #selector(openSelection)
    outline.menuAtRow = { [weak self] row in
      guard let self, let node = self.outline.item(atRow: row) as? WorkspaceNode,
        let location = self.files.location
      else { return nil }
      return FileContextMenu.make(path: node.entry.path, at: location, store: self.store)
    }
    let treeScroll = NSScrollView()
    treeScroll.documentView = outline
    treeScroll.hasVerticalScroller = true
    treeScroll.autohidesScrollers = true
    treeScroll.drawsBackground = false
    let browser = NSStackView(views: [search, treeScroll])
    browser.orientation = .vertical
    browser.alignment = .leading
    search.widthAnchor.constraint(equalTo: browser.widthAnchor).isActive = true
    treeScroll.widthAnchor.constraint(equalTo: browser.widthAnchor).isActive = true
    treeScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true

    path.lineBreakMode = .byTruncatingMiddle
    path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    saveButton.target = self
    saveButton.action = #selector(saveFile)
    reloadButton.target = self
    reloadButton.action = #selector(reloadFile)
    let copy = NSButton(title: "Copy", target: self, action: #selector(copyContents))
    actionsButton.addItem(withTitle: "Actions")
    actionsButton.setAccessibilityLabel("File actions")
    actionsButton.menu?.autoenablesItems = false
    actionsButton.menu?.delegate = self
    let actions = NSStackView(views: [
      path, NSView(), actionsButton, copy, reloadButton, saveButton,
    ])
    draftsButton.target = self
    draftsButton.action = #selector(openDraft)
    editor.isRichText = false
    editor.isAutomaticQuoteSubstitutionEnabled = false
    editor.isAutomaticDashSubstitutionEnabled = false
    editor.isAutomaticTextReplacementEnabled = false
    editor.isAutomaticSpellingCorrectionEnabled = false
    editor.isContinuousSpellCheckingEnabled = false
    editor.allowsUndo = true
    editor.usesFindBar = true
    editor.isIncrementalSearchingEnabled = true
    editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    editor.textContainerInset = NSSize(width: 8, height: 8)
    editor.isVerticallyResizable = true
    editor.isHorizontallyResizable = false
    editor.autoresizingMask = [.width]
    editor.textContainer?.widthTracksTextView = true
    editor.delegate = self
    editor.setAccessibilityLabel("Workspace file contents")
    editorScroll.documentView = editor
    editorScroll.hasVerticalScroller = true
    editorScroll.autohidesScrollers = true
    info.maximumNumberOfLines = 3
    info.font = .systemFont(ofSize: 11)
    info.textColor = .secondaryLabelColor
    mode.target = self
    mode.action = #selector(changePreviewMode)
    mode.setAccessibilityLabel("File presentation")
    let content = NSView()
    for child in [editorScroll, renderedPreview, mediaPreview] {
      content.addSubview(child)
      child.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        child.leadingAnchor.constraint(equalTo: content.leadingAnchor),
        child.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        child.topAnchor.constraint(equalTo: content.topAnchor),
        child.bottomAnchor.constraint(equalTo: content.bottomAnchor),
      ])
    }
    let preview = NSStackView(views: [draftsButton, actions, mode, info, content])
    preview.orientation = .vertical
    preview.alignment = .leading
    preview.spacing = 8
    for child in [draftsButton, actions, info, content] {
      child.widthAnchor.constraint(equalTo: preview.widthAnchor).isActive = true
    }
    content.heightAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
    let split = NSSplitView()
    split.isVertical = false
    split.dividerStyle = .thin
    split.addArrangedSubview(browser)
    split.addArrangedSubview(preview)
    let stack = NSStackView(views: [top, split])
    stack.orientation = .vertical
    stack.spacing = 12
    stack.alignment = .leading
    surface.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 12),
      stack.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -12),
      stack.topAnchor.constraint(equalTo: surface.topAnchor, constant: 46),
      stack.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -12),
      top.widthAnchor.constraint(equalTo: stack.widthAnchor),
      split.widthAnchor.constraint(equalTo: stack.widthAnchor),
      browser.heightAnchor.constraint(greaterThanOrEqualToConstant: 130),
      preview.heightAnchor.constraint(greaterThanOrEqualToConstant: 230),
    ])
    let browserHeight = browser.heightAnchor.constraint(equalToConstant: 220)
    browserHeight.priority = .defaultLow
    browserHeight.isActive = true
    refresh()
  }

  func refreshContext(active: Bool = true) {
    previewActive = active
    if !active { mediaPreview.clear() }
    files.refreshContext(active: active)
    refresh()
  }
  func open(_ url: URL) {
    guard let root = files.location?.root, let link = WorkspaceFileLink(url: url, root: root) else {
      return
    }
    files.open(link.path, position: link.position)
  }
  func closeEditor() {
    previewActive = false
    mediaPreview.clear()
    files.closeEditor()
  }
  func finishSaving() async -> Bool { await files.finishSaving() }
  func focusSearch() { view.window?.makeFirstResponder(search) }
  func findInFile() {
    forcedSource = files.selected
    refresh()
    view.window?.makeFirstResponder(editor)
    let item = NSMenuItem()
    item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
    editor.performFindPanelAction(item)
  }
  var storageError: String? { files.storageError }
  func saveDraftsBeforeExit() -> Bool { files.flush() }

  func menuNeedsUpdate(_ menu: NSMenu) {
    guard menu === actionsButton.menu else { return }
    menu.removeAllItems()
    menu.addItem(withTitle: "Actions", action: nil, keyEquivalent: "")
    guard let selected = files.selected, let location = files.location else { return }
    FileContextMenu.append(
      FileContextMenu.make(path: selected.path, at: location, store: store), to: menu)
  }

  private func refresh() {
    guard isViewLoaded else { return }
    updating = true
    defer { updating = false }
    if renderedLocation != files.location {
      renderedLocation = files.location
      expanded = []
      nodes = [:]
    }
    if search.stringValue != files.query { search.stringValue = files.query }
    let changedFile = displayedFile != files.selected
    let changedDirectory = displayedDirectory != files.selectedDirectory
    if changedFile || changedDirectory { pendingTreeSelection = files.selected }
    if changedFile || changedDirectory, let selected = files.selected {
      expanded.formUnion(
        WorkspaceTreeNavigation.directories(
          for: selected.path, isDirectory: files.selectedDirectory != nil))
    }
    let changedTree = treeRevision != files.treeRevision
    if changedTree {
      treeRevision = files.treeRevision
      let selection = (outline.item(atRow: outline.selectedRow) as? WorkspaceNode)?.entry.path
      let entries = files.directories.values.flatMap { $0 } + files.searchResults
      var retained: Set<String> = []
      for entry in entries {
        retained.insert(entry.path)
        if let node = nodes[entry.path] {
          node.entry = entry
        } else {
          nodes[entry.path] = WorkspaceNode(entry)
        }
      }
      nodes = nodes.filter { retained.contains($0.key) }
      outline.reloadData()
      if !files.isSearching {
        for path in expanded.sorted() {
          if let node = nodes[path] { outline.expandItem(node) }
        }
      }
      if let selection, let node = nodes[selection] {
        let row = outline.row(forItem: node)
        if row >= 0 {
          outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
      }
    }
    displayedFile = files.selected
    displayedDirectory = files.selectedDirectory
    if changedFile || changedDirectory {
      for path in expanded.sorted() {
        if let node = nodes[path] { outline.expandItem(node) }
      }
    }
    if let selected = pendingTreeSelection, selected == files.selected,
      let node = nodes[selected.path]
    {
      let row = outline.row(forItem: node)
      if row >= 0 {
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outline.scrollRowToVisible(row)
        pendingTreeSelection = nil
      }
    }
    let document = files.document
    if changedFile { forcedSource = nil }
    let reveal = files.revealRequest.flatMap { $0.id == handledReveal ? nil : $0 }
    if reveal != nil { forcedSource = files.selected }
    let kind = FilePreviewKind(path: files.selected?.path ?? "")
    let media = files.mediaRequest
    let showMedia =
      media != nil
      && (kind != .html || (forcedSource != files.selected && previewPreferences.rendered(.html)))
    let showRendered =
      document != nil && kind != .source && kind != .html && forcedSource != files.selected
      && previewPreferences.rendered(kind)
    mode.isHidden = document == nil || kind == .source
    mode.selectedSegment = showRendered || showMedia ? 1 : 0
    mode.setLabel(kind.delimiter == nil ? "Preview" : "Table", forSegment: 1)
    editorScroll.isHidden = showRendered || showMedia
    renderedPreview.isHidden = !showRendered
    mediaPreview.isHidden = !showMedia
    if showMedia, previewActive, let media {
      mediaPreview.show(media)
    } else {
      mediaPreview.clear()
    }
    if showRendered, let document, let id = files.selected {
      renderedPreview.show(document, id: id, editable: files.canEditDocument)
    }
    if changedFile { editor.undoManager?.removeAllActions() }
    let contents = document?.contents ?? ""
    if editor.string != contents {
      let selection = editor.selectedRange()
      editor.string = contents
      let length = (contents as NSString).length
      editor.setSelectedRange(
        changedFile
          ? NSRange(location: 0, length: 0)
          : NSRange(location: min(selection.location, length), length: 0))
      if changedFile { editor.scrollRangeToVisible(NSRange(location: 0, length: 0)) }
    }
    editor.isEditable = files.canEditDocument
    if let reveal {
      handledReveal = reveal.id
      let range = reveal.position.range(in: contents)
      editor.setSelectedRange(NSRange(location: range.location, length: 0))
      editor.scrollRangeToVisible(range)
      editor.showFindIndicator(for: range)
    }
    path.stringValue =
      (files.selected?.path ?? "Select a file") + (files.pendingSave ? " •" : "")
    path.toolTip = files.selected.map { FileOpenCapabilities.absolutePath($0.path, root: $0.root) }
    actionsButton.isEnabled = files.selected != nil
    saveButton.isEnabled = files.canSave
    saveButton.title = files.selectedSaveError == nil ? "Save  ⌘S" : "Retry  ⌘S"
    reloadButton.isEnabled =
      (document != nil || files.selectedDirectory != nil || media != nil) && !files.loadingFile
      && files.selected.map { !files.saving.contains($0) } == true
    let draftIDs = files.drafts
    if draftsButton.itemArray.compactMap({ $0.representedObject as? String })
      != draftIDs.map(\.path)
    {
      draftsButton.removeAllItems()
      draftsButton.addItem(withTitle: "Unsaved files (\(draftIDs.count))")
      for id in draftIDs {
        draftsButton.addItem(withTitle: id.path)
        draftsButton.lastItem?.representedObject = id.path
      }
    }
    draftsButton.selectItem(at: 0)
    draftsButton.isHidden = draftIDs.isEmpty
    if let error = files.storageError {
      info.stringValue = "Recovery could not be saved: " + error
    } else if let error = files.selectedSaveError {
      info.stringValue = error
    } else if files.loadingFile {
      info.stringValue = "Loading file…"
    } else if !files.message.isEmpty {
      info.stringValue = files.message
    } else if document?.truncated == true {
      info.stringValue = "Truncated preview • \(document!.byteLength) bytes on disk • read-only"
    } else if document?.canEdit == false {
      info.stringValue = "Host file • read-only"
    } else if files.pendingSave {
      info.stringValue = files.isConnected ? "Saving changes…" : "Saved locally • Reconnect to sync"
    } else if files.loadingTree {
      info.stringValue = "Loading folder…"
    } else {
      info.stringValue = files.location?.root ?? "Select a thread to browse its workspace."
    }
    info.toolTip = info.stringValue
  }

  func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
    children(item).count
  }
  func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
    nodes[children(item)[index].path]!
  }
  private func children(_ item: Any?) -> [WorkspaceEntry] {
    if files.isSearching { return item == nil ? files.searchResults : [] }
    return files.directories[(item as? WorkspaceNode)?.entry.path ?? ""] ?? []
  }
  func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
    !files.isSearching && (item as? WorkspaceNode)?.entry.isDirectory == true
  }
  func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any)
    -> NSView?
  {
    guard let node = item as? WorkspaceNode else { return nil }
    let id = NSUserInterfaceItemIdentifier("fileCell")
    let cell =
      (outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView)
      ?? NSTableCellView()
    if cell.textField == nil {
      cell.identifier = id
      let label = NSTextField(labelWithString: "")
      label.lineBreakMode = .byTruncatingMiddle
      label.font = .systemFont(ofSize: 12)
      let icon = NSImageView()
      cell.addSubview(icon)
      cell.imageView = icon
      icon.translatesAutoresizingMaskIntoConstraints = false
      cell.addSubview(label)
      cell.textField = label
      label.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
        icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        icon.widthAnchor.constraint(equalToConstant: 15),
        icon.heightAnchor.constraint(equalToConstant: 15),
        label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
        label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
        label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      ])
    }
    cell.imageView?.image = NSImage(
      systemSymbolName: node.entry.isDirectory ? "folder" : "doc",
      accessibilityDescription: node.entry.isDirectory ? "Folder" : "File")
    cell.imageView?.contentTintColor = .secondaryLabelColor
    cell.textField?.stringValue = files.isSearching ? node.entry.path : node.entry.name
    cell.textField?.textColor = node.entry.ignored ? .secondaryLabelColor : .labelColor
    cell.toolTip = node.entry.path + (node.entry.ignored ? " (ignored)" : "")
    return cell
  }
  func outlineViewItemDidExpand(_ notification: Notification) {
    guard let node = notification.userInfo?["NSObject"] as? WorkspaceNode else { return }
    expanded.insert(node.entry.path)
    files.loadDirectory(node.entry.path)
  }
  func outlineViewItemDidCollapse(_ notification: Notification) {
    guard !updating, let node = notification.userInfo?["NSObject"] as? WorkspaceNode else { return }
    expanded.remove(node.entry.path)
  }
  func outlineViewSelectionDidChange(_ notification: Notification) {
    guard !updating else { return }
    pendingTreeSelection = nil
    guard let node = outline.item(atRow: outline.selectedRow) as? WorkspaceNode,
      !node.entry.isDirectory
    else { return }
    if files.selected?.path != node.entry.path { files.open(node.entry.path) }
  }
  func controlTextDidChange(_ obj: Notification) { files.search(search.stringValue) }
  func textDidChange(_ notification: Notification) {
    if !updating { files.edit(editor.string) }
  }
  @objc private func openSelection() {
    guard let node = outline.item(atRow: outline.selectedRow) as? WorkspaceNode else { return }
    if node.entry.isDirectory {
      if files.isSearching {
        files.search("")
        let parts = node.entry.path.split(separator: "/")
        for end in 1...parts.count {
          let parent = parts.prefix(end).joined(separator: "/")
          expanded.insert(parent)
          files.loadDirectory(parent)
        }
      } else {
        outline.expandItem(node)
      }
    } else if files.selected?.path != node.entry.path {
      files.open(node.entry.path)
    }
  }
  @objc func saveFile() {
    Task { do { try await files.save() } catch { refresh() } }
  }
  @objc private func reloadFile() {
    guard let path = files.selected?.path else { return }
    if files.pendingSave {
      let alert = NSAlert()
      alert.messageText = "Discard unsaved changes to this file?"
      alert.informativeText = "Reload replaces your local edits with the current server file."
      alert.addButton(withTitle: "Cancel")
      alert.addButton(withTitle: "Discard and reload")
      guard alert.runModal() == .alertSecondButtonReturn else { return }
    }
    files.open(path, reload: true)
  }
  @objc private func changePreviewMode() {
    forcedSource = nil
    let kind = FilePreviewKind(path: files.selected?.path ?? "")
    previewPreferences.setRendered(mode.selectedSegment == 1, for: kind)
    refresh()
  }

  @objc private func copyContents() {
    guard let document = files.document else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(document.contents, forType: .string)
  }
  @objc private func openDraft() {
    guard let path = draftsButton.selectedItem?.representedObject as? String else { return }
    files.open(path)
  }
  @objc private func refreshFiles() { files.refresh() }
  @objc private func closePanel() { onClose?() }
}
