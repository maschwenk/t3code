import AppKit

@MainActor final class ConnectionWelcomeView: NSStackView {
  var onPrimary: (() -> Void)?
  var onSecondary: (() -> Void)?
  private let title = NSTextField(labelWithString: "")
  private let detail = NSTextField(wrappingLabelWithString: "")
  private lazy var primary = ActionButton("") { [weak self] in self?.onPrimary?() }
  private lazy var secondary = ActionButton("") { [weak self] in self?.onSecondary?() }

  init() {
    super.init(frame: .zero)
    orientation = .vertical
    alignment = .centerX
    spacing = 16
    setAccessibilityIdentifier("connection-welcome")
    let icon = NSImageView(
      image: NSImage(
        systemSymbolName: "bubble.left.and.bubble.right", accessibilityDescription: nil)!)
    icon.symbolConfiguration = .init(pointSize: 30, weight: .light)
    icon.contentTintColor = .tertiaryLabelColor
    title.font = .systemFont(ofSize: 22, weight: .semibold)
    title.alignment = .center
    detail.font = .systemFont(ofSize: 13)
    detail.textColor = .secondaryLabelColor
    detail.alignment = .center
    primary.controlSize = .large
    primary.keyEquivalent = ""
    secondary.bezelStyle = .inline
    secondary.isBordered = false
    secondary.font = .systemFont(ofSize: 12)
    secondary.contentTintColor = .secondaryLabelColor
    let actions = NSStackView(views: [primary, secondary])
    actions.orientation = .vertical
    actions.spacing = 10
    for view in [icon, title, detail, actions] { addArrangedSubview(view) }
    detail.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    setCustomSpacing(22, after: icon)
    setCustomSpacing(24, after: detail)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func refresh(_ store: ClientStore) {
    if store.ready {
      title.stringValue = "Start a conversation"
      detail.stringValue = "Choose a project or start a new thread to get to work."
      primary.title = "New thread"
      primary.isEnabled = store.canCreateThread
      secondary.title = "Open project…"
      secondary.isHidden = false
      secondary.isEnabled = store.catalogReady
    } else {
      title.stringValue = store.hasConnection ? "Connecting to T3" : "Connect to T3"
      detail.stringValue =
        store.hasConnection
        ? "Your conversations will appear when the server is connected."
        : "Connect to your T3 server to pick up your conversations, projects, and models."
      if let error = store.error {
        title.stringValue = "Connect to T3"
        detail.stringValue = error
      }
      primary.title = store.hasConnection ? "Try again" : "Connect to server…"
      primary.isEnabled = true
      secondary.title = "Choose another server…"
      secondary.isHidden = !store.hasConnection
    }
  }
}
