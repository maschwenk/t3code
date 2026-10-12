import AppKit
import T3Markdown

@MainActor final class MessageTextView: NSTextView, NSTextViewDelegate {
  var onOpenLink: ((URL) -> Void)?
  var fileLinkMenu: ((URL) -> NSMenu?)?
  var onLayoutChange: ((CGFloat, CGFloat) -> Void)?
  var onCodeWrapChange: ((Int, Bool) -> Void)?
  private var rendered: RenderedMarkdown
  private let layoutWidth: CGFloat
  private var surfaces: [NSRect] = []
  private var controls: [(label: NSTextField, copy: NSButton, wrap: NSButton)] = []
  private var geometryDirty = true

  var contentWidth: CGFloat { max(layoutWidth, rendered.contentWidth) }

  static func horizontalScrollerAllowance(for rendered: RenderedMarkdown, width: CGFloat) -> CGFloat
  {
    rendered.contentWidth > width + 1 ? 16 : 0
  }

  init(rendered: RenderedMarkdown, width: CGFloat, height: CGFloat) {
    self.rendered = rendered
    self.layoutWidth = width
    let storage = NSTextStorage(attributedString: rendered.text)
    let layout = MarkdownLayoutManager()
    let container = MarkdownTextContainer(text: rendered.text, width: width)
    container.lineFragmentPadding = 0
    container.widthTracksTextView = false
    storage.addLayoutManager(layout)
    layout.addTextContainer(container)
    super.init(frame: NSRect(x: 0, y: 0, width: width, height: height), textContainer: container)
    delegate = self
    isEditable = false
    isSelectable = true
    isRichText = true
    drawsBackground = false
    textContainerInset = .zero
    isHorizontallyResizable = false
    isVerticallyResizable = false
    linkTextAttributes = [
      .foregroundColor: NSColor.linkColor
    ]
    setAccessibilityLabel("Message content")
    for (index, code) in rendered.codeBlocks.enumerated() {
      guard code.surfaceRange != nil else { continue }
      let label = NSTextField(
        labelWithString: code.language?.split(separator: " ").first.map(String.init) ?? "code")
      label.font = .systemFont(ofSize: 11, weight: .medium)
      label.textColor = MarkdownPalette.codeSecondary
      label.lineBreakMode = .byTruncatingTail
      let copy = ActionButton("Copy") { [weak self] in self?.copyCode(at: index) }
      copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
      copy.toolTip = "Copy code"
      copy.setAccessibilityLabel("Copy \(label.stringValue) code")
      let wrap = ActionButton("Wrap") { [weak self] in self?.toggleCodeWrapping(at: index) }
      wrap.image = NSImage(systemSymbolName: "arrow.turn.down.left", accessibilityDescription: nil)
      wrap.setButtonType(.toggle)
      wrap.state = code.wraps ? .on : .off
      wrap.toolTip = "Wrap long lines"
      wrap.setAccessibilityLabel("Wrap \(label.stringValue) code lines")
      for button in [copy, wrap] {
        button.bezelStyle = .inline
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.contentTintColor = MarkdownPalette.codeText
        button.imagePosition = .imageLeading
        addSubview(button)
      }
      addSubview(label)
      controls.append((label, copy, wrap))
    }
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// The document keeps prose at layoutWidth while code/tables can extend horizontally.
  /// Parent rows should reserve 16pt for the horizontal scroller when using this wrapper.
  func horizontalScrollContainer() -> NSScrollView {
    let scroll = NSScrollView(frame: frame)
    scroll.drawsBackground = false
    scroll.borderType = .noBorder
    scroll.hasVerticalScroller = false
    scroll.hasHorizontalScroller = true
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay
    setFrameSize(NSSize(width: contentWidth, height: frame.height))
    scroll.documentView = self
    scroll.contentView.postsBoundsChangedNotifications = true
    NotificationCenter.default.addObserver(
      self, selector: #selector(viewportChanged), name: NSView.boundsDidChangeNotification,
      object: scroll.contentView)
    return scroll
  }

  @objc private func viewportChanged() {
    positionControls()
  }

  override func layout() {
    super.layout()
    updateGeometry()
    positionControls()
  }

  private func updateGeometry() {
    guard geometryDirty, let layoutManager, let textContainer else { return }
    layoutManager.ensureLayout(for: textContainer)
    surfaces = rendered.codeBlocks.compactMap { code in
      guard let range = code.surfaceRange else { return nil }
      let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
      let bounds = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
      return NSRect(
        x: max(0, bounds.minX - 14) + textContainerOrigin.x,
        y: bounds.minY - 14 + textContainerOrigin.y,
        width: code.contentWidth, height: bounds.height + 28)
    }
    geometryDirty = false
  }

  private func positionControls() {
    for (surface, control) in zip(surfaces, controls) {
      let right = min(surface.maxX, visibleRect.maxX) - 12
      let y = surface.minY + 10
      control.copy.frame = NSRect(x: right - 57, y: y, width: 57, height: 22)
      control.wrap.frame = NSRect(x: right - 123, y: y, width: 61, height: 22)
      control.label.frame = NSRect(
        x: max(surface.minX, visibleRect.minX) + 14, y: y + 3,
        width: max(0, right - 145 - max(surface.minX, visibleRect.minX)), height: 16)
    }
  }

  override func draw(_ dirtyRect: NSRect) {
    updateGeometry()
    for surface in surfaces where surface.intersects(dirtyRect) {
      let path = NSBezierPath(
        roundedRect: surface.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
      MarkdownPalette.codeBackground.setFill()
      path.fill()
      MarkdownPalette.codeBorder.setStroke()
      path.lineWidth = 0.5
      path.stroke()
      let rule = NSBezierPath()
      rule.move(to: NSPoint(x: surface.minX + 1, y: surface.minY + 39))
      rule.line(to: NSPoint(x: surface.maxX - 1, y: surface.minY + 39))
      rule.lineWidth = 0.5
      rule.stroke()
    }
    super.draw(dirtyRect)
  }

  private func copyCode(at index: Int) {
    guard rendered.codeBlocks.indices.contains(index) else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(rendered.codeBlocks[index].code, forType: .string)
    let controlIndex = rendered.codeBlocks.prefix(index).filter { $0.surfaceRange != nil }.count
    if controls.indices.contains(controlIndex) {
      controls[controlIndex].copy.title = "Copied"
      controls[controlIndex].copy.setAccessibilityLabel("Code copied")
    }
  }

  private func toggleCodeWrapping(at index: Int) {
    guard rendered.codeBlocks.indices.contains(index) else { return }
    let wraps = !rendered.codeBlocks[index].wraps
    let selection = selectedRange()
    rendered = MarkdownRenderer.settingCodeWrapping(
      wraps, at: index, in: rendered, width: layoutWidth)
    (textContainer as? MarkdownTextContainer)?.updateLayoutWidth(for: rendered.text)
    textStorage?.setAttributedString(rendered.text)
    setSelectedRange(selection)
    geometryDirty = true
    needsLayout = true
    needsDisplay = true
    let controlIndex = rendered.codeBlocks.prefix(index).filter { $0.surfaceRange != nil }.count
    if controls.indices.contains(controlIndex) {
      controls[controlIndex].wrap.state = wraps ? .on : .off
    }
    let height = MarkdownRenderer.height(of: rendered.text, width: layoutWidth)
    if enclosingScrollView?.documentView === self {
      setFrameSize(NSSize(width: contentWidth, height: height))
    }
    onLayoutChange?(height, contentWidth)
    onCodeWrapChange?(index, wraps)
  }

  private func open(_ url: URL) {
    if let onOpenLink { onOpenLink(url) } else { NSWorkspace.shared.open(url) }
  }
  func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
    guard let url = link as? URL else { return false }
    open(url)
    return true
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    let menu = NSMenu()
    menu.autoenablesItems = false
    guard let layoutManager, let textContainer else { return menu }
    let point = convert(event.locationInWindow, from: nil)
    let index = layoutManager.characterIndex(
      for: NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y),
      in: textContainer, fractionOfDistanceBetweenInsertionPoints: nil)
    if let codeIndex = rendered.codeBlocks.firstIndex(where: { NSLocationInRange(index, $0.range) })
    {
      let code = rendered.codeBlocks[codeIndex]
      menu.addItem(ActionMenuItem("Copy code") { [weak self] in self?.copyCode(at: codeIndex) })
      if code.surfaceRange != nil {
        menu.addItem(
          ActionMenuItem(code.wraps ? "Unwrap code" : "Wrap code") { [weak self] in
            self?.toggleCodeWrapping(at: codeIndex)
          })
      }
    }
    if index < rendered.text.length,
      let link = rendered.text.attribute(.link, at: index, effectiveRange: nil) as? URL
    {
      if link.scheme == "t3-markdown-task" {
        menu.addItem(ActionMenuItem("Toggle task") { [weak self] in self?.open(link) })
      } else {
        menu.addItem(ActionMenuItem("Open link") { [weak self] in self?.open(link) })
        menu.addItem(
          ActionMenuItem("Copy link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link.absoluteString, forType: .string)
          })
        if let actions = fileLinkMenu?(link) {
          menu.addItem(.separator())
          FileContextMenu.append(actions, to: menu)
        }
      }
    }
    if !menu.items.isEmpty { menu.addItem(.separator()) }
    let copy = NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
    copy.target = self
    copy.isEnabled = selectedRange().length > 0
    menu.addItem(copy)
    let select = NSMenuItem(
      title: "Select all", action: #selector(selectAll(_:)), keyEquivalent: "")
    select.target = self
    menu.addItem(select)
    return menu
  }
}
