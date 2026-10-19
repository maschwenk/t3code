import AppKit
import T3Core
import Testing

@testable import T3Native

@MainActor @Suite(.serialized) struct StartupTests {
  private func descendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(descendants)
  }

  private func visible(_ view: NSView) -> Bool {
    !view.isHidden && (view.superview.map(visible) ?? true)
  }

  @Test func firstLaunchHasAnActionableConnectionScreen() throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = ClientStore(draftDirectory: directory)
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
    defer { window.close() }
    let views = descendants(try #require(window.contentView))
    let labels = views.compactMap { $0 as? NSTextField }.filter(visible).map(\.stringValue)
    let buttons = views.compactMap { $0 as? NSButton }.filter(visible)
    let icon = try #require(views.first { $0.identifier?.rawValue == "thread-search-icon" })
    let search = try #require(
      views.compactMap { $0 as? NSTextField }.first {
        $0.accessibilityLabel() == "Search threads"
      })
    for query in ["", "a long thread search"] {
      search.stringValue = query
      controller.refresh()
      window.contentView?.layoutSubtreeIfNeeded()
      let iconBounds = icon.convert(icon.bounds, to: window.contentView)
      let searchBounds = search.convert(search.bounds, to: window.contentView)
      #expect(searchBounds.minX >= iconBounds.maxX + 4)
      #expect(searchBounds.width > 70)
    }
    #expect(!labels.contains("Connecting…"))
    #expect(buttons.contains { $0.title == "Connect to server…" && $0.isEnabled })
    #expect(!buttons.contains { ["Files", "Browser", "Changes", "Terminal"].contains($0.title) })
    #expect(!views.contains { $0 is Composer && visible($0) })

    store.error = "The saved connection could not be read."
    controller.refresh()
    let errorLabels = views.compactMap { $0 as? NSTextField }.filter(visible).map(\.stringValue)
    #expect(errorLabels.contains(store.error!))
    #expect(buttons.contains { $0.title == "Connect to server…" && $0.isEnabled })
  }

  @Test func selectionIsRestoredPerServerAndExplicitSelectionWins() throws {
    let suite = "T3Native.StartupTests.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let first = try ConnectionSettings(
      endpoint: URL(string: "http://127.0.0.1:4773")!, token: "test")
    let second = try ConnectionSettings(
      endpoint: URL(string: "http://127.0.0.1:4774")!, token: "test")
    let store = ClientStore(draftDirectory: directory, preferences: preferences)
    defer {
      store.disconnect()
      try? FileManager.default.removeItem(at: directory)
    }
    store.connect(first)
    store.select("first-thread")
    store.connect(second)
    #expect(store.selectedID == nil)
    store.select("second-thread")
    store.connect(first)
    #expect(store.selectedID == "first-thread")
    store.connect(first, selecting: "explicit-thread")
    #expect(store.selectedID == "explicit-thread")

    let reopened = ClientStore(draftDirectory: directory, preferences: preferences)
    defer { reopened.disconnect() }
    reopened.connect(second)
    #expect(reopened.selectedID == "second-thread")
  }
}
