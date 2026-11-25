import ExpoModulesCore
import QuartzCore
import UIKit

// Works around a UIKit stacking bug on the folded iPhone Duo's vertical rail (seen on iOS 27.2).
// UIKit draws rail buttons inside private VerticalBarPocketViews: each navigation controller has
// one, and the tab bar controller has its own. After a return from the background, or after a fold,
// tab switch, or layout rebuild, UIKit can lay the tab bar's pocket over the whole rail above the
// screen's, and that pocket's frosted backdrop (a CABackdropLayer with a gaussian blur) turns the
// screen's header buttons into gray blobs. While pockets overlap, this hides every upper pocket's
// backdrop and shows it again once it stops overlapping.
// It matches private class names, so if UIKit renames them it finds nothing and changes nothing.
public final class T3RailPocketBlurSubscriber: ExpoAppDelegateSubscriber {
  public func subscriberDidRegister() {
    T3RailPocketBlur.startObserving()
  }

  public func applicationDidBecomeActive(_ application: UIApplication) {
    T3RailPocketBlur.scheduleActivationSweep()
  }

  public func applicationDidEnterBackground(_ application: UIApplication) {
    T3RailPocketBlur.pauseForegroundChecks()
  }
}

@MainActor
enum T3RailPocketBlur {
  private static let pocketClassName = "VerticalBar".appending("PocketView")
  private static let backdropClassName = "CABackdrop".appending("Layer")
  /// Backdrop layers this hid, so they can be shown again once their pocket is alone.
  private static let hiddenLayers = NSHashTable<CALayer>.weakObjects()
  private static var observing = false
  private static var pendingUpdate = false
  private static var foregroundTimer: Timer?
  private static var sweepGeneration = 0

  private struct Pocket {
    let view: UIView
    /// Subview indexes from the window, which give the drawing order.
    let path: [Int]
    let frame: CGRect
  }

  static func startObserving() {
    guard !observing else { return }
    observing = true
    let center = NotificationCenter.default
    for name in [
      UIScene.didActivateNotification,
      UIScene.willEnterForegroundNotification,
      UIWindow.didBecomeVisibleNotification,
      UIWindow.didBecomeKeyNotification,
    ] {
      center.addObserver(forName: name, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { scheduleActivationSweep() }
      }
    }
    center.addObserver(
      forName: UIScene.didEnterBackgroundNotification, object: nil, queue: .main
    ) { _ in
      MainActor.assumeIsolated { pauseForegroundChecks() }
    }
  }

  static func scheduleActivationSweep() {
    ensureForegroundTimer()
    scheduleUpdate()
    sweepGeneration += 1
    let generation = sweepGeneration
    // UIKit can add or re-show the upper pocket after activation settles, so recheck briefly.
    for delay in [0.15, 0.4, 1.0, 2.5] {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        guard generation == sweepGeneration else { return }
        update()
      }
    }
  }

  static func scheduleUpdate() {
    guard !pendingUpdate else { return }
    pendingUpdate = true
    DispatchQueue.main.async {
      pendingUpdate = false
      update()
    }
  }

  static func pauseForegroundChecks() {
    sweepGeneration += 1
    foregroundTimer?.invalidate()
    foregroundTimer = nil
  }

  private static func ensureForegroundTimer() {
    guard foregroundTimer == nil else { return }
    // Light safety net while foregrounded on a vertical-bar device: catches late UIKit rebuilds
    // (such as post-animation pocket insertion or backdrop re-unhiding) that don't fire a layout
    // callback in our views. On devices without a vertical bar this exits immediately.
    let timer = Timer(timeInterval: 2.0, repeats: true) { _ in
      MainActor.assumeIsolated {
        guard UIApplication.shared.applicationState == .active else { return }
        update()
      }
    }
    timer.tolerance = 0.5
    RunLoop.main.add(timer, forMode: .common)
    foregroundTimer = timer
  }

  static func update() {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .filter { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }
      .flatMap(\.windows)
      .filter { !$0.isHidden && $0.alpha > 0.01 }

    // Skip the view walk when no window is displaying a vertical bar, unless we previously hid a
    // backdrop layer that needs to be restored after unfolding.
    if hiddenLayers.allObjects.isEmpty, !windows.contains(where: hasVerticalBar) {
      return
    }

    var stacked: [CALayer] = []
    for window in windows {
      var pockets: [Pocket] = []
      var path: [Int] = []
      collectPockets(in: window, window: window, path: &path, into: &pockets)
      let overlapping = pockets.filter { pocket in
        pockets.contains { other in
          other.view !== pocket.view && overlaps(pocket.frame, other.frame)
        }
      }
      // Hide backdrops on every overlapping pocket drawn above another overlapping pocket, so
      // even 3-deep stacks (e.g. during a push/tab transition) leave lower bar buttons sharp.
      for pocket in overlapping {
        let coversAnother = overlapping.contains { other in
          other.view !== pocket.view
            && overlaps(pocket.frame, other.frame)
            && drawsBelow(other.path, pocket.path)
        }
        if coversAnother {
          stacked += backdropLayers(of: pocket.view)
        }
      }
    }
    for layer in hiddenLayers.allObjects where !stacked.contains(where: { $0 === layer }) {
      layer.isHidden = false
      hiddenLayers.remove(layer)
    }
    // A backdrop UIKit hid itself stays UIKit's to show again.
    for layer in stacked where !layer.isHidden {
      layer.isHidden = true
      hiddenLayers.add(layer)
    }
  }

  private static func hasVerticalBar(_ window: UIWindow) -> Bool {
    #if canImport(UIKit, _version: 9127.0.85)
    if #available(iOS 27.1, *) {
      let edge = window.rootViewController?.traitCollection.verticalBarEdge
        ?? window.traitCollection.verticalBarEdge
      return edge == .leading || edge == .trailing
    }
    #endif
    return true
  }

  private static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
    let intersection = a.intersection(b)
    return !intersection.isNull && intersection.width > 1 && intersection.height > 1
  }

  private static func collectPockets(
    in view: UIView, window: UIWindow, path: inout [Int], into pockets: inout [Pocket]
  ) {
    guard !view.isHidden, view.alpha > 0.01 else { return }
    if NSStringFromClass(type(of: view)).contains(pocketClassName) {
      let frame = view.convert(view.bounds, to: window)
      if !frame.isEmpty { pockets.append(Pocket(view: view, path: path, frame: frame)) }
    }
    for (index, subview) in view.subviews.enumerated() {
      path.append(index)
      collectPockets(in: subview, window: window, path: &path, into: &pockets)
      path.removeLast()
    }
  }

  /// A later sibling, or a descendant, draws above.
  private static func drawsBelow(_ a: [Int], _ b: [Int]) -> Bool {
    for (x, y) in zip(a, b) where x != y { return x < y }
    return a.count < b.count
  }

  /// The pocket's frost is a layer no view owns, holding the backdrop layer that blurs.
  private static func backdropLayers(of pocket: UIView) -> [CALayer] {
    (pocket.layer.sublayers ?? []).filter { layer in
      !(layer.delegate is UIView) && containsBackdropLayer(layer, depth: 0)
    }
  }

  private static func containsBackdropLayer(_ layer: CALayer, depth: Int) -> Bool {
    if NSStringFromClass(type(of: layer)) == backdropClassName { return true }
    guard depth < 4 else { return false }
    for sublayer in layer.sublayers ?? [] where !(sublayer.delegate is UIView) {
      if containsBackdropLayer(sublayer, depth: depth + 1) { return true }
    }
    return false
  }
}
