import Combine
import Foundation
import Testing

@testable import T3Native

@MainActor @Test func nativePreferencesRoundTripAndObserveAfterDurableSave() throws {
  let directory = URL(fileURLWithPath: "/tmp/t3-native-evidence/preferences-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let file = directory.appendingPathComponent("preferences.json")
  let preferences = NativePreferences(file: file)
  var observed: [NativePreferenceValues] = []
  var persistedDuringObservation = false
  let token = preferences.observeChanges { values in
    observed.append(values)
    persistedDuringObservation =
      (try? Data(contentsOf: file)) != nil && preferences.values == values
  }
  try preferences.update {
    $0.appearance.appearance = .dark
    $0.appearance.interfaceFont = " Helvetica "
    $0.appearance.interfaceFontSize = 18
    $0.appearance.codeFont = "Menlo"
    $0.appearance.codeFontSize = 15
    $0.appearance.chatWidth = .wide
    $0.appearance.wordWrap = false
    $0.notifications.mode = .notificationsAndSound
    $0.notifications.failure = false
    $0.notifications.whileAppActive = true
  }
  let restored = NativePreferences(file: file)
  #expect(restored.values == preferences.values)
  #expect(restored.appearance.interfaceFont == "Helvetica")
  #expect(restored.appearance.resolvedInterfaceFont.pointSize == 18)
  #expect(restored.appearance.resolvedCodeFont.pointSize == 15)
  #expect(restored.appearance.chatWidth.maximumWidth == 1200)
  #expect(persistedDuringObservation)
  #expect(observed == [preferences.values])
  try preferences.update { $0.appearance.interfaceFontSize = 18 }
  #expect(observed.count == 1)
  withExtendedLifetime(token) {}
}

@Test func nativePreferencesDecodeOlderPartialFilesAndDefaults() throws {
  let defaults = try JSONDecoder().decode(NativePreferenceValues.self, from: Data("{}".utf8))
  #expect(defaults == NativePreferenceValues())
  #expect(defaults.appearance.appearance == .system)
  #expect(defaults.appearance.interfaceFontSize == 16)
  #expect(defaults.appearance.codeFontSize == 13)
  #expect(defaults.appearance.wordWrap)
  #expect(defaults.notifications.mode == .off)
  let partial = try JSONDecoder().decode(
    NativePreferenceValues.self,
    from: Data(#"{"appearance":{"appearance":"dark"},"notifications":{"mode":"sound"}}"#.utf8))
  #expect(partial.appearance.appearance == .dark)
  #expect(partial.appearance.chatWidth == .comfortable)
  #expect(partial.notifications.completion)
  #expect(partial.notifications.mode.playsSound)
  #expect(!partial.notifications.mode.showsBanner)
}

@MainActor @Test func nativePreferencesFailedWritesAndInvalidValuesKeepSavedState() throws {
  let directory = URL(
    fileURLWithPath: "/tmp/t3-native-evidence/preferences-failure-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let file = directory.appendingPathComponent("preferences.json")
  let preferences = NativePreferences(file: file)
  try preferences.update { $0.appearance.appearance = .light }
  let saved = try Data(contentsOf: file)
  let original = preferences.values
  var emissions = 0
  let token = preferences.observeChanges { _ in emissions += 1 }
  #expect(throws: (any Error).self) { try preferences.update { $0.appearance.codeFontSize = 99 } }
  #expect(try Data(contentsOf: file) == saved)
  #expect(preferences.values == original)
  try FileManager.default.removeItem(at: file)
  try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
  #expect(throws: (any Error).self) { try preferences.update { $0.notifications.mode = .sound } }
  #expect(preferences.values == original)
  #expect(preferences.error != nil)
  #expect(emissions == 0)
  withExtendedLifetime(token) {}
}

@MainActor @Test func nativePreferencesCorruptFileIsPreservedAndFontFallbackIsSafe() throws {
  let directory = URL(
    fileURLWithPath: "/tmp/t3-native-evidence/preferences-corrupt-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let file = directory.appendingPathComponent("preferences.json")
  try Data("broken".utf8).write(to: file)
  let preferences = NativePreferences(file: file)
  #expect(preferences.values == NativePreferenceValues())
  #expect(preferences.error != nil)
  #expect(try String(contentsOf: file, encoding: .utf8) == "broken")
  var appearance = NativeAppearanceValues()
  appearance.interfaceFont = "UnavailableFont-" + UUID().uuidString
  appearance.codeFont = appearance.interfaceFont
  #expect(appearance.resolvedInterfaceFont.pointSize == CGFloat(appearance.interfaceFontSize))
  #expect(appearance.resolvedCodeFont.isFixedPitch)
  #expect(NativeChatWidth.full.maximumWidth == nil)
}
