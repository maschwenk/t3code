import AppKit
import Foundation
import T3Core
import Testing

@testable import T3Native

@MainActor private func conversationDescendants(_ view: NSView) -> [NSView] {
  [view] + view.subviews.flatMap(conversationDescendants)
}

/// AppKit lays out the real component under a fixed viewport, without an NSWindow or popover.
@MainActor private func conversationViewport(_ view: NSView, width: CGFloat, height: CGFloat)
  -> NSView
{
  let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
  host.addSubview(view)
  view.translatesAutoresizingMaskIntoConstraints = false
  NSLayoutConstraint.activate([
    view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
    view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
    view.topAnchor.constraint(equalTo: host.topAnchor),
    view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
  ])
  host.layoutSubtreeIfNeeded()
  #expect(view.window == nil)
  return host
}

@MainActor @Test func nativeConversationCompactOptionRowsKeepTheirLabelsInsideHitTargets() throws {
  let controller = ComposerOptionsPopover(
    "Permissions",
    options: [
      ComposerOption(
        title: "Supervised", description: ComposerControls.modeDescription("approval-required"),
        symbol: "lock", selected: true, action: {}),
      ComposerOption(
        title: "Full access", description: ComposerControls.modeDescription("full-access"),
        symbol: "lock.open", action: {}),
    ], width: 420, close: {})
  let view = controller.view
  let host = conversationViewport(view, width: 420, height: controller.contentSize.height)
  let buttons = conversationDescendants(view).compactMap { $0 as? ActionButton }
  #expect(buttons.count == 2)
  var prior: NSRect?
  for button in buttons {
    let row = try #require(button.superview)
    #expect(row.bounds.width > 380 && row.bounds.height >= 34)
    #expect(button.frame == row.bounds)
    let rowRect = row.convert(row.bounds, to: view)
    if let prior { #expect(!prior.intersects(rowRect)) }
    prior = rowRect
    for label in conversationDescendants(row).compactMap({ $0 as? NSTextField }) {
      let labelRect = label.convert(label.bounds, to: row)
      #expect(row.bounds.insetBy(dx: -0.5, dy: -0.5).contains(labelRect))
    }
  }
  withExtendedLifetime(host) {}
}

@MainActor @Test func nativeConversationReasoningDescriptionsDoNotOverlapTheNextOption() throws {
  let description =
    "Use extra reasoning for complex changes across several files, checking assumptions and evaluating alternative approaches before choosing an implementation."
  let controller = ComposerOptionsPopover(
    "Reasoning",
    options: [
      ComposerOption(title: "High", description: description, selected: true, action: {}),
      ComposerOption(title: "Low", description: "Respond quickly for simple tasks.", action: {}),
    ], width: 210, close: {})
  let view = controller.view
  let host = conversationViewport(view, width: 210, height: controller.contentSize.height)
  let detail = try #require(
    conversationDescendants(view).compactMap { $0 as? NSTextField }.first {
      $0.stringValue == description
    })
  let button = try #require(
    conversationDescendants(view).compactMap { $0 as? ActionButton }.first {
      $0.accessibilityLabel() == "High"
    })
  let row = try #require(button.superview)
  let detailRect = detail.convert(detail.bounds, to: row)
  #expect(
    row.bounds.insetBy(dx: -0.5, dy: -0.5).contains(detailRect),
    "The wrapping provider description must fit inside its clickable option, rather than overlap the next row."
  )
  withExtendedLifetime(host) {}
}

@MainActor @Test func nativeConversationLongBranchMenusKeepTheLastChoiceScrollable() throws {
  let options = (1...24).map { index in
    ComposerOption(title: "release/native-\(index)", selected: index == 24, action: {})
  }
  let controller = ComposerOptionsPopover("Base branch", options: options, width: 320, close: {})
  let view = controller.view
  #expect(controller.contentSize.height == 420)
  let host = conversationViewport(view, width: 320, height: controller.contentSize.height)
  let scroll = try #require(conversationDescendants(view).compactMap { $0 as? NSScrollView }.first)
  let document = try #require(scroll.documentView)
  #expect(document.bounds.height > scroll.contentSize.height)
  #expect(
    document.bounds.width <= scroll.contentSize.width + 1,
    "A vertically scrolling branch menu must keep its document as narrow as the viewport.")
  let buttons = conversationDescendants(document).compactMap { $0 as? ActionButton }
  #expect(buttons.count == 24)
  let last = try #require(buttons.first { $0.accessibilityLabel() == "release/native-24" })
  let lastRect = last.convert(last.bounds, to: document)
  #expect(document.bounds.insetBy(dx: -0.5, dy: -0.5).contains(lastRect))
  document.scrollToVisible(lastRect)
  #expect(document.visibleRect.insetBy(dx: -0.5, dy: -0.5).contains(lastRect))
  #expect(scroll.contentSize.width > 280)
  withExtendedLifetime(host) {}
}

