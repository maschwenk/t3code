import Foundation
import Testing

@testable import T3Core

private func decode(_ value: String) throws -> JSON { try JSON.decode(Data(value.utf8)) }

private func request(
  _ status: String = "pending", capability: String = "live", kind: String = "command"
) -> JSON {
  .object([
    "id": .string("r"), "kind": .string(kind), "status": .string(status),
    "responseCapability": .object(["type": .string(capability)]),
    "createdAt": .string("2026-10-11T00:00:00Z"),
  ])
}

private func requestItem(_ kind: String = "approval_request") -> JSON {
  .object([
    "id": .string("item"), "type": .string(kind), "threadId": .string("t"),
    "requestId": .string("r"), "ordinal": .number(0), "prompt": .string("echo check"),
    "questions": .array([
      .object(["id": .string("q"), "question": .string("Choose a color"), "options": .array([])])
    ]),
  ])
}

private func snapshot(requests: [JSON], items: [JSON] = []) -> JSON {
  .object([
    "kind": .string("snapshot"), "snapshotSequence": .number(5),
    "projection": .object([
      "thread": .object(["id": .string("t")]), "runtimeRequests": .array(requests),
      "turnItems": .array(items),
    ]),
  ])
}

private func event(_ type: String, _ payload: JSON, _ sequence: Int) -> JSON {
  .object([
    "kind": .string("event"), "sequence": .number(Double(sequence)),
    "event": .object(["type": .string(type), "payload": payload]),
  ])
}

@Test func approvalFollowsAuthoritativeRuntimeStateAcrossClients() throws {
  var thread = ThreadState(id: "t")
  _ = try thread.apply(snapshot(requests: [request()], items: [requestItem()]))
  #expect(thread.pendingRequests.count == 1)
  #expect(thread.pendingRequests[0].detail == "echo check")
  #expect(thread.pendingRequests[0].canRespond)
  _ = try thread.apply(event("runtime-request.updated", request("resolved"), 6))
  _ = try thread.apply(event("runtime-request.updated", request(), 5))
  #expect(thread.pendingRequests.isEmpty)
  #expect(thread.rows.count == 1)
}

