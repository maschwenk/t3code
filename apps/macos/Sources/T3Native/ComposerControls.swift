import AppKit
import T3Core

@MainActor final class ActionButton: NSButton {
  var invoke: () -> Void
  init(_ title: String, action: @escaping () -> Void) {
    invoke = action
    super.init(frame: .zero)
    self.title = title
    bezelStyle = .rounded
    target = self
    self.action = #selector(performAction)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  @objc private func performAction() {
    guard isEnabled else { return }
    invoke()
  }
}

@MainActor final class ActionMenuItem: NSMenuItem {
  let invoke: () -> Void
  init(_ title: String, action: @escaping () -> Void) {
    invoke = action
    super.init(title: title, action: #selector(performAction), keyEquivalent: "")
    target = self
  }
  required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  @objc private func performAction() {
    guard isEnabled else { return }
    invoke()
  }
}

@MainActor final class ActionTextField: NSTextField, NSTextFieldDelegate {
  var changed: ((String) -> Void)?
  override init(frame: NSRect) {
    super.init(frame: frame)
    delegate = self
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  func controlTextDidChange(_ obj: Notification) { changed?(stringValue) }
}

@MainActor final class ComposerControls: NSStackView, NSPopoverDelegate {
  private let store: ClientStore
  private var fingerprint = ""
  private var previousCatalog = ProviderCatalog()
  private var popover: NSPopover?
  private weak var previousResponder: NSResponder?
  private struct Presentation {
    let pill: ComposerPill
    let full: String
    let compact: String
    let primary: Bool
  }
  private var presentations: [Presentation] = []
  private var separators: [NSView] = []
  private var overflow: ComposerPill?
  private var fullWidth: CGFloat = 0
  private var compactWidth: CGFloat = 0
  private var layoutMode = -1
  var minimumCompactWidth: CGFloat {
    let count = presentations.filter(\.primary).count + (overflow == nil ? 0 : 1)
    return CGFloat(count) * 36 + CGFloat(max(0, count - 1)) * 6
  }
  init(store: ClientStore) {
    self.store = store
    super.init(frame: .zero)
    orientation = .horizontal
    alignment = .centerY
    spacing = 9
    setHuggingPriority(.defaultLow, for: .horizontal)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func refresh() {
    let selected = store.selectedThread
    let enabled =
      store.canEditThread && store.catalogReady && (!store.isNewConversation || !store.composerBusy)
    let fingerprint =
      "\(store.environmentKey)|\(store.projectSessionID)|\(selected?.id ?? "")|\(selected?.model ?? .null)|\(selected?.runtimeMode ?? "")|\(selected?.interactionMode ?? "")|\(enabled)"
    guard fingerprint != self.fingerprint || store.catalog != previousCatalog else {
      (popover?.contentViewController as? ModelPicker)?.refresh()
      return
    }
    popover?.performClose(nil)
    self.fingerprint = fingerprint
    previousCatalog = store.catalog
    for view in arrangedSubviews {
      removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    presentations = []
    separators = []
    overflow = nil
    layoutMode = -1
    guard let selected else { return }
    let provider = store.catalog.provider(for: selected.model)
    let model = ComposerPill(
      store.catalog.model(for: selected.model)?.name ?? selected.model["model"].string
        ?? "Choose model"
    ) { [weak self] in self?.showModels() }
    model.image = provider.flatMap { ProviderArtwork.accountImage($0) }
    model.contentTintColor = .secondaryLabelColor
    model.setAccessibilityLabel("Model")
    model.toolTip = [
      provider?.name,
      store.catalog.model(for: selected.model)?.name ?? selected.model["model"].string,
    ].compactMap { $0 }.joined(separator: " — ")
    model.isEnabled = enabled
    model.widthAnchor.constraint(lessThanOrEqualToConstant: 240).isActive = true
    addArrangedSubview(model)
    presentations.append(
      Presentation(
        pill: model, full: model.title.replacingOccurrences(of: "  ⌄", with: ""),
        compact: store.catalog.model(for: selected.model)?.shortName ?? "Model", primary: true))
    var hasReasoning = false
    for descriptor in store.catalog.descriptors(for: selected.model) {
      guard let id = descriptor["id"].string else { continue }
      let stored = selected.model["options"].array.first { $0["id"].string == id }?["value"]
      let value = stored ?? descriptor["currentValue"]
      let label = descriptor["label"].string ?? id
      let control: ComposerPill
      if descriptor["type"].string == "boolean" {
        control = ComposerPill(label, symbol: value.bool ? "checkmark.circle" : "circle") {
          [weak store] in
          store?.setModelOption(id, value: .bool(!value.bool))
        }
      } else {
        let options = descriptor["options"].array
        let current = options.first { $0["id"] == value } ?? options.first { $0["isDefault"].bool }
        control = ComposerPill(
          current?["label"].string ?? label,
          symbol: id.lowercased().contains("reason") || id == "effort"
            ? "brain" : "slider.horizontal.3", action: {})
        control.invoke = { [weak self, weak control, weak store] in
          guard let self, let control else { return }
          showOptions(
            label,
            options: options.map { option in
              ComposerOption(
                title: option["label"].string ?? option["id"].string ?? "",
                description: option["description"].string,
                selected: option["id"] == current?["id"],
                badge: option["isDefault"].bool ? "Default" : nil,
                action: { [weak store] in store?.setModelOption(id, value: option["id"]) })
            }, width: 210, anchor: control)
        }
      }
      addSeparator()
      control.isEnabled = enabled
      control.setAccessibilityLabel(label)
      control.toolTip =
        label + ": " + control.title.replacingOccurrences(of: "  ⌄", with: "")
        + (descriptor["description"].string.map { " — " + $0 } ?? "")
      addArrangedSubview(control)
      let reasoning =
        !hasReasoning
        && (id.lowercased().contains("reason") || id == "effort"
          || id.lowercased().contains("thinking"))
      hasReasoning = hasReasoning || reasoning
      presentations.append(
        Presentation(
          pill: control, full: control.title.replacingOccurrences(of: "  ⌄", with: ""),
          compact: control.title.replacingOccurrences(of: "  ⌄", with: ""), primary: reasoning))
    }
    addSeparator()
    let runtime = ComposerPill(
      Self.modeLabel(selected.runtimeMode),
      symbol: selected.runtimeMode == "full-access" ? "lock.open" : "lock", action: {})
    runtime.setAccessibilityLabel("Permissions")
    runtime.toolTip = Self.modeLabel(selected.runtimeMode)
    runtime.isEnabled = enabled
    runtime.invoke = { [weak self, weak runtime, weak store] in
      guard let self, let runtime else { return }
      let modes = provider?.runtimeModes ?? []
      showOptions(
        nil,
        options: (modes.isEmpty ? ["approval-required", "full-access"] : modes).map { mode in
          ComposerOption(
            title: Self.modeLabel(mode), description: Self.modeDescription(mode),
            symbol: Self.modeSymbol(mode), selected: mode == selected.runtimeMode,
            action: { [weak store] in store?.setRuntimeMode(mode) })
        }, width: 420, anchor: runtime)
    }
    addArrangedSubview(runtime)
    let compactRuntime =
      selected.runtimeMode == "full-access"
      ? "Access"
      : selected.runtimeMode == "approval-required"
        ? "Ask" : selected.runtimeMode == "auto-accept-edits" ? "Edits" : "Auto"
    presentations.append(
      Presentation(
        pill: runtime, full: Self.modeLabel(selected.runtimeMode), compact: compactRuntime,
        primary: true))
    if store.catalog.planModeEnabled, provider?.showInteractionMode == true {
      let plan = ComposerPill(
        selected.interactionMode == "plan" ? "Plan" : "Build", symbol: "list.bullet.clipboard"
      ) { [weak store] in
        store?.setInteractionMode(selected.interactionMode == "plan" ? "default" : "plan")
      }
      plan.isEnabled = enabled
      plan.setAccessibilityLabel("Interaction mode")
      plan.toolTip = selected.interactionMode == "plan" ? "Plan" : "Build"
      addArrangedSubview(plan)
      presentations.append(
        Presentation(
          pill: plan, full: selected.interactionMode == "plan" ? "Plan" : "Build", compact: "",
          primary: false))
    }
    if presentations.contains(where: { !$0.primary }) {
      let more = ComposerPill("", symbol: "ellipsis") { [weak self] in self?.showOverflow() }
      more.setAccessibilityLabel("More conversation options")
      more.toolTip = "More conversation options"
      more.isEnabled = enabled
      addArrangedSubview(more)
      overflow = more
    }
    fullWidth =
      presentations.reduce(0) {
        $0
          + min(
            $1.pill === model ? 240 : CGFloat.greatestFiniteMagnitude,
            max(36, $1.pill.intrinsicContentSize.width))
      }
      + CGFloat(separators.count) + CGFloat(max(0, presentations.count + separators.count - 1)) * 9
    compactWidth =
      presentations.filter(\.primary).reduce(0) { result, item in
        item.pill.displayLabel(item.compact)
        return result + max(36, item.pill.intrinsicContentSize.width)
      } + (overflow == nil ? 0 : 36)
      + CGFloat(max(0, presentations.filter(\.primary).count + (overflow == nil ? 0 : 1) - 1)) * 6
    adaptLayout()
    needsLayout = true
  }

  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    for name in [NSView.frameDidChangeNotification, NSView.boundsDidChangeNotification] {
      NotificationCenter.default.removeObserver(self, name: name, object: nil)
    }
    guard let row = superview as? NSStackView else { return }
    row.postsFrameChangedNotifications = true
    row.postsBoundsChangedNotifications = true
    for name in [NSView.frameDidChangeNotification, NSView.boundsDidChangeNotification] {
      NotificationCenter.default.addObserver(
        self, selector: #selector(rowGeometryChanged), name: name, object: row)
    }
    needsLayout = true
  }

  @objc private func rowGeometryChanged(_ notification: Notification) {
    // The spacer can absorb a resize without changing our frame.
    needsLayout = true
  }

  override func layout() {
    adaptLayout()
    super.layout()
  }

  private func adaptLayout() {
    guard !presentations.isEmpty else { return }
    var available = bounds.width
    if let row = superview as? NSStackView, row.orientation == .horizontal,
      row.arrangedSubviews.contains(self)
    {
      // Use the row's budget: our intrinsic width shrinks when labels hide, while its spacer grows.
      let siblings = row.arrangedSubviews.filter { $0 !== self && !$0.isHidden }
      available =
        row.bounds.width - row.edgeInsets.left - row.edgeInsets.right
        - siblings.reduce(0) { $0 + max(0, $1.fittingSize.width) }
        - CGFloat(siblings.count) * row.spacing
    }
    let mode = available <= 0 || available >= fullWidth ? 0 : available >= compactWidth ? 1 : 2
    guard mode != layoutMode else { return }
    layoutMode = mode
    spacing = mode == 0 ? 9 : 6
    for item in presentations {
      item.pill.isHidden = mode != 0 && !item.primary
      item.pill.displayLabel(mode == 0 ? item.full : mode == 1 ? item.compact : "")
      // Some providers have no artwork. An icon-only model control still needs a visible affordance.
      if item.pill === presentations.first?.pill, item.pill.image == nil {
        item.pill.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: nil)
      }
    }
    for separator in separators { separator.isHidden = mode != 0 }
    overflow?.isHidden = mode == 0
  }

  func overflowMenu() -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    guard let selected = store.selectedThread else { return menu }
    let enabled =
      store.canEditThread && store.catalogReady && (!store.isNewConversation || !store.composerBusy)
    for descriptor in store.catalog.descriptors(for: selected.model) {
      guard let id = descriptor["id"].string else { continue }
      let label = descriptor["label"].string ?? id
      let value =
        selected.model["options"].array.first { $0["id"].string == id }?["value"]
        ?? descriptor["currentValue"]
      if descriptor["type"].string == "boolean" {
        let item = ActionMenuItem(label) { [weak store] in
          store?.setModelOption(id, value: .bool(!value.bool))
        }
        item.state = value.bool ? .on : .off
        item.isEnabled = enabled
        menu.addItem(item)
      } else {
        let group = NSMenuItem(title: label, action: nil, keyEquivalent: "")
        let options = NSMenu()
        options.autoenablesItems = false
        for option in descriptor["options"].array {
          let item = ActionMenuItem(option["label"].string ?? option["id"].string ?? "") {
            [weak store] in store?.setModelOption(id, value: option["id"])
          }
          item.state = option["id"] == value ? .on : .off
          item.toolTip = option["description"].string
          item.isEnabled = enabled
          options.addItem(item)
        }
        group.submenu = options
        group.isEnabled = enabled
        menu.addItem(group)
      }
    }
    if store.catalog.planModeEnabled,
      store.catalog.provider(for: selected.model)?.showInteractionMode == true
    {
      let item = ActionMenuItem("Plan mode") { [weak store] in
        store?.setInteractionMode(selected.interactionMode == "plan" ? "default" : "plan")
      }
      item.state = selected.interactionMode == "plan" ? .on : .off
      item.isEnabled = enabled
      menu.addItem(item)
    }
    return menu
  }

