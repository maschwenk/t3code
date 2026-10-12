import Foundation
import Testing

@testable import T3Core

@Suite struct ProviderManagementContractTests {
  private func json(_ text: String) throws -> JSON { try JSON.decode(Data(text.utf8)) }

  @Test func atomicAccountEditPreservesOpaqueConfigurationAndEnvironment() throws {
    let settings = try json(
      """
      {"providerInstances":{"claude_work":{"driver":"claudeAgent","displayName":"Work","enabled":true,
      "accentColor":"#fa853d","environment":[{"name":"ORG_SETTING","value":"configured","sensitive":false}],
      "config":{"homePath":"/server/work","binaryPath":"claude","autoCompactWindow":"300000",
      "customModels":[{"slug":"claude-custom","name":"Custom","capabilities":{"optionDescriptors":[{"id":"effort","type":"select","options":[{"id":"high","name":"High"}]}]}}]}}}}
      """)
    let snapshot = try json(
      """
      {"instanceId":"claude_work","driver":"claudeAgent","displayName":"Work","status":"ready",
       "auth":{"status":"authenticated","email":"work@example.invalid"},"models":[]}
      """)
    let provider = try ManagedProvider(snapshot: snapshot, settings: settings)
    var draft = ProviderInstanceDraft(provider: provider)
    draft.homePath = "/server/renamed"
    draft.launchArgs = "--chrome --verbose"
    let wire = try JSON.decode(draft.mutation(create: false).data())
    let mutation = wire["providerInstanceMutation"]
    #expect(wire["patch"] == .object([:]))
    #expect(mutation["operation"] == .string("upsert"))
    #expect(mutation["instanceId"] == .string("claude_work"))
    #expect(mutation["instance"]["config"]["homePath"] == .string("/server/renamed"))
    #expect(mutation["instance"]["config"]["autoCompactWindow"] == .string("300000"))
    #expect(
      mutation["instance"]["config"]["customModels"]
        == settings["providerInstances"]["claude_work"]["config"]["customModels"])
    #expect(
      mutation["instance"]["environment"]
        == settings["providerInstances"]["claude_work"]["environment"])
    #expect(mutation["instance"]["accentColor"] == .string("#fa853d"))
    #expect(provider.signedIn)
  }

  @Test func legacyAccountUsesDriverConfigWhileNewInstancesUseAtomicCreate() throws {
    let settings = try json(
      """
      {"providers":{"codex":{"binaryPath":"/server/bin/codex","homePath":"/server/codex","shadowHomePath":"/server/auth","launchArgs":"--config x=y","customModels":[]}}}
      """)
    let provider = try ManagedProvider(
      snapshot: json(
        """
        {"instanceId":"codex","driver":"codex","displayName":"Codex","auth":{"status":"unauthenticated"},"models":[]}
        """), settings: settings)
    #expect(!provider.explicit)
    let old = try ProviderInstanceDraft(provider: provider).mutation(create: false)
    #expect(
      old["providerInstanceMutation"]["instance"]["config"]["shadowHomePath"]
        == .string("/server/auth"))
    var new = ProviderInstanceDraft()
    new.id = "codex_personal"
    new.displayName = "Personal"
    #expect(
      try new.mutation(create: true)["providerInstanceMutation"]["operation"] == .string("create"))
    new.id = "1invalid"
    #expect(throws: T3Error.self) { try new.mutation(create: true) }
    new.id = "personal"
    new.customModels = [.string("duplicate"), .object(["slug": .string("duplicate")])]
    #expect(throws: T3Error.self) { try new.mutation(create: true) }
  }

  @Test func loginUsesServerFlowAndInteractionIDsAndRejectsStaleStates() throws {
    let state = try ProviderLoginState(
      json(
        """
        {"instanceId":"codex_work","phase":"waiting","flowId":"flow-17","authorizationUrl":null,
         "interaction":{"type":"browser","id":"browser-3","url":"https://accounts.example.invalid/login","requiresConsent":true},"methods":[]}
        """))
    let payload = try state.response(
      .object(["type": .string("browser"), "action": .string("accept")]))
    #expect(payload["flowId"] == .string("flow-17"))
    #expect(payload["interactionId"] == .string("browser-3"))
    #expect(payload["instanceId"] == .string("codex_work"))
    #expect(state.url?.scheme == "https")
    let finished = try ProviderLoginState(
      json(
        """
        {"instanceId":"codex_work","phase":"succeeded","flowId":null,"interaction":null,"authorizationUrl":"javascript:alert(1)"}
        """))
    #expect(finished.url == nil)
    #expect(throws: T3Error.self) { try finished.response(.object([:])) }
  }

  @Test func preferenceStorageIsEndpointAndAccountScopedAndMaintainsCustomModels() throws {
    let name = "t3-provider-contract-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    var preferences = ModelPickerPreferences()
    preferences.favorites = [ModelIdentity(instanceID: "work", modelID: "b")]
    preferences.hidden = [
      ModelIdentity(instanceID: "work", modelID: "a"),
      ModelIdentity(instanceID: "work", modelID: "custom"),
    ]
    preferences.order = ["work": ["custom", "b", "a"]]
    try preferences.save(environment: "https://one.invalid", defaults: defaults)
    #expect(
      ModelPickerPreferences(environment: "https://one.invalid", defaults: defaults) == preferences)
    #expect(
      ModelPickerPreferences(environment: "https://two.invalid", defaults: defaults).favorites
        .isEmpty)
    let models = try json(
      """
      [{"slug":"a","name":"A"},{"slug":"b","name":"B"},{"slug":"custom","name":"Custom","isCustom":true}]
      """
    ).array.map(ProviderModel.init)
    #expect(preferences.models(models, instanceID: "work").map(\.id) == ["b", "custom"])
    #expect(preferences.models(models, instanceID: "personal").map(\.id) == ["a", "b", "custom"])
  }

  @Test func interruptedAccountDraftRecoversItsIDAndRebasesOntoLatestConfig() throws {
    let provider = try ManagedProvider(
      snapshot: json(
        """
        {"instanceId":"codex_work","driver":"codex","displayName":"Work","auth":{"status":"authenticated"},"models":[]}
        """),
      settings: json(
        """
        {"providerInstances":{"codex_work":{"driver":"codex","displayName":"Work","config":{"homePath":"/work","otherOption":"old"}}}}
        """))
    var value = ProviderInstanceDraft(provider: provider)
    value.homePath = "/new-home"
    let recovered = try JSONDecoder().decode(
      ProviderInstanceDraft.self, from: JSONEncoder().encode(value))
    #expect(recovered.id == "codex_work")
    let latest = try json(
      """
      {"driver":"codex","displayName":"Work","accentColor":"#123456",
       "environment":[{"name":"API_TOKEN","value":"","sensitive":true,"valueRedacted":true}],
       "config":{"homePath":"/work","otherOption":"changed-on-other-client","futureOption":true}}
      """)
    let next = try recovered.mutation(create: false, mergingLatest: latest)[
      "providerInstanceMutation"]["instance"]
    #expect(next["config"]["homePath"] == .string("/new-home"))
    #expect(next["config"]["otherOption"] == .string("changed-on-other-client"))
    #expect(next["config"]["futureOption"] == .bool(true))
    #expect(next["environment"] == latest["environment"])
    #expect(next["accentColor"] == .string("#123456"))
  }
}
