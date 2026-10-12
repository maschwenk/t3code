import Foundation
import Testing

@testable import T3Core

@Suite struct WorkspaceDefaultsContractTests {
  private func json(_ contents: String) throws -> JSON {
    try JSON.decode(Data(contents.utf8))
  }

  @Test func projectOverridesBeatLegacyAndEnvironmentAndDoNotLeakBetweenProjects() throws {
    let settings = try json(
      """
      {"defaultThreadEnvMode":"worktree","projectSettingsFolded":false,
       "projectSettingsOverrides":{"project-a":{"defaultThreadEnvMode":"local"}}}
      """)
    #expect(
      WorkspaceDefaults.configuredMode(
        settings: settings,
        project: try json(#"{"id":"project-a","defaultThreadEnvMode":"worktree"}"#)) == "local")
    #expect(
      WorkspaceDefaults.configuredMode(
        settings: settings, project: try json(#"{"id":"project-b"}"#)) == "worktree")
  }

  @Test func explicitNullOverrideMasksEnvironmentAndLegacyAndDefersToRepository() throws {
    let settings = try json(
      """
      {"defaultThreadEnvMode":"local","projectSettingsFolded":false,
       "projectSettingsOverrides":{"project-a":{"defaultThreadEnvMode":null}}}
      """)
    let project = try json(#"{"id":"project-a","defaultThreadEnvMode":"local"}"#)
    let configured = WorkspaceDefaults.configuredMode(settings: settings, project: project)
    #expect(configured == nil)
    #expect(
      configured
        ?? WorkspaceDefaults.fileMode(contents: #"{"defaultThreadEnvMode":"worktree"}"#)
        ?? "local" == "worktree")
    #expect(configured ?? WorkspaceDefaults.fileMode(contents: "{invalid") ?? "local" == "local")
  }

  @Test func foldingDisablesStaleAggregateValuesButKeepsExplicitOverrides() throws {
    let project = try json(#"{"id":"project-a","defaultThreadEnvMode":"worktree"}"#)
    var settings = try json(#"{"defaultThreadEnvMode":"local","projectSettingsFolded":false}"#)
    #expect(WorkspaceDefaults.configuredMode(settings: settings, project: project) == "worktree")
    settings = try json(#"{"defaultThreadEnvMode":"local","projectSettingsFolded":true}"#)
    #expect(WorkspaceDefaults.configuredMode(settings: settings, project: project) == "local")
    settings = try json(
      """
      {"defaultThreadEnvMode":null,"projectSettingsFolded":true,
       "projectSettingsOverrides":{"project-a":{"defaultThreadEnvMode":"local"}}}
      """)
    #expect(WorkspaceDefaults.configuredMode(settings: settings, project: project) == "local")
    #expect(
      WorkspaceDefaults.configuredMode(
        settings: try json(#"{"defaultThreadEnvMode":null,"projectSettingsFolded":true}"#),
        project: project) == nil)
  }

  @Test func absentOverrideKeyAndNullLegacyStillUseTheEnvironmentWithoutReadingAFile() throws {
    let settings = try json(
      """
      {"defaultThreadEnvMode":"local","projectSettingsFolded":false,
       "projectSettingsOverrides":{"project-a":{"defaultRuntimeMode":"full-access"}}}
      """)
    #expect(
      WorkspaceDefaults.configuredMode(
        settings: settings,
        project: try json(#"{"id":"project-a","defaultThreadEnvMode":null}"#)) == "local")
    #expect(
      WorkspaceDefaults.configuredMode(
        settings: .object([:]), project: try json(#"{"id":"project-a"}"#)) == nil)
  }

  @Test func repositoryJSONCPreservesStringsAndAcceptsNestedTrailingCommas() {
    let contents = #"""
      {
        /* Repository choice; // inside the block is ordinary comment text. */
        "defaultThreadEnvMode": "worktree", // trailing comment
        "iconPath": "assets/logo.svg",
        "worktreeSubmodules": "top-level",
        "scripts": [
          {
            "name": "Run // local /* preview */ ,] ,}",
            "command": "printf \"// /* literal */ ,] ,}\"; echo C:\\tools\\",
            "previewUrl": "http://localhost:3000/a,]//path",
            "async": false,
          },
        ],
        "unknownFutureField": {"nested": [1, 2, /* before close */],},
      } // end of file
      """#
    #expect(WorkspaceDefaults.fileMode(contents: contents) == "worktree")
    #expect(
      WorkspaceDefaults.fileMode(
        contents: #"{"note":"a,] // worktree","defaultThreadEnvMode":"local",}"#)
        == "local")
  }

  @Test(arguments: [
    "", "null", "[]", "{ not json", #"{"defaultThreadEnvMode":"worktree""#,
    #"{"defaultThreadEnvMode":"worktree"} /* unterminated"#,
    #"{"defaultThreadEnvMode":"worktree",,}"#,
    #"{"defaultThreadEnvMode":"worktree","extra":[1,,]}"#,
    #"{"defaultThreadEnvMode":"worktree","extra":[,]}"#,
    #"{"defaultThreadEnvMode":"worktree","extra":tru/* split token */e}"#,
    #"{"defaultThreadEnvMode":" worktree "}"#,
    #"{"defaultThreadEnvMode":"spaceship"}"#,
    #"{"defaultThreadEnvMode":null}"#,
    #"{"defaultThreadEnvMode":true}"#,
  ])
  func malformedOrIncompleteRepositoryFilesDeferToLocal(contents: String) {
    #expect(WorkspaceDefaults.fileMode(contents: contents) == nil)
    #expect(WorkspaceDefaults.fileMode(contents: contents) ?? "local" == "local")
  }

  @Test(arguments: [
    #""scripts":[{"name":"Dev"}]"#,
    #""scripts":[{"name":" ","command":"pnpm dev"}]"#,
    #""scripts":[{"name":"Dev","command":"pnpm dev","icon":"unknown"}]"#,
    #""scripts":[{"name":"Dev","command":"pnpm dev","async":null}]"#,
    #""scripts":[{"name":"Dev","command":"pnpm dev","previewUrl":" "}]"#,
    #""scripts":null"#,
    #""iconPath":" ""#,
    #""$schema":3"#,
    #""worktreeSubmodules":"invalid""#,
  ])
  func invalidKnownProjectFileFieldsRejectTheWholeFile(field: String) {
    #expect(
      WorkspaceDefaults.fileMode(contents: "{\"defaultThreadEnvMode\":\"worktree\",\(field)}")
        == nil)
  }

  @Test func projectFileLimitsMatchTheSharedDecoder() {
    let script = #"{"name":"Dev","command":"pnpm dev"}"#
    let atLimit = Array(repeating: script, count: 50).joined(separator: ",")
    let overLimit = atLimit + "," + script
    #expect(
      WorkspaceDefaults.fileMode(
        contents: "{\"defaultThreadEnvMode\":\"worktree\",\"scripts\":[\(atLimit)]}") == "worktree")
    #expect(
      WorkspaceDefaults.fileMode(
        contents: "{\"defaultThreadEnvMode\":\"worktree\",\"scripts\":[\(overLimit)]}") == nil)
    let icon = String(repeating: "a", count: 513)
    #expect(
      WorkspaceDefaults.fileMode(
        contents: "{\"defaultThreadEnvMode\":\"worktree\",\"iconPath\":\"\(icon)\"}") == nil)
    #expect(WorkspaceDefaults.fileMode(contents: #"{"scripts":[]}"#) == nil)
  }

  @Test func repeatedRepositoryKeysUseTheLastValueAsJSONParseDoes() {
    #expect(
      WorkspaceDefaults.fileMode(
        contents: #"{"defaultThreadEnvMode":"local","defaultThreadEnvMode":"worktree"}"#)
        == "worktree")
    #expect(
      WorkspaceDefaults.fileMode(
        contents: #"{"defaultThreadEnvMode":"worktree","defaultThreadEnvMode":null}"#) == nil)
  }

  @Test func repositoryFilesAreBoundedBeforeParsing() {
    let document = #"{"defaultThreadEnvMode":"worktree","note":"é"}"#
    let atLimit = document + String(repeating: " ", count: 1_048_576 - document.utf8.count)
    #expect(WorkspaceDefaults.fileMode(contents: atLimit) == "worktree")
    #expect(WorkspaceDefaults.fileMode(contents: atLimit + " ") == nil)
    let nested =
      #"{"defaultThreadEnvMode":"worktree","extra":"#
      + String(repeating: "[", count: 32) + "0" + String(repeating: "]", count: 32) + "}"
    #expect(WorkspaceDefaults.fileMode(contents: nested) == "worktree")
    let tooDeep =
      #"{"defaultThreadEnvMode":"worktree","extra":"#
      + String(repeating: "[", count: 65) + "0" + String(repeating: "]", count: 65) + "}"
    #expect(WorkspaceDefaults.fileMode(contents: tooDeep) == nil)
  }
}
