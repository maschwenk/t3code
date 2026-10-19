import AppKit

@MainActor final class MessageBubble: NSView {
  override init(frame: NSRect = .zero) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = 18
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override var wantsUpdateLayer: Bool { true }
  override func updateLayer() {
    layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.045).cgColor
  }
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }
}
