import Foundation
import Testing

@testable import T3Core

private func contextFixture() throws -> (DiffFile, String, String) {
  let old = (1...100).map { "line \($0) 日本語\r" }
  var new = old
  new[39] = "changed 40 👋\r"
  new.replaceSubrange(54...54, with: ["changed 55\r", "inserted\r"])
  let chunks: [String] = [
    "diff --git a/file b/file\n@@ -38,5 +38,5 @@\n",
    old[37...38].map { " " + $0 + "\n" }.joined(),
    "-" + old[39] + "\n+" + new[39] + "\n",
    old[40...41].map { " " + $0 + "\n" }.joined(),
    "@@ -53,5 +53,6 @@\n",
    old[52...53].map { " " + $0 + "\n" }.joined(),
    "-" + old[54] + "\n+" + new[54] + "\n+" + new[55] + "\n",
    old[55...56].map { " " + $0 + "\n" }.joined(),
  ]
  let raw = chunks.joined()
  return (
    try #require(UnifiedDiff.parse(raw).first), old.joined(separator: "\n") + "\n",
    new.joined(separator: "\n") + "\n"
  )
}

@Test func contextExpansionKeepsBothLineSequencesAndRawPatchWhileFillingEachGap() throws {
  let (file, old, new) = try contextFixture()
  let context = try DiffContext(file, oldContents: old, newContents: new, ignoreWhitespace: false)
  #expect(context.gaps.map(\.id) == [0, 1, 2])
  #expect(context.gaps.map(\.count) == [37, 10, 43])
  #expect(DiffContext.preview(file).lines.compactMap(\.contextID) == [0, 1, 2])
  let full = context.render(
    expanded: Dictionary(uniqueKeysWithValues: context.gaps.map { ($0.id, $0.count) }))
  #expect(!full.limited)
  #expect(full.file.rawPatch == file.rawPatch)
  #expect(full.file.additions == file.additions && full.file.deletions == file.deletions)
  #expect(full.file.lines.compactMap(\.oldLine) == Array(1...100))
  #expect(full.file.lines.compactMap(\.newLine) == Array(1...101))
  #expect(full.file.lines.first?.text == "line 1 日本語\r")
  let partial = context.render(expanded: [0: 20, 1: 4, 2: 20]).file
  #expect(partial.lines.first?.contextID == 0)
  #expect(partial.lines.compactMap(\.oldLine).first == 18)
  let between = partial.lines.compactMap(\.oldLine).filter { (43...52).contains($0) }
  #expect(between == [43, 44, 51, 52])
  #expect(partial.lines.compactMap(\.oldLine).last == 77)
  #expect(context.render(expanded: [:]).file.lines.compactMap(\.contextID) == [0, 1, 2])
}

@Test func contextExpansionRejectsEditsInsideOutsideAndAtTheEndOfThePatch() throws {
  let (file, old, new) = try contextFixture()
  for modified in [
    new.replacingOccurrences(of: "line 1 日本語", with: "new unseen edit"),
    new.replacingOccurrences(of: "changed 40 👋", with: "different change"),
    String(new.dropLast()), new + "extra\n",
  ] {
    #expect(throws: T3Error.self) {
      try DiffContext(file, oldContents: old, newContents: modified, ignoreWhitespace: false)
    }
  }
}

@Test func contextExpansionHonorsWhitespaceFilteringAndKeepsEachSidesActualText() throws {
  let file = try #require(
    UnifiedDiff.parse(
      "diff --git a/a b/a\n@@ -2,2 +2,2 @@\n-old\n+new\n tail\n"
    ).first)
  let old = "let a = 1\nold\n\ttail\n"
  let new = "let  a=1\nnew\ntail\n"
  #expect(throws: T3Error.self) {
    try DiffContext(file, oldContents: old, newContents: new, ignoreWhitespace: false)
  }
  let context = try DiffContext(file, oldContents: old, newContents: new, ignoreWhitespace: true)
  let full = context.render(expanded: [0: 1]).file
  #expect(full.lines.first?.text == "let  a=1" && full.lines.first?.oldText == "let a = 1")
  #expect(full.lines.last?.text == "tail" && full.lines.last?.oldText == "\ttail")
  #expect(throws: T3Error.self) {
    try DiffContext(
      file, oldContents: old,
      newContents: new.replacingOccurrences(of: "let  a", with: "let\u{00A0}a"),
      ignoreWhitespace: true)
  }
}

@Test func contextExpansionUnderstandsNoFinalNewlineAndBoundsFullFilePresentation() throws {
  let file = try #require(
    UnifiedDiff.parse(
      "diff --git a/a b/a\n@@ -1 +1 @@\n-before\n+after\n\\ No newline at end of file\n"
    ).first)
  let context = try DiffContext(
    file, oldContents: "before\n", newContents: "after", ignoreWhitespace: false)
  #expect(context.gaps.isEmpty)
  #expect(throws: T3Error.self) {
    try DiffContext(file, oldContents: "before\n", newContents: "after\n", ignoreWhitespace: false)
  }
  let mode = try #require(
    UnifiedDiff.parse("diff --git a/a b/a\nold mode 100644\nnew mode 100755\n").first)
  let contents = String(repeating: "same\n", count: 12_000)
  let huge = try DiffContext(
    mode, oldContents: contents, newContents: contents, ignoreWhitespace: false)
  let rendered = huge.render(expanded: [0: 12_000])
  #expect(rendered.limited && rendered.file.lines.count <= 10_000)
  #expect(throws: T3Error.self) {
    try DiffContext(
      mode, oldContents: String(repeating: "a", count: 1_000_001), newContents: "",
      ignoreWhitespace: false)
  }
}
