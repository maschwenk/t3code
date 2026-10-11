import AppKit
import T3Core

@MainActor enum ReviewText {
  enum Column { case unified, old, new }
  struct Position {
    let id: String
    let offset: CGFloat
  }
  private static let anchorKey = NSAttributedString.Key("T3ReviewLine")
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
    let content = column == .old ? line?.oldText ?? line?.text : line?.text
    let value = NSMutableAttributedString(
      string: prefix + sign + " " + (content ?? "") + "\n",
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
      case .hunk, .gap:
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
    if let id = line?.contextID {
      value.addAttribute(
        .link, value: "context:\(id)",
        range: NSRange(location: prefix.utf16.count + 2, length: (content ?? "").utf16.count))
    }
    let anchor =
      line?.contextID.map { "gap:\($0)" }
      ?? (column == .old ? line?.oldLine : line?.newLine).map { "line:\($0)" }
    if let anchor {
      value.addAttribute(
        anchorKey, value: anchor, range: NSRange(location: 0, length: value.length))
    }
    return value
  }

  static func capturePosition(_ text: NSTextView, in scroll: NSScrollView) -> [Position] {
    guard let manager = text.layoutManager, let container = text.textContainer,
      let storage = text.textStorage, storage.length > 0
    else { return [] }
    manager.ensureLayout(for: container)
    let point = NSPoint(
      x: 0, y: max(0, scroll.contentView.bounds.minY - text.textContainerInset.height))
    let glyph = manager.glyphIndex(for: point, in: container)
    guard glyph < manager.numberOfGlyphs else { return [] }
    var index = manager.characterIndexForGlyph(at: glyph)
    var result: [Position] = []
    while index < storage.length, result.count < 2 {
      var range = NSRange()
      let id = storage.attribute(anchorKey, at: index, effectiveRange: &range) as? String
      if let id {
        let row = manager.lineFragmentRect(
          forGlyphAt: manager.glyphIndexForCharacter(at: range.location), effectiveRange: nil)
        result.append(
          Position(
            id: id,
            offset: row.minY + text.textContainerInset.height - scroll.contentView.bounds.minY))
      }
      index = NSMaxRange(range)
    }
    return result
  }

  static func restorePosition(_ positions: [Position], text: NSTextView, scroll: NSScrollView) {
    guard let manager = text.layoutManager, let container = text.textContainer,
      let storage = text.textStorage
    else { return }
    manager.ensureLayout(for: container)
    for position in positions {
      var found: Int?
      storage.enumerateAttribute(anchorKey, in: NSRange(location: 0, length: storage.length)) {
        value, range, stop in
        if value as? String == position.id {
          found = range.location
          stop.pointee = true
        }
      }
      if let found {
        let row = manager.lineFragmentRect(
          forGlyphAt: manager.glyphIndexForCharacter(at: found), effectiveRange: nil)
        scroll.contentView.scroll(
          to: NSPoint(
            x: scroll.contentView.bounds.minX,
            y: max(0, row.minY + text.textContainerInset.height - position.offset)))
        scroll.reflectScrolledClipView(scroll.contentView)
        return
      }
    }
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
