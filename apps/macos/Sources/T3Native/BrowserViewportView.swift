import AppKit
import T3Core
import WebKit

@MainActor final class BrowserViewportView: NSView {
  private let canvas = NSView()
  private(set) var web: WKWebView?
  var setting: BrowserViewport = .fill { didSet { if oldValue != setting { needsLayout = true } } }
  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    addSubview(canvas)
    canvas.wantsLayer = true
    canvas.layer?.masksToBounds = true
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func show(_ web: WKWebView?) {
    guard self.web !== web else { return }
    self.web?.removeFromSuperview()
    self.web = web
    if let web {
      web.translatesAutoresizingMaskIntoConstraints = true
      canvas.addSubview(web)
    }
    needsLayout = true
  }

  override func layout() {
    super.layout()
    guard let web else { return }
    if let width = setting.width, let height = setting.height {
      // WebKit truncates view points before dividing by page zoom. Round the outer size up so
      // fractional zoom cannot shrink the requested responsive breakpoint by a CSS pixel.
      // Scale presentation, not page zoom: responsive breakpoints keep the requested CSS size.
      let size = NSSize(
        width: ceil(Double(width) * web.pageZoom) + 0.01,
        height: ceil(Double(height) * web.pageZoom) + 0.01
      )
      let scale = min(
        1, max(1, bounds.width - 24) / size.width, max(1, bounds.height - 24) / size.height)
      let displayed = NSSize(width: size.width * scale, height: size.height * scale)
      canvas.frame = NSRect(
        x: (bounds.width - displayed.width) / 2, y: 12,
        width: displayed.width, height: displayed.height)
      canvas.bounds = NSRect(origin: .zero, size: size)
    } else {
      canvas.frame = bounds
      canvas.bounds = NSRect(origin: .zero, size: bounds.size)
    }
    web.frame = canvas.bounds
  }
}
