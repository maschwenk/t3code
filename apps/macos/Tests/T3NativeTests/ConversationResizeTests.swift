import AppKit
import QuartzCore
import T3Core
import Testing

@testable import T3Native

@MainActor @Suite(.serialized) struct ConversationResizeTests {
  private func fixture() throws -> (ChatWindow, NSTableView) {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = ClientStore(draftDirectory: directory)
    store.selectedID = "resize-test"
    var thread = ThreadState(id: "resize-test")
    _ = try thread.apply(
      .object([
        "kind": .string("snapshot"), "snapshotSequence": .number(1),
        "projection": .object([
          "thread": .object(["id": .string("resize-test")]),
          "turnItems": .array(
            (0..<240).map { index in
              .object([
                "id": .string("message-\(index)"), "ordinal": .number(Double(index)),
                "type": .string("assistant_message"),
                "text": .string(
                  String(
                    repeating: "A **message** with enough text to wrap across the conversation. ",
                    count: 12)),
              ])
            }),
        ]),
      ]))
    store.thread = thread
    let frameKey = "NSWindow Frame T3NativeMain"
    let savedFrame = UserDefaults.standard.object(forKey: frameKey)
    let controller = ChatWindow(store: store)
    let window = try #require(controller.window)
    window.setFrameAutosaveName("")
    if let savedFrame {
      UserDefaults.standard.set(savedFrame, forKey: frameKey)
    } else {
      UserDefaults.standard.removeObject(forKey: frameKey)
    }
    window.setContentSize(NSSize(width: 1200, height: 800))
    window.contentView?.layoutSubtreeIfNeeded()
    func tables(_ view: NSView) -> [NSTableView] {
      (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables)
    }
    let content = try #require(window.contentView)
    let table = try #require(
      tables(content).first {
        $0.accessibilityLabel() == "Conversation"
      })
    return (controller, table)
  }

  @Test(arguments: [false, true])
  func liveResizeRetainsRowsThenReflowsAndKeepsTheScrollAnchor(atBottom: Bool) throws {
    let (controller, table) = try fixture()
    let window = try #require(controller.window)
    defer { window.close() }
    let clip = try #require(table.enclosingScrollView?.contentView)
    let anchorRow = atBottom ? 239 : 120
    let y =
      atBottom ? table.bounds.height - clip.bounds.height : table.rect(ofRow: anchorRow).minY + 5
    clip.scroll(to: NSPoint(x: 0, y: y))
    let original = try #require(table.view(atColumn: 0, row: anchorRow, makeIfNecessary: true))
    let originalHeight = table.rect(ofRow: anchorRow).height
    NotificationCenter.default.post(name: NSWindow.willStartLiveResizeNotification, object: window)
    var durations: [Double] = []
    for width in stride(from: 1180, through: 920, by: -20) {
      let start = CACurrentMediaTime()
      window.setContentSize(NSSize(width: width, height: 800))
      window.contentView?.layoutSubtreeIfNeeded()
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.001))
      durations.append((CACurrentMediaTime() - start) * 1000)
    }
    let during = try #require(table.view(atColumn: 0, row: anchorRow, makeIfNecessary: true))
    #expect(during === original)
    #expect(table.rect(ofRow: anchorRow).height == originalHeight)
    NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window)
    window.contentView?.layoutSubtreeIfNeeded()
    #expect(table.rect(ofRow: anchorRow).height > originalHeight)
    if atBottom {
      #expect(abs(clip.bounds.maxY - table.bounds.maxY) < 1)
    } else {
      #expect(table.row(at: NSPoint(x: 1, y: clip.bounds.minY + 1)) == anchorRow)
      #expect(abs(clip.bounds.minY - table.rect(ofRow: anchorRow).minY - 5) < 1)
    }
    print(
      "Resize benchmark, 240 messages: median \(durations.sorted()[durations.count / 2]) ms, max \(durations.max()!) ms"
    )
  }

  @Test func onlyTheActivePageParticipatesInWindowLayout() throws {
    let (controller, _) = try fixture()
    let window = try #require(controller.window)
    defer { window.close() }
    let split = try #require(window.contentViewController as? NSSplitViewController)
    let pages = split.splitViewItems[1].viewController
    let usage = try #require(pages.children.last as? UsagePageController)
    #expect(!usage.isViewLoaded)
    for index in 0..<3 {
      #expect(NSApp.sendAction(NSSelectorFromString("showUsage"), to: controller, from: nil))
      #expect(usage.view.superview === pages.view)
      #expect(pages.children[0].view.superview == nil)
      controller.store.selectedID = "next-\(index)"
      controller.refresh()
      #expect(usage.view.superview == nil)
      #expect(pages.children[0].view.superview === pages.view)
      #expect(pages.view.subviews.count == 1)
    }
  }

  @Test func messageTextStaysInsideItsRowAfterWindowResizing() throws {
    let (controller, table) = try fixture()
    let window = try #require(controller.window)
    defer { window.close() }
    func textViews(_ view: NSView) -> [MessageTextView] {
      (view as? MessageTextView).map { [$0] } ?? view.subviews.flatMap(textViews)
    }
    for width: CGFloat in [1200, 920, 1200] {
      controller.windowWillStartLiveResize(
        Notification(name: NSWindow.willStartLiveResizeNotification))
      window.setContentSize(NSSize(width: width, height: 800))
      window.layoutIfNeeded()
      controller.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification))
      let cell = try #require(table.view(atColumn: 0, row: 120, makeIfNecessary: true))
      cell.layoutSubtreeIfNeeded()
      let body = try #require(textViews(cell).first)
      let viewport = try #require(body.enclosingScrollView)
      let rect = viewport.convert(viewport.bounds, to: cell)
      #expect(rect.minX >= 0, "The first character must not be clipped by AppKit's row inset.")
      #expect(rect.maxX <= cell.bounds.maxX)
      #expect(body.visibleRect.minX == 0)
    }
  }
}
