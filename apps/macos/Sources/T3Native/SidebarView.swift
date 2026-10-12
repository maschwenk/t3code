import AppKit
import T3Core

@MainActor private final class ThreadTable: NSTableView {
  var contextMenu: ((Int) -> NSMenu?)?
  override func menu(for event: NSEvent) -> NSMenu? {
    contextMenu?(row(at: convert(event.locationInWindow, from: nil)))
  }
}

@MainActor
final class SidebarView: NSStackView, NSTableViewDataSource, NSTableViewDelegate,
  NSTextFieldDelegate
{
  private enum Row: Equatable {
    case header(ThreadSection, Int, Bool)
    case thread(SidebarThreadPresentation)
  }
  private let store: ClientStore
  var onSettings: (() -> Void)?
  var onShowUsage: (() -> Void)?
  var onThreadChosen: (() -> Void)?
  var onNewThread: (() -> Void)?
  var onOpenProject: (() -> Void)?
  var onToggleSidebar: (() -> Void)?
  var onConnect: (() -> Void)?
  var onReconnect: (() -> Void)?
  var onBrowserSettings: (() -> Void)?
  var onBack: (() -> Void)?
  private let table = ThreadTable()
  private let search = NSTextField(string: "")
  private lazy var clearSearchButton = sidebarIcon("Clear search", "xmark.circle.fill", size: 18) {
    [weak self] in self?.clearSearch()
  }
  private lazy var projects = sidebarIcon("Filter by project", "folder") { [weak self] in
    self?.chooseProject()
  }
  private lazy var archiveButton = sidebarIcon("Archived threads", "archivebox") { [weak self] in
    self?.toggleArchives()
  }
  private lazy var newButton = sidebarIcon("New thread (⌘N)", "square.and.pencil") { [weak self] in
    self?.onNewThread?()
  }
  private lazy var openProjectButton = sidebarIcon("Open project (⌘O)", "folder.badge.plus") {
    [weak self] in
    self?.onOpenProject?()
  }
  private lazy var settingsButton = sidebarIcon("Settings", "gearshape") { [weak self] in
    self?.showSettings()
  }
  private lazy var reconnectButton = sidebarIcon("Reconnect", "arrow.clockwise") { [weak self] in
    self?.onReconnect?()
  }
  private lazy var usageButton = sidebarIcon("Usage (⌘⇧U)", "chart.bar") { [weak self] in
    self?.onShowUsage?()
  }
  private lazy var backButton = ActionButton("Back") { [weak self] in self?.onBack?() }
  private let scope = NSTextField(labelWithString: "")
  private let message = NSTextField(wrappingLabelWithString: "")
  private var rows: [Row] = []
  private var collapsed = Set(
    UserDefaults.standard.stringArray(forKey: "collapsedThreadGroups") ?? ["Settled", "Snoozed"])
  private var projectID: String?
  private var pendingProjectID: String?
  var selectedProjectID: String? { projectID }
  func focusSearch() { window?.makeFirstResponder(search) }
  private var previousProjects: [String: String] = [:]
  private var restoringSelection = false
  private var refreshTimer: Task<Void, Never>?
  private var searchCandidate: String?
  private var lastSelectedID: String?

  init(store: ClientStore) {
    self.store = store
    super.init(frame: .zero)
    orientation = .vertical
    alignment = .leading
    spacing = 6
    search.isEditable = true
    search.isSelectable = true
    search.focusRingType = .none
    search.placeholderString = "Search"
    search.stringValue = Arguments.value("--filter") ?? ""
    search.delegate = self
    search.setAccessibilityLabel("Search threads")
    search.isBordered = false
    search.drawsBackground = false
    search.font = .systemFont(ofSize: 13)
    search.heightAnchor.constraint(equalToConstant: 22).isActive = true
    let searchIcon = NSImageView(
      image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!)
    searchIcon.identifier = NSUserInterfaceItemIdentifier("thread-search-icon")
    searchIcon.contentTintColor = .secondaryLabelColor
    searchIcon.widthAnchor.constraint(equalToConstant: 14).isActive = true
    searchIcon.heightAnchor.constraint(equalToConstant: 14).isActive = true
    let searchGroup = NSStackView(views: [searchIcon, search, clearSearchButton])
    searchGroup.spacing = 8
    let toggle = sidebarIcon("Toggle sidebar (⌘B)", "sidebar.left") { [weak self] in
      self?.onToggleSidebar?()
    }
    let brand = NSTextField(labelWithString: "T3 Code")
    brand.font = .systemFont(ofSize: 13, weight: .medium)
    let trafficSpace = NSView()
    trafficSpace.widthAnchor.constraint(equalToConstant: 66).isActive = true
    let brandRow = NSStackView(views: [trafficSpace, toggle, brand, NSView()])
    brandRow.spacing = 4
    brandRow.heightAnchor.constraint(equalToConstant: 30).isActive = true
    let header = NSStackView(views: [searchGroup, projects, openProjectButton, newButton])
    header.spacing = 1
    header.heightAnchor.constraint(equalToConstant: 32).isActive = true
    scope.font = .systemFont(ofSize: 11)
    scope.textColor = .secondaryLabelColor
    scope.lineBreakMode = .byTruncatingTail
    scope.isHidden = true
    table.headerView = nil
    table.addTableColumn(NSTableColumn(identifier: .init("thread")))
    table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
    table.style = .plain
    table.backgroundColor = .clear
    table.intercellSpacing = .zero
    table.dataSource = self
    table.delegate = self
    table.target = self
    table.action = #selector(threadClicked)
    table.doubleAction = #selector(renameSelected)
    table.contextMenu = { [weak self] row in self?.contextMenu(for: row) }
    table.setAccessibilityLabel("Threads")
    let scroll = NSScrollView()
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.drawsBackground = false
    message.font = .systemFont(ofSize: 12)
    message.textColor = .secondaryLabelColor
    usageButton.setAccessibilityLabel("Usage")
    newButton.setAccessibilityLabel("New thread")
    newButton.toolTip = "New thread in the selected project (⌘N)"
    backButton.image = NSImage(systemSymbolName: "arrow.left", accessibilityDescription: nil)
    backButton.imagePosition = .imageLeading
    backButton.setAccessibilityLabel("Back to conversation")
    backButton.isBordered = false
    backButton.bezelStyle = .inline
    backButton.font = .systemFont(ofSize: 12)
    backButton.isHidden = true
    let footer = NSStackView(views: [
      settingsButton, archiveButton, usageButton, backButton, NSView(), reconnectButton,
    ])
    footer.spacing = 3
    footer.heightAnchor.constraint(equalToConstant: 30).isActive = true
    for view in [brandRow, header, scope, scroll, message, footer] {
      addArrangedSubview(view)
      view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }
    scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func refresh(revealSelection: Bool = false) {
    let now = Date()
    var projectNames = store.shell.projects.merging(store.archives.projects) { current, _ in current
    }
    for draft in store.conversationDrafts.values {
      if let id = draft.project["id"].string, projectNames[id] == nil {
        projectNames[id] = draft.project["title"].string ?? "Project"
      }
    }
    previousProjects = projectNames
    if let projectID, projectNames[projectID] != nil { pendingProjectID = nil }
    if let projectID, projectNames[projectID] == nil, pendingProjectID != projectID {
      self.projectID = nil
    }
    projects.contentTintColor = projectID == nil ? .secondaryLabelColor : .controlAccentColor
    projects.toolTip =
      "Filter by project: " + (projectID.flatMap { projectNames[$0] } ?? "All projects")
    scope.stringValue = projectID.flatMap { projectNames[$0] } ?? ""
    scope.isHidden = scope.stringValue.isEmpty
    newButton.isEnabled = store.canCreateThread
    openProjectButton.isEnabled = store.ready && store.catalogReady
    let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    clearSearchButton.isHidden = search.stringValue.isEmpty
    let source = store.showingArchives ? store.archives.threads : store.activeSidebarThreads
    let filtered = source.values.filter { thread in
      (projectID == nil || thread.projectID == projectID)
        && (query.isEmpty
          || [thread.title, projectNames[thread.projectID] ?? "", thread.branch ?? ""]
            .contains(where: { $0.localizedCaseInsensitiveContains(query) }))
    }
    let groups = ThreadGroup.resolve(Array(filtered), at: now)
    let directory = SidebarProviderDirectory(store.catalog)
    let projectData = store.shell.projectDetails.merging(store.archives.projectDetails) {
      current, _ in current
    }
    let projectIdentities = Dictionary(
      projectNames.map { id, name in
        (id, SidebarProjectIdentity(name: name, icon: projectData[id]?["projectIcon"] ?? .null))
      }, uniquingKeysWith: { _, new in new })
    let next = groups.flatMap { group -> [Row] in
      let expanded =
        group.section == .active || group.section == .pinned
        || !collapsed.contains(group.section.rawValue) || !query.isEmpty || store.showingArchives
      let header: [Row] =
        group.section == .active || group.section == .pinned || !query.isEmpty
        ? [] : [.header(group.section, group.threads.count, expanded)]
      return header
        + (expanded
          ? group.threads.map { thread in
            .thread(
              SidebarThreadPresentation(
                thread: thread,
                project: projectNames[thread.projectID] ?? "No project",
                identity: projectIdentities[thread.projectID]
                  ?? SidebarProjectIdentity(name: "No project"),
                directory: directory, draft: !(store.drafts[thread.id] ?? "").isEmpty,
                enabled: store.ready && !store.lifecycleBusy(thread.id),
                now: now))
          } : [])
    }
    restoringSelection = true
    if rows != next {
      let sameOrder =
        rows.count == next.count
        && zip(rows, next).allSatisfy { old, new in
          switch (old, new) {
          case (.header(let left, _, _), .header(let right, _, _)): return left == right
          case (.thread(let left), .thread(let right)): return left.thread.id == right.thread.id
          default: return false
          }
        }
      let changed = sameOrder ? IndexSet(rows.indices.filter { rows[$0] != next[$0] }) : IndexSet()
      let heights =
        sameOrder
        ? IndexSet(
          changed.filter { index in
            if case .thread(let old) = rows[index], case .thread(let new) = next[index] {
              return old.compact != new.compact
            }
            return false
          }) : IndexSet()
      rows = next
      if sameOrder {
        table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0))
        if !heights.isEmpty { table.noteHeightOfRows(withIndexesChanged: heights) }
      } else {
        table.reloadData()
      }
    }
    if let index = rows.firstIndex(where: { row in
      if case .thread(let value) = row {
        return value.thread.id == (searchCandidate ?? store.selectedID)
      }
      return false
    }) {
      if table.selectedRow != index {
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
      }
      if searchCandidate == nil && (revealSelection || lastSelectedID != store.selectedID) {
        table.scrollRowToVisible(index)
      }
    } else {
      table.deselectAll(nil)
    }
    restoringSelection = false
    lastSelectedID = store.selectedID
    table.enumerateAvailableRowViews { [weak self] view, index in
      guard let self else { return }
      (view.view(atColumn: 0) as? SidebarThreadCell)?.setSelected(index == self.table.selectedRow)
    }
    archiveButton.toolTip = store.showingArchives ? "Back to active threads" : "Archived threads"
    archiveButton.setAccessibilityLabel(archiveButton.toolTip)
    archiveButton.contentTintColor =
      store.showingArchives ? .controlAccentColor : .secondaryLabelColor
    archiveButton.isEnabled = store.ready
    reconnectButton.toolTip = store.hasConnection ? "Reconnect" : "Connect to server…"
    reconnectButton.setAccessibilityLabel(reconnectButton.toolTip)
    message.stringValue =
      store.showingArchives
      ? store.archiveError
        ?? (store.archives.synchronized
          ? (filtered.isEmpty ? "No archived threads" : "") : "Loading archives…")
      : (filtered.isEmpty ? (store.ready ? "No matching threads" : store.status) : "")
    message.isHidden = message.stringValue.isEmpty
    scheduleWake(source.values.compactMap { $0.lifecycle.snoozedUntil }.filter { $0 > now }.min())
  }

  private func scheduleWake(_ date: Date?) {
    refreshTimer?.cancel()
    guard window?.isVisible == true else {
      refreshTimer = nil
      return
    }
    refreshTimer = Task { [weak self] in
      do {
        try await Task.sleep(for: .seconds(max(0.05, min(60, date?.timeIntervalSinceNow ?? 60))))
      } catch { return }
      self?.refresh()
    }
  }

  private func toggle(_ section: ThreadSection) {
    if !collapsed.insert(section.rawValue).inserted { collapsed.remove(section.rawValue) }
    UserDefaults.standard.set(Array(collapsed), forKey: "collapsedThreadGroups")
    refresh()
  }

  func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
  func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
    if case .header = rows[row] { return 28 }
    if case .thread(let value) = rows[row] { return value.compact ? 36 : 78 }
    return 78
  }
  func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
    if case .thread = rows[row] { return true }
    return false
  }
  func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    SidebarTableRow()
  }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int)
    -> NSView?
  {
    switch rows[index] {
    case .header(let section, let count, let expanded):
      let button = ActionButton("\(section.rawValue) (\(count))") { [weak self] in
        self?.toggle(section)
      }
      button.image = NSImage(
        systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil
      )
      button.imagePosition = .imageLeading
      button.bezelStyle = .inline
      button.isBordered = false
      button.alignment = .left
      button.font = .systemFont(ofSize: 11, weight: .medium)
      button.contentTintColor = .secondaryLabelColor
      button.setAccessibilityLabel(
        "\(section.rawValue), \(count) threads, \(expanded ? "expanded" : "collapsed")")
      return button
    case .thread(let value):
      let cell =
        table.makeView(withIdentifier: .init("thread"), owner: self) as? SidebarThreadCell
        ?? SidebarThreadCell(frame: .zero)
      let thread = value.thread
      cell.configure(
        value, enabled: value.enabled && store.conversationDrafts[thread.id] == nil,
        quickAction: { [weak self] in
          guard let self, self.store.ready, !self.store.lifecycleBusy(thread.id) else { return }
          if thread.lifecycle.snoozed(at: Date()) {
            self.store.snooze(thread.id, until: nil)
          } else {
            self.store.setSettled(thread.id, !thread.lifecycle.settled)
          }
        }, snoozeAction: { [weak self] in self?.customSnooze(thread) })
      cell.setSelected(value.thread.id == (searchCandidate ?? store.selectedID))
      return cell
    }
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    guard !restoringSelection, rows.indices.contains(table.selectedRow),
      case .thread(let value) = rows[table.selectedRow]
    else { return }
    searchCandidate = nil
    store.select(value.thread.id)
    onThreadChosen?()
  }
  @objc private func threadClicked() {
    guard rows.indices.contains(table.clickedRow), case .thread = rows[table.clickedRow] else {
      return
    }
    onThreadChosen?()
  }
  func controlTextDidChange(_ obj: Notification) {
    searchCandidate = nil
    refresh(revealSelection: search.stringValue.isEmpty)
  }
  func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector)
    -> Bool
  {
    guard control === search else { return false }
    let candidates = rows.enumerated().compactMap { index, row -> (Int, String)? in
      if case .thread(let value) = row { return (index, value.thread.id) }
      return nil
    }
    switch commandSelector {
    case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
      guard !candidates.isEmpty else { return true }
      let old = candidates.firstIndex { $0.1 == searchCandidate }
      let forward = commandSelector == #selector(NSResponder.moveDown(_:))
      let next =
        old.map { ($0 + (forward ? 1 : candidates.count - 1)) % candidates.count }
        ?? (forward ? 0 : candidates.count - 1)
      searchCandidate = candidates[next].1
      refresh()
      table.scrollRowToVisible(candidates[next].0)
      return true
    case #selector(NSResponder.insertNewline(_:)):
      guard !search.stringValue.isEmpty, let id = searchCandidate ?? candidates.first?.1 else {
        return false
      }
      search.stringValue = ""
      searchCandidate = nil
      store.select(id)
      refresh(revealSelection: true)
      onThreadChosen?()
      return true
    case #selector(NSResponder.cancelOperation(_:)):
      guard !search.stringValue.isEmpty else { return false }
      search.stringValue = ""
      searchCandidate = nil
      refresh(revealSelection: true)
      return true
    default: return false
    }
  }

  func showUtilityPage(_ visible: Bool) {
    for button in [settingsButton, archiveButton, usageButton] { button.isHidden = visible }
    backButton.isHidden = !visible
  }

  func selectProject(_ id: String) {
    projectID = id
    pendingProjectID = id
    clearSearch()
  }

  func clearSearch() {
    search.stringValue = ""
    searchCandidate = nil
    refresh(revealSelection: true)
  }

  private func chooseProject() {
    let menu = NSMenu()
    menu.autoenablesItems = false
    func add(_ name: String, id: String?) {
      let item = ActionMenuItem(name) { [weak self] in
        self?.projectID = id
        self?.searchCandidate = nil
        self?.refresh(revealSelection: true)
      }
      item.state = projectID == id ? .on : .off
      menu.addItem(item)
    }
    add("All projects", id: nil)
    menu.addItem(.separator())
    for (id, name) in previousProjects.sorted(by: {
      $0.value.localizedStandardCompare($1.value) == .orderedAscending
    }) {
      add(name, id: id)
    }
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: projects.bounds.maxY), in: projects)
  }

  private func showSettings() {
    if let onSettings {
      onSettings()
      return
    }
    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.addItem(ActionMenuItem("Connections…") { [weak self] in self?.onConnect?() })
    menu.addItem(ActionMenuItem("Browser Settings…") { [weak self] in self?.onBrowserSettings?() })
    menu.popUp(
      positioning: nil, at: NSPoint(x: 0, y: settingsButton.bounds.maxY), in: settingsButton)
  }
  @objc private func toggleArchives() { store.showArchives(!store.showingArchives) }
  @objc private func renameSelected() {
    guard rows.indices.contains(table.clickedRow), case .thread(let value) = rows[table.clickedRow]
    else { return }
    rename(value.thread)
  }

  private func contextMenu(for row: Int) -> NSMenu? {
    guard rows.indices.contains(row), case .thread(let value) = rows[row] else { return nil }
    let thread = value.thread
    guard store.conversationDrafts[thread.id] == nil else { return nil }
    let menu = NSMenu()
    menu.autoenablesItems = false
    let enabled = store.ready && !store.lifecycleBusy(thread.id)
    func add(_ title: String, enabled allowed: Bool = true, action: @escaping () -> Void) {
      let item = ActionMenuItem(title, action: action)
      item.isEnabled = enabled && allowed
      menu.addItem(item)
    }
    add("Rename…") { [weak self] in self?.rename(thread) }
    add("Mark unread", enabled: thread.lifecycle.latestRunCompletedAt != nil) { [weak store] in
      store?.markUnread(thread.id)
    }
    menu.addItem(.separator())
    if thread.archived {
      add("Restore thread") { [weak store] in store?.setArchived(thread.id, false) }
      return menu
    }
    add(thread.lifecycle.pinned ? "Unpin" : "Pin") { [weak store] in
      store?.setPinned(thread.id, !thread.lifecycle.pinned)
    }
    add(
      thread.lifecycle.settled ? "Move to active" : "Settle",
      enabled: thread.lifecycle.settled
        || (thread.activeRunID == nil && !thread.lifecycle.hasQueuedStart(at: Date()))
    ) { [weak store] in
      store?.setSettled(thread.id, !thread.lifecycle.settled)
    }
    add(
      thread.lifecycle.autoSettleDisabled
        ? "Enable automatic settling" : "Disable automatic settling"
    ) { [weak store] in
      store?.setAutoSettle(thread.id, enabled: thread.lifecycle.autoSettleDisabled)
    }
    if thread.lifecycle.snoozedUntil != nil {
      add("Wake now") { [weak store] in store?.snooze(thread.id, until: nil) }
    }
    let snooze = NSMenuItem(title: "Snooze", action: nil, keyEquivalent: "")
    snooze.isEnabled = enabled && thread.lifecycle.canSnooze(at: Date())
    let choices = NSMenu()
    choices.autoenablesItems = false
    for preset in SnoozePreset.choices(at: Date()) {
      choices.addItem(
        ActionMenuItem(
          preset.title + " · " + preset.date.formatted(date: .omitted, time: .shortened)
        ) { [weak store] in
          store?.snooze(thread.id, until: preset.date)
        })
    }
    choices.addItem(
      ActionMenuItem("Choose date and time…") { [weak self] in self?.customSnooze(thread) })
    snooze.submenu = choices
    menu.addItem(snooze)
    menu.addItem(.separator())
    add("Archive…") { [weak self] in self?.archive(thread) }
    return menu
  }

  private func rename(_ thread: ThreadSummary) {
    guard let window, store.ready, store.conversationDrafts[thread.id] == nil else { return }
    let alert = NSAlert()
    alert.messageText = "Rename thread"
    let name = NSTextField(string: thread.title)
    name.frame = NSRect(x: 0, y: 0, width: 380, height: 26)
    alert.accessoryView = name
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")
    alert.beginSheetModal(for: window) { [weak store] result in
      if result == .alertFirstButtonReturn { store?.rename(thread.id, to: name.stringValue) }
    }
    alert.window.makeFirstResponder(name)
    name.selectText(nil)
  }

  private func archive(_ thread: ThreadSummary) {
    guard let window else { return }
    let alert = NSAlert()
    alert.messageText = "Archive “\(thread.title)”?"
    alert.informativeText = "You can restore this thread from Archived threads."
    alert.addButton(withTitle: "Archive")
    alert.addButton(withTitle: "Cancel")
    alert.beginSheetModal(for: window) { [weak store] result in
      if result == .alertFirstButtonReturn { store?.setArchived(thread.id, true) }
    }
  }

  private func customSnooze(_ thread: ThreadSummary) {
    guard let window, store.ready, !store.lifecycleBusy(thread.id) else { return }
    let alert = NSAlert()
    alert.messageText = "Snooze until"
    let picker = NSDatePicker()
    picker.datePickerStyle = .textFieldAndStepper
    picker.datePickerElements = [.yearMonthDay, .hourMinute]
    picker.dateValue = Date().addingTimeInterval(3600)
    picker.minDate = Date().addingTimeInterval(60)
    picker.frame = NSRect(x: 0, y: 0, width: 320, height: 28)
    alert.accessoryView = picker
    alert.addButton(withTitle: "Snooze")
    alert.addButton(withTitle: "Cancel")
    alert.beginSheetModal(for: window) { [weak store] result in
      if result == .alertFirstButtonReturn { store?.snooze(thread.id, until: picker.dateValue) }
    }
  }
}
