import AppKit
import T3Core

@MainActor enum ProviderArtwork {
  private static var images: [String: NSImage] = [:]
  static func image(_ driver: String) -> NSImage? {
    if let image = images[driver] { return image }
    let ext = driver == "antigravity" ? "png" : "pdf"
    guard
      let url = Bundle.module.url(
        forResource: driver, withExtension: ext, subdirectory: "Resources/Providers"),
      let image = NSImage(contentsOf: url)
    else { return nil }
    image.isTemplate = ext == "pdf"
    image.size = NSSize(width: 18, height: 18)
    images[driver] = image
    return image
  }
  static func color(_ driver: String) -> NSColor {
    driver == "claudeAgent"
      ? NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1) : .secondaryLabelColor
  }
  static func accountImage(_ provider: ProviderEntry) -> NSImage? {
    let key = "account:" + provider.id + ":" + provider.name + ":" + provider.driver
    if let image = images[key] { return image }
    guard let artwork = image(provider.driver) else { return nil }
    let badge = provider.driver == "codex" ? "" : SidebarProviderMark.initials(provider.name)
    let combined = NSImage(size: NSSize(width: 22, height: 24), flipped: false) { _ in
      let iconRect = NSRect(x: 1, y: 6, width: 18, height: 18)
      artwork.draw(in: iconRect)
      if artwork.isTemplate {
        color(provider.driver).setFill()
        iconRect.fill(using: .sourceAtop)
      }
      if !badge.isEmpty {
        let rect = NSRect(x: 4, y: 0, width: 18, height: 10)
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        let attributes: [NSAttributedString.Key: Any] = [
          .font: NSFont.systemFont(ofSize: 7, weight: .semibold),
          .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let size = (badge as NSString).size(withAttributes: attributes)
        (badge as NSString).draw(
          at: NSPoint(x: rect.midX - size.width / 2, y: 1), withAttributes: attributes)
      }
      return true
    }
    images[key] = combined
    return combined
  }
}

@MainActor final class ComposerPill: NSButton {
  var invoke: () -> Void
  private var hover = false
  private var tracking: NSTrackingArea?
  init(_ label: String, symbol: String? = nil, height: CGFloat = 32, action: @escaping () -> Void) {
    invoke = action
    super.init(frame: .zero)
    title = label + "  ⌄"
    font = .systemFont(ofSize: 13)
    isBordered = false
    bezelStyle = .inline
    alignment = .left
    imagePosition = .imageLeading
    contentTintColor = .secondaryLabelColor
    if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    symbolConfiguration = .init(pointSize: 14, weight: .regular)
    wantsLayer = true
    layer?.cornerRadius = 8
    target = self
    self.action = #selector(performAction)
    heightAnchor.constraint(equalToConstant: height).isActive = true
    widthAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true
    setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    cell?.lineBreakMode = .byTruncatingTail
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  func displayLabel(_ label: String) { title = label.isEmpty ? "" : label + "  ⌄" }
  @objc private func performAction() {
    guard isEnabled else { return }
    invoke()
  }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    tracking = NSTrackingArea(
      rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self)
    addTrackingArea(tracking!)
  }
  override func mouseEntered(with event: NSEvent) {
    hover = true
    needsDisplay = true
  }
  override func mouseExited(with event: NSEvent) {
    hover = false
    needsDisplay = true
  }
  override func draw(_ dirtyRect: NSRect) {
    layer?.backgroundColor =
      hover && isEnabled
      ? NSColor.labelColor.withAlphaComponent(0.06).cgColor : NSColor.clear.cgColor
    super.draw(dirtyRect)
  }
}

struct ComposerOption {
  let title: String
  var description: String? = nil
  var symbol: String? = nil
  var selected = false
  var badge: String? = nil
  let action: () -> Void
}

@MainActor private final class ComposerOptionBackground: NSView {
  let selected: Bool
  private var hover = false
  private var tracking: NSTrackingArea?
  init(selected: Bool) {
    self.selected = selected
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 8
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override var wantsUpdateLayer: Bool { true }
  override func updateLayer() {
    layer?.backgroundColor =
      NSColor.labelColor.withAlphaComponent(selected ? 0.085 : hover ? 0.045 : 0).cgColor
  }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    tracking = NSTrackingArea(
      rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self)
    addTrackingArea(tracking!)
  }
  override func mouseEntered(with event: NSEvent) {
    hover = true
    needsDisplay = true
  }
  override func mouseExited(with event: NSEvent) {
    hover = false
    needsDisplay = true
  }
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }
}

