import AppKit
import T3Core

@MainActor private final class ModelTable: NSTableView {
  var choose: (() -> Void)?
  var dismiss: (() -> Void)?
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 36 {
      choose?()
    } else if event.keyCode == 53 {
      dismiss?()
    } else {
      super.keyDown(with: event)
    }
  }
}

@MainActor private final class ModelRail: NSStackView {
  override var isFlipped: Bool { true }
}

@MainActor
final class ModelPicker: NSViewController, NSTableViewDataSource,
  NSTableViewDelegate, NSSearchFieldDelegate
{
  private enum Row {
    case model(ModelChoice)
    case legacy(Int)
  }
  private let store: ClientStore
  private let threadID: String?
  private let environment: String
  private let close: () -> Void
  private let search = NSSearchField()
  private let table = ModelTable()
  private let rail = ModelRail()
  private let railScroll = NSScrollView()
  private let footer = NSTextField(wrappingLabelWithString: "")
  private var catalog = ProviderCatalog()
  private var index = ModelSearch(catalog: ProviderCatalog())
  private var rows: [Row] = []
  private var instanceID: String?
  private var favoritesOnly = false
  private var preferences = ModelPickerPreferences()
  private var favorites: Set<ModelIdentity> = []
  private var expandedLegacy: Set<String> = []
  private var previousSelection: JSON?
  private var previousEnabled: Bool?
  private var previousStarted: Bool?
  private var favoritesKey: String { "modelFavorites:" + environment }

  init(store: ClientStore, close: @escaping () -> Void) {
    self.store = store
    threadID = store.selectedID
    environment = store.environmentKey
    self.close = close
    super.init(nibName: nil, bundle: nil)
    if let data = UserDefaults.standard.data(forKey: favoritesKey),
      let saved = try? JSONDecoder().decode(Set<ModelIdentity>.self, from: data)
    {
      favorites = saved
    }
    preferences = ModelPickerPreferences(environment: environment)
    favorites = preferences.favorites
    instanceID = store.selectedThread?.model["instanceId"].string
    favoritesOnly =
      !favorites.isEmpty
      && store.catalog.provider(for: store.selectedThread?.model ?? .null)?.available == true
    if store.catalog.model(for: store.selectedThread?.model ?? .null)?.legacy == true,
      let instanceID
    {
      expandedLegacy.insert(instanceID)
    }
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func loadView() {
    view = SurfaceView(raised: true)
    view.frame = NSRect(x: 0, y: 0, width: 440, height: 340)
    rail.orientation = .vertical
    rail.alignment = .centerX
    rail.spacing = 3
    rail.edgeInsets = NSEdgeInsets(top: 10, left: 6, bottom: 10, right: 6)
    railScroll.documentView = rail
    railScroll.hasVerticalScroller = true
    railScroll.drawsBackground = false
    rail.translatesAutoresizingMaskIntoConstraints = false
    rail.widthAnchor.constraint(equalTo: railScroll.widthAnchor).isActive = true
    search.placeholderString = "Search models…"
    search.font = .systemFont(ofSize: 14)
    search.isBezeled = true
    search.drawsBackground = false
    search.focusRingType = .none
    search.heightAnchor.constraint(equalToConstant: 34).isActive = true
    search.setAccessibilityLabel("Search models")
    search.sendsSearchStringImmediately = true
    search.sendsWholeSearchString = true
    search.delegate = self
    table.headerView = nil
    table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("model")))
    table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
    table.dataSource = self
    table.delegate = self
    table.target = self
    table.action = #selector(clicked)
    table.rowHeight = 58
    table.selectionHighlightStyle = .regular
    table.intercellSpacing = .zero
    table.backgroundColor = .clear
    table.setAccessibilityLabel("Models")
    table.choose = { [weak self] in self?.chooseSelected() }
    table.dismiss = close
    let scroll = NSScrollView()
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.drawsBackground = false
    footer.font = .systemFont(ofSize: 11)
    footer.textColor = .secondaryLabelColor
    let right = NSStackView(views: [search, scroll, footer])
    right.orientation = .vertical
    right.alignment = .leading
    right.spacing = 8
    right.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
    for child in [search, scroll, footer] {
      child.widthAnchor.constraint(equalTo: right.widthAnchor, constant: -20).isActive = true
    }
    view.addSubview(railScroll)
    view.addSubview(right)
    railScroll.translatesAutoresizingMaskIntoConstraints = false
    right.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      railScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      railScroll.topAnchor.constraint(equalTo: view.topAnchor),
      railScroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      railScroll.widthAnchor.constraint(equalToConstant: 56),
      right.leadingAnchor.constraint(equalTo: railScroll.trailingAnchor),
      right.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      right.topAnchor.constraint(equalTo: view.topAnchor),
      right.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
    ])
    refresh()
  }

  override func viewDidAppear() {
    super.viewDidAppear()
    view.window?.makeFirstResponder(search)
  }

  func refresh() {
    guard store.selectedID == threadID, store.environmentKey == environment else {
      close()
      return
    }
    let changedCatalog = catalog != store.catalog
    let selection = store.selectedThread?.model
    let enabled = store.canEditThread && store.catalogReady
    let started = !(store.thread?.rows.isEmpty ?? true)
    guard
      changedCatalog || previousSelection != selection || previousEnabled != enabled
        || previousStarted != started
    else { return }
    previousSelection = selection
    previousEnabled = enabled
    previousStarted = started
    if changedCatalog {
      catalog = store.catalog
      index = ModelSearch(catalog: catalog)
    }
    guard isViewLoaded else { return }
    rebuildRail()
    reloadResults()
  }

  private func rebuildRail() {
    for child in rail.arrangedSubviews {
      rail.removeArrangedSubview(child)
      child.removeFromSuperview()
    }
    func add(
      _ title: String, image: NSImage?, badge: String = "", selected: Bool,
      action: @escaping () -> Void
    ) {
      let button = ModelAccountButton(badge, selected: selected, action: action)
      button.image = image
      button.toolTip = title
      button.setAccessibilityLabel(title)
      rail.addArrangedSubview(button)
      button.widthAnchor.constraint(equalToConstant: 40).isActive = true
      button.heightAnchor.constraint(equalToConstant: 44).isActive = true
    }
    add(
      "Favorites", image: NSImage(systemSymbolName: "star.fill", accessibilityDescription: nil),
      selected: favoritesOnly
    ) { [weak self] in self?.filter(nil, favorites: true) }
    for provider in catalog.providers {
      add(
        provider.name, image: ProviderArtwork.image(provider.driver),
        badge: provider.driver == "codex" ? "" : SidebarProviderMark.initials(provider.name),
        selected: !favoritesOnly && instanceID == provider.id
      ) { [weak self] in self?.filter(provider.id, favorites: false) }
    }
  }

  private func filter(_ id: String?, favorites: Bool) {
    instanceID = id
    favoritesOnly = favorites
    search.stringValue = ""
    rebuildRail()
    reloadResults(resetSelection: true)
    view.window?.makeFirstResponder(search)
  }

  private func reloadResults(resetSelection: Bool = false) {
    let oldID: ModelIdentity? = {
      guard rows.indices.contains(table.selectedRow),
        case .model(let choice) = rows[table.selectedRow]
      else { return nil }
      return choice.id
    }()
    preferences = ModelPickerPreferences(environment: environment)
    favorites = preferences.favorites
    var matches = index.results(
      query: search.stringValue, instanceID: favoritesOnly ? nil : instanceID,
      favoritesOnly: favoritesOnly, favorites: favorites
    )
    .filter { !preferences.hidden.contains($0.id) || $0.model.custom }
    if search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let positions = Dictionary(
        uniqueKeysWithValues: catalog.providers.flatMap { provider in
          preferences.models(provider.models, instanceID: provider.id).enumerated().map {
            (ModelIdentity(instanceID: provider.id, modelID: $0.element.id), $0.offset)
          }
        })
      let providers = Dictionary(
        uniqueKeysWithValues: catalog.providers.enumerated().map { ($0.element.id, $0.offset) })
      matches = matches.enumerated().sorted { a, b in
        let left = (
          providers[a.element.provider.id] ?? Int.max, positions[a.element.id] ?? Int.max, a.offset
        )
        let right = (
          providers[b.element.provider.id] ?? Int.max, positions[b.element.id] ?? Int.max, b.offset
        )
        return left < right
      }.map(\.element)
    }
    let searching = !search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    if !searching && !favoritesOnly, let instanceID {
      rows = matches.filter { !$0.model.legacy }.map(Row.model)
      let legacy = matches.filter { $0.model.legacy }
      if !legacy.isEmpty {
        rows.append(.legacy(legacy.count))
        if expandedLegacy.contains(instanceID) { rows += legacy.map(Row.model) }
      }
    } else {
      rows = matches.map(Row.model)
    }
    table.reloadData()
    let selectedID =
      resetSelection ? nil : oldID ?? store.selectedThread.map { ModelIdentity($0.model) }
    let selected =
      selectedID.flatMap { identity in
        rows.firstIndex {
          if case .model(let choice) = $0 { return choice.id == identity }
          return false
        }
      } ?? (rows.isEmpty ? -1 : 0)
    table.selectRowIndexes(
      selected < 0 ? [] : IndexSet(integer: selected), byExtendingSelection: false)
    if selected >= 0 { table.scrollRowToVisible(selected) }
    updateFooter()
  }

  private func updateFooter() {
    if rows.isEmpty {
      footer.stringValue =
        favoritesOnly && search.stringValue.isEmpty
        ? "Star a model to add it to Favorites." : "No matching models."
    } else if rows.indices.contains(table.selectedRow),
      case .model(let choice) = rows[table.selectedRow]
    {
      footer.stringValue =
        store.modelDisabledReason(choice) ?? "↑ ↓ to browse · Return to select · Esc to close"
    } else {
      footer.stringValue = "Return to show or hide legacy models"
    }
  }

  func controlTextDidChange(_ obj: Notification) { reloadResults(resetSelection: true) }
  func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector)
    -> Bool
  {
    switch commandSelector {
    case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
      guard !rows.isEmpty else { return true }
      let delta = commandSelector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
      let next = max(0, min(rows.count - 1, table.selectedRow + delta))
      table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
      table.scrollRowToVisible(next)
      return true
    case #selector(NSResponder.insertNewline(_:)):
      chooseSelected()
      return true
    case #selector(NSResponder.cancelOperation(_:)):
      close()
      return true
    default: return false
    }
  }
  func tableViewSelectionDidChange(_ notification: Notification) { updateFooter() }
  func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
  @objc private func clicked() { if table.clickedRow >= 0 { chooseSelected() } }

  private func chooseSelected() {
    guard rows.indices.contains(table.selectedRow) else { return }
    switch rows[table.selectedRow] {
    case .legacy:
      guard let instanceID else { return }
      let selectedRow = table.selectedRow
      if !expandedLegacy.insert(instanceID).inserted { expandedLegacy.remove(instanceID) }
      reloadResults()
      table.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
      table.scrollRowToVisible(selectedRow)
    case .model(let choice):
      guard store.selectedID == threadID, store.environmentKey == environment,
        store.modelDisabledReason(choice) == nil,
        let provider = store.catalog.providers.first(where: { $0.id == choice.provider.id }),
        let model = provider.models.first(where: { $0.id == choice.model.id })
      else {
        refresh()
        return
      }
      let previous = store.selectedThread?.model
      close()
      store.setModel(
        model.selection(
          instanceID: provider.id,
          preserving: previous?["instanceId"].string == provider.id ? previous : nil,
          planModeEnabled: store.catalog.planModeEnabled))
    }
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    let cell = NSView()
    switch rows[row] {
    case .legacy(let count):
      let expanded = instanceID.map { expandedLegacy.contains($0) } ?? false
      let label = NSTextField(labelWithString: "\(expanded ? "⌄" : "›") Legacy models · \(count)")
      label.font = .systemFont(ofSize: 12)
      cell.addSubview(label)
      label.frame = NSRect(x: 10, y: 15, width: table.bounds.width - 20, height: 20)
      label.autoresizingMask = [.width]
    case .model(let choice):
      let title = NSTextField(
        labelWithString: choice.model.name + (choice.model.badge == "new" ? "  NEW" : ""))
      title.font = .systemFont(ofSize: 14, weight: .regular)
      title.textColor =
        store.modelDisabledReason(choice) == nil ? .labelColor : .secondaryLabelColor
      title.lineBreakMode = .byTruncatingTail
      let detail = NSTextField(
        labelWithString: choice.provider.name
          + (choice.model.subProvider.map { " · " + $0 } ?? "")
          + (choice.model.legacy ? " · Legacy" : choice.model.custom ? " · Custom" : ""))
      detail.font = .systemFont(ofSize: 12)
      detail.textColor = .secondaryLabelColor
      detail.lineBreakMode = .byTruncatingTail
      let favorite = favorites.contains(choice.id)
      let star = ActionButton("") { [weak self] in
        guard let self else { return }
        if !self.favorites.insert(choice.id).inserted { self.favorites.remove(choice.id) }
        self.preferences.favorites = self.favorites
        try? self.preferences.save(environment: self.environment)
        self.reloadResults()
      }
      star.isBordered = false
      star.image = NSImage(
        systemSymbolName: favorite ? "star.fill" : "star", accessibilityDescription: nil)
      star.setAccessibilityLabel(
        (favorite ? "Unfavorite " : "Favorite ") + choice.model.name + " · " + choice.provider.name)
      cell.toolTip = store.modelDisabledReason(choice) ?? choice.model.id
      let labels = NSStackView(views: [title, detail])
      labels.orientation = .vertical
      labels.alignment = .leading
      labels.spacing = 5
      cell.addSubview(labels)
      cell.addSubview(star)
      labels.translatesAutoresizingMaskIntoConstraints = false
      star.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        labels.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
        labels.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        labels.trailingAnchor.constraint(equalTo: star.leadingAnchor, constant: -6),
        title.widthAnchor.constraint(equalTo: labels.widthAnchor),
        detail.widthAnchor.constraint(equalTo: labels.widthAnchor),
        star.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
        star.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        star.widthAnchor.constraint(equalToConstant: 22),
      ])
    }
    return cell
  }

  func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    ModelSelectionRow()
  }
}

