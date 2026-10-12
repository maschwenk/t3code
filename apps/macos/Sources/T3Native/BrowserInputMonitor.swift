import AppKit
import WebKit

// Local AppKit events are human input. Agent events are dispatched directly to the
// page's responder, so they never pass through this monitor or take system focus.
@MainActor final class BrowserInputMonitor {
  private let pages = NSMapTable<WKWebView, BrowserPage>.weakToWeakObjects()
  private var monitor: Any?
  init() {
    monitor = NSEvent.addLocalMonitorForEvents(matching: [
      .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel, .magnify, .swipe,
      .rotate,
    ]) { [weak self] event in
      self?.receive(event)
      return event
    }
  }
  isolated deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
  func register(_ page: BrowserPage) { pages.setObject(page, forKey: page.web) }
  func receive(_ event: NSEvent) {
    guard let window = event.window else { return }
    var target: NSView?
    if event.type == .keyDown {
      target = window.firstResponder as? NSView
    } else if let content = window.contentView {
      target = content.hitTest(
        content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow)
    }
    while let view = target {
      if let web = view as? WKWebView, let page = pages.object(forKey: web) {
        page.takeControl()
        if page.recording.active {
          page.automation.cursor.humanInput(event, web: web)
        }
        return
      }
      target = view.superview
    }
  }
}