@Test func requestAndDisplayEventsMayArriveInEitherOrder() throws {
  for itemFirst in [true, false] {
    var thread = ThreadState(id: "t")
    _ = try thread.apply(snapshot(requests: []))
    let values = [
      ("turn-item.updated", requestItem("user_input_request")),
      ("runtime-request.updated", request(kind: "user_input")),
    ]
    for (index, value) in (itemFirst ? values : values.reversed()).enumerated() {
      _ = try thread.apply(event(value.0, value.1, index + 6))
      if index == 0 { #expect(thread.pendingRequests.isEmpty) }
    }
    #expect(thread.pendingRequests.count == 1)
    #expect(thread.pendingRequests[0].questions.count == 1)
  }
}

@Test func answeredQuestionHistorySurvivesEventOrderAndReconnect() throws {
  let answered = try decode(
    """
    {"id":"r","kind":"user_input","status":"resolved",
     "answers":{"q":{"answers":["Blue","",{"answers":["Green"]}]}}}
    """)
  let item = requestItem("user_input_request")
  for itemFirst in [true, false] {
    var thread = ThreadState(id: "t")
    _ = try thread.apply(snapshot(requests: []))
    let values = [("turn-item.updated", item), ("runtime-request.updated", answered)]
    for (index, value) in (itemFirst ? values : values.reversed()).enumerated() {
      _ = try thread.apply(event(value.0, value.1, index + 6))
    }
    #expect(thread.rows[0].text == "Choose a color\nBlue, Green")
    #expect(thread.rows[0].title == "Answered questions")
    #expect(thread.rows[0].item == item)
    _ = try thread.apply(event("runtime-request.updated", request(kind: "user_input"), 6))
    #expect(thread.rows[0].text == "Choose a color\nBlue, Green")
    _ = try thread.apply(event("turn-item.updated", item, 8))
    #expect(thread.rows[0].text == "Choose a color\nBlue, Green")
    _ = try thread.apply(snapshot(requests: [answered], items: [item]))
    #expect(thread.rows[0].text == "Choose a color\nBlue, Green")
    #expect(thread.pendingRequests.isEmpty)
  }
}

@Test func pagedQuestionAnswersStayWithinTheirSourceThread() throws {
  let answered = try decode(
    """
    {"id":"r","kind":"user_input","status":"resolved","answers":{"q":"Blue"}}
    """)
  let item = requestItem("user_input_request")
  let rows: [JSON] = ["parent", "t"].enumerated().map { index, source in
    .object([
      "item": item, "position": .number(Double(index)), "sourceThreadId": .string(source),
      "visibility": .string(source == "t" ? "own" : "inherited"),
    ])
  }
  var thread = ThreadState(id: "t")
  _ = try thread.apply(snapshot(requests: [answered]))
  try thread.prependHistory(.object(["items": .array(rows)]))
  #expect(thread.rows.map(\.text) == ["Choose a color", "Choose a color\nBlue"])
  _ = try thread.apply(event("runtime-request.updated", answered, 6))
  #expect(thread.rows.map(\.text) == ["Choose a color", "Choose a color\nBlue"])
  _ = try thread.apply(
    .object([
      "kind": .string("snapshot"), "snapshotSequence": .number(7),
      "projection": .object([
        "thread": .object(["id": .string("t")]), "runtimeRequests": .array([answered]),
        "visibleTurnItems": .array(rows),
      ]),
    ]))
  #expect(thread.rows.map(\.text) == ["Choose a color", "Choose a color\nBlue"])
  for status in ["pending", "expired", "cancelled"] {
    let unresolved = try decode(
      """
      {"id":"r","kind":"user_input","status":"\(status)","answers":{"q":"Blue"}}
      """)
    let row = try TimelineRow(item: item, position: 0, sourceID: "t", request: unresolved)
    #expect(row.text == "Choose a color")
    #expect(row.title == "Question")
  }
}

@Test func recordedQuestionAnswerAndFilesTakePrecedenceOverLegacyRequest() throws {
  let item = try decode(
    """
    {"id":"item","type":"user_input_request","requestId":"r",
     "questions":[{"id":"q","question":"Which file?"}],
     "questionAnswer":{"answers":{"q":"Use this file"},
       "attachmentsByQuestionId":{"q":[{"id":"file","name":"notes.txt"}]}}}
    """)
  let answered = try decode(
    """
    {"id":"r","kind":"user_input","status":"resolved","answers":{"q":"Legacy answer"}}
    """)
  let row = try TimelineRow(item: item, position: 0, sourceID: "t", request: answered)
  #expect(row.text == "Which file?\nUse this file")
  #expect(row.attachments.first?["name"].string == "notes.txt")
}

@Test func stoppedSessionCannotApproveButMessageQuestionsRemainAnswerable() throws {
  let expired = try PendingRequest(
    request: request(capability: "not_resumable"), item: requestItem())
  #expect(!expired.canRespond)
  let message = try PendingRequest(
    request: request(capability: "message", kind: "user_input"),
    item: requestItem("user_input_request"))
  #expect(message.canRespond)
  #expect(message.dismissible)
  let approval = try PendingRequest(request: request(capability: "message"), item: requestItem())
  #expect(!approval.canRespond)
}

@Test func providerApprovalChoicesAreNotExpandedByClientDefaults() throws {
  let item = try decode(
    """
    {"options":[{"decision":"decline","label":"Deny","warning":"Untrusted content"}]}
    """)
  let pending = try PendingRequest(request: request(), item: item)
  #expect(pending.options.count == 1)
  #expect(pending.options[0]["warning"].string == "Untrusted content")
  #expect(!pending.options.contains { $0["decision"].string == "accept" })
  let noChoices = try PendingRequest(request: request(), item: decode("{\"options\":[]}"))
  #expect(noChoices.options.isEmpty)
}

@Test func inheritedApprovalDoesNotSupplyDetailsForLocalRequestWithSameID() throws {
  var thread = ThreadState(id: "t")
  let value: JSON = .object([
    "kind": .string("snapshot"), "snapshotSequence": .number(5),
    "projection": .object([
      "thread": .object(["id": .string("t")]), "runtimeRequests": .array([request()]),
      "visibleTurnItems": .array([
        .object([
          "item": requestItem(), "position": .number(0), "sourceThreadId": .string("parent"),
          "visibility": .string("inherited"),
        ])
      ]),
    ]),
  ])
  _ = try thread.apply(value)
  #expect(thread.pendingRequests[0].detail == "Command approval")
}

@Test func reconnectReplacesPendingRequestsAndBoundedRowsDoNotHideThem() throws {
  var thread = ThreadState(id: "t")
  _ = try thread.apply(snapshot(requests: [request()], items: [requestItem()]))
  _ = try thread.apply(snapshot(requests: []))
  #expect(thread.pendingRequests.isEmpty)
  _ = try thread.apply(snapshot(requests: [request("expired")], items: [requestItem()]))
  #expect(thread.pendingRequests.isEmpty)
}

@Test func answerValuesRemainExactAndInvalidSelectionsCannotBeSubmitted() throws {
  let question = try decode(
    """
    {"id":"q","multiSelect":true,"options":[{"value":"  A ","label":"First"},{"value":"","label":"Empty"}]}
    """)
  var draft = QuestionDraft()
  draft.selected = ["  A ", "  A ", "missing", ""]
  #expect(draft.answer(for: question) == .array([.string("  A "), .string("")]))
  draft.custom = " custom answer \n"
  #expect(draft.answer(for: question) == .string("custom answer"))
  let restricted = try decode("{\"id\":\"q\",\"allowCustomAnswer\":false,\"options\":[]}")
  #expect(draft.answer(for: restricted) == nil)
  let pending = try PendingRequest(
    request: request(kind: "user_input"), item: requestItem("user_input_request"))
  #expect(pending.answers(from: [:]) == nil)
  #expect(pending.answers(from: ["q": draft]) == .object(["q": .string("custom answer")]))
}

@Test func modelChangeOnlyPreservesOptionsSupportedByTheNewModel() throws {
  let model = try ProviderModel(
    decode(
      """
      {"slug":"new","name":"New","capabilities":{"optionDescriptors":[
        {"id":"effort","type":"select","options":[{"id":"high","label":"High","isDefault":true}]},
        {"id":"fast","type":"boolean"}
      ]}}
      """))
  let old = try decode(
    """
    {"options":[{"id":"effort","value":"ultra"},{"id":"fast","value":true},{"id":"unsupported","value":"yes"}]}
    """)
  let selection = model.selection(instanceID: "custom-instance", preserving: old)
  #expect(selection["instanceId"].string == "custom-instance")
  #expect(
    selection["options"].array == [
      .object(["id": .string("effort"), "value": .string("high")]),
      .object(["id": .string("fast"), "value": .bool(true)]),
    ])
}