  private func showOverflow() {
    guard store.canEditThread, store.catalogReady, let overflow else { return }
    overflowMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: overflow.bounds.maxY), in: overflow)
  }

  private func addSeparator() {
    let line = NSBox()
    line.boxType = .separator
    line.widthAnchor.constraint(equalToConstant: 1).isActive = true
    line.heightAnchor.constraint(equalToConstant: 16).isActive = true
    addArrangedSubview(line)
    separators.append(line)
  }

  private func showOptions(
    _ heading: String?, options: [ComposerOption], width: CGFloat, anchor: NSView
  ) {
    popover?.performClose(nil)
    previousResponder = window?.firstResponder
    let next = NSPopover()
    next.behavior = .transient
    next.delegate = self
    let controller = ComposerOptionsPopover(heading, options: options, width: width) {
      [weak self] in
      self?.popover?.performClose(nil)
    }
    next.contentViewController = controller
    next.contentSize = controller.contentSize
    popover = next
    next.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
  }

  func showModels() {
    if popover?.isShown == true {
      popover?.performClose(nil)
      return
    }
    guard store.canEditThread, store.catalogReady, let anchor = arrangedSubviews.first else {
      return
    }
    previousResponder = window?.firstResponder
    let next = NSPopover()
    next.behavior = .transient
    next.delegate = self
    next.contentViewController = ModelPicker(store: store) { [weak self] in
      self?.popover?.performClose(nil)
    }
    next.contentSize = NSSize(width: 440, height: 340)
    popover = next
    next.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
  }

  func popoverDidClose(_ notification: Notification) {
    popover = nil
    fingerprint = ""
    refresh()
    if let previousResponder { window?.makeFirstResponder(previousResponder) }
  }
  static func modeLabel(_ mode: String) -> String {
    switch mode {
    case "approval-required": "Supervised"
    case "auto-accept-edits": "Auto-accept edits"
    case "auto": "Auto"
    case "full-access": "Full access"
    default: mode
    }
  }
  static func modeDescription(_ mode: String) -> String? {
    switch mode {
    case "approval-required": "Ask before commands and file changes."
    case "auto-accept-edits": "Auto-approve edits, ask before other actions."
    case "auto": "Supported providers approve routine actions; others still ask."
    case "full-access": "Allow commands and edits without prompts."
    default: nil
    }
  }
  static func modeSymbol(_ mode: String) -> String {
    switch mode {
    case "auto-accept-edits": "pencil"
    case "auto": "sparkles"
    case "full-access": "lock.open"
    default: "lock"
    }
  }
}
