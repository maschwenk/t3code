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
  NSSearchFieldDelegate
{
  private enum Row: Equatable {
    case header(ThreadSection, Int, Bool)
    case thread(ThreadSummary)
  }
  private let store: ClientStore
  var onShowUsage: (() -> Void)?
  var onThreadChosen: (() -> Void)?
  private let table = ThreadTable()
  private let search = NSSearchField()
  private let projects = NSPopUpButton()
  private let archiveButton = NSButton(title: "Archived threads", target: nil, action: nil)
  private let message = NSTextField(wrappingLabelWithString: "")
  private var rows: [Row] = []
  private var collapsed = Set(
    UserDefaults.standard.stringArray(forKey: "collapsedThreadGroups") ?? ["Settled", "Snoozed"])
  private var projectID: String?
  private var previousProjects: [String: String] = [:]
  private var restoringSelection = false
  private var refreshTimer: Task<Void, Never>?

  init(store: ClientStore) {
    self.store = store
    super.init(frame: .zero)
    orientation = .vertical
    alignment = .leading
    spacing = 10
    search.placeholderString = "Search threads"
    search.stringValue = Arguments.value("--filter") ?? ""
    search.delegate = self
    search.setAccessibilityLabel("Search threads")
    projects.target = self
    projects.action = #selector(projectChanged)
    projects.setAccessibilityLabel("Filter by project")
    table.headerView = nil
    table.addTableColumn(NSTableColumn(identifier: .init("thread")))
    table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
    table.style = .sourceList
    table.backgroundColor = .clear
    table.intercellSpacing = NSSize(width: 0, height: 2)
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
    archiveButton.target = self
    archiveButton.action = #selector(toggleArchives)
    archiveButton.bezelStyle = .inline
    let usage = ActionButton("Usage") { [weak self] in self?.onShowUsage?() }
    usage.image = NSImage(systemSymbolName: "chart.bar", accessibilityDescription: nil)
    usage.bezelStyle = .inline
    usage.setAccessibilityLabel("Usage")
    usage.toolTip = "Usage (⌘⇧U)"
    let footer = NSStackView(views: [archiveButton, NSView(), usage])
    for view in [search, projects, scroll, message, footer] {
      addArrangedSubview(view)
      view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }
    scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func refresh() {
    let now = Date()
    let projectNames = store.shell.projects.merging(store.archives.projects) { current, _ in current
    }
    if projectNames != previousProjects || projects.numberOfItems == 0 {
      previousProjects = projectNames
      projects.removeAllItems()
      projects.addItem(withTitle: "All projects")
      for (id, name) in projectNames.sorted(by: {
        $0.value.localizedStandardCompare($1.value) == .orderedAscending
      }) {
        projects.addItem(withTitle: name)
        projects.lastItem?.representedObject = id
      }
      if let projectID,
        let item = projects.itemArray.first(where: { $0.representedObject as? String == projectID })
      {
        projects.select(item)
      } else {
        projectID = nil
      }
    }
    let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let source = store.showingArchives ? store.archives.threads : store.shell.threads
    let filtered = source.values.filter { thread in
      (projectID == nil || thread.projectID == projectID)
        && (query.isEmpty
          || [thread.title, projectNames[thread.projectID] ?? "", thread.branch ?? ""]
            .contains(where: { $0.localizedCaseInsensitiveContains(query) }))
    }
    let groups = ThreadGroup.resolve(Array(filtered), at: now)
    let next = groups.flatMap { group -> [Row] in
      let expanded =
        !collapsed.contains(group.section.rawValue) || !query.isEmpty || store.showingArchives
      return [.header(group.section, group.threads.count, expanded)]
        + (expanded ? group.threads.map(Row.thread) : [])
    }
    restoringSelection = true
    if rows != next {
      rows = next
      table.reloadData()
    }
    if let index = rows.firstIndex(where: { row in
      if case .thread(let thread) = row { return thread.id == store.selectedID }
      return false
    }) {
      if table.selectedRow != index {
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
      }
    } else {
      table.deselectAll(nil)
    }
    restoringSelection = false
    archiveButton.title = store.showingArchives ? "Back to active threads" : "Archived threads"
    archiveButton.isEnabled = store.ready
    message.stringValue =
      store.showingArchives
      ? store.archiveError
        ?? (store.archives.synchronized
          ? (filtered.isEmpty ? "No archived threads" : "") : "Loading archives…")
      : (filtered.isEmpty ? (store.ready ? "No matching threads" : "Connecting…") : "")
    message.isHidden = message.stringValue.isEmpty
    scheduleWake(source.values.compactMap { $0.lifecycle.snoozedUntil }.filter { $0 > now }.min())
  }

  private func scheduleWake(_ date: Date?) {
    refreshTimer?.cancel()
    guard let date else {
      refreshTimer = nil
      return
    }
    refreshTimer = Task { [weak self] in
      do {
        try await Task.sleep(for: .seconds(max(0.05, min(60, date.timeIntervalSinceNow))))
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
    return 55
  }
  func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
    if case .thread = rows[row] { return true }
    return false
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
    case .thread(let thread):
      let cell = NSView()
      let title = NSTextField(labelWithString: thread.title)
      title.font = .systemFont(ofSize: 13, weight: thread.lifecycle.unread ? .semibold : .regular)
      title.lineBreakMode = .byTruncatingTail
      let dot = NSTextField(labelWithString: thread.lifecycle.unread ? "●" : "")
      dot.textColor = .controlAccentColor
      dot.font = .systemFont(ofSize: 8)
      let top = NSStackView(views: [title, NSView(), dot])
      let state = thread.lifecycle.statusLabel(at: Date())
      let project = previousProjects[thread.projectID] ?? "Project"
      var detail = [project]
      if let state {
        detail.append(state)
      } else if let branch = thread.branch {
        detail.append(branch)
      }
      if thread.lifecycle.snoozed(at: Date()), let until = thread.lifecycle.snoozedUntil {
        detail.append("until " + until.formatted(date: .abbreviated, time: .shortened))
      }
      let subtitle = NSTextField(labelWithString: detail.joined(separator: " · "))
      subtitle.font = .systemFont(ofSize: 11)
      subtitle.textColor = thread.lifecycle.needsAttention ? .systemOrange : .secondaryLabelColor
      subtitle.lineBreakMode = .byTruncatingTail
      let stack = NSStackView(views: [top, subtitle])
      stack.orientation = .vertical
      stack.alignment = .leading
      stack.spacing = 4
      cell.addSubview(stack)
      stack.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
        stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
        stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        top.widthAnchor.constraint(equalTo: stack.widthAnchor),
        subtitle.widthAnchor.constraint(equalTo: stack.widthAnchor),
      ])
      cell.setAccessibilityElement(true)
      cell.setAccessibilityLabel(([thread.title] + detail).joined(separator: ", "))
      cell.toolTip = ([thread.title] + detail).joined(separator: "\n")
      return cell
    }
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    guard !restoringSelection, rows.indices.contains(table.selectedRow),
      case .thread(let thread) = rows[table.selectedRow]
    else { return }
    store.select(thread.id)
    onThreadChosen?()
  }
  @objc private func threadClicked() {
    guard rows.indices.contains(table.clickedRow), case .thread = rows[table.clickedRow] else {
      return
    }
    onThreadChosen?()
  }
  func controlTextDidChange(_ obj: Notification) { refresh() }
  @objc private func projectChanged() {
    projectID = projects.selectedItem?.representedObject as? String
    refresh()
  }
  @objc private func toggleArchives() { store.showArchives(!store.showingArchives) }
  @objc private func renameSelected() {
    guard rows.indices.contains(table.clickedRow), case .thread(let thread) = rows[table.clickedRow]
    else { return }
    rename(thread)
  }

  private func contextMenu(for row: Int) -> NSMenu? {
    guard rows.indices.contains(row), case .thread(let thread) = rows[row] else { return nil }
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
    guard let window, store.ready else { return }
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
    guard let window else { return }
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
