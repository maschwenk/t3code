import AppKit

@MainActor final class WorkspaceSaveSheet: NSWindowController {
  private let path = ActionTextField()
  private let errorLabel = NSTextField(wrappingLabelWithString: "")
  private let saveButton = NSButton(title: "Save", target: nil, action: nil)
  private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
  private let write: (String) async throws -> String
  private let saved: (String) -> Void
  private let closed: (String) -> Void
  private var task: Task<Void, Never>?

  init(
    root: String, path initialPath: String, write: @escaping (String) async throws -> String,
    saved: @escaping (String) -> Void, closed: @escaping (String) -> Void
  ) {
    self.write = write
    self.saved = saved
    self.closed = closed
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 240),
      styleMask: [.titled], backing: .buffered, defer: false)
    panel.title = "Save plan to workspace"
    super.init(window: panel)
    let explanation = NSTextField(wrappingLabelWithString: "Enter a path relative to \(root).")
    explanation.font = .systemFont(ofSize: 12)
    explanation.textColor = .secondaryLabelColor
    explanation.isSelectable = true
    path.stringValue = initialPath
    path.placeholderString = "plans/plan.md"
    path.setAccessibilityLabel("Workspace path")
    path.changed = { [weak self] _ in self?.updateButtons() }
    errorLabel.textColor = .systemRed
    errorLabel.font = .systemFont(ofSize: 12)
    errorLabel.isHidden = true
    saveButton.target = self
    saveButton.action = #selector(save)
    saveButton.keyEquivalent = "\r"
    cancelButton.target = self
    cancelButton.action = #selector(cancel)
    cancelButton.keyEquivalent = "\u{1b}"
    let actions = NSStackView(views: [NSView(), cancelButton, saveButton])
    actions.spacing = 8
    let stack = NSStackView(views: [explanation, path, errorLabel, NSView(), actions])
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
      path.heightAnchor.constraint(equalToConstant: 26),
    ])
    for view in [explanation, path, errorLabel, actions] {
      view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    updateButtons()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func present(on parent: NSWindow) {
    guard let window else { return }
    parent.beginSheet(window) { [weak self] _ in
      guard let self else { return }
      closed(path.stringValue)
    }
    window.makeFirstResponder(path)
    path.selectText(nil)
  }
  private func updateButtons() {
    saveButton.isEnabled =
      task == nil && !path.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    saveButton.title = task == nil ? "Save" : "Saving…"
    cancelButton.isEnabled = task == nil
    path.isEditable = task == nil
  }
  @objc private func save() {
    guard task == nil, saveButton.isEnabled else { return }
    let relativePath = path.stringValue
    errorLabel.isHidden = true
    task = Task { [self] in
      do {
        let result = try await write(relativePath)
        saved(result)
        if let window { window.sheetParent?.endSheet(window, returnCode: .OK) }
      } catch {
        errorLabel.stringValue = error.localizedDescription
        errorLabel.isHidden = false
      }
      task = nil
      updateButtons()
    }
    updateButtons()
  }
  @objc private func cancel() {
    guard task == nil, let window else { return }
    window.sheetParent?.endSheet(window, returnCode: .cancel)
  }
}
