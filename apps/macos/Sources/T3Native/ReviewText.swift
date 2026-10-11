import AppKit
import T3Core

@MainActor enum ReviewText {
  enum Column { case unified, old, new }
  private static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
  private static let paragraph: NSParagraphStyle = {
    let value = NSMutableParagraphStyle()
    value.lineSpacing = 2
    value.defaultTabInterval = font.maximumAdvancement.width * 4
    return value
  }()

  static func render(_ file: DiffFile?) -> (text: NSAttributedString, limited: Bool) {
    let output = NSMutableAttributedString()
    guard let file else { return (output, false) }
    var limited = false
    for (index, line) in file.lines.enumerated() {
      if index >= 10_000 || output.length + line.text.utf16.count > 1_000_000 {
        limited = true
        break
      }
      output.append(styled(line, column: .unified, canOpen: !file.isDeleted))
    }
    return (output, limited)
  }

  static func styled(_ line: DiffLine?, column: Column, canOpen: Bool) -> NSAttributedString {
    let old = line?.oldLine.map(String.init) ?? ""
    let new = line?.newLine.map(String.init) ?? ""
    func padded(_ value: String) -> String {
      String(repeating: " ", count: max(0, 5 - value.count)) + value + " "
    }
    let prefix = column == .unified ? padded(old) + padded(new) : padded(column == .old ? old : new)
    let sign = line?.kind == .addition ? "+" : line?.kind == .deletion ? "−" : " "
    let value = NSMutableAttributedString(
      string: prefix + sign + " " + (line?.text ?? "") + "\n",
      attributes: [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph])
    if let line {
      switch line.kind {
      case .addition:
        value.addAttribute(
          .backgroundColor, value: NSColor.systemGreen.withAlphaComponent(0.13),
          range: NSRange(location: 0, length: value.length))
      case .deletion:
        value.addAttribute(
          .backgroundColor, value: NSColor.systemRed.withAlphaComponent(0.13),
          range: NSRange(location: 0, length: value.length))
      case .hunk:
        value.addAttribute(
          .foregroundColor, value: NSColor.systemBlue,
          range: NSRange(location: 0, length: value.length))
      case .metadata:
        value.addAttribute(
          .foregroundColor, value: NSColor.secondaryLabelColor,
          range: NSRange(location: 0, length: value.length))
      case .context: break
      }
    }
    value.addAttribute(
      .foregroundColor, value: NSColor.secondaryLabelColor,
      range: NSRange(location: 0, length: prefix.utf16.count))
    if column != .old, let number = line?.newLine, canOpen {
      value.addAttribute(
        .link, value: String(number),
        range: NSRange(location: prefix.utf16.count - new.count - 1, length: new.count))
    }
    return value
  }
}

@MainActor struct SplitReviewText {
  let old: NSAttributedString
  let new: NSAttributedString
  let oldRanges: [NSRange]
  let newRanges: [NSRange]
  let limited: Bool

  init(_ file: DiffFile?) {
    let layout = SplitDiff(file)
    let old = NSMutableAttributedString()
    let new = NSMutableAttributedString()
    var oldRanges: [NSRange] = []
    var newRanges: [NSRange] = []
    for row in layout.rows {
      let before = ReviewText.styled(row.old, column: .old, canOpen: false)
      let after = ReviewText.styled(row.new, column: .new, canOpen: file?.isDeleted != true)
      oldRanges.append(NSRange(location: old.length, length: before.length))
      newRanges.append(NSRange(location: new.length, length: after.length))
      old.append(before)
      new.append(after)
    }
    self.old = old
    self.new = new
    self.oldRanges = oldRanges
    self.newRanges = newRanges
    limited = layout.limited
  }
}
