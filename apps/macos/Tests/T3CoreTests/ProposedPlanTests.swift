import Foundation
import Testing

@testable import T3Core

private func planFixture(_ id: String, run: String = "run", status: String = "active") -> JSON {
  .object([
    "kind": .string("proposed_plan"), "id": .string(id), "runId": .string(run),
    "status": .string(status),
    "markdown": .string("# Make the button accessible\n\nAdd a label.\n"),
  ])
}

@Test func planSelectionTracksRunStatusItemTimingAndCrossClientCompletion() throws {
  var state = ThreadState(id: "t")
  let run: JSON = .object([
    "id": .string("run"), "ordinal": .number(1), "status": .string("completed"),
    "completedAt": .string("2026-10-11T12:00:00Z"),
  ])
  _ = try state.apply(
    .object([
      "kind": .string("snapshot"), "snapshotSequence": .number(1),
      "projection": .object([
        "thread": .object(["id": .string("t")]), "runs": .array([run]),
        "plans": .array([planFixture("old", run: "older"), planFixture("a"), planFixture("b")]),
        "updatedAt": .string("2026-10-11T12:00:00Z"),
      ]),
    ]))
  #expect(state.execution.latestRunSettled)
  #expect(state.latestProposedPlan?.id == "b")
  func update(_ type: String, _ payload: JSON, sequence: Int) throws {
    _ = try state.apply(
      .object([
        "kind": .string("event"), "sequence": .number(Double(sequence)),
        "event": .object(["type": .string(type), "threadId": .string("t"), "payload": payload]),
      ]))
  }
  try update(
    "turn-item.updated",
    .object([
      "id": .string("item"), "threadId": .string("t"), "type": .string("proposed_plan"),
      "planId": .string("a"), "markdown": .string("# Latest plan"),
      "updatedAt": .string("2026-10-11T12:01:00Z"),
    ]), sequence: 2)
  #expect(state.latestProposedPlan?.id == "a")
  try update("plan.updated", planFixture("a", status: "completed"), sequence: 3)
  #expect(state.latestProposedPlan?.status == "completed")
  try update("plan.updated", planFixture("a"), sequence: 2)
  #expect(state.latestProposedPlan?.status == "completed")
  try update(
    "run.created",
    .object([
      "id": .string("next"), "ordinal": .number(2), "status": .string("starting"),
    ]), sequence: 4)
  #expect(!state.execution.latestRunSettled)
  #expect(state.execution.latestRunID == "next")
  #expect(state.latestProposedPlan?.id == "a")
}

@Test func planRefinementAndImplementationKeepDifferentModesAndSourceLinks() throws {
  let plan = ProposedPlan(planFixture("plan"), updatedAt: "")!
  let template = try ThreadSummary(
    .object([
      "id": .string("source"), "projectId": .string("project"), "title": .string("Planning"),
      "modelSelection": .object(["instanceId": .string("account"), "model": .string("chosen")]),
      "runtimeMode": .string("approval-required"), "interactionMode": .string("plan"),
      "branch": .string("feature"), "worktreePath": .string("/tmp/isolated-worktree"),
    ]))
  let refine = PendingPlanSubmission(
    plan: plan, template: template, draft: "  Make the label shorter.\n", newThread: false,
    defaultRuntimeMode: "full-access")
  #expect(refine.setup["interactionMode"].string == "plan")
  #expect(refine.message["text"].string == "Make the label shorter.")
  #expect(refine.message["sourcePlanRef"] == .null)
  for newThread in [false, true] {
    let implement = PendingPlanSubmission(
      plan: plan, template: template, draft: " \n", newThread: newThread,
      defaultRuntimeMode: "full-access")
    #expect(implement.setup["interactionMode"].string == "default")
    #expect(
      implement.message["text"].string
        == "PLEASE IMPLEMENT THIS PLAN:\n# Make the button accessible\n\nAdd a label.")
    #expect(
      implement.message["sourcePlanRef"]
        == .object(["threadId": .string("source"), "planId": .string("plan")]))
    #expect(implement.message["modelSelection"] == template.model)
    if newThread {
      #expect(implement.targetThreadID != template.id)
      #expect(implement.setup["title"].string == "Implement Make the button accessible")
      #expect(implement.setup["branch"].string == "feature")
      #expect(implement.setup["worktreePath"].string == template.worktreePath)
      #expect(implement.setup["runtimeMode"].string == "full-access")
    } else {
      #expect(implement.targetThreadID == template.id)
    }
  }
  #expect(Commands.newThread(template: template, id: "ordinary")["worktreePath"] == .null)
  let simplyNamed = ProposedPlan(
    .object([
      "id": .string("plan"), "kind": .string("proposed_plan"),
      "markdown": .string("# Plan\n\nDo the work."),
    ]), updatedAt: "")!
  let named = PendingPlanSubmission(
    plan: simplyNamed, template: template, draft: "", newThread: true,
    defaultRuntimeMode: "approval-required")
  #expect(named.setup["title"].string == "Implement Plan")
}

@Test func partialPlanSendPreservesBothCommandIdentitiesAcrossRestart() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let repository = DraftRepository(directory: root)
  let endpoint = URL(string: "https://example.test")!
  let template = try ThreadSummary(
    .object([
      "id": .string("source"), "projectId": .string("project"), "title": .string("Planning"),
    ]))
  for newThread in [false, true] {
    let command = PendingPlanSubmission(
      plan: ProposedPlan(planFixture("plan"), updatedAt: "")!, template: template,
      draft: "", newThread: newThread, defaultRuntimeMode: "approval-required")
    let saved = SavedDrafts(
      messages: ["source": "Unsent draft"], planSubmissions: ["source": command])
    try repository.save(saved, for: endpoint)
    let restored = try DraftRepository(directory: root).load(for: endpoint)
    #expect(restored == saved)
    #expect(restored.planSubmissions?["source"]?.message == command.message)
    #expect(restored.planSubmissions?["source"]?.setup == command.setup)
    #expect(try repository.load(for: URL(string: "https://other.test")!).planSubmissions == nil)
  }
  let old = Data(
    #"{"version":4,"messages":{"source":"keep"},"questions":{},"submissions":{},"questionPages":{"r":1}}"#
      .utf8)
  try old.write(to: repository.file(for: endpoint))
  let restored = try repository.load(for: endpoint)
  #expect(restored.messages["source"] == "keep")
  #expect(restored.questionPages?["r"] == 1)
  #expect(restored.planSubmissions == nil)
}
