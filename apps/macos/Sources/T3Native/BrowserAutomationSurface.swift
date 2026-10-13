import AppKit
import T3Core
import WebKit

@MainActor final class BrowserAutomationSurface: NSObject, NSWindowDelegate {
  var onStop: (() -> Void)?
  let window: NSPanel
  let viewport = BrowserViewportView()
  private weak var page: BrowserPage?
  override init() {
    window = NSPanel(
      contentRect: NSRect(x: 80, y: 80, width: 1000, height: 720),
      styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered,
      defer: false)
    super.init()
    window.delegate = self
    window.isReleasedWhenClosed = false
    window.hidesOnDeactivate = false
    window.level = .floating
    window.becomesKeyOnlyIfNeeded = true
    window.contentView = viewport
    window.minSize = NSSize(width: 360, height: 300)
    window.collectionBehavior = [.fullScreenAuxiliary]
    window.isMovableByWindowBackground = true
    let accessory = NSTitlebarAccessoryViewController()
    accessory.layoutAttribute = .right
    let stop = NSButton(title: "Stop agent", target: self, action: #selector(stopAgent))
    stop.bezelStyle = .inline
    stop.frame = NSRect(x: 0, y: 2, width: 90, height: 24)
    accessory.view = NSView(frame: NSRect(x: 0, y: 0, width: 98, height: 28))
    accessory.view.addSubview(stop)
    window.addTitlebarAccessoryViewController(accessory)
  }
  func attach(_ page: BrowserPage, show: Bool, title: String) {
    self.page = page
    viewport.setting = (try? BrowserViewport(page.snapshot.viewport)) ?? .fill
    viewport.show(page.web)
    window.title = title
    viewport.layoutSubtreeIfNeeded()
    if show { window.orderFront(nil) }
  }
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    page?.recording.cancel()
    page?.automation.interrupt()
    onStop?()
    return true
  }
  @objc private func stopAgent() { window.performClose(nil) }
  func close() {
    page?.recording.cancel()
    page = nil
    viewport.show(nil)
    window.close()
  }
}
