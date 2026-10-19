import Foundation
import Testing

@testable import T3Core

@Test func collapsedPlanKeepsFullExportAndOnlyDropsDisplayHeadings() {
  let steps = (1...14).map { "- Step \($0)\n" }.joined(separator: "\n")
  let source = "# Integrate `Effect` RPC: Server!\n\n## Summary\n\n" + steps + " \n\t"
  let document = PlanDocument(source)
  #expect(document.title == "Integrate `Effect` RPC: Server!")
  #expect(document.filename == "integrate-effect-rpc-server.md")
  #expect(document.canCollapse)
  #expect(document.body.hasPrefix("- Step 1\n\n- Step 2"))
  #expect(document.body.hasSuffix("- Step 14"))
  #expect(document.preview.contains("- Step 10"))
  #expect(!document.preview.contains("- Step 11"))
  #expect(document.preview.hasSuffix("\n\n..."))
  #expect(document.contents == "# Integrate `Effect` RPC: Server!\n\n## Summary\n\n" + steps)
  let scope = PlanDocument("## Build\r\n\r\n## Scope\r\n\r\n```swift\r\nlet x = 1\r\n```\r\n")
  #expect(scope.body == "## Scope\n\n```swift\nlet x = 1\n```")
  #expect(scope.contents.hasSuffix("```\n"))
  #expect(scope.contents.contains("let x = 1\r\n"))
}

@Test func planPreviewHandlesMissingHeadingsAndUsesElectronCollapseThresholds() {
  let plain = PlanDocument("- Step one\n\n- Step two\n")
  #expect(plain.title == "Proposed plan")
  #expect(plain.filename == "plan.md")
  #expect(plain.body == "- Step one\n\n- Step two")
  #expect(!plain.canCollapse)
  #expect(PlanDocument("# Only title").preview == "Only title")
  #expect(PlanDocument("# 日本語").filename == "plan.md")
  #expect(!PlanDocument(String(repeating: "x", count: 900)).canCollapse)
  #expect(PlanDocument(String(repeating: "🌊", count: 451)).canCollapse)
  #expect(!PlanDocument(Array(repeating: "line", count: 20).joined(separator: "\n")).canCollapse)
  #expect(PlanDocument(Array(repeating: "line", count: 21).joined(separator: "\n")).canCollapse)
  #expect(
    PlanDocument("Intro\n\n# Later heading\n\nText").body.hasPrefix("Intro\n\n# Later heading"))
  #expect(PlanDocument("    # Code, not a title").heading == nil)
}

@Test func planWorkspaceUsesTheThreadsWorktreeAndPreservesExportBytes() throws {
  let project: JSON = .object(["workspaceRoot": .string("/project-root")])
  func thread(worktree: JSON = .null) throws -> ThreadSummary {
    try ThreadSummary(
      .object([
        "id": .string("thread"), "projectId": .string("project"), "title": .string("Plan"),
        "worktreePath": worktree,
      ]))
  }
  let root = try #require(
    WorkspaceLocation(environment: "server", thread: thread(), project: project))
  let worktree = try #require(
    WorkspaceLocation(
      environment: "server", thread: thread(worktree: .string("/separate-worktree")),
      project: project))
  #expect(root.root == "/project-root")
  #expect(worktree.root == "/separate-worktree")
  #expect(root != worktree)
  let document = PlanDocument("# Plan\n\nFull **content**.\n\n")
  let input = try worktree.writeInput(
    relativePath: " plans/full.md \n", contents: document.contents)
  #expect(input["cwd"].string == "/separate-worktree")
  #expect(input["relativePath"].string == "plans/full.md")
  #expect(input["contents"].string == "# Plan\n\nFull **content**.\n")
  #expect(throws: T3Error.self) {
    try worktree.writeInput(relativePath: " \n", contents: document.contents)
  }
  #expect(try WorkspaceLocation(environment: "server", thread: thread(), project: .null) == nil)
}
