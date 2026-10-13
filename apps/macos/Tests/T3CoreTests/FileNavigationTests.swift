import Foundation
import Testing

@testable import T3Core

@Test func fileNavigationPreservesLocationsWithoutSendingThemAsFilenames() throws {
  for (destination, expectedPath, line, column) in [
    ("source.swift:42:7", "docs/source.swift", 42, 7),
    ("../src/source.swift#L42C7", "src/source.swift", 42, 7),
    ("file://localhost/repo/src/source.swift#l42c7", "src/source.swift", 42, 7),
    ("../src/source.swift:42:7#L99C3", "src/source.swift", 42, 7),
    ("<../src/My%20File.swift:42:7>", "src/My File.swift", 42, 7),
    ("/tmp/external.swift#L42C7", "/tmp/external.swift", 42, 7),
    ("#L42C7", "docs/readme.md", 42, 7),
  ] {
    let url = try #require(
      WorkspaceMarkdown.link(destination, filePath: "docs/readme.md", root: "/repo"))
    let link = try #require(WorkspaceFileLink(url: url, root: "/repo"))
    #expect(link.path == expectedPath)
    #expect(link.position == FileSourcePosition(line: line, column: column))
  }
  let conversation = try #require(
    WorkspaceMarkdown.link("src/main.swift:8", filePath: "", root: "/repo"))
  let link = try #require(WorkspaceFileLink(url: conversation, root: "/repo"))
  #expect(link.path == "src/main.swift")
  #expect(link.position == FileSourcePosition(line: 8))
  let encoded = try #require(
    WorkspaceMarkdown.link("file:///repo/100%2520%23.md#L2", filePath: "", root: "/repo"))
  #expect(WorkspaceFileLink(url: encoded, root: "/repo")?.path == "100%20#.md")
  let zero = try #require(
    WorkspaceMarkdown.link("source.swift:0:0", filePath: "", root: "/repo"))
  #expect(WorkspaceFileLink(url: zero, root: "/repo")?.path == "source.swift")
  #expect(WorkspaceFileLink(url: zero, root: "/repo")?.position == nil)
  for unsafe in ["javascript:1", "data:text/html,bad", "t3-markdown-task://toggle/1"] {
    #expect(WorkspaceMarkdown.link(unsafe, filePath: "", root: "/repo") == nil)
  }
  #expect(WorkspaceMarkdown.link("src/main.swift:8", filePath: "", root: nil) == nil)
  #expect(
    WorkspaceMarkdown.link("https://example.test", filePath: "", root: nil)?.scheme == "https")
}

@Test func sourceLocationsClampLinesAndColumnsWithoutSplittingUnicodeOrCRLF() {
  for ending in ["\n", "\r\n", "\r"] {
    let source = "first" + ending + "🦉 cafe\u{301}" + ending + "last"
    let text = source as NSString
    let start = text.range(of: "🦉").location
    let last = text.range(of: "last")
    #expect(FileSourcePosition(line: 2).range(in: source) == NSRange(location: start, length: 8))
    #expect(FileSourcePosition(line: 2, column: 2).range(in: source).location == start)
    #expect(FileSourcePosition(line: 2, column: 3).range(in: source).location == start + 2)
    #expect(FileSourcePosition(line: 2, column: 8).range(in: source).location == start + 6)
    #expect(FileSourcePosition(line: 2, column: Int.max).range(in: source).location == start + 8)
    #expect(FileSourcePosition(line: Int.max).range(in: source) == last)
    #expect(
      FileSourcePosition(line: Int.max).range(in: source + ending).location == text.length
        + (ending as NSString).length)
  }
  #expect(
    FileSourcePosition(line: Int.max, column: Int.max).range(in: "")
      == NSRange(location: 0, length: 0))
  #expect(FileSourcePosition(line: 1).range(in: "\r\n\n") == NSRange(location: 0, length: 0))
  #expect(FileSourcePosition(line: 2).range(in: "\r\n\n") == NSRange(location: 2, length: 0))
}

@Test func folderFailuresRemainStructuredThroughTheRPCEnvelope() throws {
  for failure in ["path_not_file", "binary_file", "operation_failed"] {
    let value: JSON = .object([
      "_tag": .string("Failure"),
      "cause": .object([
        "reasons": .array([
          .object([
            "_tag": .string("Fail"),
            "error": .object([
              "_tag": .string("ProjectReadFileError"), "failure": .string(failure),
              "message": .string("Cannot read the requested path"),
            ]),
          ])
        ])
      ]),
    ])
    let error = RPCConnection.requestError(value)
    #expect(error.remoteCode == "ProjectReadFileError")
    #expect(error.remoteFailure == failure)
    #expect(error.localizedDescription == "Cannot read the requested path")
  }
  let unknown = RPCConnection.requestError(.object(["message": .string("Connection lost")]))
  #expect(unknown.remoteCode == nil)
  #expect(unknown.remoteFailure == nil)
  #expect(unknown.localizedDescription == "Connection lost")
  #expect(
    WorkspaceTreeNavigation.directories(for: "docs/nested/readme.md", isDirectory: false) == [
      "", "docs", "docs/nested",
    ])
  #expect(
    WorkspaceTreeNavigation.directories(for: "docs/nested/", isDirectory: true) == [
      "", "docs", "docs/nested",
    ])
  #expect(WorkspaceTreeNavigation.directories(for: "../outside", isDirectory: true).isEmpty)
  #expect(WorkspaceTreeNavigation.directories(for: "/tmp/report", isDirectory: true).isEmpty)
  let root = try #require(WorkspaceMarkdown.link("..", filePath: "docs/readme.md", root: "/repo"))
  #expect(WorkspaceMarkdown.workspacePath(root, root: "/repo") == ".")
  #expect(WorkspaceTreeNavigation.directories(for: ".", isDirectory: true) == [""])
}