@Test func catalogTracksProviderInstancesAndPlanSettingIndependently() throws {
  let provider = try decode(
    """
    {"instanceId":"custom","displayName":"Work account","enabled":true,"installed":true,"models":[
      {"slug":"model","capabilities":{"optionDescriptors":[
        {"id":"agent","type":"select","options":[{"id":"build"},{"id":"plan"}]}
      ]}}
    ]}
    """)
  var catalog = ProviderCatalog()
  try catalog.apply(
    .object(["type": .string("snapshot"), "config": .object(["providers": .array([provider])])]))
  let selection: JSON = .object(["instanceId": .string("custom"), "model": .string("model")])
  #expect(catalog.provider(for: selection)?.available == true)
  #expect(catalog.descriptors(for: selection)[0]["options"].array.count == 1)
  let normalized = catalog.model(for: selection)?.selection(
    instanceID: "custom",
    preserving: .object([
      "options": .array([.object(["id": .string("agent"), "value": .string("plan")])])
    ]), planModeEnabled: false)
  #expect(
    normalized?["options"].array == [.object(["id": .string("agent"), "value": .string("build")])])
  catalog.setPlanModeEnabled(true)
  try catalog.apply(
    .object([
      "type": .string("settingsUpdated"),
      "payload": .object([
        "settings": .object([
          "defaultRuntimeMode": .string("full-access"),
          "projectSettingsOverrides": .object([
            "restricted": .object(["defaultRuntimeMode": .string("approval-required")])
          ]),
        ])
      ]),
    ]))
  #expect(catalog.planModeEnabled)
  #expect(catalog.defaultRuntimeMode(projectID: "restricted") == "approval-required")
  #expect(catalog.defaultRuntimeMode(projectID: "other") == "full-access")
  #expect(catalog.descriptors(for: selection)[0]["options"].array.count == 2)
  #expect(catalog.providers.count == 1)
  try catalog.apply(
    .object(["type": .string("providerStatuses"), "payload": .object(["providers": .array([])])]))
  #expect(catalog.providers.isEmpty)
}
