import AppKit
import T3Core
import Testing

@testable import T3Native

@MainActor @Test func contextReviewExpansionKeepsTheVisibleLineAndLinksInBothLayouts() throws {
  let old = (1...240).map { "line \($0) 日本語" }
  var new = old
  var raw = "diff --git a/a b/a\n"
  for number in [30, 120, 200] {
    new[number - 1] = "changed \(number)"
    raw +=
      "@@ -\(number - 1),3 +\(number - 1),3 @@\n \(old[number - 2])\n-\(old[number - 1])\n+\(new[number - 1])\n \(old[number])\n"
  }
  let file = try #require(UnifiedDiff.parse(raw).first)
  let context = try DiffContext(
    file, oldContents: old.joined(separator: "\n") + "\n",
    newContents: new.joined(separator: "\n") + "\n", ignoreWhitespace: false)
  let collapsed = context.render(expanded: [:]).file
  let full = context.render(
    expanded: Dictionary(uniqueKeysWithValues: context.gaps.map { ($0.id, $0.count) })
  ).file
  let view = SplitReviewView(frame: NSRect(x: 0, y: 0, width: 650, height: 100))
  view.setWrapped(true)
  view.render(collapsed)
  // Put a numbered context row at the top, beyond the first replacement block.
  let rendered = SplitReviewText(collapsed)
  let rows = SplitDiff(collapsed).rows
  let index = try #require(rows.firstIndex { $0.old?.oldLine == 119 })
  let frames = SplitReviewView.rowFrames(in: view.oldText, ranges: rendered.oldRanges)
  view.oldScroll.contentView.scroll(to: NSPoint(x: 0, y: frames[index].minY + 8))
  let before = ReviewText.capturePosition(view.oldText, in: view.oldScroll)
  try #require(before.first?.id == "line:119")
  view.render(full, preservePosition: true)
  let after = ReviewText.capturePosition(view.oldText, in: view.oldScroll)
  #expect(after.first?.id == before.first?.id)
  #expect(abs((after.first?.offset ?? 0) - (before.first?.offset ?? 0)) < 0.5)
  #expect(view.oldScroll.contentView.bounds.minY == view.newScroll.contentView.bounds.minY)
  var links: [String] = []
  let unified = ReviewText.render(collapsed).text
  unified.enumerateAttribute(.link, in: NSRange(location: 0, length: unified.length)) {
    value, _, _ in
    if let value = value as? String { links.append(value) }
  }
  #expect(links.filter { $0.hasPrefix("context:") } == context.gaps.map { "context:\($0.id)" })
  let split = SplitReviewText(collapsed)
  var oldLinks: [String] = []
  split.old.enumerateAttribute(.link, in: NSRange(location: 0, length: split.old.length)) {
    value, _, _ in
    if let value = value as? String { oldLinks.append(value) }
  }
  #expect(oldLinks == context.gaps.map { "context:\($0.id)" })
}

@MainActor @Test func contextReviewShowsActualWhitespaceOnBothSides() throws {
  let file = try #require(UnifiedDiff.parse("diff --git a/a b/a\n@@ -2 +2 @@\n-old\n+new\n").first)
  let context = try DiffContext(
    file, oldContents: "let a = 1\nold\n", newContents: "let  a=1\nnew\n", ignoreWhitespace: true)
  let split = SplitReviewText(context.render(expanded: [0: 1]).file)
  #expect(split.old.string.contains("let a = 1") && split.new.string.contains("let  a=1"))
}
