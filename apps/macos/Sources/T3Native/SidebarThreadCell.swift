import AppKit
import T3Core

@MainActor func sidebarIcon(
  _ label: String, _ symbol: String, size: CGFloat = 26, action: @escaping () -> Void
)
  -> ActionButton
{
  let button = ActionButton("", action: action)
  button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
  button.symbolConfiguration = .init(pointSize: 14, weight: .regular)
  button.imagePosition = .imageOnly
  button.bezelStyle = .inline
  button.isBordered = false
  button.contentTintColor = .secondaryLabelColor
  button.toolTip = label
  button.setAccessibilityLabel(label)
  button.widthAnchor.constraint(equalToConstant: size).isActive = true
  button.heightAnchor.constraint(equalToConstant: size).isActive = true
  return button
}

@MainActor private enum SidebarColors {
  private static let tokens: [String: (UInt32, UInt32)] = [
    "gray": (0x4b5563, 0x9ca3af), "red": (0xdc2626, 0xf87171),
    "orange": (0xea580c, 0xfb923c), "amber": (0xd97706, 0xfbbf24),
    "yellow": (0xca8a04, 0xfacc15), "lime": (0x65a30d, 0xa3e635),
    "green": (0x16a34a, 0x4ade80), "emerald": (0x059669, 0x34d399),
    "teal": (0x0d9488, 0x2dd4bf), "cyan": (0x0891b2, 0x22d3ee),
    "sky": (0x0284c7, 0x38bdf8), "blue": (0x2563eb, 0x60a5fa),
    "indigo": (0x4f46e5, 0x818cf8), "violet": (0x7c3aed, 0xa78bfa),
    "purple": (0x9333ea, 0xc084fc), "fuchsia": (0xc026d3, 0xe879f9),
    "pink": (0xdb2777, 0xf472b6), "rose": (0xe11d48, 0xfb7185),
  ]
  static let values = tokens.mapValues { pair in
    NSColor(name: nil) { appearance in
      let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? pair.1 : pair.0
      return NSColor(
        srgbRed: CGFloat((value >> 16) & 255) / 255,
        green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }
  }
}

@MainActor final class SidebarProjectBadge: NSView {
  var identity = SidebarProjectIdentity(name: "") { didSet { needsDisplay = true } }
  override var isFlipped: Bool { true }
  override func draw(_ dirtyRect: NSRect) {
    let color = SidebarColors.values[identity.color] ?? SidebarColors.values["blue"]!
    if !identity.emoji {
      color.withAlphaComponent(0.14).setFill()
      NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
    }
    let font: NSFont =
      identity.emoji
      ? .systemFont(ofSize: 13) : .monospacedSystemFont(ofSize: 8.25, weight: .bold)
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let text = identity.text as NSString
    let size = text.size(withAttributes: attributes)
    text.draw(
      at: NSPoint(
        x: (bounds.width - size.width) / 2,
        y: (bounds.height - size.height) / 2), withAttributes: attributes)
  }
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }
}

@MainActor private final class SidebarProviderBadge: NSView {
  private static var images: [String: NSImage] = [:]
  private let icon = NSImageView()
  private let initials = NSTextField(labelWithString: "")
  private var color = NSColor.secondaryLabelColor
  private var showBadge = false