@MainActor private final class ComposerOptionsDocument: NSView {
  override var isFlipped: Bool { true }
}

@MainActor final class ComposerOptionsPopover: NSViewController {
  private let heading: String?
  private let options: [ComposerOption]
  private let close: () -> Void
  private let width: CGFloat
  private var measuredContentSize = NSSize.zero
  var contentSize: NSSize {
    _ = view
    return measuredContentSize
  }
  init(_ heading: String?, options: [ComposerOption], width: CGFloat, close: @escaping () -> Void) {
    self.heading = heading
    self.options = options
    self.width = width
    self.close = close
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func loadView() {
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 2
    stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
    if let heading {
      let label = NSTextField(labelWithString: heading)
      label.font = .systemFont(ofSize: 12)
      label.textColor = .secondaryLabelColor
      let container = NSView()
      container.addSubview(label)
      label.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
        label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        container.heightAnchor.constraint(equalToConstant: 28),
      ])
      stack.addArrangedSubview(container)
    }
    for option in options {
      let row = ComposerOptionBackground(selected: option.selected)
      let title = NSTextField(labelWithString: option.title)
      title.font = .systemFont(ofSize: 14)
      title.lineBreakMode = .byTruncatingTail
      title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      let titleRow = NSStackView(views: [title])
      titleRow.spacing = 6
      if let symbol = option.symbol,
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
      {
        let icon = NSImageView(image: image)
        icon.contentTintColor = .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 18).isActive = true
        titleRow.insertArrangedSubview(icon, at: 0)
      }
      if let badge = option.badge {
        let tag = NSTextField(labelWithString: badge)
        tag.font = .systemFont(ofSize: 10)
        tag.textColor = .secondaryLabelColor
        titleRow.addArrangedSubview(tag)
      }
      titleRow.addArrangedSubview(NSView())
      if option.selected {
        let check = NSImageView(
          image: NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Selected")!)
        check.contentTintColor = .secondaryLabelColor
        titleRow.addArrangedSubview(check)
      }
      let contents = NSStackView(views: [titleRow])
      contents.orientation = .vertical
      contents.alignment = .leading
      contents.spacing = 5
      if let description = option.description {
        let detail = NSTextField(wrappingLabelWithString: description)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.preferredMaxLayoutWidth = width - 34
        detail.setContentCompressionResistancePriority(.required, for: .vertical)
        contents.addArrangedSubview(detail)
        detail.widthAnchor.constraint(equalTo: contents.widthAnchor).isActive = true
      }
      row.addSubview(contents)
      contents.translatesAutoresizingMaskIntoConstraints = false
      let button = ActionButton("") { [close] in
        close()
        option.action()
      }
      button.isBordered = false
      button.setAccessibilityLabel(option.title)
      button.toolTip = option.description
      row.addSubview(button)
      button.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        contents.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 9),
        contents.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -9),
        contents.topAnchor.constraint(equalTo: row.topAnchor, constant: 8),
        contents.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -8),
        titleRow.widthAnchor.constraint(equalTo: contents.widthAnchor),
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 34),
        button.leadingAnchor.constraint(equalTo: row.leadingAnchor),
        button.trailingAnchor.constraint(equalTo: row.trailingAnchor),
        button.topAnchor.constraint(equalTo: row.topAnchor),
        button.bottomAnchor.constraint(equalTo: row.bottomAnchor),
      ])
      stack.addArrangedSubview(row)
      row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16).isActive = true
    }
    // Measure once at the menu's fixed width; callers reuse the bounded result.
    let measurement = stack.widthAnchor.constraint(equalToConstant: width)
    measurement.isActive = true
    let height = ceil(stack.fittingSize.height)
    measurement.isActive = false
    measuredContentSize = NSSize(width: width, height: min(420, max(34, height)))
    view = SurfaceView(raised: true)
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay
    let document = ComposerOptionsDocument(frame: NSRect(x: 0, y: 0, width: width, height: height))
    document.translatesAutoresizingMaskIntoConstraints = false
    scroll.documentView = document
    document.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(scroll)
    scroll.translatesAutoresizingMaskIntoConstraints = false
    let preferredHeight = view.heightAnchor.constraint(equalToConstant: measuredContentSize.height)
    preferredHeight.priority = .defaultHigh
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
      stack.topAnchor.constraint(equalTo: document.topAnchor),
      stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
      document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
      document.heightAnchor.constraint(equalToConstant: height),
      scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scroll.topAnchor.constraint(equalTo: view.topAnchor),
      scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      view.widthAnchor.constraint(equalToConstant: width), preferredHeight,
    ])
  }
}
