import Combine
import Foundation
import T3Core

struct BrowserProfile: Codable, Equatable, Identifiable {
  let id: String
  var name: String
  var builtIn: Bool { id == "default" || id == "incognito" }
}

struct BrowserPreferenceValues: Codable, Equatable {
  var profiles: [BrowserProfile] = []
  var defaultProfileID = "default"
  var viewport = BrowserViewport.fill.json
  var zoom = 1.0
  var appearance = "system"
  var externalLinks = false
  var showAgentPreview = true

  var availableProfiles: [BrowserProfile] {
    [
      BrowserProfile(id: "default", name: "Default"),
      BrowserProfile(id: "incognito", name: "Incognito"),
    ] + profiles
  }
  var defaultViewport: BrowserViewport { (try? BrowserViewport(viewport)) ?? .fill }
  func validated() throws -> Self {
    var result = self
    guard zoom.isFinite, (0.25...5).contains(zoom),
      ["system", "light", "dark"].contains(appearance)
    else {
      throw T3Error("Choose a zoom from 25% to 500% and a supported appearance.")
    }
    guard ["fill", "freeform", "preset"].contains(viewport["_tag"].string ?? "") else {
      throw T3Error("Choose a supported browser viewport.")
    }
    result.viewport = try BrowserViewport(viewport).json
    var seen: Set<String> = ["default", "incognito"]
    result.profiles = try profiles.filter { seen.insert($0.id).inserted }.map {
      guard !$0.id.isEmpty, $0.id.utf16.count <= 64,
        $0.id.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
      else {
        throw T3Error("Invalid browser profile identity.")
      }
      return BrowserProfile(id: $0.id, name: try Self.name($0.name))
    }
    guard result.profiles.count <= 24 else {
      throw T3Error("You can create up to 24 browser profiles.")
    }
    if defaultProfileID != "default"
      && !result.profiles.contains(where: { $0.id == defaultProfileID })
    {
      result.defaultProfileID = "default"
    }
    return result
  }
  static func name(_ value: String) throws -> String {
    let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value.utf16.count <= 48 else {
      throw T3Error("Use a profile name from 1 to 48 characters.")
    }
    return value
  }
}

@MainActor final class BrowserPreferences: ObservableObject {
  @Published private(set) var values = BrowserPreferenceValues()
  @Published var error: String?
  var onChange: (() -> Void)?
  let file: URL
  init(file: URL? = nil) {
    self.file =
      file
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("T3Native/browser-preferences.json")
    if FileManager.default.fileExists(atPath: self.file.path) {
      do {
        values = try JSONDecoder().decode(
          BrowserPreferenceValues.self, from: Data(contentsOf: self.file)
        ).validated()
      } catch {
        self.error = "Browser preferences could not be read: " + error.localizedDescription
      }
    }
  }
  func update(_ change: (inout BrowserPreferenceValues) throws -> Void) throws {
    var next = values
    try change(&next)
    next = try next.validated()
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try JSONEncoder().encode(next).write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    values = next
    error = nil
    onChange?()
  }
  @discardableResult func create(_ name: String) throws -> BrowserProfile {
    let profile = BrowserProfile(
      id: "profile-" + UUID().uuidString, name: try BrowserPreferenceValues.name(name))
    try update { $0.profiles.append(profile) }
    return profile
  }
  func rename(_ id: String, to name: String) throws {
    let name = try BrowserPreferenceValues.name(name)
    try update { values in
      guard let index = values.profiles.firstIndex(where: { $0.id == id }) else {
        throw T3Error("That profile cannot be renamed.")
      }
      values.profiles[index].name = name
    }
  }
  func remove(_ id: String) throws {
    try update { $0.profiles.removeAll { $0.id == id } }
  }
  func name(_ id: String?) -> String {
    values.availableProfiles.first { $0.id == (id ?? "default") }?.name ?? "Removed profile"
  }
}