  init(_ mark: SidebarProviderMark) {
    super.init(frame: .zero)
    let image: NSImage?
    if let cached = Self.images[mark.driver] {
      image = cached
    } else {
      let ext = mark.driver == "antigravity" ? "png" : "pdf"
      image = Bundle.module.url(
        forResource: mark.driver, withExtension: ext,
        subdirectory: "Resources/Providers"
      ).flatMap(NSImage.init(contentsOf:))
      if let image {
        image.isTemplate = ext == "pdf"
        Self.images[mark.driver] = image
      }
    }
    color =
      mark.driver == "claudeAgent"
      ? NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1) : .labelColor
    icon.image = image
    icon.contentTintColor = color.withAlphaComponent(mark.current ? 0.6 : 0.35)
    icon.imageScaling = .scaleProportionallyUpOrDown
    initials.stringValue =
      mark.initials ?? (image == nil ? SidebarProviderMark.initials(mark.name) : "")
    initials.font = .systemFont(ofSize: 6.5, weight: .semibold)
    initials.alignment = .center
    initials.textColor = .secondaryLabelColor
    showBadge = mark.initials != nil
    if let accent = mark.accent, accent.count == 7, accent.first == "#",
      let value = UInt32(accent.dropFirst(), radix: 16)
    {
      color = NSColor(
        srgbRed: CGFloat((value >> 16) & 255) / 255,
        green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
      initials.textColor = .white
    } else {
      color = .controlBackgroundColor
    }
    for view in [icon, initials] {
      addSubview(view)
      view.translatesAutoresizingMaskIntoConstraints = false
    }
    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: mark.current ? 21 : 14),
      heightAnchor.constraint(equalToConstant: 21),
      icon.leadingAnchor.constraint(equalTo: leadingAnchor),
      icon.topAnchor.constraint(equalTo: topAnchor),
      icon.widthAnchor.constraint(equalToConstant: mark.current ? 14 : 12),
      icon.heightAnchor.constraint(equalToConstant: mark.current ? 14 : 12),
      initials.trailingAnchor.constraint(equalTo: trailingAnchor),
      initials.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
      initials.widthAnchor.constraint(equalToConstant: 14),
      initials.heightAnchor.constraint(equalToConstant: 9),
    ])
    setAccessibilityElement(false)
    initials.setAccessibilityElement(false)
    icon.setAccessibilityElement(false)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func draw(_ dirtyRect: NSRect) {
    guard showBadge else { return }
    color.setFill()
    NSBezierPath(
      roundedRect: NSRect(x: bounds.width - 15, y: 0, width: 15, height: 11),
      xRadius: 5.5, yRadius: 5.5
    ).fill()
  }
}

@MainActor final class SidebarTableRow: NSTableRowView {
  override func drawSelection(in dirtyRect: NSRect) {
    guard isSelected else { return }
    NSColor.labelColor.withAlphaComponent(0.09).setFill()
    NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 7, yRadius: 7).fill()
  }
}

