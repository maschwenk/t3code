import ExpoModulesCore
import OSLog
import QuartzCore
import UIKit

// Diagnostics for the iPhone Duo vertical-bar blur, on the diag/duo-rail-blur branch only.
// Appends app lifecycle events, every header button set, and the state of each view in the
// right-hand 88pt of the window to Application Support/T3RailDiag.log (and os_log). A rail
// snapshot is written only when it differs from the previous one, so the log shows the moment
// the buttons change. From lldb: expr -l objc -O -- [T3RailDiagnostics dumpNow]
public final class T3RailDiagnosticsSubscriber: ExpoAppDelegateSubscriber {
  public func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    T3RailDiagnostics.shared.start(application, launchOptions: launchOptions)
    return true
  }
}

@objc(T3RailDiagnostics)
public final class T3RailDiagnostics: NSObject {
  @objc public static let shared = T3RailDiagnostics()

  private let logger = Logger(subsystem: "com.maschwenk.t3code.diag", category: "rail")
  private let formatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone.current
    return formatter
  }()
  private var handle: FileHandle?
  private var buffer = Data()
  private var started = false
  private var lastSignature: String?
  private var lastWrite = Date()
  private var timer: Timer?
  private var backgroundedAt: Date?
  private var pendingSample: DispatchWorkItem?
  private var barSets = 0

  func start(_ application: UIApplication, launchOptions: [UIApplication.LaunchOptionsKey: Any]?) {
    guard !started else { return }
    started = true
    openLog()
    let options = (launchOptions?.keys.map(\.rawValue) ?? []).sorted().joined(separator: ",")
    let info = Bundle.main.infoDictionary ?? [:]
    let version = "\(info["CFBundleShortVersionString"] ?? "?")(\(info["CFBundleVersion"] ?? "?"))"
    write(
      "launch state=\(Self.name(application.applicationState)) options=[\(options)] version=\(version) ios=\(UIDevice.current.systemVersion)"
    )
    Self.installSwizzles()
    observeLifecycle()
    scheduleSample("launch+2s", after: 2)
    startTimer()
  }

  @objc public static func dumpNow() -> String {
    shared.sample("manual", force: true)
    return shared.lastSignature ?? ""
  }

  func noteBarItems(_ side: String, _ items: [UIBarButtonItem]?, animated: Bool) {
    barSets += 1
    let list = (items ?? []).map(Self.describe(item:)).joined(separator: ",")
    write(
      "bar#\(barSets) \(side) n=\(items?.count ?? 0) animated=\(animated ? 1 : 0) state=\(Self.name(UIApplication.shared.applicationState)) [\(list)]",
      flushNow: false
    )
    pendingSample?.cancel()
    let item = DispatchWorkItem { [weak self] in self?.sample("after-bar", force: false) }
    pendingSample = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: item)
  }

  // MARK: Lifecycle

  private func observeLifecycle() {
    let events: [(Notification.Name, String)] = [
      (UIApplication.didEnterBackgroundNotification, "didEnterBackground"),
      (UIApplication.willEnterForegroundNotification, "willEnterForeground"),
      (UIApplication.didBecomeActiveNotification, "didBecomeActive"),
      (UIApplication.willResignActiveNotification, "willResignActive"),
      (UIApplication.didReceiveMemoryWarningNotification, "memoryWarning"),
      (UIApplication.protectedDataWillBecomeUnavailableNotification, "deviceLocking"),
      (UIApplication.protectedDataDidBecomeAvailableNotification, "deviceUnlocked"),
      (UIApplication.significantTimeChangeNotification, "significantTimeChange"),
      (UIApplication.willTerminateNotification, "willTerminate"),
      (UIScene.willConnectNotification, "sceneWillConnect"),
      (UIScene.didDisconnectNotification, "sceneDidDisconnect"),
      (UIScene.didActivateNotification, "sceneDidActivate"),
      (UIScene.willDeactivateNotification, "sceneWillDeactivate"),
      (UIScene.didEnterBackgroundNotification, "sceneDidEnterBackground"),
      (UIScene.willEnterForegroundNotification, "sceneWillEnterForeground"),
    ]
    for (name, label) in events {
      NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
        [weak self] _ in
        self?.lifecycle(label)
      }
    }
  }

  private func lifecycle(_ label: String) {
    var extra = ""
    switch label {
    case "didEnterBackground":
      backgroundedAt = Date()
      timer?.invalidate()
      timer = nil
    case "didBecomeActive":
      if let since = backgroundedAt {
        extra = " away=\(Int(Date().timeIntervalSince(since)))s"
      }
      backgroundedAt = nil
      startTimer()
      scheduleSample("active+0.3s", after: 0.3)
      scheduleSample("active+2s", after: 2)
    default:
      break
    }
    write("event \(label) state=\(Self.name(UIApplication.shared.applicationState))\(extra)")
  }

  private func scheduleSample(_ tag: String, after delay: TimeInterval) {
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
      self?.sample(tag, force: true)
    }
  }

  private func startTimer() {
    guard timer == nil else { return }
    let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
      self?.sample("tick", force: false)
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  // MARK: Rail snapshot

  private struct Snapshot {
    let signature: String
    let lines: [String]
    let suspect: Bool
  }

  private func sample(_ tag: String, force: Bool) {
    let snapshot = railSnapshot()
    let changed = snapshot.signature != lastSignature
    guard force || changed else {
      if tag == "tick", Date().timeIntervalSince(lastWrite) > 300 {
        write("tick rail unchanged state=\(Self.name(UIApplication.shared.applicationState))")
      }
      return
    }
    lastSignature = snapshot.signature
    write(
      "rail \(tag) state=\(Self.name(UIApplication.shared.applicationState)) changed=\(changed ? 1 : 0)\(snapshot.suspect ? " SUSPECT" : "") lines=\(snapshot.lines.count)",
      flushNow: false
    )
    for line in snapshot.lines {
      write("  \(line)", flushNow: false)
    }
    flush()
  }

  private func railSnapshot() -> Snapshot {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
      .filter { !$0.isHidden }
    guard !windows.isEmpty else {
      return Snapshot(signature: "no-window", lines: ["no visible window"], suspect: false)
    }
    var lines: [String] = []
    var suspect = false
    for window in windows {
      let bounds = window.bounds
      // The folded Duo's rail is the right-hand ~80pt; list content ends just left of it.
      let rail = CGRect(x: bounds.maxX - 88, y: bounds.minY, width: 88, height: bounds.height)
      let traits = window.traitCollection
      lines.append(
        "window \(NSStringFromClass(type(of: window))) \(Self.rect(bounds)) level=\(Int(window.windowLevel.rawValue)) key=\(window.isKeyWindow ? 1 : 0) style=\(traits.userInterfaceStyle.rawValue) scale=\(traits.displayScale)"
      )
      visit(window, window: window, rail: rail, path: [], lines: &lines, suspect: &suspect)
    }
    return Snapshot(signature: lines.joined(separator: "\n"), lines: lines, suspect: suspect)
  }

  private static let reactNoise = ["RCT", "MenuView", "FabricMenu", "ExpoSymbols"]
  private static let structural = ["Pocket", "Capture", "Portal", "Backdrop", "Bar", "Glass", "Lens"]

  private func visit(
    _ view: UIView, window: UIWindow, rail: CGRect, path: [Int], lines: inout [String],
    suspect: inout Bool
  ) {
    // The navigation bar that draws the rail lives inside React's root view, so walk everything,
    // but leave React's own rows out of the log: they scroll under the rail and are never blurred.
    let className = NSStringFromClass(type(of: view))
    let frame = view.convert(view.bounds, to: window)
    let isReact = Self.reactNoise.contains { className.hasPrefix($0) || className.contains($0) }
    if frame.intersects(rail), !isReact, frame.width <= 160 || Self.isInteresting(view) {
      var line = describe(view, className: className, frame: frame, depth: path.count, suspect: &suspect)
      // The index path from the window gives the z-order: a later sibling draws above.
      if Self.structural.contains(where: { className.contains($0) }) {
        line += " path=\(path.map(String.init).joined(separator: "."))"
      }
      lines.append(line)
      lines.append(contentsOf: describeSublayers(of: view, window: window, depth: path.count, suspect: &suspect))
    }
    for (index, subview) in view.subviews.enumerated() {
      visit(
        subview, window: window, rail: rail, path: path + [index], lines: &lines, suspect: &suspect)
    }
  }

  private static func isInteresting(_ view: UIView) -> Bool {
    let layer = view.layer
    return view.alpha < 0.999 || !(layer.filters ?? []).isEmpty || layer.compositingFilter != nil
      || !(layer.animationKeys() ?? []).isEmpty || layer.speed != 1
  }

  // Layers that no view owns (backdrops, portals, captured content) can draw over the buttons.
  private func describeSublayers(of view: UIView, window: UIWindow, depth: Int, suspect: inout Bool)
    -> [String]
  {
    let className = NSStringFromClass(type(of: view))
    return (view.layer.sublayers ?? []).compactMap { sublayer -> String? in
      if sublayer.delegate is UIView { return nil }
      let frame = view.layer.convert(sublayer.frame, to: window.layer)
      var parts = ["\(depth)   L \(NSStringFromClass(type(of: sublayer))) \(Self.rect(frame))"]
      if sublayer.isHidden { parts.append("hidden") }
      if sublayer.opacity < 0.999 { parts.append("opacity=\(Self.round(sublayer.opacity))") }
      let filters = Self.filters(sublayer.filters, className: className, suspect: &suspect)
      if !filters.isEmpty { parts.append("filters=[\(filters)]") }
      if let compositing = sublayer.compositingFilter { parts.append("compositing=\(compositing)") }
      if let keys = sublayer.animationKeys(), !keys.isEmpty {
        parts.append("anims=[\(keys.joined(separator: ","))]")
      }
      if let count = sublayer.sublayers?.count, count > 0 { parts.append("sublayers=\(count)") }
      return parts.joined(separator: " ")
    }
  }

  private func describe(
    _ view: UIView, className: String, frame: CGRect, depth: Int, suspect: inout Bool
  ) -> String {
    let layer = view.layer
    let presentation = layer.presentation()
    var parts = ["\(depth) \(className) \(Self.rect(frame))"]
    if view.isHidden { parts.append("hidden") }
    if view.alpha < 0.999 { parts.append("alpha=\(Self.round(view.alpha))") }
    if let presentation, abs(presentation.opacity - layer.opacity) > 0.01 {
      parts.append("presOpacity=\(Self.round(presentation.opacity))")
    }
    if layer.speed != 1 {
      parts.append("speed=\(layer.speed)")
      if layer.speed == 0 { suspect = true }
    }
    if layer.shouldRasterize { parts.append("rasterize@\(layer.rasterizationScale)") }
    let displayScale = view.traitCollection.displayScale
    if layer.contents != nil, displayScale > 0, layer.contentsScale < displayScale - 0.5 {
      parts.append("contentsScale=\(layer.contentsScale)")
      suspect = true
    }
    if !CATransform3DIsIdentity(layer.transform) { parts.append("transformed") }
    let filters = Self.filters(layer.filters, className: className, suspect: &suspect)
    if !filters.isEmpty { parts.append("filters=[\(filters)]") }
    if let presentation {
      let presentationFilters = Self.filters(
        presentation.filters, className: className, suspect: &suspect)
      if presentationFilters != filters { parts.append("presFilters=[\(presentationFilters)]") }
    }
    if let compositing = layer.compositingFilter { parts.append("compositing=\(compositing)") }
    if let keys = layer.animationKeys(), !keys.isEmpty {
      let animations = keys.map { key -> String in
        guard let animation = layer.animation(forKey: key) else { return key }
        let path = (animation as? CAPropertyAnimation)?.keyPath ?? ""
        return
          "\(key)(\(path) dur=\(Self.round(animation.duration)) speed=\(animation.speed) keep=\(animation.isRemovedOnCompletion ? 0 : 1))"
      }
      parts.append("anims=[\(animations.joined(separator: ","))]")
    }
    if let image = (view as? UIImageView)?.image {
      parts.append(
        "image=\(Self.round(image.size.width))x\(Self.round(image.size.height))@\(image.scale)")
    }
    if let label = view.accessibilityLabel, !label.isEmpty { parts.append("ax=\"\(label)\"") }
    return parts.joined(separator: " ")
  }

  private static func filters(_ filters: [Any]?, className: String, suspect: inout Bool)
    -> String
  {
    guard let filters, !filters.isEmpty else { return "" }
    return filters.map { filter -> String in
      guard let object = filter as? NSObject else { return "\(type(of: filter))" }
      let filterClass = NSStringFromClass(type(of: object))
      // Only CAFilter is known to answer these keys; anything else could throw on KVC.
      guard filterClass == "CAFilter", let name = object.value(forKey: "name") as? String else {
        return filterClass
      }
      guard name.lowercased().contains("blur") else { return name }
      let radius = (object.value(forKey: "inputRadius") as? NSNumber)?.doubleValue ?? -1
      if radius > 1, !className.contains("Backdrop") { suspect = true }
      return "\(name):\(Self.round(radius))"
    }.joined(separator: ",")
  }

  // MARK: Header items

  private static func installSwizzles() {
    swap(
      #selector(UINavigationItem.setRightBarButtonItems(_:animated:)),
      #selector(UINavigationItem.t3diag_setRightBarButtonItems(_:animated:)))
    swap(
      #selector(UINavigationItem.setLeftBarButtonItems(_:animated:)),
      #selector(UINavigationItem.t3diag_setLeftBarButtonItems(_:animated:)))
  }

  private static func swap(_ original: Selector, _ replacement: Selector) {
    guard let originalMethod = class_getInstanceMethod(UINavigationItem.self, original),
      let replacementMethod = class_getInstanceMethod(UINavigationItem.self, replacement)
    else { return }
    method_exchangeImplementations(originalMethod, replacementMethod)
  }

  private static func describe(item: UIBarButtonItem) -> String {
    let id = String(UInt(bitPattern: ObjectIdentifier(item).hashValue) & 0xfffff, radix: 16)
    let label =
      item.accessibilityLabel ?? item.title
      ?? item.customView.map { NSStringFromClass(type(of: $0)) } ?? "image"
    return "\(label)#\(id)\(item.isHidden ? " hidden" : "")"
  }

  // MARK: Output

  private func openLog() {
    let manager = FileManager.default
    guard let directory = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    else { return }
    try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("T3RailDiag.log")
    if let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
      size.intValue > 4_000_000
    {
      let previous = directory.appendingPathComponent("T3RailDiag.1.log")
      try? manager.removeItem(at: previous)
      try? manager.moveItem(at: url, to: previous)
    }
    if !manager.fileExists(atPath: url.path) {
      manager.createFile(atPath: url.path, contents: nil)
    }
    handle = try? FileHandle(forWritingTo: url)
    _ = try? handle?.seekToEnd()
  }

  private func write(_ line: String, flushNow: Bool = true) {
    lastWrite = Date()
    logger.notice("\(line, privacy: .public)")
    buffer.append(Data("\(formatter.string(from: lastWrite)) \(line)\n".utf8))
    if flushNow || buffer.count > 16_384 { flush() }
  }

  private func flush() {
    guard !buffer.isEmpty else { return }
    try? handle?.write(contentsOf: buffer)
    buffer.removeAll(keepingCapacity: true)
  }

  private static func name(_ state: UIApplication.State) -> String {
    switch state {
    case .active: return "active"
    case .inactive: return "inactive"
    case .background: return "background"
    @unknown default: return "unknown"
    }
  }

  private static func round<T: BinaryFloatingPoint>(_ value: T) -> String {
    String(format: "%.2f", Double(value))
  }

  private static func rect(_ rect: CGRect) -> String {
    "(\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height)))"
  }
}

extension UINavigationItem {
  @objc func t3diag_setRightBarButtonItems(_ items: [UIBarButtonItem]?, animated: Bool) {
    T3RailDiagnostics.shared.noteBarItems("R", items, animated: animated)
    t3diag_setRightBarButtonItems(items, animated: animated)
  }

  @objc func t3diag_setLeftBarButtonItems(_ items: [UIBarButtonItem]?, animated: Bool) {
    T3RailDiagnostics.shared.noteBarItems("L", items, animated: animated)
    t3diag_setLeftBarButtonItems(items, animated: animated)
  }
}
