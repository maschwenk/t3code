import Foundation
import Testing

@testable import T3Core

@Suite struct NewConversationDraftTests {
  private func json(_ value: String) throws -> JSON {
    try JSON.decode(Data(value.utf8))
  }

  private func conversation(workspace: String = "local") throws -> NewConversationDraft {
    let project = try json(
      """
      {"id":"project-native-draft","title":"Draft project","workspaceRoot":"/server/projects/draft"}
      """)
    let model = try json(
      """
      {"instanceId":"codex_work","model":"gpt-current","options":[{"id":"effort","value":"high"}]}
      """)
    return NewConversationDraft(
      project: project,
      configuration: NewThreadConfiguration(
        projectID: "project-native-draft", model: model,
        runtimeMode: "full-access", interactionMode: "plan"),
      workspaceMode: workspace)
  }

  private func directory() -> URL {
    URL(fileURLWithPath: "/tmp/t3-native-evidence", isDirectory: true)
      .appendingPathComponent("new-conversation-drafts-" + UUID().uuidString, isDirectory: true)
  }

  @Test func unsentConversationSurvivesRepositoryRestartAndKeepsItsSelectedConfiguration() throws {
    let directory = directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let endpoint = try #require(URL(string: "https://draft-server.example.invalid"))
    let other = try #require(URL(string: "https://other-server.example.invalid"))
    var draft = try conversation(workspace: "worktree")
    draft.branch = "release/native"
    let repository = DraftRepository(directory: directory)
    try repository.save(
      SavedDrafts(
        messages: [draft.id: "A message that has never been sent"], conversations: [draft.id: draft]
      ),
      for: endpoint)

    let reloaded = try DraftRepository(directory: directory).load(for: endpoint)
    let restored = try #require(reloaded.conversations?[draft.id])
    #expect(restored == draft)
    #expect(reloaded.messages[restored.id] == "A message that has never been sent")
    #expect(reloaded.submissions.isEmpty)
    #expect(restored.summary?.id == draft.id)
    #expect(restored.summary?.projectID == "project-native-draft")
    #expect(restored.summary?.model == draft.model)
    #expect(restored.summary?.runtimeMode == "full-access")
    #expect(restored.summary?.interactionMode == "plan")
    #expect(restored.summary?.branch == "release/native")
    #expect(restored.summary?.updatedAt == draft.createdAt)
    #expect(try repository.load(for: other).conversations == nil)
  }

