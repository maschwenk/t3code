import Foundation
import T3Core
import Testing

@testable import T3Native

@Test func nativeSettingsPatchesUseGlobalServerContractWithoutProjectOverrides() throws {
  let cases: [(NativeServerSettingsPatch, String, JSON)] = [
    (.workspace("worktree"), "defaultThreadEnvMode", .string("worktree")),
    (.workspace(nil), "defaultThreadEnvMode", .null),
    (.permission("full-access"), "defaultRuntimeMode", .string("full-access")),
    (.restartContinuation(true), "continueThreadsAfterServerUpdate", .bool(true)),
    (.usageLimitContinuation(true), "autoResumeLimitedThreads", .bool(true)),
    (.settleOnMerge(false), "sidebarAutoSettleOnMerge", .bool(false)),
    (.settleAfterDays(90), "sidebarAutoSettleAfterDays", .number(90)),
    (.settleAfterDays(nil), "sidebarAutoSettleAfterDays", .null),
    (.worktreesDirectory(" /tmp/worktrees "), "worktreesDirectory", .string("/tmp/worktrees")),
    (.model(.null), "defaultModelSelection", .null),
  ]
  for (patch, key, value) in cases {
    let request = RPCConnection.request(
      id: "settings", method: "server.updateSettings", payload: try patch.payload())
    let decoded = try JSON.decode(request.data())
    #expect(decoded["tag"] == .string("server.updateSettings"))
    #expect(decoded["payload"] == .object(["patch": .object([key: value])]))
  }
}

@Test func nativeSettingsReasoningPatchRetainsProviderModelAndOtherOptions() throws {
  let selection: JSON = .object([
    "instanceId": .string("custom-codex"), "model": .string("a-real-catalog-choice"),
    "options": .array([
      .object(["id": .string("reasoningEffort"), "value": .string("medium")]),
      .object(["id": .string("serviceTier"), "value": .string("fast")]),
    ]),
  ])
  let payload = try NativeServerSettingsPatch.modelOption(
    selection: selection, id: "reasoningEffort", value: .string("high")
  ).payload()
  let changed = payload["patch"]["defaultModelSelection"]
  #expect(changed["instanceId"] == selection["instanceId"])
  #expect(changed["model"] == selection["model"])
  #expect(
    changed["options"].array.contains(
      .object(["id": .string("serviceTier"), "value": .string("fast")])))
  #expect(
    changed["options"].array.filter { $0["id"].string == "reasoningEffort" } == [
      .object(["id": .string("reasoningEffort"), "value": .string("high")])
    ])
  let reset = try NativeServerSettingsPatch.modelOption(
    selection: changed, id: "reasoningEffort", value: .null
  ).payload()
  #expect(
    reset["patch"]["defaultModelSelection"]["options"].array == [selection["options"].array[1]])
}

@Test func nativeSettingsRejectOutOfRangeSettlingAndUnsupportedWorkspaceBeforeRPC() {
  #expect(throws: (any Error).self) { try NativeServerSettingsPatch.settleAfterDays(0).payload() }
  #expect(throws: (any Error).self) { try NativeServerSettingsPatch.settleAfterDays(91).payload() }
  #expect(throws: (any Error).self) {
    try NativeServerSettingsPatch.workspace("container").payload()
  }
  #expect(throws: (any Error).self) {
    try NativeServerSettingsPatch.permission("invalid").payload()
  }
}

@Test func nativeSettingsResponseGateRejectsSameEndpointReconnectAndOlderWindowRequest() throws {
  let endpoint = URL(string: "http://127.0.0.1:9100")!
  let settings = try ConnectionSettings(endpoint: endpoint, token: "test")
  let issued = RPCConnection(settings: settings)
  let replacement = RPCConnection(settings: settings)
  let revision = UUID()
  let gate = NativeSettingsResponseGate(connection: issued, endpoint: endpoint, revision: revision)
  #expect(gate.accepts(connection: issued, endpoint: endpoint, revision: revision))
  #expect(!gate.accepts(connection: replacement, endpoint: endpoint, revision: revision))
  #expect(!gate.accepts(connection: nil, endpoint: endpoint, revision: revision))
  #expect(
    !gate.accepts(
      connection: issued, endpoint: URL(string: "http://127.0.0.1:9200")!, revision: revision))
  #expect(!gate.accepts(connection: issued, endpoint: endpoint, revision: UUID()))
}
