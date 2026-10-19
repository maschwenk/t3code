import Foundation
import Testing

@testable import T3Core

@Test func composerMentionsReplaceWholeTokensAtUTF16CaretOffsets() throws {
  let text = "🌊 café @Sources/Part.swift and $review"
  let source = text as NSString
  let cursor = source.range(of: "Part").location + 2
  let mention = try #require(ComposerMention.detect(text: text, cursor: cursor))
  #expect(mention.kind == .file)
  #expect(mention.query == "Sources/Pa")
  #expect(source.substring(with: mention.range) == "@Sources/Part.swift")
  let insertion = mention.insertion(in: text, replacement: "[Other.swift](Sources/Other.swift)")
  #expect(
    source.replacingCharacters(in: insertion.range, with: insertion.replacement)
      == "🌊 café [Other.swift](Sources/Other.swift) and $review")
  #expect(ComposerMention.detect(text: text, cursor: source.length)?.query == "review")
  #expect(ComposerMention.detect(text: "user@example.test", cursor: 17) == nil)
  #expect(ComposerMention.detect(text: "cost $20k", cursor: 9) == nil)
  #expect(ComposerMention.detect(text: "explain\n/compact", cursor: 16)?.kind == .command)
  #expect(ComposerMention.detect(text: "/compact", cursor: 8)?.kind == .command)
  #expect(
    ComposerMention.detect(text: "@" + String(repeating: "a", count: 257), cursor: 258) == nil)
}

@Test func composerFileLinksMatchWebWireFormatAndLiteralFallbackPreservesRoots() {
  #expect(
    ComposerMention.fileReference(path: "docs/My File (draft).md", root: "/repo")
      == "[My File (draft).md](docs/My%20File%20%28draft%29.md)")
  #expect(
    ComposerMention.fileReference(path: "docs/[café]?#.md", root: "/repo")
      == "[\\[café\\]?#.md](docs/%5Bcaf%C3%A9%5D%3F%23.md)")
  #expect(
    ComposerMention.fileReference(path: "C:\\repo\\src\\index.ts", root: "/repo")
      == "[index.ts](C:%5Crepo%5Csrc%5Cindex.ts)")
  #expect(
    ComposerMention.fileReference(path: "src", root: "/worktrees/one/", format: .absoluteLiteral)
      == "/worktrees/one/src")
  #expect(
    ComposerMention.fileReference(path: "src/a.ts", root: "C:\\repo", format: .absoluteLiteral)
      == "C:\\repo\\src/a.ts")
}

private func completionProvider() -> JSON {
  .object([
    "enabled": .bool(true), "installed": .bool(true), "status": .string("ready"),
    "slashCommands": .array([.object(["name": .string("global-command")])]),
    "skills": .array([.object(["name": .string("global-skill"), "enabled": .bool(true)])]),
    "workspaceSnapshots": .array([
      .object([
        "cwd": .string("/repo"),
        "slashCommands": .array([
          .object(["name": .string("review"), "description": .string("Review changes")]),
          .object(["name": .string("compact")]),
        ]),
        "skills": .array([
          .object([
            "name": .string("review-code"), "enabled": .bool(true),
            "displayName": .string("Code review"),
          ]),
          .object(["name": .string("disabled"), "enabled": .bool(false)]),
          .object([
            "name": .string("agent-only"), "enabled": .bool(true), "userInvocable": .bool(false),
          ]),
          .object([
            "name": .string("user-only"), "enabled": .bool(true), "userInvocationOnly": .bool(true),
          ]),
        ]),
      ])
    ]),
  ])
}

@Test func composerUsesTheSelectedWorktreeCatalogAndFiltersUnusableSkillsAndCommands() {
  let provider = completionProvider()
  let commands = ComposerSuggestion.providerItems(provider, cwd: "/repo", kind: .command, query: "")
  #expect(commands.map(\.name) == ["review"])
  #expect(commands.first?.replacement(root: "/repo") == "/review")
  let skills = ComposerSuggestion.providerItems(provider, cwd: "/repo", kind: .skill, query: "")
  #expect(Set(skills.map(\.name)) == ["review-code", "user-only"])
  #expect(
    skills.first(where: { $0.name == "review-code" })?.replacement(root: "/repo") == "$review-code")
  #expect(
    ComposerSuggestion.providerItems(provider, cwd: "/other", kind: .command, query: "").map(\.name)
      == ["global-command"])
  #expect(
    ComposerSuggestion.providerItems(
      provider, cwd: "/repo", kind: .command, query: "compact", allowCompact: true
    ).map(\.name) == ["compact"])
  #expect(
    ComposerSuggestion.providerItems(provider, cwd: "/repo", kind: .skill, query: "code review")
      .map(\.name) == ["review-code"])
  guard case .object(var fields) = provider else { return }
  fields["availability"] = .string("unavailable")
  #expect(
    ComposerSuggestion.providerItems(.object(fields), cwd: "/repo", kind: .command, query: "")
      .isEmpty)
}

