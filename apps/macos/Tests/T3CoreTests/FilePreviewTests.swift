import Foundation
import Testing

@testable import T3Core

@Test func delimitedPreviewPreservesQuotedCellsAndEmptyRows() {
  let source = "\u{feff}Name,Note\r\n\"🦉, café\",\"First\r\nSecond \"\"quoted\"\"\"\r\n,\r\n\"\""
  let preview = DelimitedFilePreview(source, delimiter: 44)
  #expect(
    preview.rows == [
      ["Name", "Note"], ["🦉, café", "First\r\nSecond \"quoted\""], ["", ""], [""],
    ])
  #expect(!preview.truncated)
  #expect(DelimitedFilePreview("", delimiter: 44).rows.isEmpty)
  #expect(DelimitedFilePreview("\u{feff}", delimiter: 44).rows.isEmpty)
  #expect(
    DelimitedFilePreview("A\tB\n1\t\"two\tthree\"\n", delimiter: 9).rows == [
      ["A", "B"], ["1", "two\tthree"],
    ])
  let incomplete = DelimitedFilePreview("A,B\n1,\"unfinished", delimiter: 44)
  #expect(incomplete.rows == [["A", "B"], ["1", "unfinished"]])
  #expect(incomplete.truncated)
}

@Test func tablePreviewBoundsDoNotLoseQuotedDelimitersOrLaterCells() {
  let exactRows = String(repeating: "a,b\r\n", count: 100)
  #expect(!DelimitedFilePreview(exactRows, delimiter: 44).truncated)
  let overflow = DelimitedFilePreview(exactRows + "hidden,row", delimiter: 44)
  #expect(overflow.rows.count == 100)
  #expect(overflow.truncated)
  let columns = DelimitedFilePreview(
    (0...30).map(String.init).joined(separator: ","), delimiter: 44)
  #expect(columns.rows[0].count == 30)
  #expect(columns.rows[0].last == "29")
  #expect(columns.truncated)
  let long = String(repeating: "🦉", count: 1000)
  #expect(!DelimitedFilePreview(long, delimiter: 44).truncated)
  let clipped = DelimitedFilePreview("\"" + long + ",inside\",after\nnext,row", delimiter: 44)
  #expect(clipped.rows == [[long, "after"], ["next", "row"]])
  #expect(clipped.truncated)
}

@Test func checkingMarkdownChangesOnlyTheRequestedUTF16Marker() {
  let source = "# 🦉 café\r\n\r\n- [ ] first\r\n  - [X] second\r\n"
  let first = (source as NSString).range(of: "[ ]").location
  let second = (source as NSString).range(of: "[X]").location
  let checked = WorkspaceMarkdown.settingTask(source, offset: first, checked: true)
  #expect(checked == source.replacingOccurrences(of: "[ ]", with: "[x]"))
  #expect(WorkspaceMarkdown.settingTask(checked, offset: first, checked: false) == source)
  #expect(
    WorkspaceMarkdown.settingTask(source, offset: second, checked: false)
      == source.replacingOccurrences(of: "[X]", with: "[ ]"))
  for offset in [-1, 0, first + 1, Int.max] {
    #expect(WorkspaceMarkdown.settingTask(source, offset: offset, checked: true) == source)
  }
}

@Test func workspaceLinksUseTheDocumentsHostDirectoryAndKeepWorkspaceBoundaries() throws {
  let relative = try #require(
    WorkspaceMarkdown.link("../src/My%20File.swift#L12", filePath: "docs/readme.md", root: "/repo"))
  #expect(relative.path == "/repo/src/My File.swift")
  #expect(relative.fragment == "L12")
  #expect(WorkspaceMarkdown.workspacePath(relative, root: "/repo") == "src/My File.swift")
  let outside = try #require(
    WorkspaceMarkdown.link("appendix.md", filePath: "/tmp/report/readme.md", root: "/repo"))
  #expect(WorkspaceMarkdown.workspacePath(outside, root: "/repo") == "/tmp/report/appendix.md")
  let sibling = try #require(
    WorkspaceMarkdown.link("/repo-other/notes.md", filePath: "readme.md", root: "/repo"))
  #expect(WorkspaceMarkdown.workspacePath(sibling, root: "/repo") == "/repo-other/notes.md")
  #expect(WorkspaceMarkdown.workspacePath(sibling, root: "/") == "repo-other/notes.md")
  let encoded = try #require(
    WorkspaceMarkdown.link("100%25%23%20done.md", filePath: "docs/readme.md", root: "/repo"))
  #expect(encoded.path == "/repo/docs/100%# done.md")
  #expect(
    WorkspaceMarkdown.link("https://example.test/docs", filePath: "readme.md", root: "/repo")?
      .scheme == "https")
  for unsafe in [
    "javascript:alert(1)", "data:text/html,bad", "t3-markdown-task://toggle/1",
    "//another-host/file", "#section",
  ] {
    #expect(WorkspaceMarkdown.link(unsafe, filePath: "readme.md", root: "/repo") == nil)
  }
  #expect(
    WorkspaceMarkdown.workspacePath(URL(string: "file://another-host/private")!, root: "/repo")
      == nil)
}

@Test func filePreviewPreferencesPersistSeparatelyForMarkdownAndTables() throws {
  let name = "T3FilePreviewTests-" + UUID().uuidString
  let defaults = try #require(UserDefaults(suiteName: name))
  defer { defaults.removePersistentDomain(forName: name) }
  let preferences = FilePreviewPreferences(defaults: defaults)
  #expect(!preferences.rendered(.markdown))
  #expect(preferences.rendered(.csv))
  preferences.setRendered(true, for: .markdown)
  preferences.setRendered(false, for: .tsv)
  let restored = FilePreviewPreferences(defaults: try #require(UserDefaults(suiteName: name)))
  #expect(restored.rendered(.markdown))
  #expect(!restored.rendered(.csv))
  #expect(!restored.rendered(.tsv))
}
