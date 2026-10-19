import AppKit
import T3Core
import Testing

@testable import T3Native

@MainActor @Test func diffPresentationLinksOnlyCurrentLinesAndBoundsLargePatches() throws {
  let file = try #require(
    UnifiedDiff.parse(
      """
      diff --git a/test b/test
      @@ -7,2 +7,2 @@
       same
      -old
      +new 日本語
      """
    ).first)
  let rendered = ReviewText.render(file)
  #expect(!rendered.limited)
  #expect(rendered.text.string.contains("new 日本語"))
  var links: [String] = []
  rendered.text.enumerateAttribute(.link, in: NSRange(location: 0, length: rendered.text.length)) {
    value, _, _ in
    if let value = value as? String { links.append(value) }
  }
  #expect(links == ["7", "8"])
  let huge = UnifiedDiff.parse(
    "diff --git a/huge b/huge\n@@ -0,0 +1,12000 @@\n" + String(repeating: "+line\n", count: 12_000)
  ).first
  let limited = ReviewText.render(huge)
  #expect(limited.limited)
  #expect(limited.text.string.components(separatedBy: "\n").count <= 10_001)
}
