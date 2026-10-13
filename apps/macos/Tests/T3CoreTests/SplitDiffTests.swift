import Testing

@testable import T3Core

@Test func splitDiffPairsReplacementsAndPadsUnequalSidesWithoutCrossingHunks() throws {
  let file = try #require(
    UnifiedDiff.parse(
      """
      diff --git a/file b/file
      @@ -2,3 +2,4 @@
       context
      -old first
      -old second
      +new first
      +new second
      +new third
      @@ -100 +101 @@
      -last old
      +last new
      """
    ).first)
  let split = SplitDiff(file)
  #expect(!split.limited)
  #expect(
    split.rows.map { $0.old?.text } == [
      "@@ -2,3 +2,4 @@", "context", "old first", "old second", nil,
      "@@ -100 +101 @@", "last old",
    ])
  #expect(split.rows.map { $0.new?.newLine } == [nil, 2, 3, 4, 5, nil, 101])
  #expect(split.rows.map { $0.old?.oldLine } == [nil, 2, 3, 4, nil, nil, 100])
}

@Test func splitDiffKeepsNoNewlineMarkersOnTheirOwnSide() throws {
  let file = try #require(
    UnifiedDiff.parse(
      """
      diff --git a/file b/file
      @@ -1 +1 @@
      -before
      \\ No newline at end of file
      +after
      \\ No newline at end of file
      """
    ).first)
  let rows = SplitDiff(file).rows
  #expect(rows.count == 3)
  #expect(rows[1].old?.text == "before" && rows[1].new?.text == "after")
  #expect(rows[2].old?.text == "\\ No newline at end of file")
  #expect(rows[2].new?.text == "\\ No newline at end of file")
  let added = UnifiedDiff.parse("diff --git a/a b/a\n@@ -0,0 +1 @@\n+added\n").first
  #expect(SplitDiff(added).rows.last?.old == nil)
  let removed = UnifiedDiff.parse("diff --git a/a b/a\n@@ -1 +0,0 @@\n-removed\n").first
  #expect(SplitDiff(removed).rows.last?.new == nil)
}

@Test func splitDiffBoundsSourceWorkAndAccountsForBothCopiesOfContext() throws {
  let file = try #require(
    UnifiedDiff.parse(
      "diff --git a/a b/a\n@@ -1,12000 +0,0 @@\n" + String(repeating: "-old\n", count: 12_000)
    ).first)
  let split = SplitDiff(file)
  #expect(split.limited && split.rows.count == 10_000)
  let context = UnifiedDiff.parse("diff --git a/a b/a\n@@ -1 +1 @@\n same\n").first
  let short = SplitDiff(context, characterLimit: 10)
  #expect(short.limited && short.rows.isEmpty)
  #expect(SplitDiff(nil).rows.isEmpty && !SplitDiff(nil).limited)
}
