import Foundation
import Testing

@testable import T3Core

private func searchCatalog() throws -> ProviderCatalog {
  var catalog = ProviderCatalog()
  try catalog.apply(
    JSON.decode(
      Data(
        """
        {"type":"snapshot","config":{"providers":[
          {"instanceId":"personal","driver":"codex","displayName":"Codex Personal","enabled":true,"installed":true,"models":[
            {"slug":"gpt-new","name":"GPT New","shortName":"New","isCustom":false},
            {"slug":"gpt-old","name":"GPT Old","isLegacy":true,"isCustom":false}]},
          {"instanceId":"work","driver":"codex","displayName":"Codex Work","enabled":true,"installed":true,"models":[
            {"slug":"gpt-new","name":"GPT New","isCustom":false}]},
          {"instanceId":"proxy","driver":"opencode","displayName":"OpenCode","enabled":true,"installed":true,"models":[
            {"slug":"claude-opus","name":"Claude Opus 4.7","subProvider":"GitHub Copilot","isCustom":true}]},
          {"instanceId":"unavailable","driver":"cursor","displayName":"Cursor Offline","enabled":false,"installed":false,"models":[
            {"slug":"opus","name":"Opus 4.7","isCustom":false}]}]}}
        """.utf8)))
  return catalog
}

@Test func modelSearchMatchesTokensAcrossAccountDriverAndModelFields() throws {
  let search = ModelSearch(catalog: try searchCatalog())
  let matches = search.results(query: "  PERSONAL  new ", instanceID: "work")
  #expect(matches.map(\.id) == [ModelIdentity(instanceID: "personal", modelID: "gpt-new")])
  #expect(
    search.results(query: "coplt op", instanceID: "personal").map(\.model.id) == ["claude-opus"])
  #expect(search.results(query: "personal opus", instanceID: nil).isEmpty)
  #expect(search.results(query: "missing", instanceID: nil).isEmpty)
  #expect(
    search.results(query: "gpt", instanceID: nil).map(\.id) == [
      ModelIdentity(instanceID: "work", modelID: "gpt-new"),
      ModelIdentity(instanceID: "personal", modelID: "gpt-new"),
      ModelIdentity(instanceID: "personal", modelID: "gpt-old"),
      ModelIdentity(instanceID: "proxy", modelID: "claude-opus"),
    ])
}

@Test func modelFavoritesStayAccountScopedAndSearchCanLeaveFavorites() throws {
  let search = ModelSearch(catalog: try searchCatalog())
  let favorite = ModelIdentity(instanceID: "work", modelID: "gpt-new")
  let favorites: Set<ModelIdentity> = [favorite]
  #expect(
    search.results(query: "", instanceID: nil, favoritesOnly: true, favorites: favorites).map(\.id)
      == [favorite])
  let other = search.results(
    query: "personal", instanceID: nil, favoritesOnly: true, favorites: favorites)
  #expect(other.count == 2)
  #expect(other.allSatisfy { $0.provider.id == "personal" })
  #expect(search.results(query: "new", instanceID: nil, favorites: favorites).first?.id == favorite)
}

@Test func favoritesBoostDoesNotOutrankAnExactModelName() throws {
  let search = ModelSearch(catalog: try searchCatalog())
  let favorite = ModelIdentity(instanceID: "proxy", modelID: "claude-opus")
  let exact = search.results(query: "opus 4.7", instanceID: nil, favorites: [favorite])
  #expect(exact.first?.provider.id == "unavailable")
  #expect(exact.first?.provider.available == false)
  #expect(
    search.results(query: "opu", instanceID: nil, favorites: [favorite]).first?.id == favorite)
}

@Test func browsingRetainsServerOrderAndKeepsLegacyAndCustomModelsDiscoverable() throws {
  let catalog = try searchCatalog()
  let search = ModelSearch(catalog: catalog)
  #expect(
    search.results(query: "", instanceID: "personal").map(\.model.id) == ["gpt-new", "gpt-old"])
  #expect(search.results(query: "old", instanceID: "work").first?.model.legacy == true)
  #expect(search.results(query: "copilot", instanceID: nil).first?.model.custom == true)
  #expect(search.results(query: "", instanceID: "gone").isEmpty)
  var removed = ProviderCatalog()
  try removed.apply(
    .object(["type": .string("providerStatuses"), "payload": .object(["providers": .array([])])]))
  #expect(ModelSearch(catalog: removed).results(query: "new", instanceID: nil).isEmpty)
}
