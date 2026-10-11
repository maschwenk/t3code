import AppKit
import T3Core
import Testing

@testable import T3Native

@MainActor @Test func splitReviewWrapResizeAndScrollKeepCorrespondingLinesTogether() throws {
  let long = String(repeating: "Unicode 日本語 👋 and tabs\t ", count: 12)
  let raw =
    "diff --git a/a b/a\n@@ -1,5 +1,6 @@\n header\n-short\r\n+\(long)\r\n \(long)\n-\(long)\n+short\n+extra\n end\n"
  let file = try #require(UnifiedDiff.parse(raw).first)
  let rendered = SplitReviewText(file)
  let view = SplitReviewView(frame: NSRect(x: 0, y: 0, width: 600, height: 240))
  view.setWrapped(true)
  #expect(!view.render(file))
  func verifyAlignment() throws {
    view.layoutSubtreeIfNeeded()
    let before = SplitReviewView.rowFrames(in: view.oldText, ranges: rendered.oldRanges)
    let after = SplitReviewView.rowFrames(in: view.newText, ranges: rendered.newRanges)
    try #require(before.count == after.count && !before.isEmpty)
    for index in before.indices {
      #expect(!before[index].isNull && !after[index].isNull)
      #expect(abs(before[index].minY - after[index].minY) < 0.5)
    }
    #expect(view.oldText.frame.height == view.newText.frame.height)
  }
  try verifyAlignment()
  view.newText.setSelectedRange(NSRange(location: 4, length: 10))
  view.setFrameSize(NSSize(width: 430, height: 240))
  view.needsLayout = true
  try verifyAlignment()
  #expect(view.newText.selectedRange() == NSRange(location: 4, length: 10))
  let origin = NSPoint(x: 0, y: 120)
  view.oldScroll.contentView.scroll(to: origin)
  #expect(abs(view.newScroll.contentView.bounds.minY - origin.y) < 0.5)
  view.newScroll.contentView.scroll(to: NSPoint(x: 0, y: 200))
  #expect(abs(view.oldScroll.contentView.bounds.minY - 200) < 0.5)
  view.setWrapped(false)
  try verifyAlignment()
  #expect(view.newText.frame.width > view.newScroll.contentSize.width)
  view.render(nil)
  #expect(view.oldText.string.isEmpty && view.newText.string.isEmpty)
}

@MainActor @Test func splitReviewLinksOnlyNewLinesAndDoesNotLosePatchCharacters() throws {
  let raw = "diff --git a/a b/a\n@@ -4,2 +4,2 @@\n-before\r\n+after 日本語\r\n same\n"
  let file = try #require(UnifiedDiff.parse(raw).first)
  let rendered = SplitReviewText(file)
  func links(_ text: NSAttributedString) -> [String] {
    var result: [String] = []
    text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, _, _ in
      if let value = value as? String { result.append(value) }
    }
    return result
  }
  #expect(links(rendered.old).isEmpty && links(rendered.new) == ["4", "5"])
  #expect(rendered.old.string.contains("before\r\n"))
  #expect(rendered.new.string.contains("after 日本語\r\n"))
  #expect(file.rawPatch == raw)
}
