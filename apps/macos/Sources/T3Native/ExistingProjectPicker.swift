import AppKit
import T3Core

@MainActor
final class ExistingProjectPicker: NSViewController, NSTableViewDataSource,
  NSTableViewDelegate, NSSearchFieldDelegate
{
  private let search = NSSearchField()
  private let table = NSTableView()
  private let empty = NSTextField(labelWithString: "No matching projects")
  private var projects: [JSON] = []
  private var matches: [JSON] = []
  private var selectedID: String?
  private let choose: (JSON) -> Void
  private let openFolder: () -> Void
  private let close: () -> Void

  init(
    projects: [JSON], selectedID: String?, choose: @escaping (JSON) -> Void,
    openFolder: @escaping () -> Void, close: @escaping () -> Void
  ) {
    self.choose = choose
    self.openFolder = openFolder
    self.close = close
    super.init(nibName: nil, bundle: nil)
    update(projects: projects, selectedID: selectedID)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func loadView() {
    view = SurfaceView(raised: true)
    search.placeholderString = "Search projects…"
    search.font = .systemFont(ofSize: 14)
    search.isBezeled = true
    search.drawsBackground = false
    search.focusRingType = .none
    search.sendsSearchStringImmediately = true
    search.sendsWholeSearchString = true
    search.delegate = self
    search.setAccessibilityLabel("Search existing projects")
    table.headerView = nil
    table.addTableColumn(NSTableColumn(identifier: .init("project")))
    table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
    table.rowHeight = 52
    table.intercellSpacing = .zero
    table.backgroundColor = .clear
    table.dataSource = self
    table.delegate = self
    table.target = self
    table.action = #selector(chooseClicked)
    table.setAccessibilityLabel("Existing projects")
    let scroll = NSScrollView()
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.drawsBackground = false
    empty.font = .systemFont(ofSize: 13)
    empty.textColor = .secondaryLabelColor
    empty.alignment = .center
    let results = NSView()
    for child in [scroll, empty] { results.addSubview(child) }
    scroll.translatesAutoresizingMaskIntoConstraints = false
    empty.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      scroll.leadingAnchor.constraint(equalTo: results.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: results.trailingAnchor),
      scroll.topAnchor.constraint(equalTo: results.topAnchor),
      scroll.bottomAnchor.constraint(equalTo: results.bottomAnchor),
      empty.centerXAnchor.constraint(equalTo: results.centerXAnchor),
      empty.centerYAnchor.constraint(equalTo: results.centerYAnchor),
    ])
    let open = ComposerPill("", symbol: "folder.badge.plus") { [weak self] in
      guard let self else { return }
      close()
      openFolder()
    }
    open.title = "Open another folder…"
    open.setAccessibilityLabel("Open another folder")
    let stack = NSStackView(views: [search, results, open])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    view.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
      stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
      stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
      stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
      search.heightAnchor.constraint(equalToConstant: 32),
    ])
    for child in [search, results, open] {
      child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    preferredContentSize = NSSize(width: 400, height: 340)
    reload()
  }

  override func viewDidAppear() {
    super.viewDidAppear()
    view.window?.makeFirstResponder(search)
  }

  func update(projects: [JSON], selectedID: String?) {
    let sorted = projects.filter {
      $0["id"].string != nil && $0["workspaceRoot"].string?.isEmpty == false
    }.sorted {
      let left = $0["title"].string ?? "Project"
      let right = $1["title"].string ?? "Project"
      if left != right { return left.localizedStandardCompare(right) == .orderedAscending }
      return ($0["workspaceRoot"].string ?? "") < ($1["workspaceRoot"].string ?? "")
    }
    guard sorted != self.projects || selectedID != self.selectedID else { return }
    self.projects = sorted
    self.selectedID = selectedID
    if isViewLoaded { reload() }
  }

  private func reload() {
    let tokens = search.stringValue.split(whereSeparator: \.isWhitespace).map(String.init)
    matches = projects.filter { project in
      let text = (project["title"].string ?? "") + " " + (project["workspaceRoot"].string ?? "")
      return tokens.allSatisfy { text.localizedStandardContains($0) }
    }
    table.reloadData()
    empty.isHidden = !matches.isEmpty
    if !matches.isEmpty {
      let index = matches.firstIndex { $0["id"].string == selectedID } ?? 0
      table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
      table.scrollRowToVisible(index)
    }
  }

  func controlTextDidChange(_ obj: Notification) { reload() }
  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    switch selector {
    case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
      guard !matches.isEmpty else { return true }
      let step = selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
      let index = min(matches.count - 1, max(0, table.selectedRow + step))
      table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
      table.scrollRowToVisible(index)
      return true
    case #selector(NSResponder.insertNewline(_:)):
      select(table.selectedRow)
      return true
    case #selector(NSResponder.cancelOperation(_:)):
      close()
      return true
    default: return false
    }
  }

  @objc private func chooseClicked() { select(table.clickedRow) }
  private func select(_ row: Int) {
    guard matches.indices.contains(row) else { return }
    let project = matches[row]
    close()
    choose(project)
  }
  func numberOfRows(in tableView: NSTableView) -> Int { matches.count }
  func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    SidebarTableRow()
  }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    let project = matches[row]
    let title = project["title"].string ?? "Project"
    let root = project["workspaceRoot"].string ?? ""
    let name = NSTextField(labelWithString: title)
    name.font = .systemFont(ofSize: 14)
    name.lineBreakMode = .byTruncatingTail
    let path = NSTextField(labelWithString: root)
    path.font = .systemFont(ofSize: 11)
    path.textColor = .secondaryLabelColor
    path.lineBreakMode = .byTruncatingMiddle
    let labels = NSStackView(views: [name, path])
    labels.orientation = .vertical
    labels.alignment = .leading
    labels.spacing = 3
    let icon = NSImageView(
      image: NSImage(systemSymbolName: "folder", accessibilityDescription: nil)!)
    icon.contentTintColor = .secondaryLabelColor
    let check = NSImageView(
      image: NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)!)
    check.isHidden = project["id"].string != selectedID
    let content = NSStackView(views: [icon, labels, check])
    content.spacing = 10
    let cell = NSTableCellView()
    cell.addSubview(content)
    cell.setAccessibilityLabel(title + ", " + root)
    content.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      content.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 9),
      content.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -9),
      content.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      name.widthAnchor.constraint(equalTo: labels.widthAnchor),
      path.widthAnchor.constraint(equalTo: labels.widthAnchor),
      icon.widthAnchor.constraint(equalToConstant: 18),
      check.widthAnchor.constraint(equalToConstant: 14),
    ])
    return cell
  }
}
