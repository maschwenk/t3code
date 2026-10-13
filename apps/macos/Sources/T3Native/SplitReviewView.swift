import AppKit
import T3Core

@MainActor final class SplitReviewView: NSView, NSTextViewDelegate {
  let oldText = NSTextView()
  let newText = NSTextView()
  let oldScroll = NSScrollView()
  let newScroll = NSScrollView()
  var onOpenLine: ((Int) -> Void)?
  var onExpandContext: ((Int) -> Void)?
  private var rendered: SplitReviewText?
  private var widths: [CGFloat] = []
  private var wrapping = false
  private var synchronizing = false
  private var resetPosition = false
  private var resetSelection = false
  private var pendingPosition: [ReviewText.Position] = []

  override init(frame: NSRect) {
    super.init(frame: frame)
    var columns: [NSView] = []
    for (title, text, scroll) in [
      ("Before", oldText, oldScroll), ("After", newText, newScroll),
    ] {
      let heading = NSTextField(labelWithString: title)
      heading.font = .systemFont(ofSize: 11, weight: .medium)
      heading.textColor = .secondaryLabelColor
      text.isEditable = false
      text.isSelectable = true
      text.isRichText = false
      text.isAutomaticLinkDetectionEnabled = false
      text.isIncrementalSearchingEnabled = true
      text.textContainerInset = NSSize(width: 8, height: 8)
      text.textContainer?.widthTracksTextView = false
      text.linkTextAttributes = [:]
      text.delegate = self
      text.setAccessibilityLabel("\(title) changes, file diff")
      scroll.documentView = text
      scroll.hasVerticalScroller = true
      scroll.hasHorizontalScroller = true
      scroll.autohidesScrollers = true
      scroll.contentView.postsBoundsChangedNotifications = true
      NotificationCenter.default.addObserver(
        self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
        object: scroll.contentView)
      let column = NSStackView(views: [heading, scroll])
      column.orientation = .vertical
      column.alignment = .leading
      column.spacing = 4
      scroll.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
      columns.append(column)
    }
    let split = NSStackView(views: columns)
    split.distribution = .fillEqually
    split.spacing = 8
    split.alignment = .top
    addSubview(split)
    split.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      split.leadingAnchor.constraint(equalTo: leadingAnchor),
      split.trailingAnchor.constraint(equalTo: trailingAnchor),
      split.topAnchor.constraint(equalTo: topAnchor),
      split.bottomAnchor.constraint(equalTo: bottomAnchor),
      columns[0].heightAnchor.constraint(equalTo: split.heightAnchor),
      columns[1].heightAnchor.constraint(equalTo: split.heightAnchor),
    ])
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  @discardableResult func render(_ file: DiffFile?, preservePosition: Bool = false) -> Bool {
    pendingPosition = preservePosition ? ReviewText.capturePosition(oldText, in: oldScroll) : []
    rendered = SplitReviewText(file)
    resetPosition = !preservePosition
    resetSelection = true
    widths = []
    needsLayout = true
    layoutSubtreeIfNeeded()
    return rendered?.limited ?? false
  }

  func setWrapped(_ value: Bool) {
    guard value != wrapping else { return }
    wrapping = value
    for scroll in [oldScroll, newScroll] { scroll.hasHorizontalScroller = !value }
    widths = []
    needsLayout = true
    layoutSubtreeIfNeeded()
  }

  override func layout() {
    super.layout()
    alignRows()
  }

  private func alignRows() {
    let nextWidths = [oldScroll.contentSize.width, newScroll.contentSize.width]
    guard !synchronizing, nextWidths.allSatisfy({ $0 > 16 }), let rendered,
      widths != nextWidths
    else { return }
    widths = nextWidths
    synchronizing = true
    defer { synchronizing = false }
    let offset = resetPosition ? NSPoint.zero : oldScroll.contentView.bounds.origin
    let documents = [rendered.old, rendered.new]
    let ranges = [rendered.oldRanges, rendered.newRanges]
    let texts = [oldText, newText]
    let selections = texts.map {
      resetSelection ? NSRange(location: 0, length: 0) : $0.selectedRange()
    }
    for index in 0..<2 {
      let text = texts[index]
      text.textStorage?.setAttributedString(documents[index])
      text.isHorizontallyResizable = !wrapping
      text.setFrameSize(NSSize(width: widths[index], height: text.frame.height))
      text.textContainer?.containerSize = NSSize(
        width: wrapping ? widths[index] - 16 : CGFloat.greatestFiniteMagnitude,
        height: CGFloat.greatestFiniteMagnitude)
    }
    let before = Self.rowFrames(in: oldText, ranges: rendered.oldRanges)
    let after = Self.rowFrames(in: newText, ranges: rendered.newRanges)
    oldText.textStorage?.beginEditing()
    newText.textStorage?.beginEditing()
    for row in before.indices {
      let difference = after[row].height - before[row].height
      guard abs(difference) > 0.01 else { continue }
      let side = difference > 0 ? 0 : 1
      let text = texts[side]
      let range = ranges[side][row]
      guard let storage = text.textStorage,
        let paragraph = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
          as? NSParagraphStyle,
        let adjusted = paragraph.mutableCopy() as? NSMutableParagraphStyle
      else { continue }
      adjusted.paragraphSpacing = abs(difference)
      // Pad only the final paragraph, including when file content contains a carriage return.
      let last = (storage.string as NSString).paragraphRange(
        for: NSRange(location: NSMaxRange(range) - 1, length: 0))
      storage.addAttribute(
        .paragraphStyle, value: adjusted, range: NSIntersectionRange(last, range))
    }
    oldText.textStorage?.endEditing()
    newText.textStorage?.endEditing()
    var sizes: [NSSize] = []
    for (index, text) in texts.enumerated() {
      guard let manager = text.layoutManager, let container = text.textContainer else { return }
      manager.ensureLayout(for: container)
      let used = manager.usedRect(for: container)
      sizes.append(
        NSSize(
          width: wrapping ? widths[index] : max(widths[index], used.maxX + 16),
          height: max(used.maxY, manager.extraLineFragmentRect.maxY) + 16))
    }
    let height = max(
      sizes[0].height, sizes[1].height, oldScroll.contentSize.height, newScroll.contentSize.height)
    for (index, text) in texts.enumerated() {
      text.setFrameSize(NSSize(width: sizes[index].width, height: height))
      let selection = selections[index]
      if NSMaxRange(selection) <= text.string.utf16.count { text.setSelectedRange(selection) }
    }
    for scroll in [oldScroll, newScroll] {
      scroll.contentView.scroll(
        to: NSPoint(x: resetPosition ? 0 : scroll.contentView.bounds.minX, y: offset.y))
      scroll.reflectScrolledClipView(scroll.contentView)
    }
    if !pendingPosition.isEmpty {
      ReviewText.restorePosition(pendingPosition, text: oldText, scroll: oldScroll)
      newScroll.contentView.scroll(
        to: NSPoint(
          x: newScroll.contentView.bounds.minX,
          y: oldScroll.contentView.bounds.minY))
      newScroll.reflectScrolledClipView(newScroll.contentView)
      pendingPosition = []
    }
    resetPosition = false
    resetSelection = false
  }

  /// One layout traversal per column; wrapping never creates one text view or layout manager per row.
  static func rowFrames(in text: NSTextView, ranges: [NSRange]) -> [NSRect] {
    var frames = [NSRect](repeating: .null, count: ranges.count)
    guard let manager = text.layoutManager, let container = text.textContainer, !ranges.isEmpty
    else { return frames }
    manager.ensureLayout(for: container)
    var row = 0
    manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) {
      rect, _, _, glyphs, _ in
      let character = manager.characterIndexForGlyph(at: glyphs.location)
      while row < ranges.count && NSMaxRange(ranges[row]) <= character { row += 1 }
      if row < ranges.count { frames[row] = frames[row].union(rect) }
    }
    return frames
  }

  @objc private func scrolled(_ notification: Notification) {
    guard !synchronizing, let source = notification.object as? NSClipView else { return }
    let target = source === oldScroll.contentView ? newScroll : oldScroll
    let y = source.bounds.minY
    guard abs(target.contentView.bounds.minY - y) > 0.01 else { return }
    synchronizing = true
    target.contentView.scroll(to: NSPoint(x: target.contentView.bounds.minX, y: y))
    target.reflectScrolledClipView(target.contentView)
    synchronizing = false
  }

  func find() {
    let text = window?.firstResponder === oldText ? oldText : newText
    window?.makeFirstResponder(text)
    let item = NSMenuItem()
    item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
    text.performFindPanelAction(item)
  }

  func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
    if let string = link as? String, string.hasPrefix("context:"), let id = Int(string.dropFirst(8))
    {
      onExpandContext?(id)
      return true
    }
    guard textView === newText, let string = link as? String, let line = Int(string) else {
      return false
    }
    onOpenLine?(line)
    return true
  }
}
