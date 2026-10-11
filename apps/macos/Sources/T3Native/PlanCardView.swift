import AppKit
import T3Core
import T3Markdown

@MainActor struct PlanCardLayout {
  let document: PlanDocument
  let rendered: RenderedMarkdown
  let width: CGFloat
  let textHeight: CGFloat
  let bodyHeight: CGFloat
  let expanded: Bool
  var height: CGFloat { 94 + bodyHeight + (document.canCollapse ? 44 : 0) }

  init(markdown: String, width: CGFloat, expanded: Bool, resolveLink: ((String) -> URL?)? = nil) {
    document = PlanDocument(markdown)
    self.width = max(120, width - 64)
    self.expanded = expanded
    let text = document.canCollapse && !expanded ? document.preview : document.body
    rendered = MarkdownRenderer.render(
      text, width: self.width, headingLevelOffset: 3, resolveLink: resolveLink)
    textHeight = max(20, MarkdownRenderer.height(of: rendered.text, width: self.width))
    bodyHeight = document.canCollapse && !expanded ? min(416, textHeight) : textHeight
  }
}

@MainActor final class PlanCardView: NSView {
  init(
    layout: PlanCardLayout, inherited: Bool, canSave: Bool,
    toggle: @escaping () -> Void, copy: @escaping () -> Void,
    download: @escaping () -> Void, save: @escaping () -> Void,
    openLink: @escaping (URL) -> Void, fileLinkMenu: ((URL) -> NSMenu?)? = nil
  ) {
    super.init(frame: .zero)
    let surface = SurfaceView(raised: true)
    surface.layer?.cornerRadius = 24
    addSubview(surface)
    surface.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      surface.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      surface.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      surface.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      surface.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
    ])
    let badge = NSTextField(labelWithString: "Plan")
    badge.font = .systemFont(ofSize: 11, weight: .medium)
    badge.textColor = .secondaryLabelColor
    let title = NSTextField(
      labelWithString: layout.document.title + (inherited ? " · inherited" : ""))
    title.font = .systemFont(ofSize: 14, weight: .medium)
    title.lineBreakMode = .byTruncatingTail
    title.toolTip = title.stringValue
    title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let actions = NSPopUpButton(frame: .zero, pullsDown: true)
    actions.bezelStyle = .inline
    actions.addItem(withTitle: "")
    actions.item(at: 0)?.image = NSImage(
      systemSymbolName: "ellipsis", accessibilityDescription: nil)
    actions.setAccessibilityLabel("Plan actions")
    actions.toolTip = "Plan actions"
    actions.menu?.autoenablesItems = false
    actions.menu?.addItem(ActionMenuItem("Copy to clipboard", action: copy))
    actions.menu?.addItem(ActionMenuItem("Download as markdown", action: download))
    let saveItem = ActionMenuItem("Save to workspace", action: save)
    saveItem.isEnabled = canSave
    actions.menu?.addItem(saveItem)
    let header = NSStackView(views: [badge, title, NSView(), actions])
    header.spacing = 8
    let body = PlanBodyView(layout: layout, openLink: openLink, fileLinkMenu: fileLinkMenu)
    let stack = NSStackView(views: [header, body])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 16
    if layout.document.canCollapse {
      let footer = NSView()
      let button = ActionButton(layout.expanded ? "Collapse plan" : "Expand plan", action: toggle)
      button.bezelStyle = .rounded
      button.controlSize = .small
      button.setAccessibilityLabel(button.title)
      footer.addSubview(button)
      button.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        button.centerXAnchor.constraint(equalTo: footer.centerXAnchor),
        button.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
        button.heightAnchor.constraint(equalToConstant: 28),
        footer.heightAnchor.constraint(equalToConstant: 28),
      ])
      stack.addArrangedSubview(footer)
      footer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    surface.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 20),
      stack.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -20),
      stack.topAnchor.constraint(equalTo: surface.topAnchor, constant: 20),
      header.widthAnchor.constraint(equalTo: stack.widthAnchor),
      header.heightAnchor.constraint(equalToConstant: 22),
      body.widthAnchor.constraint(equalTo: stack.widthAnchor),
      body.heightAnchor.constraint(equalToConstant: layout.bodyHeight),
    ])
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor private final class PlanBodyView: NSView {
  private let fade: CAGradientLayer?
  init(layout: PlanCardLayout, openLink: @escaping (URL) -> Void, fileLinkMenu: ((URL) -> NSMenu?)?)
  {
    fade = layout.document.canCollapse && !layout.expanded ? CAGradientLayer() : nil
    super.init(frame: .zero)
    wantsLayer = true
    layer?.masksToBounds = true
    if let fade {
      fade.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
      fade.startPoint = CGPoint(x: 0.5, y: 1)
      fade.endPoint = CGPoint(x: 0.5, y: 0)
      layer?.mask = fade
    }
    let text = MessageTextView(
      rendered: layout.rendered, width: layout.width, height: layout.textHeight)
    text.onOpenLink = openLink
    text.fileLinkMenu = fileLinkMenu
    text.setAccessibilityLabel("Plan content")
    addSubview(text)
    text.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      text.leadingAnchor.constraint(equalTo: leadingAnchor),
      text.trailingAnchor.constraint(equalTo: trailingAnchor),
      text.topAnchor.constraint(equalTo: topAnchor),
      text.heightAnchor.constraint(equalToConstant: layout.textHeight),
    ])
  }
  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    fade?.frame = bounds
    fade?.locations = [0, NSNumber(value: max(0, 1 - 96 / max(1, Double(bounds.height)))), 1]
    CATransaction.commit()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
