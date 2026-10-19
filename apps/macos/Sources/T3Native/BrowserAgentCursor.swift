import AppKit
import QuartzCore
import T3Core
import WebKit

// A view-backed layer remains visible to screen sharing; no display-link or repaint loop.
@MainActor final class BrowserAgentCursor: NSView {
  private let scene = CALayer()
  private let pointer = CAShapeLayer()
  private let ring = CAShapeLayer()
  private let badge = CATextLayer()
  private let keyBadge = CATextLayer()
  private var feedbackTask: Task<Void, Never>?
  private(set) var target: CGPoint?
  private(set) var feedback = ""
  private var humanPoint: CGPoint?
  var reduceMotionOverride: Bool?
  var reducedMotion: Bool {
    reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }
  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.masksToBounds = true
    // AppKit resets backing-layer geometry. Keep the top-left coordinate system on
    // our own child layer so page/cursor positions stay aligned after layout.
    scene.isGeometryFlipped = true
    scene.frame = bounds
    layer?.addSublayer(scene)
    pointer.path = Self.path
    pointer.fillColor = NSColor.systemPurple.cgColor
    pointer.strokeColor = NSColor.white.cgColor
    pointer.lineWidth = 1.5
    pointer.shadowColor = NSColor.black.cgColor
    pointer.shadowOpacity = 0.35
    pointer.shadowRadius = 2
    pointer.shadowOffset = CGSize(width: 0, height: 1)
    pointer.bounds = CGRect(x: 0, y: 0, width: 24, height: 29)
    pointer.anchorPoint = .zero
    ring.path = CGPath(ellipseIn: CGRect(x: -13, y: -13, width: 26, height: 26), transform: nil)
    ring.fillColor = NSColor.clear.cgColor
    ring.strokeColor = NSColor.systemPurple.cgColor
    ring.lineWidth = 3
    ring.opacity = 0
    for text in [badge, keyBadge] {
      text.fontSize = 11
      text.foregroundColor = NSColor.white.cgColor
      text.backgroundColor = NSColor.systemPurple.cgColor
      text.cornerRadius = 4
      text.alignmentMode = .center
      text.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
    }
    badge.string = "Agent"
    badge.bounds = CGRect(x: 0, y: 0, width: 45, height: 19)
    badge.anchorPoint = .zero
    scene.addSublayer(ring)
    scene.addSublayer(pointer)
    scene.addSublayer(badge)
    scene.addSublayer(keyBadge)
    isHidden = true
    setAccessibilityLabel("Agent browser cursor")
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    scene.frame = bounds
    CATransaction.commit()
  }
  var contentGeometryFlipped: Bool { scene.isGeometryFlipped }
  static var path: CGPath {
    let path = CGMutablePath()
    path.move(to: .zero)
    for point in [
      CGPoint(x: 1, y: 23), CGPoint(x: 7, y: 17), CGPoint(x: 12, y: 27),
      CGPoint(x: 17, y: 24), CGPoint(x: 12, y: 15), CGPoint(x: 21, y: 14),
    ] {
      path.addLine(to: point)
    }
    path.closeSubpath()
    return path
  }
  @discardableResult func move(css: CGPoint, zoom: Double, animate: Bool = true) throws -> Double {
    guard css.x.isFinite, css.y.isFinite, zoom.isFinite, zoom > 0,
      css.x >= 0, css.y >= 0, css.x * zoom < bounds.width, css.y * zoom < bounds.height
    else {
      throw BrowserAutomationError(
        "PreviewAutomationCoordinatesOutsideViewportError",
        "The target is outside the browser viewport.")
    }
    if let parent = superview { parent.addSubview(self, positioned: .above, relativeTo: nil) }
    let destination = CGPoint(x: css.x * zoom, y: css.y * zoom)
    let source = pointer.presentation()?.position ?? target ?? destination
    let duration = animate && !reducedMotion && target != nil ? 0.24 : 0
    target = destination
    humanPoint = nil
    pointer.opacity = 1
    badge.opacity = 1
    isHidden = false
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    pointer.position = destination
    badge.position = badgePosition(destination)
    ring.position = destination
    CATransaction.commit()
    for (item, from, to) in [
      (pointer as CALayer, source, destination),
      (badge as CALayer, badgePosition(source), badgePosition(destination)),
      (ring as CALayer, source, destination),
    ] {
      item.removeAnimation(forKey: "agentMove")
      if duration > 0 {
        let animation = CABasicAnimation(keyPath: "position")
        animation.fromValue = NSValue(point: from)
        animation.toValue = NSValue(point: to)
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        item.add(animation, forKey: "agentMove")
      }
    }
    return duration
  }
  private func badgePosition(_ point: CGPoint) -> CGPoint {
    CGPoint(
      x: max(0, min(bounds.width - 45, point.x + 20)),
      y: max(0, min(bounds.height - 19, point.y + 24)))
  }
  func click() {
    guard target != nil else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    ring.opacity = reducedMotion ? 1 : 0
    CATransaction.commit()
    if !reducedMotion {
      let opacity = CABasicAnimation(keyPath: "opacity")
      opacity.fromValue = 1
      opacity.toValue = 0
      opacity.duration = 0.65
      ring.add(opacity, forKey: "click")
      let scale = CABasicAnimation(keyPath: "transform.scale")
      scale.fromValue = 0.5
      scale.toValue = 1.8
      scale.duration = 0.65
      ring.add(scale, forKey: "clickScale")
    }
    showFeedback("Agent click")
  }
  func showFeedback(_ value: String) {
    feedbackTask?.cancel()
    feedback = value
    isHidden = false
    if target == nil {
      pointer.opacity = 0
      badge.opacity = 0
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    keyBadge.string = value
    keyBadge.backgroundColor =
      value.hasPrefix("Human") ? NSColor.systemBlue.cgColor : NSColor.systemPurple.cgColor
    keyBadge.frame = CGRect(x: 12, y: max(0, bounds.height - 36), width: 180, height: 24)
    keyBadge.opacity = 1
    CATransaction.commit()
    feedbackTask = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(1.2)) } catch { return }
      self?.feedback = ""
      self?.keyBadge.opacity = 0
      self?.ring.opacity = 0
      self?.humanPoint = nil
      if self?.target == nil { self?.isHidden = true }
    }
  }
  func humanInput(_ event: NSEvent, web: WKWebView) {
    if event.type != .keyDown {
      let local = web.convert(event.locationInWindow, from: nil)
      humanPoint = CGPoint(x: local.x, y: web.isFlipped ? local.y : web.bounds.height - local.y)
    }
    let namedKeys: [UInt16: String] = [
      36: "Enter", 48: "Tab", 53: "Escape", 51: "Backspace",
      123: "ArrowLeft", 124: "ArrowRight", 125: "ArrowDown", 126: "ArrowUp",
    ]
    showFeedback(
      event.type == .keyDown ? "Human " + (namedKeys[event.keyCode] ?? "key") : "Human input")
  }
  func hide() {
    feedbackTask?.cancel()
    feedbackTask = nil
    target = nil
    humanPoint = nil
    feedback = ""
    isHidden = true
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    ring.opacity = 0
    keyBadge.opacity = 0
    for item in [pointer, ring, badge, keyBadge] { item.removeAllAnimations() }
    CATransaction.commit()
  }
  isolated deinit { feedbackTask?.cancel() }
  var movementAnimation: CAAnimation? { pointer.animation(forKey: "agentMove") }

  // WKSnapshotConfiguration captures the page, not native sibling layers. Compose the
  // same vector cursor explicitly; deterministic screenshots use its final position.
  func drawCapture(size: CGSize, mouse: Bool, keys: Bool, deterministic: Bool) {
    guard bounds.width > 0, bounds.height > 0, let context = NSGraphicsContext.current?.cgContext
    else { return }
    context.saveGState()
    context.scaleBy(x: size.width / bounds.width, y: size.height / bounds.height)
    if mouse, !isHidden, let target {
      let point = deterministic ? target : pointer.presentation()?.position ?? target
      context.saveGState()
      context.translateBy(x: point.x, y: point.y)
      context.addPath(Self.path)
      context.setFillColor(NSColor.systemPurple.cgColor)
      context.setStrokeColor(NSColor.white.cgColor)
      context.setLineWidth(1.5)
      context.drawPath(using: .fillStroke)
      if feedback == "Agent click" {
        context.setStrokeColor(NSColor.systemPurple.cgColor)
        context.strokeEllipse(in: CGRect(x: -13, y: -13, width: 26, height: 26))
      }
      context.restoreGState()
      drawLabel("Agent", at: badgePosition(point))
    }
    if mouse, let humanPoint {
      context.setStrokeColor(NSColor.systemBlue.cgColor)
      context.setLineWidth(3)
      context.strokeEllipse(
        in: CGRect(x: humanPoint.x - 10, y: humanPoint.y - 10, width: 20, height: 20))
    }
    if keys, !feedback.isEmpty {
      drawLabel(feedback, at: CGPoint(x: 12, y: max(0, bounds.height - 36)))
    }
    context.restoreGState()
  }
  private func drawLabel(_ string: String, at point: CGPoint) {
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white,
    ]
    let size = (string as NSString).size(withAttributes: attributes)
    (string.hasPrefix("Human") ? NSColor.systemBlue : NSColor.systemPurple).setFill()
    NSBezierPath(
      roundedRect: CGRect(
        origin: point,
        size: CGSize(width: size.width + 10, height: 20)), xRadius: 4, yRadius: 4
    ).fill()
    (string as NSString).draw(
      at: CGPoint(x: point.x + 5, y: point.y + 2), withAttributes: attributes)
  }
}
