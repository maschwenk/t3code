import Foundation
import Testing

@testable import T3Core

private let project: JSON = .object(["id": .string("project")])
private func selection(_ instance: String, model: String = "current") -> JSON {
  .object(["instanceId": .string(instance), "model": .string(model)])
}
private func catalog(_ settings: [String: JSON] = [:]) throws -> ProviderCatalog {
  var value = ProviderCatalog()
  try value.apply(
    .object([
      "type": .string("snapshot"),
      "config": .object([
        "settings": .object(settings),
        "providers": .array(
          ["one", "two", "disabled"].map { id in
            .object([
              "instanceId": .string(id), "enabled": .bool(id != "disabled"),
              "installed": .bool(true),
              "models": .array([
                .object(["slug": .string("old"), "isLegacy": .bool(true)]),
                .object(["slug": .string("current")]),
              ]),
            ])
          }),
      ]),
    ]))
  return value
}
private func template() throws -> ThreadSummary {
  try ThreadSummary(
    .object([
      "id": .string("original"), "projectId": .string("other-project"),
      "title": .string("Existing"),
      "modelSelection": selection("two"), "runtimeMode": .string("full-access"),
      "branch": .string("worktree-branch"), "worktreePath": .string("/old-worktree"),
    ]))
}

@Test func newThreadCanStartWithoutATemplateAndResetsWorkspaceAndPermissions() throws {
  let catalog = try catalog()
  let config = try catalog.newThreadConfiguration(project: project, carrying: nil)
  #expect(config.model["instanceId"].string == "one")
  #expect(config.model["model"].string == "current")
  let carried = try catalog.newThreadConfiguration(project: project, carrying: template())
  #expect(carried.model["instanceId"].string == "two")
  #expect(carried.runtimeMode == "approval-required")
  let command = carried.command(id: "new-thread")
  #expect(command["projectId"].string == "project")
  #expect(command["branch"] == .null)
  #expect(command["worktreePath"] == .null)
}

@Test func projectOverridesWinAndExplicitNullClearsTheEnvironmentModel() throws {
  let settings: [String: JSON] = [
    "defaultModelSelection": selection("one"),
    "projectSettingsOverrides": .object([
      "project": .object([
        "defaultModelSelection": selection("two"), "defaultRuntimeMode": .string("full-access"),
      ])
    ]),
  ]
  let configured = try catalog(settings).newThreadConfiguration(project: project, carrying: nil)
  #expect(configured.model["instanceId"].string == "two")
  #expect(configured.runtimeMode == "full-access")
  var cleared = settings
  cleared["projectSettingsOverrides"] = .object([
    "project": .object(["defaultModelSelection": .null])
  ])
  #expect(
    try catalog(cleared).newThreadConfiguration(project: project, carrying: template()).model[
      "instanceId"
    ].string == "two")
}

@Test func foldedSettingsIgnoreOldProjectDefaultsAndDisabledProvidersFallBack() throws {
  let legacy: JSON = .object(["id": .string("project"), "defaultModelSelection": selection("two")])
  var settings: [String: JSON] = ["defaultModelSelection": selection("one")]
  #expect(
    try catalog(settings).newThreadConfiguration(project: legacy, carrying: nil).model["instanceId"]
      .string == "two")
  settings["projectSettingsFolded"] = .bool(true)
  #expect(
    try catalog(settings).newThreadConfiguration(project: legacy, carrying: nil).model["instanceId"]
      .string == "one")
  settings["projectSettingsOverrides"] = .object([
    "project": .object(["defaultModelSelection": selection("disabled")])
  ])
  #expect(
    try catalog(settings).newThreadConfiguration(project: project, carrying: template()).model[
      "instanceId"
    ].string == "one")
}

@Test func newThreadWithoutAnyAvailableProviderReportsWhyItCannotStart() throws {
  #expect(throws: T3Error.self) {
    try ProviderCatalog().newThreadConfiguration(project: project, carrying: template())
  }
}
