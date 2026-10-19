import AppKit
import T3Core

@MainActor final class BrowserAnnotationCanvas: NSView {
  let image: NSImage
  var document: BrowserAnnotationDocument
  var tool: BrowserAnnotation.Tool = .pen
  var onChange: (() -> Void)?
  private var stroke: BrowserAnnotation?
  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  init(image: NSImage, pageURL: String) {
    self.image = image
    document = BrowserAnnotationDocument(pageURL: pageURL)
    super.init(frame: .zero)
    setAccessibilityLabel("Browser screenshot annotation canvas")
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  var imageRect: CGRect {
    let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    return CGRect(
      x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
      width: size.width, height: size.height)
  }
  override func draw(_ dirtyRect: NSRect) {
    NSColor.windowBackgroundColor.setFill()
    bounds.fill()
    let rect = imageRect
    image.draw(
      in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.saveGState()
    context.clip(to: rect)
    context.translateBy(x: rect.minX, y: rect.minY)
    BrowserAnnotationRenderer.draw(
      document.annotations + (stroke.map { [$0] } ?? []), size: rect.size)
    context.restoreGState()
  }
  private func point(_ event: NSEvent) -> BrowserAnnotationPoint? {
    let local = convert(event.locationInWindow, from: nil)
    let rect = imageRect
    guard rect.width > 0, rect.height > 0 else { return nil }
    return .init(
      x: max(0, min(1, (local.x - rect.minX) / rect.width)),
      y: max(0, min(1, (local.y - rect.minY) / rect.height)))
  }
  override func mouseDown(with event: NSEvent) {
    guard imageRect.contains(convert(event.locationInWindow, from: nil)),
      let point = point(event), document.annotations.count < 1000
    else { return }
    stroke = BrowserAnnotation(tool: tool, points: [point, point])
    needsDisplay = true
  }
  override func mouseDragged(with event: NSEvent) {
    guard let point = point(event), stroke != nil else { return }
    if tool == .pen {
      if stroke!.points.count < 2000 { stroke?.points.append(point) }
    } else {
      stroke?.points[1] = point
    }
    needsDisplay = true
  }
  override func mouseUp(with event: NSEvent) {
    mouseDragged(with: event)
    if let stroke { document.annotations.append(stroke) }
    stroke = nil
    needsDisplay = true
    onChange?()
  }
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 {
      stroke = nil
      needsDisplay = true
      return
    }
    if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "z" {
      undoStroke()
      return
    }
    super.keyDown(with: event)
  }
  func undoStroke() {
    if !document.annotations.isEmpty { document.annotations.removeLast() }
    needsDisplay = true
    onChange?()
  }
  func clear() {
    document.annotations = []
    stroke = nil
    needsDisplay = true
    onChange?()
  }
}

@MainActor final class BrowserAnnotationWindow: NSWindowController, NSWindowDelegate {
  let canvas: BrowserAnnotationCanvas
  var onSave: ((URL, Bool) -> Void)?
  var onClose: (() -> Void)?
  private let message = NSTextField(
    labelWithString: "Draw on the screenshot, then save or attach it.")
  init(image: NSImage, pageURL: String) {
    canvas = BrowserAnnotationCanvas(image: image, pageURL: pageURL)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    super.init(window: window)
    window.title = "Annotate browser screenshot"
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.minSize = NSSize(width: 480, height: 360)
    let tools = NSPopUpButton()
    tools.addItems(withTitles: ["Pen", "Rectangle", "Arrow"])
    tools.target = self
    tools.action = #selector(selectTool(_:))
    let toolbar = NSStackView(views: [
      tools,
      ActionButton("Undo") { [weak self] in self?.canvas.undoStroke() },
      ActionButton("Clear") { [weak self] in self?.canvas.clear() },
      ActionButton("Save") { [weak self] in self?.save(attach: false) },
      ActionButton("Save and Attach") { [weak self] in self?.save(attach: true) },
    ])
    let stack = NSStackView(views: [toolbar, canvas, message])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    window.contentView?.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 12),
      stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -12),
      stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 12),
      stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -12),
      canvas.widthAnchor.constraint(equalTo: stack.widthAnchor),
      canvas.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
    ])
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  @objc private func selectTool(_ sender: NSPopUpButton) {
    canvas.tool = [.pen, .rectangle, .arrow][sender.indexOfSelectedItem]
  }
  private func save(attach: Bool) {
    do {
      let file = try BrowserAnnotationRenderer.save(
        canvas.image, document: canvas.document,
        directory: BrowserArtifacts.directory)
      message.stringValue = "Saved " + file.lastPathComponent
      onSave?(file, attach)
    } catch { message.stringValue = error.localizedDescription }
  }
  func windowWillClose(_ notification: Notification) { onClose?() }
}
