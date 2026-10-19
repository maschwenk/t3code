import AppKit
import T3Core

@MainActor final class BrowserDeviceToolbar: NSStackView {
  var onChange: ((BrowserViewport) -> Void)?
  var onError: ((String) -> Void)?
  private let preset = NSPopUpButton()
  private let width = NSTextField()
  private let height = NSTextField()
  private let rotate = NSButton()
  private let close = NSButton()
  private var setting: BrowserViewport = .fill

  override init(frame: NSRect) {
    super.init(frame: frame)
    spacing = 5
    alignment = .centerY
    setAccessibilityLabel("Browser device toolbar")
    preset.addItem(withTitle: "Responsive")
    for device in BrowserDevicePreset.all { preset.addItem(withTitle: device.name) }
    preset.target = self
    preset.action = #selector(selectPreset)
    preset.setAccessibilityLabel("Browser device preset")
    preset.widthAnchor.constraint(equalToConstant: 140).isActive = true
    for (field, label) in [(width, "Viewport width"), (height, "Viewport height")] {
      field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
      field.alignment = .center
      field.target = self
      field.action = #selector(applyCustom)
      field.setAccessibilityLabel(label)
      field.toolTip = label + " in CSS pixels. Press Return to apply."
      field.widthAnchor.constraint(equalToConstant: 48).isActive = true
    }
    for (button, symbol, label, action) in [
      (rotate, "rotate.right", "Rotate viewport", #selector(rotateViewport)),
      (close, "xmark", "Close device toolbar", #selector(fillPanel)),
    ] {
      button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
      button.bezelStyle = .inline
      button.isBordered = false
      button.target = self
      button.action = action
      button.toolTip = label
      button.setAccessibilityLabel(label)
      button.widthAnchor.constraint(equalToConstant: 24).isActive = true
    }
    for child in [preset, width, NSTextField(labelWithString: "×"), height, rotate, close] {
      addArrangedSubview(child)
    }
    heightAnchor.constraint(equalToConstant: 28).isActive = true
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func render(_ next: BrowserViewport, enabled: Bool) {
    let changed = setting != next
    setting = next
    isHidden = next.width == nil
    if changed || width.currentEditor() == nil {
      width.stringValue = next.width.map(String.init) ?? ""
    }
    if changed || height.currentEditor() == nil {
      height.stringValue = next.height.map(String.init) ?? ""
    }
    preset.selectItem(
      at: next.presetID.flatMap { id in
        BrowserDevicePreset.all.firstIndex { $0.id == id }.map { $0 + 1 }
      } ?? 0)
    for control in [preset, width, height, rotate, close] { control.isEnabled = enabled }
  }

  @objc private func selectPreset() {
    let index = preset.indexOfSelectedItem - 1
    if BrowserDevicePreset.all.indices.contains(index) {
      onChange?(BrowserDevicePreset.all[index].viewport)
    } else if let width = setting.width, let height = setting.height,
      let next = try? BrowserViewport(width: width, height: height)
    {
      onChange?(next)
    }
  }
  @objc private func applyCustom() {
    do {
      guard let width = Int(width.stringValue), let height = Int(height.stringValue) else {
        throw T3Error("Enter whole numbers for the viewport width and height.")
      }
      onChange?(try BrowserViewport(width: width, height: height))
    } catch { onError?(error.localizedDescription) }
  }
  @objc private func rotateViewport() { onChange?(setting.rotated) }
  @objc private func fillPanel() { onChange?(.fill) }
}