@MainActor final class SidebarThreadCell: NSTableCellView {
  private let badge = SidebarProjectBadge()
  private let project = NSTextField(labelWithString: "")
  private let title = NSTextField(labelWithString: "")
  private let branch = NSTextField(labelWithString: "")
  private let time = NSTextField(labelWithString: "")
  private let pin = NSImageView()
  private let draft = NSImageView()
  private let marks = NSStackView()
  private let actions = NSStackView()
  private let top = NSStackView()
  private let bottom = NSStackView()
  private let content = NSStackView()
  private var lastMarks: [SidebarProviderMark] = []
  private var hover: NSTrackingArea?
  private var hovered = false
  private var compact = false
  private var unread = false
  private var selected = false
  private var quickAction: (() -> Void)?
  private var snoozeAction: (() -> Void)?
  private var canAct = false
  private var canSnooze = false
  private var titleWidth: NSLayoutConstraint?
  private var prURL: URL?
  private var prLinks: [(String, URL)] = []
  private lazy var pr = ActionButton("") { [weak self] in
    self?.openPullRequest()
  }
  private lazy var settle = sidebarIcon("Settle thread", "checkmark", size: 20) { [weak self] in
    self?.quickAction?()
  }
  private lazy var snooze = sidebarIcon("Snooze thread", "clock", size: 20) { [weak self] in
    self?.snoozeAction?()
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    identifier = .init("thread")
    for label in [project, title, branch, time] {
      label.lineBreakMode = .byTruncatingTail
      label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    project.font = .systemFont(ofSize: 11)
    project.textColor = .secondaryLabelColor
    title.font = .systemFont(ofSize: 13)
    branch.font = .systemFont(ofSize: 11)
    branch.lineBreakMode = .byTruncatingMiddle
    branch.textColor = .tertiaryLabelColor
    time.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    time.textColor = .secondaryLabelColor
    time.setContentCompressionResistancePriority(.required, for: .horizontal)
    for (view, symbol) in [(pin, "pin.fill"), (draft, "square.and.pencil")] {
      view.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
      view.contentTintColor = .secondaryLabelColor
      view.widthAnchor.constraint(equalToConstant: 12).isActive = true
      view.heightAnchor.constraint(equalToConstant: 12).isActive = true
    }
    badge.widthAnchor.constraint(equalToConstant: 16).isActive = true
    badge.heightAnchor.constraint(equalToConstant: 16).isActive = true
    marks.spacing = 3
    actions.spacing = 0
    for view in [snooze, settle] { actions.addArrangedSubview(view) }
    for view in [badge, project, draft, pin, time, actions] { top.addArrangedSubview(view) }
    top.spacing = 6
    top.heightAnchor.constraint(equalToConstant: 20).isActive = true
    pr.bezelStyle = .inline
    pr.isBordered = false
    pr.font = .systemFont(ofSize: 10)
    pr.contentTintColor = .systemPurple
    pr.imagePosition = .imageLeading
    pr.symbolConfiguration = .init(pointSize: 10, weight: .regular)
    for view in [branch, NSView(), pr, marks] { bottom.addArrangedSubview(view) }
    bottom.spacing = 4
    content.orientation = .vertical
    content.alignment = .leading
    content.spacing = 3
    for view in [top, title, bottom] { content.addArrangedSubview(view) }
    addSubview(content)
    content.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      content.centerYAnchor.constraint(equalTo: centerYAnchor),
      top.widthAnchor.constraint(equalTo: content.widthAnchor),
      bottom.widthAnchor.constraint(equalTo: content.widthAnchor),
    ])
    titleWidth = title.widthAnchor.constraint(equalTo: content.widthAnchor)
    titleWidth?.isActive = true
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(
    _ value: SidebarThreadPresentation, enabled: Bool,
    quickAction: @escaping () -> Void, snoozeAction: @escaping () -> Void
  ) {
    self.quickAction = quickAction
    self.snoozeAction = snoozeAction
    hovered = false
    compact = value.compact
    unread = value.thread.lifecycle.unread
    badge.identity = value.identity
    project.stringValue = value.project
    title.stringValue = value.thread.title
    title.font = .systemFont(ofSize: 13, weight: value.thread.lifecycle.unread ? .medium : .regular)
    updateTitleColor()
    branch.stringValue = value.thread.branch ?? ""
    time.stringValue = value.status ?? value.time
    time.textColor =
      value.thread.lifecycle.needsAttention || value.status == "Failed"
      ? .systemOrange : .secondaryLabelColor
    pin.isHidden = !value.thread.lifecycle.pinned
    draft.isHidden = !value.draft
    project.isHidden = compact
    bottom.isHidden = compact
    // Compact history keeps the project badge, title and status in one row.
    titleWidth?.isActive = !compact
    if compact && title.superview !== top {
      content.removeArrangedSubview(title)
      title.removeFromSuperview()
      top.insertArrangedSubview(title, at: 1)
    } else if !compact && title.superview === top {
      top.removeArrangedSubview(title)
      title.removeFromSuperview()
      content.insertArrangedSubview(title, at: 1)
    }
    canAct =
      enabled && !value.thread.archived
      && (value.thread.lifecycle.settled
        || (value.thread.activeRunID == nil && !value.thread.lifecycle.hasQueuedStart(at: Date())))
    canSnooze =
      enabled && !value.thread.archived && value.thread.lifecycle.canSnooze(at: Date())
      && !value.thread.lifecycle.snoozed(at: Date())
    let verb =
      value.thread.lifecycle.settled
      ? "Move to active"
      : value.thread.lifecycle.snoozed(at: Date()) ? "Wake now" : "Settle thread"
    settle.toolTip = verb
    settle.setAccessibilityLabel(verb)
    settle.image = NSImage(
      systemSymbolName: value.thread.lifecycle.settled
        ? "arrow.uturn.backward"
        : value.thread.lifecycle.snoozed(at: Date()) ? "alarm" : "checkmark",
      accessibilityDescription: nil)
    settle.isEnabled = canAct
    snooze.isEnabled = canSnooze
    var seen = Set<String>()
    let links = value.thread.pullRequests.filter { seen.insert($0["url"].string ?? "").inserted }
    let url = links.first?["url"].string.flatMap(URL.init(string:))
    prURL = url.flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
    prLinks = links.compactMap { link in
      guard let text = link["url"].string, let url = URL(string: text),
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
      else { return nil }
      let title = link["number"].int.map { "#\($0)" } ?? "Pull request"
      return (title + " · " + (url.host ?? "") + url.path, url)
    }
    pr.isHidden = prURL == nil
    pr.title =
      links.count > 1 ? "\(links.count)" : links.first?["number"].int.map(String.init) ?? ""
    pr.image = NSImage(
      systemSymbolName: links.count > 1 ? "square.stack" : "arrow.triangle.branch",
      accessibilityDescription: nil)
    pr.toolTip = links.count > 1 ? "\(links.count) linked pull requests" : prURL?.absoluteString
    pr.setAccessibilityLabel(
      links.count > 1 ? "\(links.count) linked pull requests" : "Pull request \(pr.title)")
    if lastMarks != value.providers {
      lastMarks = value.providers
      for view in marks.arrangedSubviews {
        marks.removeArrangedSubview(view)
        view.removeFromSuperview()
      }
      for mark in value.providers { marks.addArrangedSubview(SidebarProviderBadge(mark)) }
    }
    toolTip = value.detail
    setAccessibilityLabel(value.detail.replacingOccurrences(of: "\n", with: ", "))
    updateActions()
  }