@MainActor private func conversationLayoutStore(directory: URL) throws -> ClientStore {
  let store = ClientStore(draftDirectory: directory)
  let thread: JSON = .object([
    "id": .string("layout-thread"), "projectId": .string("layout-project"),
    "title": .string("Layout review"),
    "modelSelection": .object([
      "instanceId": .string("codex"), "model": .string("layout-model"),
      "options": .array([.object(["id": .string("effort"), "value": .string("high")])]),
    ]),
    "runtimeMode": .string("full-access"), "interactionMode": .string("plan"),
  ])
  try store.shell.apply(
    .object([
      "kind": .string("snapshot"),
      "snapshot": .object([
        "snapshotSequence": .number(1), "threads": .array([thread]), "projects": .array([]),
      ]),
    ]))
  store.selectedID = "layout-thread"
  try store.catalog.apply(
    try JSON.decode(
      Data(
        #"""
        {"type":"snapshot","config":{"providers":[{"instanceId":"codex","driver":"codex","enabled":true,"installed":true,"status":"ready","showInteractionModeToggle":true,"supportedRuntimeModes":["approval-required","full-access"],"models":[{"slug":"layout-model","name":"A provider model with a long display name","capabilities":{"optionDescriptors":[{"id":"effort","type":"select","label":"Reasoning","currentValue":"high","options":[{"id":"high","label":"High","isDefault":true}]}]}}]}],"settings":{}}}
        """#.utf8)))
  store.catalog.setPlanModeEnabled(true)
  return store
}

@MainActor @Test
func nativeConversationDisconnectedModelRowsKeepEveryControlReachableAtCompactWidth() throws {
  let directory = URL(
    fileURLWithPath: "/tmp/t3-native-evidence/conversation-layout-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = try conversationLayoutStore(directory: directory)
  let controls = ComposerControls(store: store)
  controls.refresh()
  let host = conversationViewport(controls, width: 280, height: 32)
  let originalViews = conversationDescendants(controls).compactMap { $0 as? ComposerPill }
  #expect(originalViews.count == 5)
  let minimum = controls.minimumCompactWidth
  #expect(minimum <= 200)
  for width: CGFloat in [280, 200, 900, 280] {
    host.setFrameSize(NSSize(width: width, height: 32))
    host.layoutSubtreeIfNeeded()
    let buttons = conversationDescendants(controls).compactMap { $0 as? ComposerPill }.filter {
      !$0.isHidden
    }
    let labels = Set(buttons.compactMap { $0.accessibilityLabel() })
    #expect(labels.isSuperset(of: ["Model", "Reasoning", "Permissions"]))
    #expect(buttons.count == 4)
    #expect(
      buttons.allSatisfy { !$0.isEnabled },
      "A disconnected conversation must not leave model or permission controls interactive.")
    for button in buttons {
      #expect(
        button.frame.width >= 36,
        "Each visible pill retains a usable minimum hit target after compacting.")
      #expect(
        button.frame.minX >= -0.5 && button.frame.maxX <= controls.bounds.maxX + 0.5,
        "The control must remain horizontally inside the composer row.")
    }
    if width < 900 {
      #expect(labels.contains("More conversation options"))
      let menu = controls.overflowMenu()
      let plan = try #require(menu.items.first { $0.title == "Plan mode" })
      #expect(plan.state == .on && !plan.isEnabled)
      let reasoning = try #require(
        menu.items.first { $0.title == "Reasoning" }?.submenu?.items.first)
      #expect(reasoning.title == "High" && reasoning.state == .on && !reasoning.isEnabled)
    } else {
      #expect(labels.contains("Interaction mode"))
      #expect(!labels.contains("More conversation options"))
    }
    controls.refresh()
    let reused = conversationDescendants(controls).compactMap { $0 as? ComposerPill }
    #expect(
      Set(originalViews.map(ObjectIdentifier.init)) == Set(reused.map(ObjectIdentifier.init)),
      "Resizing and unchanged refreshes reuse the controls instead of rebuilding conversation content."
    )
  }
  withExtendedLifetime(host) {}
}

@MainActor @Test
func nativeConversationWindowResizeRestoresComposerLabelsWithoutChildInvalidation() throws {
  let directory = URL(
    fileURLWithPath: "/tmp/t3-native-evidence/conversation-window-layout-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = try conversationLayoutStore(directory: directory)
  let nestedControls = ComposerControls(store: store)
  nestedControls.refresh()
  let endButtons = ["paperclip", "stop.fill", "arrow.up.circle.fill", "chevron.down"].enumerated()
    .map { index, symbol in
      let button = NSButton(
        image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!, target: nil,
        action: nil)
      button.isBordered = false
      button.widthAnchor.constraint(equalToConstant: index == 2 ? 36 : 24).isActive = true
      return button
    }
  let bottom = NSStackView(views: [nestedControls, NSView()] + endButtons)
  bottom.spacing = 8
  let editor = NSTextView()
  editor.isVerticallyResizable = true
  editor.isHorizontallyResizable = false
  editor.autoresizingMask = [.width]
  editor.textContainer?.widthTracksTextView = true
  let scroll = NSScrollView()
  scroll.documentView = editor
  scroll.heightAnchor.constraint(equalToConstant: 86).isActive = true
  let composer = NSStackView(views: [scroll, bottom])
  composer.orientation = .vertical
  composer.alignment = .leading
  composer.spacing = 8
  let surface = NSView()
  surface.addSubview(composer)
  composer.translatesAutoresizingMaskIntoConstraints = false
  NSLayoutConstraint.activate([
    composer.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 16),
    composer.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -16),
    composer.topAnchor.constraint(equalTo: surface.topAnchor, constant: 6),
    composer.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -6),
    scroll.widthAnchor.constraint(equalTo: composer.widthAnchor),
    bottom.widthAnchor.constraint(equalTo: composer.widthAnchor),
  ])
  _ = NSApplication.shared
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1187, height: 840),
    styleMask: [.titled, .resizable], backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  defer { window.close() }
  let content = try #require(window.contentView)
  content.addSubview(surface)
  surface.translatesAutoresizingMaskIntoConstraints = false
  let preferredWidth = surface.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -304)
  preferredWidth.priority = .defaultHigh
  NSLayoutConstraint.activate([
    surface.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 280),
    surface.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
    surface.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
    surface.heightAnchor.constraint(equalToConstant: 142),
    surface.widthAnchor.constraint(lessThanOrEqualToConstant: 880),
    preferredWidth,
  ])
  let nestedViews = conversationDescendants(nestedControls).compactMap { $0 as? ComposerPill }
  for width: CGFloat in [1187, 900, 1187, 900, 1187] {
    window.setContentSize(NSSize(width: width, height: width == 900 ? 720 : 839))
    // Flush only AppKit's pending layout; do not invalidate the controls or their descendants.
    window.layoutIfNeeded()
    let visible = conversationDescendants(nestedControls).compactMap { $0 as? ComposerPill }.filter
    { !$0.isHidden }
    #expect(
      Set(visible.compactMap { $0.accessibilityLabel() }).isSuperset(of: [
        "Model", "Reasoning", "Permissions",
      ]))
    #expect(bottom.bounds.width == min(880, width - 304) - 32)
    #expect(scroll.bounds.width == bottom.bounds.width)
    var previousRect: NSRect?
    for button in visible + endButtons {
      let rect = button.convert(button.bounds, to: bottom)
      if let previousRect { #expect(!previousRect.intersects(rect)) }
      previousRect = rect
      #expect(rect.width >= (endButtons.contains(button) ? 24 : 36))
      #expect(rect.minX >= -0.5 && rect.maxX <= bottom.bounds.maxX + 0.5)
    }
    if width == 1187 {
      let model = try #require(visible.first { $0.accessibilityLabel() == "Model" })
      let reasoning = try #require(visible.first { $0.accessibilityLabel() == "Reasoning" })
      let permissions = try #require(visible.first { $0.accessibilityLabel() == "Permissions" })
      #expect(model.title == "A provider model with a long display name  ⌄")
      #expect(reasoning.title == "High  ⌄")
      #expect(permissions.title == "Full access  ⌄")
      #expect(model.frame.width > 100 && reasoning.frame.width > 36 && permissions.frame.width > 80)
      #expect(visible.contains { $0.accessibilityLabel() == "Interaction mode" })
      #expect(!visible.contains { $0.accessibilityLabel() == "More conversation options" })
      #expect(reasoning.frame.width >= reasoning.intrinsicContentSize.width - 0.5)
      #expect(permissions.frame.width >= permissions.intrinsicContentSize.width - 0.5)
    } else {
      #expect(visible.first { $0.accessibilityLabel() == "Model" }?.title == "Model  ⌄")
      #expect(visible.first { $0.accessibilityLabel() == "Permissions" }?.title == "Access  ⌄")
      #expect(visible.contains { $0.accessibilityLabel() == "More conversation options" })
    }
    let currentViews = conversationDescendants(nestedControls).compactMap { $0 as? ComposerPill }
    #expect(
      Set(nestedViews.map(ObjectIdentifier.init)) == Set(currentViews.map(ObjectIdentifier.init)))
  }
}

@Test func nativeConversationBranchFetchRetriesReadinessAndRejectsStaleSessions() {
  let initialSession = UUID()
  func key(ready: Bool = true, session: UUID? = nil, retry: Int = 0, draftID: String = "draft")
    -> DraftBranchFetchState.Key
  {
    .init(
      environment: "ws://server", session: session ?? initialSession, draftID: draftID,
      root: "/repo", ready: ready, retry: retry)
  }
  var fetch = DraftBranchFetchState()
  #expect({ fetch.select(key(ready: false)) }())
  #expect(!fetch.loading)
  let request = key()
  #expect({ fetch.select(request) }())
  #expect(fetch.loading)
  #expect(
    { !fetch.select(request) }(),
    "An ordinary refresh does not refetch or cancel an in-flight request.")
  #expect({ fetch.finish(request, current: request, error: "Connection closed") }())
  #expect(fetch.failure == "Connection closed" && !fetch.loading)
  #expect({ !fetch.select(request) }(), "A failure stays visible without creating a request loop.")
  let retry = key(retry: 1)
  #expect({ fetch.select(retry) }())
  #expect(fetch.loading && fetch.failure == nil)
  #expect(
    { !fetch.finish(request, current: retry) }(),
    "A late result from before retry cannot replace newer branches.")
  #expect({ fetch.finish(retry, current: retry) }())
  let reconnected = key(session: UUID(), retry: 1)
  #expect({ fetch.select(reconnected) }())
  #expect(fetch.loading)
  #expect(
    { !fetch.finish(retry, current: reconnected) }(),
    "The same endpoint and project after reconnect is a new scope.")
  #expect(
    {
      !fetch.finish(reconnected, current: key(ready: false, session: reconnected.session, retry: 1))
    }())
  #expect(
    {
      !fetch.finish(
        reconnected, current: key(session: reconnected.session, retry: 1, draftID: "other"))
    }())
  #expect({ fetch.finish(reconnected, current: reconnected) }())
  #expect(!fetch.loading && fetch.failure == nil)
}

@MainActor @Test func nativeConversationContextReminderFitsAndDismissesWithoutCompacting() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = ClientStore(draftDirectory: directory)
  store.selectedID = "context-layout"
  var thread = ThreadState(id: "context-layout")
  _ = try thread.apply(
    try JSON.decode(
      Data(
        #"""
        {"kind":"snapshot","snapshotSequence":1,"projection":{
          "thread":{"id":"context-layout","activeProviderThreadId":"context-provider"},
          "providerThreads":[{"id":"context-provider","appThreadId":"context-layout",
            "driver":"claudeAgent","providerInstanceId":"context-layout-test",
            "updatedAt":"2020-01-01T12:00:00Z","contextUsage":{"usedTokens":206000,"maxTokens":200000}}]
        }}
        """#.utf8)))
  store.thread = thread
  let banner = NativeContextBanner(store: store)
  var compacted = false
  banner.onCompact = { compacted = true }
  let host = conversationViewport(banner, width: 880, height: 70)
  let dismiss = try #require(
    conversationDescendants(banner).compactMap { $0 as? NSButton }.first {
      $0.accessibilityLabel() == "Keep full history"
    })
  let reminder = try #require(dismiss.superview)
  #expect(!reminder.isHidden)
  for width: CGFloat in [880, 420, 880] {
    host.setFrameSize(NSSize(width: width, height: 70))
    host.layoutSubtreeIfNeeded()
    let controls = reminder.subviews.filter { $0 is NSTextField || $0 is NSButton }
    for control in controls {
      #expect(control.frame.minX >= 0 && control.frame.maxX <= reminder.bounds.maxX)
    }
    #expect(dismiss.frame.maxX >= reminder.bounds.maxX - 12)
  }
  dismiss.performClick(nil)
  #expect(reminder.isHidden)
  #expect(!compacted)
  let meter = try #require(
    conversationDescendants(banner).compactMap { $0 as? NSButton }.first {
      $0.accessibilityLabel()?.hasPrefix("Context usage:") == true
    })
  #expect(meter.isEnabled && !banner.isHidden)
  withExtendedLifetime(host) {}
}
