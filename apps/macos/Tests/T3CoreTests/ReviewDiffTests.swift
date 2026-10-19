import Foundation
import Testing

@testable import T3Core

@Test func reviewRepositoryErrorsDisplayServerDetails() {
  let error = RPCConnection.requestError(
    .object([
      "_tag": .string("Failure"),
      "cause": .array([
        .object([
          "_tag": .string("Fail"),
          "error": .object([
            "_tag": .string("VcsRepositoryDetectionError"),
            "detail": .string(
              "Review diff preview cwd must stay within the configured workspace root."),
          ]),
        ])
      ]),
    ]))
  #expect(error.remoteCode == "VcsRepositoryDetectionError")
  #expect(
    error.message == "Review diff preview cwd must stay within the configured workspace root.")
}

@Test func diffLinesPreserveUnicodeCRLFAndHeaderLikeContents() throws {
  let files = UnifiedDiff.parse(
    """
    diff --git a/a b/a
    index abc..def 100644
    --- a/a
    +++ b/a
    @@ -8,3 +8,4 @@ function
     same\r
    --- actual text\r
    +++ actual text\r
    +日本語 👋\r
     end\r
    @@ -30 +31 @@
    -old
    +new
    \\ No newline at end of file
    """)
  let file = try #require(files.first)
  let lines = file.lines.filter { $0.oldLine != nil || $0.newLine != nil }
  try #require(lines.count == 7)
  #expect(file.path == "a")
  #expect(file.previousPath == nil)
  #expect(!file.incomplete)
  #expect(file.additions == 3 && file.deletions == 2)
  #expect(lines.map(\.oldLine) == [8, 9, nil, nil, 10, 30, nil])
  #expect(lines.map(\.newLine) == [8, nil, 9, 10, 11, nil, 31])
  #expect(lines[1].text == "-- actual text\r")
  #expect(lines[2].text == "++ actual text\r")
  #expect(lines[3].text == "日本語 👋\r")
  #expect(file.lines.last?.text == "\\ No newline at end of file")
}

@Test func diffParsesNewDeletedRenamedBinaryAndModeOnlyFiles() throws {
  let files = UnifiedDiff.parse(
    """
    diff --git a/new file b/new file
    new file mode 100644
    --- /dev/null
    +++ b/new file
    @@ -0,0 +1,2 @@
    +one
    +two
    diff --git a/deleted b/deleted
    deleted file mode 100644
    --- a/deleted
    +++ /dev/null
    @@ -1,2 +0,0 @@
    -one
    -two
    diff --git a/old name b/new name
    similarity index 100%
    rename from old name
    rename to new name
    diff --git a/image.png b/image.png
    Binary files a/image.png and b/image.png differ
    diff --git a/script b/script
    old mode 100644
    new mode 100755
    """)
  #expect(files.count == 5)
  #expect(files.map(\.path) == ["new file", "deleted", "new name", "image.png", "script"])
  #expect(files[0].lines.last?.newLine == 2)
  #expect(files[1].isDeleted && files[1].lines.last?.oldLine == 2)
  #expect(files[2].previousPath == "old name")
  #expect(files[3].isBinary)
  #expect(files.allSatisfy { !$0.incomplete })
}

@Test func diffMarkersAreBytesEvenWhenTheFileLineStartsWithACombiningMark() throws {
  let file = try #require(
    UnifiedDiff.parse(
      "diff --git a/a b/a\n@@ -1 +1 @@\n-\u{0301}old\n+\u{0301}new\n"
    ).first)
  #expect(!file.incomplete)
  #expect(file.deletions == 1 && file.additions == 1)
  #expect(file.lines.last?.text == "\u{0301}new")
}

@Test func gitQuotedPathsDecodeOctalUTF8AndEscapedCharacters() throws {
  let files = UnifiedDiff.parse(
    #"""
    diff --git "a/\346\227\245\346\234\254\350\252\236\t\".txt" "b/\346\227\245\346\234\254\350\252\236\t\".txt"
    --- "a/\346\227\245\346\234\254\350\252\236\t\".txt"
    +++ "b/\346\227\245\346\234\254\350\252\236\t\".txt"
    @@ -1 +1 @@
    -before
    +after
    """#)
  let file = try #require(files.first)
  #expect(file.path == "日本語\t\".txt")
  #expect(file.previousPath == nil)
  #expect(!file.incomplete)
  let spaced = UnifiedDiff.parse(
    "diff --git a/a b/inside b/a b/inside\nold mode 100644\nnew mode 100755\n")
  #expect(spaced.first?.path == "a b/inside")
}

@Test func truncatedHunksDoNotInventLineNumbersOrConsumeTheNextFile() {
  let files = UnifiedDiff.parse(
    """
    diff --git a/a b/a
    --- a/a
    +++ b/a
    @@ -1,3 +1,3 @@
    -first
    +second
    [output truncated]
    diff --git a/b b/b
    --- a/b
    +++ b/b
    @@ -1 +1 @@
    -a
    +b
    """)
  #expect(files[0].incomplete)
  #expect(!files[1].incomplete)
  #expect(files[0].lines.last?.newLine == nil)
  #expect(files[1].lines.last?.newLine == 1)
  #expect(UnifiedDiff.parse("diff --git a/a b/a\n@@ -1 +1 @@\n-old").first?.incomplete == true)
}

@Test func completeServerStatsSurviveTruncatedPatchAndSortNaturally() throws {
  let value: JSON = .object([
    "kind": .string("working-tree"), "title": .string("Uncommitted"),
    "diffHash": .string("hash"), "truncated": .bool(true), "diff": .string(""),
    "files": .array([
      .object(["path": .string("file10"), "additions": .number(300), "deletions": .number(2)]),
      .object(["path": .string("file2"), "additions": .number(3), "deletions": .number(4)]),
    ]),
  ])
  let source = try ReviewSource(value)
  #expect(source.files.map(\.path) == ["file2", "file10"])
  #expect(source.files.last?.additions == 300)
  #expect(source.completeFileList)
  #expect(source.truncated)
  let older = try ReviewSource(
    .object([
      "kind": .string("working-tree"), "title": .string("Uncommitted"), "diffHash": .string("old"),
      "diff": .string("diff --git a/a b/a\n@@ -1 +1 @@\n-old\n+new\n"),
    ]))
  #expect(!older.completeFileList)
  #expect(older.files.first?.additions == 1)
}
