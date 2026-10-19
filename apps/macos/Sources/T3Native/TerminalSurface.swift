import AppKit
import GhosttyKit
import Metal
import QuartzCore
import T3Core

/// Ghostty owns rendering and terminal protocols; the connected server owns the PTY.
@MainActor final class TerminalSurface: NSView, @preconcurrency NSTextInputClient {
  private static let initialized = ghostty_init(1, CommandLine.unsafeArgv) == 0
  var onInput: ((String) -> Void)?
  var onResize: ((TerminalGrid) -> Void)?
  var onError: ((String) -> Void)?
  var onShortcut: ((NSEvent) -> Bool)?
  var onOpenLink: ((URL) -> Void)?
  var inputEnabled = false
  private var app: ghostty_app_t?
  private var surface: ghostty_surface_t?
  private var cursor: TerminalOutput.Cursor?
  private var lastGrid: TerminalGrid?
  private var lastPixels: NSSize?
  private var lastScale: CGFloat?
  private var creating = false
  private var creationFailed = false
  private var marked = NSAttributedString(string: "")
  private var accumulated: [String]?
  private var tracking: NSTrackingArea?
  private var fontSize: Float = 12

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    setAccessibilityElement(true)
    setAccessibilityRole(.textArea)
    setAccessibilityLabel("Terminal")
    for name in [
      NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
      NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
    ] {
      NotificationCenter.default.addObserver(
        self, selector: #selector(focusChanged), name: name, object: nil)
    }
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  isolated deinit { stop() }
  override var acceptsFirstResponder: Bool { true }

  func start() {
    guard surface == nil, !creating, !creationFailed, bounds.width > 0, bounds.height > 0 else {
      return
    }
    guard Self.initialized else {
      fail("The terminal engine could not start.")
      return
    }
    creating = true
    defer { creating = false }
    guard let config = configuration() else {
      fail("Terminal settings could not be loaded.")
      return
    }
    defer { ghostty_config_free(config) }
    var runtime = ghostty_runtime_config_s(
      userdata: Unmanaged.passUnretained(self).toOpaque(),
      supports_selection_clipboard: false,
      wakeup_cb: { @Sendable pointer in TerminalSurface.wakeup(pointer) },
      action_cb: { @Sendable app, target, action in TerminalSurface.action(app, target, action) },
      read_clipboard_cb: { @Sendable _, _, _, _, _, _ in GHOSTTY_CLIPBOARD_READ_UNSUPPORTED },
      confirm_read_clipboard_cb: { @Sendable _, _, _, _ in },
      write_clipboard_cb: { @Sendable _, _, _, _, _ in },
      close_surface_cb: { @Sendable _, _ in }
    )
    guard let app = ghostty_app_new(&runtime, config) else {
      fail("The terminal engine could not start.")
      return
    }
    self.app = app
    var options = ghostty_surface_config_new()
    options.platform_tag = GHOSTTY_PLATFORM_MACOS
    options.platform.macos.nsview = Unmanaged.passUnretained(self).toOpaque()
    options.userdata = Unmanaged.passUnretained(self).toOpaque()
    options.scale_factor = Double(window?.backingScaleFactor ?? 2)
    options.font_size = fontSize
    options.use_custom_io = true
    options.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
    guard let surface = ghostty_surface_new(app, &options) else {
      self.app = nil
      ghostty_app_free(app)
      fail("The terminal renderer could not start.")
      return
    }
    self.surface = surface
    ghostty_surface_set_write_callback(
      surface,
      { @Sendable pointer, bytes, count in
        TerminalSurface.write(pointer, bytes, count)
      }, Unmanaged.passUnretained(self).toOpaque())
    updateSize()
    updateFocus()
  }

  func stop() {
    inputEnabled = false
    if let surface {
      self.surface = nil
      ghostty_surface_set_write_callback(surface, nil, nil)
      ghostty_surface_free(surface)
    }
    if let app {
      self.app = nil
      ghostty_app_free(app)
    }
    cursor = nil
    lastGrid = nil
    lastPixels = nil
    lastScale = nil
    creationFailed = false
    unmarkText()
  }

  func synchronize(_ output: TerminalOutput) {
    start()
    guard let surface else { return }
    let update = output.read(after: cursor)
    if update.reset { binding("reset") }
    if !update.bytes.isEmpty {
      update.bytes.withUnsafeBytes { bytes in
        ghostty_surface_feed_data(
          surface, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
      }
    }
    cursor = update.cursor
  }

  private func fail(_ message: String) {
    creationFailed = true
    onError?(message)
  }
  private func configuration() -> ghostty_config_t? {
    guard let config = ghostty_config_new() else { return nil }
    let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let text = """
      font-family = Menlo
      font-size = \(fontSize)
      background = \(dark ? "0b0b0b" : "ffffff")
      foreground = \(dark ? "e5e5e5" : "202020")
      window-padding-x = 8
      window-padding-y = 6
      keybind = clear
      clipboard-read = deny
      clipboard-write = deny
      confirm-close-surface = false
      """
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(
      "t3-terminal-\(UUID().uuidString).conf")
    do {
      try Data(text.utf8).write(to: file, options: .atomic)
      defer { try? FileManager.default.removeItem(at: file) }
      file.path.withCString { ghostty_config_load_file(config, $0) }
      ghostty_config_finalize(config)
      guard ghostty_config_diagnostics_count(config) == 0 else {
        ghostty_config_free(config)
        return nil
      }
      return config
    } catch {
      ghostty_config_free(config)
      return nil
    }
  }

  // Ghostty invokes I/O callbacks on its worker. Enter AppKit only after dispatching to main.
  private nonisolated static func wakeup(_ pointer: UnsafeMutableRawPointer?) {
    guard let pointer else { return }
    let view = Unmanaged<TerminalSurface>.fromOpaque(pointer).takeUnretainedValue()
    DispatchQueue.main.async { [weak view] in
      if let app = view?.app { ghostty_app_tick(app) }
    }
  }
  private nonisolated static func write(
    _ pointer: UnsafeMutableRawPointer?, _ bytes: UnsafePointer<UInt8>?, _ count: Int
  ) {
    guard let pointer, let bytes, count > 0 else { return }
    let view = Unmanaged<TerminalSurface>.fromOpaque(pointer).takeUnretainedValue()
    let text = String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
    DispatchQueue.main.async { [weak view] in
      guard let view, view.inputEnabled else { return }
      view.onInput?(text)
    }
  }
  private nonisolated static func action(
    _ app: ghostty_app_t?, _ target: ghostty_target_s, _ action: ghostty_action_s
  ) -> Bool {
    guard let app, let pointer = ghostty_app_userdata(app) else { return false }
    let view = Unmanaged<TerminalSurface>.fromOpaque(pointer).takeUnretainedValue()
    switch action.tag {
    case GHOSTTY_ACTION_OPEN_URL:
      let value = action.action.open_url
      guard let pointer = value.url else { return false }
      let bytes = UnsafeRawBufferPointer(start: pointer, count: Int(value.len))
      guard let url = URL(string: String(decoding: bytes, as: UTF8.self)) else { return false }
      DispatchQueue.main.async { [weak view] in view?.onOpenLink?(url) }
      return true
    case GHOSTTY_ACTION_RING_BELL:
      DispatchQueue.main.async { NSSound.beep() }
      return true
    case GHOSTTY_ACTION_CELL_SIZE:
      DispatchQueue.main.async { [weak view] in view?.updateSize() }
      return true
    default: return false
    }
  }

  override func layout() {
    super.layout()
    start()
    updateSize()
  }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateSize()
    updateFocus()
  }
  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    updateSize()
  }
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    guard let surface, let config = configuration() else { return }
    ghostty_surface_update_config(surface, config)
    ghostty_config_free(config)
  }
  private func updateSize() {
    guard let surface else { return }
    let scale = window?.backingScaleFactor ?? 2
    if lastScale != scale {
      lastScale = scale
      ghostty_surface_set_content_scale(surface, scale, scale)
    }
    let pixels = NSSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
    if lastPixels != pixels {
      lastPixels = pixels
      ghostty_surface_set_size(surface, UInt32(pixels.width), UInt32(pixels.height))
    }
    ghostty_surface_set_occlusion(surface, window != nil && !isHiddenOrHasHiddenAncestor)
    if let display = window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
      as? NSNumber
    {
      ghostty_surface_set_display_id(surface, display.uint32Value)
    }
    let size = ghostty_surface_size(surface)
    let grid = TerminalGrid(columns: Int(size.columns), rows: Int(size.rows))
    if grid != lastGrid {
      lastGrid = grid
      onResize?(grid)
    }
  }
  private func updateFocus() {
    guard let surface, let app else { return }
    ghostty_app_set_focus(app, NSApp.isActive)
    ghostty_surface_set_focus(
      surface, window?.firstResponder === self && window?.isKeyWindow == true)
  }
  @objc private func focusChanged() { updateFocus() }
  override func becomeFirstResponder() -> Bool {
    if let surface { ghostty_surface_set_focus(surface, window?.isKeyWindow == true) }
    return true
  }
  override func resignFirstResponder() -> Bool {
    if let surface { ghostty_surface_set_focus(surface, false) }
    return true
  }

  private static func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
    var value: UInt32 = 0
    for (flag, bit) in [
      (NSEvent.ModifierFlags.shift, GHOSTTY_MODS_SHIFT), (.control, GHOSTTY_MODS_CTRL),
      (.option, GHOSTTY_MODS_ALT), (.command, GHOSTTY_MODS_SUPER), (.capsLock, GHOSTTY_MODS_CAPS),
    ] {
      if flags.contains(flag) { value |= bit.rawValue }
    }
    return ghostty_input_mods_e(rawValue: value)
  }
  private func key(
    _ event: NSEvent, action: ghostty_input_action_e, text: String? = nil, composing: Bool = false
  ) {
    guard inputEnabled, let surface else { return }
    var key = ghostty_input_key_s()
    key.action = action
    key.keycode = UInt32(event.keyCode)
    key.mods = Self.mods(event.modifierFlags)
    key.consumed_mods = Self.mods(event.modifierFlags.subtracting([.control, .command]))
    if event.type == .keyDown || event.type == .keyUp {
      key.unshifted_codepoint =
        event.characters(byApplyingModifiers: [])?.unicodeScalars.first?.value ?? 0
    }
    key.composing = composing
    if let text, let first = text.unicodeScalars.first, first.value >= 0x20,
      !(0xF700...0xF8FF).contains(first.value)
    {
      text.withCString {
        key.text = $0
        _ = ghostty_surface_key(surface, key)
      }
    } else {
      _ = ghostty_surface_key(surface, key)
    }
  }
  override func keyDown(with event: NSEvent) {
    guard inputEnabled else {
      NSSound.beep()
      return
    }
    let wasMarked = hasMarkedText()
    accumulated = []
    interpretKeyEvents([event])
    let committed = accumulated ?? []
    accumulated = nil
    let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
    if wasMarked && !committed.isEmpty {
      for text in committed { commit(text) }
    } else if !committed.isEmpty {
      for text in committed { key(event, action: action, text: text) }
    } else {
      key(event, action: action, text: event.characters, composing: wasMarked || hasMarkedText())
    }
  }
  override func keyUp(with event: NSEvent) { key(event, action: GHOSTTY_ACTION_RELEASE) }
  override func flagsChanged(with event: NSEvent) {
    guard !hasMarkedText() else { return }
    let flag: NSEvent.ModifierFlags
    switch event.keyCode {
    case 0x39: flag = .capsLock
    case 0x38, 0x3C: flag = .shift
    case 0x3B, 0x3E: flag = .control
    case 0x3A, 0x3D: flag = .option
    case 0x37, 0x36: flag = .command
    default: return
    }
    key(
      event,
      action: event.modifierFlags.contains(flag) ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE)
  }
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard window?.firstResponder === self else { return false }
    if onShortcut?(event) == true { return true }
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if flags == .command {
      switch event.charactersIgnoringModifiers {
      case "c":
        copy(nil)
        return true
      case "v":
        paste(nil)
        return true
      case "a":
        selectAll(nil)
        return true
      case "+", "=":
        changeFontSize(fontSize + 1)
        return true
      case "-":
        changeFontSize(fontSize - 1)
        return true
      case "0":
        changeFontSize(12)
        return true
      default: break
      }
    }
    return false
  }
  private func changeFontSize(_ size: Float) {
    fontSize = max(4, min(96, size))
    binding("set_font_size:\(fontSize)")
    updateSize()
  }
  override func doCommand(by selector: Selector) {}
  private func commit(_ text: String) {
    guard inputEnabled, let surface, !text.isEmpty else { return }
    var key = ghostty_input_key_s()
    key.action = GHOSTTY_ACTION_PRESS
    text.withCString {
      key.text = $0
      _ = ghostty_surface_key(surface, key)
    }
  }
  func insertText(_ string: Any, replacementRange: NSRange) {
    let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
    unmarkText()
    if accumulated != nil { accumulated?.append(text) } else { commit(text) }
  }
  func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    marked =
      (string as? NSAttributedString) ?? NSAttributedString(string: (string as? String) ?? "")
    if let surface {
      marked.string.withCString {
        ghostty_surface_preedit(surface, $0, UInt(marked.string.utf8.count))
      }
    }
  }
  func unmarkText() {
    marked = NSAttributedString(string: "")
    if let surface { ghostty_surface_preedit(surface, nil, 0) }
  }
  func hasMarkedText() -> Bool { marked.length > 0 }
  func markedRange() -> NSRange {
    NSRange(location: hasMarkedText() ? 0 : NSNotFound, length: marked.length)
  }
  func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
  func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
  func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?)
    -> NSAttributedString?
  { nil }
  func characterIndex(for point: NSPoint) -> Int { 0 }
  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
    var x = 0.0
    var y = 0.0
    var width = 0.0
    var height = 0.0
    if let surface { ghostty_surface_ime_point(surface, &x, &y, &width, &height) }
    let rect = convert(
      NSRect(x: x, y: bounds.height - y - height, width: width, height: height), to: nil)
    return window?.convertToScreen(rect) ?? rect
  }

  private func binding(_ value: String) {
    guard let surface else { return }
    value.withCString { _ = ghostty_surface_binding_action(surface, $0, UInt(value.utf8.count)) }
  }
  var selectedText: String? {
    guard let surface else { return nil }
    var text = ghostty_text_s()
    guard ghostty_surface_read_selection(surface, &text), let pointer = text.text else {
      return nil
    }
    defer { ghostty_surface_free_text(surface, &text) }
    return String(cString: pointer)
  }
  override func accessibilityValue() -> Any? {
    guard let surface else { return "" }
    var text = ghostty_text_s()
    let selection = ghostty_selection_s(
      top_left: ghostty_point_s(
        tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
      bottom_right: ghostty_point_s(
        tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
      rectangle: false)
    guard ghostty_surface_read_text(surface, selection, &text), let pointer = text.text else {
      return ""
    }
    defer { ghostty_surface_free_text(surface, &text) }
    return String(cString: pointer)
  }
  override func accessibilitySelectedText() -> String? { selectedText }
  @objc func copy(_ sender: Any?) {
    guard let text = selectedText, !text.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
  @objc func paste(_ sender: Any?) {
    guard let text = NSPasteboard.general.string(forType: .string) else { return }
    pasteText(text)
  }
  func pasteText(_ text: String) {
    guard inputEnabled, let surface else { return }
    text.withCString { ghostty_surface_text(surface, $0, UInt(text.utf8.count)) }
  }
  @objc override func selectAll(_ sender: Any?) { binding("select_all") }
  override func menu(for event: NSEvent) -> NSMenu? {
    let menu = NSMenu()
    for (label, action) in [
      ("Copy", #selector(copy(_:))), ("Paste", #selector(paste(_:))),
      ("Select All", #selector(selectAll(_:))),
    ] {
      let item = menu.addItem(withTitle: label, action: action, keyEquivalent: "")
      item.target = self
    }
    return menu
  }
  override func updateTrackingAreas() {
    if let tracking { removeTrackingArea(tracking) }
    let tracking = NSTrackingArea(
      rect: bounds, options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect], owner: self)
    self.tracking = tracking
    addTrackingArea(tracking)
    super.updateTrackingAreas()
  }
  override func resetCursorRects() { addCursorRect(bounds, cursor: .iBeam) }
  override func mouseMoved(with event: NSEvent) {
    guard let surface else { return }
    let point = convert(event.locationInWindow, from: nil)
    ghostty_surface_mouse_pos(
      surface, point.x, bounds.height - point.y, Self.mods(event.modifierFlags))
  }
  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    mouseMoved(with: event)
    if let surface {
      _ = ghostty_surface_mouse_button(
        surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, Self.mods(event.modifierFlags))
    }
  }
  override func mouseUp(with event: NSEvent) {
    mouseMoved(with: event)
    if let surface {
      _ = ghostty_surface_mouse_button(
        surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, Self.mods(event.modifierFlags))
    }
  }
  override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
  override func scrollWheel(with event: NSEvent) {
    guard let surface else { return }
    let factor = event.hasPreciseScrollingDeltas ? 2.0 : 1.0
    let momentum: Int32 =
      switch event.momentumPhase {
      case .began: 1
      case .stationary: 2
      case .changed: 3
      case .ended: 4
      case .cancelled: 5
      case .mayBegin: 6
      default: 0
      }
    ghostty_surface_mouse_scroll(
      surface, event.scrollingDeltaX * factor, event.scrollingDeltaY * factor,
      (event.hasPreciseScrollingDeltas ? 1 : 0) | momentum << 1)
  }
}