  @Test func localLaunchUsesTheLaunchThreadEnvelopeAndPreservesFirstMessageBytes() throws {
    var draft = try conversation()
    draft.branch = "feature/existing"
    let attachment = try json(
      """
      {"type":"file","id":"uploaded_draft_file","name":"notes.txt","mimeType":"text/plain","sizeBytes":28}
      """)
    let submission = PendingSubmission(
      text: "  Review these notes\nKeep the indentation  ",
      command: "launch-command-original", message: "initial-message-original",
      attachments: [attachment], localAttachmentIDs: ["local-file-original"])
    let wire = try JSON.decode(draft.launch(submission).data())

    #expect(wire["commandId"] == .string("launch-command-original"))
    #expect(wire["threadId"] == .string(draft.id))
    #expect(wire["projectId"] == .string("project-native-draft"))
    #expect(wire["creationSource"] == .string("web"))
    #expect(wire["generateTitle"] == .bool(true))
    #expect(wire["title"] == .string("Review these notes\nKeep the indentation"))
    #expect(wire["modelSelection"] == draft.model)
    #expect(wire["runtimeMode"] == .string("full-access"))
    #expect(wire["interactionMode"] == .string("plan"))
    #expect(
      wire["workspaceStrategy"]
        == .object([
          "type": .string("root"), "branch": .string("feature/existing"),
        ]))
    #expect(
      wire["initialMessage"]
        == .object([
          "messageId": .string("initial-message-original"), "text": .string(submission.text),
          "attachments": .array([attachment]),
        ]))
    #expect(wire["type"] == .null)
    #expect(wire["initialMessage"]["localAttachmentIDs"] == .null)
    #expect(wire["initialMessage"]["delivery"] == .null)
  }

  @Test func restoredUnsentConversationAppearsBeforeOlderActiveThreads() throws {
    let draft = try JSONDecoder().decode(
      NewConversationDraft.self, from: JSONEncoder().encode(conversation()))
    let summary = try #require(draft.summary)
    let older = try ThreadSummary(
      json(
        """
        {"id":"older-thread","projectId":"project-native-draft","title":"Earlier conversation","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}
        """))
    let groups = ThreadGroup.resolve([older, summary], at: Date())
    let active = try #require(groups.first { $0.section == .active })
    #expect(active.threads.map(\.id) == [draft.id, older.id])
  }

  @Test func worktreeLaunchUsesTheSelectedBranchAsBaseRefRatherThanTheNewBranchName() throws {
    var draft = try conversation(workspace: "worktree")
    draft.branch = "origin/release/native"
    let launch = try draft.launch(PendingSubmission(text: "Inspect release changes"))
    #expect(
      launch["workspaceStrategy"]
        == .object([
          "type": .string("worktree"), "baseRef": .string("origin/release/native"),
        ]))
    #expect(launch["workspaceStrategy"]["branch"] == .null)
    #expect(launch["initialMessage"]["attachments"] == .array([]))
  }

  @Test(arguments: [nil, "", " \n\t "] as [String?])
  func worktreeRejectsAMissingOrBlankBaseBranch(baseRef: String?) throws {
    var draft = try conversation(workspace: "worktree")
    draft.branch = baseRef
    #expect(throws: T3Error.self) {
      try draft.launch(PendingSubmission(text: "Do not send a launch without a base branch"))
    }
  }

  @Test func attachmentOnlyLaunchKeepsAValidTitleAndAnEmptyInitialMessage() throws {
    let draft = try conversation()
    let file = try json(
      """
      {"type":"file","id":"uploaded_empty_prompt","name":"spec.md","mimeType":"text/markdown","sizeBytes":100}
      """)
    let launch = try draft.launch(PendingSubmission(text: "", attachments: [file]))
    #expect(launch["title"] == .string("New conversation"))
    #expect(launch["initialMessage"]["text"] == .string(""))
    #expect(launch["initialMessage"]["attachments"] == .array([file]))
    #expect(launch["workspaceStrategy"] == .object(["type": .string("root")]))
  }

  @Test func anUncertainLaunchRetainsTheExactPayloadAndIDsAcrossSaveReloadAndRetries() throws {
    let directory = directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let endpoint = try #require(URL(string: "http://127.0.0.1:4773"))
    var draft = try conversation(workspace: "worktree")
    draft.branch = "main"
    let file = try json(
      """
      {"type":"file","id":"uploaded_retry_file","name":"README.md","mimeType":"text/markdown","sizeBytes":400}
      """)
    let initial = PendingSubmission(
      text: "A launch whose response might be lost", command: "stable-launch-command",
      message: "stable-initial-message", attachments: [file],
      localAttachmentIDs: ["local-retry-file"], delivery: .auto)
    let launched = try draft.launch(initial)
    let pending = PendingSubmission(
      text: initial.text, command: initial.command, message: initial.message,
      attachments: initial.attachments, localAttachmentIDs: initial.localAttachmentIDs,
      delivery: initial.delivery, launch: launched)
    let repository = DraftRepository(directory: directory)
    var saved = SavedDrafts(
      messages: [draft.id: initial.text], submissions: [draft.id: pending],
      conversations: [draft.id: draft])

    for _ in 0..<3 {
      try repository.save(saved, for: endpoint)
      saved = try DraftRepository(directory: directory).load(for: endpoint)
      let recoveredDraft = try #require(saved.conversations?[draft.id])
      let recoveredPending = try #require(saved.submissions[draft.id])
      #expect(recoveredPending.command == "stable-launch-command")
      #expect(recoveredPending.message == "stable-initial-message")
      #expect(recoveredPending.launch == launched)
      #expect(try recoveredDraft.launch(recoveredPending) == launched)
      #expect(recoveredPending.localAttachmentIDs == ["local-retry-file"])
      #expect(recoveredPending.launch?["initialMessage"]["attachments"] == .array([file]))
    }

    // An already prepared launch stays frozen even if the surrounding composer draft is edited.
    var edited = try #require(saved.conversations?[draft.id])
    edited.branch = "different-base"
    edited.model = .object(["instanceId": .string("claude_work"), "model": .string("opus")])
    saved.conversations?[draft.id] = edited
    try repository.save(saved, for: endpoint)
    let recovered = try repository.load(for: endpoint)
    #expect(recovered.submissions[draft.id]?.launch == launched)
    #expect(recovered.conversations?[draft.id]?.branch == "different-base")
  }

  @Test(arguments: [1, 2, 3, 4, 5])
  func preConversationDraftFilesStillLoadAndTheirPendingMessagesRemainRetryable(version: Int) throws
  {
    let directory = directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let endpoint = try #require(URL(string: "https://legacy-drafts.example.invalid"))
    let repository = DraftRepository(directory: directory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let legacy = Data(
      """
      {"version":\(version),"messages":{"existing-thread":"The old unsent message"},
       "questions":{},"submissions":{"existing-thread":{"text":"The old unsent message",
       "command":"old-command","message":"old-message"}}}
      """.utf8)
    try legacy.write(to: repository.file(for: endpoint))

    let saved = try repository.load(for: endpoint)
    #expect(saved.version == version)
    #expect(saved.conversations == nil)
    #expect(saved.messages["existing-thread"] == "The old unsent message")
    let pending = try #require(saved.submissions["existing-thread"])
    #expect(pending.launch == nil)
    #expect(pending.matches(text: "The old unsent message", attachments: []))
    let payload = pending.payload(threadID: "existing-thread")
    #expect(payload["type"] == .string("message.dispatch"))
    #expect(payload["commandId"] == .string("old-command"))
    #expect(payload["messageId"] == .string("old-message"))
    #expect(payload["threadId"] == .string("existing-thread"))
    #expect(payload["attachments"] == .array([]))
    try repository.save(saved, for: endpoint)
    #expect(try repository.load(for: endpoint) == saved)
  }
}