@Test func composerSkillLiteralFallbackNamesTheRealCatalogFile() throws {
  let provider: JSON = .object([
    "enabled": .bool(true), "installed": .bool(true),
    "skills": .array([
      .object([
        "name": .string("review"), "path": .string("/repo/.agents/skills/review/SKILL.md"),
        "enabled": .bool(true),
      ])
    ]),
  ])
  let skill = try #require(
    ComposerSuggestion.providerItems(provider, cwd: "/repo", kind: .skill, query: "review").first)
  #expect(skill.replacement(root: "/repo") == "$review")
  #expect(
    skill.replacement(root: "/repo", skillUsesLiteralPath: true)
      == "/repo/.agents/skills/review/SKILL.md")
}

@Test func composerDisabledDuplicatesCannotHideAnEnabledSkillAndMoneyNamesStayLiteral() {
  let provider: JSON = .object([
    "enabled": .bool(true), "installed": .bool(true),
    "skills": .array([
      .object(["name": .string("review"), "enabled": .bool(false)]),
      .object(["name": .string("review"), "enabled": .bool(true)]),
      .object(["name": .string("20k"), "enabled": .bool(true)]),
    ]),
  ])
  #expect(
    ComposerSuggestion.providerItems(provider, cwd: "/repo", kind: .skill, query: "").map(\.name)
      == ["review"])
}

@Test func composerFileResultsKeepServerRankingAndBoundDuplicateMatches() {
  let result: JSON = .object([
    "entries": .array([
      .object(["path": .string("src/z.swift"), "kind": .string("file")]),
      .object(["path": .string("src"), "kind": .string("directory")]),
      .object(["path": .string("src/z.swift"), "kind": .string("file")]),
      .object(["path": .string("src/a.swift"), "kind": .string("file")]),
    ])
  ])
  let items = ComposerSuggestion.files(result, limit: 2)
  #expect(items.map(\.name) == ["src/z.swift", "src"])
  #expect(items[1].isDirectory)
  #expect(items[1].replacement(root: "/repo") == "[src](src)")
}

private func completionScope(
  thread: String = "one", provider: String = "codex", root: String = "/repo", session: UUID
) -> ComposerCompletionScope {
  ComposerCompletionScope(
    environment: "https://server.example", session: session,
    thread: thread, draft: thread, provider: provider, root: root)
}

@Test func composerRejectsStaleSearchesAfterTypingReconnectOrThreadAndProviderChanges() throws {
  let session = UUID()
  let scope = completionScope(session: session)
  var state = ComposerCompletionState()
  state.refresh(text: "@a", cursor: 2, scope: scope)
  let first = try #require(state.ticket)
  state.refresh(text: "@ab", cursor: 3, scope: scope)
  #expect(!state.accepts(first))
  let newer = try #require(state.ticket)
  #expect(state.accepts(newer))
  for next in [
    completionScope(thread: "two", session: session),
    completionScope(provider: "claude", session: session),
    completionScope(root: "/worktree", session: session), completionScope(session: UUID()),
  ] {
    state.refresh(text: "@ab", cursor: 3, scope: next)
    #expect(!state.accepts(newer))
  }
  state.refresh(text: "@ab", cursor: 3, scope: nil)
  #expect(state.ticket == nil)
}

@Test func composerEscapeStaysDismissedWhileTypingUntilCaretLeavesToken() throws {
  let scope = completionScope(session: UUID())
  var state = ComposerCompletionState()
  state.refresh(text: "$rev", cursor: 4, scope: scope)
  let ticket = try #require(state.ticket)
  state.dismiss()
  state.refresh(text: "$review", cursor: 7, scope: scope)
  #expect(state.mention == nil)
  #expect(!state.accepts(ticket))
  state.refresh(text: "$review ", cursor: 8, scope: scope)
  state.refresh(text: "$review $", cursor: 9, scope: scope)
  #expect(state.mention?.kind == .skill)
}

