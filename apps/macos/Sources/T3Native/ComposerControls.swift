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
  @objc private func performAction() { invoke() }
}

@MainActor final class ActionMenuItem: NSMenuItem {
  let invoke: () -> Void
  init(_ title: String, action: @escaping () -> Void) {
    invoke = action
    super.init(title: title, action: #selector(performAction), keyEquivalent: "")
    target = self
  }
  required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  @objc private func performAction() { invoke() }
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
  private var fingerprint: String = ""
  private var previousCatalog = ProviderCatalog()
  private var modelPopover: NSPopover?
  private weak var previousResponder: NSResponder?
  init(store: ClientStore) {
    self.store = store
    super.init(frame: .zero)
    orientation = .horizontal
    alignment = .centerY
    spacing = 6
    setHuggingPriority(.defaultLow, for: .horizontal)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func refresh() {
    if modelPopover?.isShown == true {
      (modelPopover?.contentViewController as? ModelPicker)?.refresh()
      return
    }
    let selected = store.selectedThread
    let enabled = store.canEditThread && store.catalogReady
    let fingerprint =
      "\(selected?.id ?? "")|\(selected?.model ?? .null)|\(selected?.runtimeMode ?? "")|\(selected?.interactionMode ?? "")|\(enabled)"
    guard fingerprint != self.fingerprint || store.catalog != previousCatalog else { return }
    self.fingerprint = fingerprint
    previousCatalog = store.catalog
    for view in arrangedSubviews {
      removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    guard let selected else { return }
    let model = ActionButton(
      store.catalog.model(for: selected.model)?.name ?? selected.model["model"].string
        ?? "Choose model"
    ) { [weak self] in self?.showModels() }
    model.setAccessibilityLabel("Model")
    model.toolTip = store.catalog.provider(for: selected.model)?.name
    model.isEnabled = enabled
    addArrangedSubview(model)
    for descriptor in store.catalog.descriptors(for: selected.model) {
      guard let id = descriptor["id"].string else { continue }
      let stored = selected.model["options"].array.first { $0["id"].string == id }?["value"]
      let value = stored ?? descriptor["currentValue"]
      let label = descriptor["label"].string ?? id
      let control: ActionButton
      if descriptor["type"].string == "boolean" {
        control = ActionButton(label) { [weak store] in
          store?.setModelOption(id, value: .bool(!value.bool))
        }
        control.setButtonType(.switch)
        control.state = value.bool ? .on : .off
      } else {
        let options = descriptor["options"].array
        let current = options.first { $0["id"] == value } ?? options.first { $0["isDefault"].bool }
        control = ActionButton(current?["label"].string ?? label, action: {})
        control.invoke = { [weak store, weak control] in
          let menu = NSMenu()
          for option in options {
            let item = ActionMenuItem(option["label"].string ?? option["id"].string ?? "") {
              [weak store] in store?.setModelOption(id, value: option["id"])
            }
            item.state = option["id"] == current?["id"] ? .on : .off
            item.toolTip = option["description"].string
            menu.addItem(item)
          }
          if let control {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: control.bounds.height), in: control)
          }
        }
      }
      control.isEnabled = enabled
      control.setAccessibilityLabel(label)
      control.toolTip = descriptor["description"].string ?? label
      addArrangedSubview(control)
    }
    let runtime = ActionButton(Self.modeLabel(selected.runtimeMode), action: {})
    runtime.setAccessibilityLabel("Runtime mode")
    runtime.isEnabled = enabled
    runtime.invoke = { [weak store, weak runtime] in
      guard let store else { return }
      let modes = store.catalog.provider(for: selected.model)?.runtimeModes ?? []
      let menu = NSMenu()
      for mode in modes.isEmpty ? ["approval-required", "full-access"] : modes {
        let item = ActionMenuItem(Self.modeLabel(mode)) { [weak store] in
          store?.setRuntimeMode(mode)
        }
        item.state = mode == selected.runtimeMode ? .on : .off
        menu.addItem(item)
      }
      if let runtime {
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: runtime.bounds.height), in: runtime)
      }
    }
    addArrangedSubview(runtime)
    if store.catalog.planModeEnabled,
      store.catalog.provider(for: selected.model)?.showInteractionMode == true
    {
      let plan = ActionButton("Plan") { [weak store] in
        store?.setInteractionMode(selected.interactionMode == "plan" ? "default" : "plan")
      }
      plan.setButtonType(.switch)
      plan.state = selected.interactionMode == "plan" ? .on : .off
      plan.isEnabled = enabled
      addArrangedSubview(plan)
    }
    for view in arrangedSubviews {
      if let button = view as? NSButton {
        button.bezelStyle = .inline
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
      }
    }
  }

  func showModels() {
    if modelPopover?.isShown == true {
      modelPopover?.performClose(nil)
      return
    }
    guard store.canEditThread, store.catalogReady, let anchor = arrangedSubviews.first else {
      return
    }
    previousResponder = window?.firstResponder
    let popover = NSPopover()
    popover.behavior = .transient
    popover.delegate = self
    popover.contentViewController = ModelPicker(store: store) { [weak self] in
      self?.modelPopover?.performClose(nil)
    }
    popover.contentSize = NSSize(width: 520, height: 350)
    modelPopover = popover
    popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
  }

  func popoverDidClose(_ notification: Notification) {
    modelPopover = nil
    fingerprint = ""
    refresh()
    if let previousResponder { window?.makeFirstResponder(previousResponder) }
  }

  static func modeLabel(_ mode: String) -> String {
    switch mode {
    case "approval-required": "Ask for approval"
    case "auto-accept-edits": "Accept edits"
    case "auto": "Auto"
    case "full-access": "Full access"
    default: mode
    }
  }
}