@MainActor private final class ModelSelectionRow: NSTableRowView {
  override func drawSelection(in dirtyRect: NSRect) {
    NSColor.labelColor.withAlphaComponent(0.08).setFill()
    NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 9, yRadius: 9).fill()
  }
  override var isEmphasized: Bool {
    get { false }
    set {}
  }
}

@MainActor private final class ModelAccountButton: NSButton {
  let selectedAccount: Bool
  let invoke: () -> Void
  init(_ badge: String, selected: Bool, action: @escaping () -> Void) {
    selectedAccount = selected
    invoke = action
    super.init(frame: .zero)
    title = badge
    font = .systemFont(ofSize: 8, weight: .semibold)
    imagePosition = badge.isEmpty ? .imageOnly : .imageAbove
    isBordered = false
    contentTintColor = selected ? .labelColor : .secondaryLabelColor
    symbolConfiguration = .init(pointSize: 23, weight: .regular)
    target = self
    self.action = #selector(choose)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  @objc private func choose() { invoke() }
  override func draw(_ dirtyRect: NSRect) {
    if selectedAccount {
      NSColor.controlAccentColor.setFill()
      NSBezierPath(
        roundedRect: NSRect(x: bounds.maxX - 3, y: 7, width: 3, height: bounds.height - 14),
        xRadius: 1.5, yRadius: 1.5
      ).fill()
    }
    super.draw(dirtyRect)
  }
}
