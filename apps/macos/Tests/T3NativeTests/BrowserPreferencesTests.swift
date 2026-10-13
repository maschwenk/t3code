import Foundation
import T3Core
import Testing

@testable import T3Native

@MainActor @Test func browserPreferencesRestoreProfilesAndDefaults() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let file = directory.appendingPathComponent("preferences.json")
  let preferences = BrowserPreferences(file: file)
  let work = try preferences.create(" Work ")
  let personal = try preferences.create("Personal")
  try preferences.update {
    $0.defaultProfileID = work.id
    $0.viewport = BrowserDevicePreset.all[0].viewport.json
    $0.zoom = 1.5
    $0.appearance = "dark"
    $0.externalLinks = true
    $0.showAgentPreview = false
  }
  let restored = BrowserPreferences(file: file)
  #expect(restored.error == nil)
  #expect(restored.values == preferences.values)
  try restored.rename(work.id, to: "Company")
  #expect(restored.values.defaultProfileID == work.id)
  #expect(restored.name(work.id) == "Company")
  try restored.remove(work.id)
  let removed = BrowserPreferences(file: file)
  #expect(removed.values.defaultProfileID == "default")
  #expect(removed.values.profiles == [personal])
  #expect(removed.values.zoom == 1.5)
  #expect(removed.values.defaultViewport == BrowserDevicePreset.all[0].viewport)
}

@MainActor @Test func browserPreferencesRejectInvalidOrUnwritableUpdates() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let file = directory.appendingPathComponent("preferences.json")
  let preferences = BrowserPreferences(file: file)
  try preferences.create("Keep")
  let saved = try Data(contentsOf: file)
  let previous = preferences.values
  #expect(throws: (any Error).self) { try preferences.update { $0.zoom = .nan } }
  #expect(throws: (any Error).self) { try preferences.update { $0.viewport = .null } }
  #expect(throws: (any Error).self) { try preferences.rename("default", to: "Wrong") }
  #expect(try Data(contentsOf: file) == saved)
  #expect(preferences.values == previous)
  try FileManager.default.removeItem(at: file)
  try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
  #expect(throws: (any Error).self) { try preferences.create("Must not appear") }
  #expect(preferences.values == previous)
}

@MainActor @Test func browserPreferencesNormalizeStaleProfilesWithoutShadowingBuiltIns() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let file = directory.appendingPathComponent("preferences.json")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  var saved = BrowserPreferenceValues()
  saved.profiles = [
    .init(id: "default", name: "Wrong"), .init(id: "work", name: "Work"),
    .init(id: "work", name: "Duplicate"),
  ]
  saved.defaultProfileID = "removed"
  try JSONEncoder().encode(saved).write(to: file)
  let preferences = BrowserPreferences(file: file)
  #expect(preferences.values.defaultProfileID == "default")
  #expect(preferences.name("default") == "Default")
  #expect(preferences.values.profiles == [.init(id: "work", name: "Work")])
  try Data("broken".utf8).write(to: file)
  let broken = BrowserPreferences(file: file)
  #expect(broken.error != nil)
  #expect(broken.values == BrowserPreferenceValues())
  #expect(try String(contentsOf: file, encoding: .utf8) == "broken")
}
