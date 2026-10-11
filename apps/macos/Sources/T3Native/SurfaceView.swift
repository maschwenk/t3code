import AppKit

@MainActor final class SurfaceView: NSView {
  private let sidebar: Bool
  private let raised: Bool
  init(sidebar: Bool = false, raised: Bool = false) {
    self.sidebar = sidebar
    self.raised = raised
    super.init(frame: .zero)
    wantsLayer = true
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override var wantsUpdateLayer: Bool { true }
  override func updateLayer() {
    let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let white: CGFloat =
      dark ? (raised ? 0.075 : sidebar ? 0.035 : 0.045) : (raised ? 1 : sidebar ? 0.95 : 0.99)
    layer?.backgroundColor = NSColor(calibratedWhite: white, alpha: 1).cgColor
    if raised {
      layer?.borderWidth = 1
      layer?.borderColor = NSColor(calibratedWhite: dark ? 0.14 : 0.88, alpha: 1).cgColor
    }
  }
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }
}