@Test func composerLocalActionsKeepProviderCommandsAtPromptStartAndRespectPlanAvailability() throws
{
  let providerItems = ComposerSuggestion.providerItems(
    completionProvider(), cwd: "/repo", kind: .command, query: "")
  let start = try #require(ComposerMention.detect(text: "/", cursor: 1))
  let middle = try #require(ComposerMention.detect(text: "Explain 🌊 /", cursor: 12))
  func items(
    _ mention: ComposerMention, enabled: Bool = true, plan: Bool = true, support: Bool = true
  ) -> [ComposerSuggestion] {
    ComposerSuggestion.slashItems(
      providerItems: providerItems, mention: mention,
      localCommandsEnabled: enabled, planModeEnabled: plan, interactionModeSupported: support)
  }
  #expect(items(start).map(\.name) == ["model", "plan", "default", "review"])
  #expect(items(middle).map(\.name) == ["model", "plan", "default"])
  #expect(items(middle, plan: false).map(\.name) == ["model"])
  #expect(items(middle, support: false).map(\.name) == ["model"])
  #expect(items(middle, enabled: false).isEmpty)
  #expect(items(start, enabled: false).map(\.name) == ["review"])
  let search = try #require(ComposerMention.detect(text: "Explain /pl", cursor: 11))
  #expect(items(search).map(\.localCommand) == ["plan"])
  #expect(items(search, plan: false).isEmpty)
  let review = try #require(ComposerMention.detect(text: "Explain /review", cursor: 15))
  #expect(items(review).isEmpty)
}

@Test func composerLocalSelectionRemovesOnlyTheCommandAndPreservesPromptContext() throws {
  for command in ["model", "plan", "default"] {
    let text = "🌊 discuss /\(command)more  [file.swift](src/file.swift) $review"
    let source = text as NSString
    let cursor = source.range(of: "/" + command).location + command.utf16.count + 1
    let mention = try #require(ComposerMention.detect(text: text, cursor: cursor))
    let item = try #require(
      ComposerSuggestion.slashItems(
        providerItems: [], mention: mention,
        localCommandsEnabled: true, planModeEnabled: true, interactionModeSupported: true
      ).first)
    let edit = item.selectionEdit(mention: mention, text: text, root: "/repo")
    #expect(item.localCommand == command)
    #expect(edit.range == source.range(of: "/" + command + "more"))
    #expect(edit.replacement.isEmpty)
    #expect(
      source.replacingCharacters(in: edit.range, with: edit.replacement)
        == "🌊 discuss   [file.swift](src/file.swift) $review")
    #expect(item.replacement(root: "/repo").isEmpty)
  }
  let text = "/review later"
  let mention = try #require(ComposerMention.detect(text: text, cursor: 7))
  let item = try #require(
    ComposerSuggestion.providerItems(
      completionProvider(), cwd: "/repo", kind: .command, query: "review"
    ).first)
  let edit = item.selectionEdit(mention: mention, text: text, root: "/repo")
  #expect(item.localCommand == nil)
  #expect((text as NSString).replacingCharacters(in: edit.range, with: edit.replacement) == text)
}

@Test func composerLocalActionsCannotUseTicketsFromAnotherDraftEnvironmentOrConnection() throws {
  let session = UUID()
  let scope = completionScope(session: session)
  for changed in [
    ComposerCompletionScope(
      environment: "other-server", session: session, thread: scope.thread,
      draft: scope.draft, provider: scope.provider, root: scope.root),
    ComposerCompletionScope(
      environment: scope.environment, session: session, thread: scope.thread,
      draft: "edited-queued-message", provider: scope.provider, root: scope.root),
    completionScope(thread: "two", session: session),
    completionScope(provider: "claude", session: session),
    completionScope(root: "/another-worktree", session: session),
    completionScope(session: UUID()),
  ] {
    var state = ComposerCompletionState()
    state.refresh(text: "Explain /model", cursor: 14, scope: scope)
    let original = try #require(state.ticket)
    #expect(
      !ComposerSuggestion.slashItems(
        providerItems: [], mention: original.mention,
        localCommandsEnabled: true, planModeEnabled: false, interactionModeSupported: false
      ).isEmpty)
    state.refresh(text: "Explain /model", cursor: 14, scope: changed)
    #expect(!state.accepts(original))
    #expect(state.ticket?.scope == changed)
    state.refresh(text: "Explain /model", cursor: 14, scope: nil)
    #expect(state.ticket == nil)
  }
}