  func setSelected(_ value: Bool) {
    selected = value
    updateTitleColor()
  }
  private func openPullRequest() {
    if prLinks.count == 1, let url = prLinks.first?.1 {
      NSWorkspace.shared.open(url)
      return
    }
    let menu = NSMenu()
    for (title, url) in prLinks {
      menu.addItem(ActionMenuItem(title) { NSWorkspace.shared.open(url) })
    }
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: pr.bounds.maxY), in: pr)
  }
  private func updateTitleColor() {
    title.textColor =
      selected || unread ? .labelColor : compact ? .tertiaryLabelColor : .secondaryLabelColor
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hover { removeTrackingArea(hover) }
    hover = NSTrackingArea(
      rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self, userInfo: nil)
    addTrackingArea(hover!)
    hovered =
      window.map {
        visibleRect.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil))
      } ?? false
    updateActions()
    needsDisplay = true
  }
  override func mouseEntered(with event: NSEvent) {
    hovered = true
    updateActions()
    needsDisplay = true
  }
  override func mouseExited(with event: NSEvent) {
    hovered = false
    updateActions()
    needsDisplay = true
  }
  private func updateActions() {
    actions.isHidden = !hovered || (!canAct && !canSnooze)
    time.isHidden = !actions.isHidden
    settle.isHidden = !canAct
    snooze.isHidden = !canSnooze || compact
    var custom: [NSAccessibilityCustomAction] = []
    if canAct {
      custom.append(
        NSAccessibilityCustomAction(name: settle.toolTip ?? "Settle") { [weak self] in
          self?.quickAction?()
          return true
        })
    }
    if canSnooze {
      custom.append(
        NSAccessibilityCustomAction(name: "Snooze thread") { [weak self] in
          self?.snoozeAction?()
          return true
        })
    }
    setAccessibilityCustomActions(custom)
  }
  override func draw(_ dirtyRect: NSRect) {
    if hovered && (superview as? NSTableRowView)?.isSelected != true {
      NSColor.labelColor.withAlphaComponent(0.035).setFill()
      NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 7, yRadius: 7).fill()
    }
  }
}
