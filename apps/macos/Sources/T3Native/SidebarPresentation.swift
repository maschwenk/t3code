import Foundation
import T3Core

struct SidebarProjectIdentity: Equatable {
  static let colors = [
    "gray", "red", "orange", "amber", "yellow", "lime", "green", "emerald", "teal",
    "cyan", "sky", "blue", "indigo", "violet", "purple", "fuchsia", "pink", "rose",
  ]
  let text: String
  let color: String
  let emoji: Bool

  init(name: String, icon: JSON = .null) {
    if icon["kind"].string == "emoji", let text = icon["emoji"].string {
      self.text = text
      color = "gray"
      emoji = true
      return
    }
    emoji = false
    if icon["kind"].string == "monogram", let text = icon["text"].string {
      self.text = text
      color = icon["color"].string ?? "blue"
      return
    }
    let normalized = name.precomposedStringWithCompatibilityMapping
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let words = normalized.components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
    if let firstWord = words.first {
      let glyphs = Array(firstWord.unicodeScalars)
      let first = glyphs.first.map(String.init) ?? "P"
      let second =
        glyphs.dropFirst().first { CharacterSet.decimalDigits.contains($0) }
        .map(String.init)
        ?? (words.count > 1 ? words.last?.unicodeScalars.first : glyphs.last).map(String.init)
        ?? first
      text = String((first + second).uppercased().unicodeScalars.prefix(2))
    } else {
      text = "PR"
    }
    let seed =
      normalized.isEmpty ? "project" : normalized.lowercased(with: Locale(identifier: "en_US"))
    let index = seed.unicodeScalars.reduce(0) { ($0 * 31 + Int($1.value)) % Self.colors.count }
    color = Self.colors[index]
  }
}

struct SidebarProviderMark: Equatable {
  let id: String
  let driver: String
  let name: String
  let initials: String?
  let accent: String?
  let current: Bool

  static func initials(_ name: String) -> String {
    let words = name.replacingOccurrences(of: "_", with: " ")
      .replacingOccurrences(of: "-", with: " ").split(whereSeparator: \.isWhitespace)
    if words.count == 1 { return String(words[0].unicodeScalars.prefix(2)).uppercased() }
    return words.prefix(2).compactMap { $0.unicodeScalars.first.map(String.init) }
      .joined().uppercased()
  }
}

struct SidebarProviderDirectory {
  let marks: [String: SidebarProviderMark]
  let modelNames: [String: [String: String]]

  init(_ catalog: ProviderCatalog) {
    let counts = catalog.providers.reduce(into: [String: Int]()) { $0[$1.driver, default: 0] += 1 }
    marks = Dictionary(
      catalog.providers.map { entry in
        (
          entry.id,
          SidebarProviderMark(
            id: entry.id, driver: entry.driver, name: entry.name,
            initials: entry.accentColor != nil || counts[entry.driver, default: 0] > 1
              ? SidebarProviderMark.initials(entry.name) : nil, accent: entry.accentColor,
            current: true)
        )
      }, uniquingKeysWith: { _, new in new })
    modelNames = Dictionary(
      catalog.providers.map { entry in
        (
          entry.id,
          Dictionary(entry.models.map { ($0.id, $0.name) }, uniquingKeysWith: { _, new in new })
        )
      }, uniquingKeysWith: { _, new in new })
  }
}

struct SidebarThreadPresentation: Equatable {
  let thread: ThreadSummary
  let project: String
  let identity: SidebarProjectIdentity
  let time: String
  let status: String?
  let providers: [SidebarProviderMark]
  let draft: Bool
  let compact: Bool
  let detail: String
  let enabled: Bool

  init(
    thread: ThreadSummary, project: String, identity: SidebarProjectIdentity,
    directory: SidebarProviderDirectory, draft: Bool, enabled: Bool, now: Date
  ) {
    self.thread = thread
    self.project = project
    self.identity = identity
    self.draft = draft
    self.enabled = enabled
    compact = thread.archived || thread.lifecycle.settled || thread.lifecycle.snoozed(at: now)
    status =
      thread.lifecycle.statusLabel(at: now)
      ?? (["failed", "error"].contains(thread.status) ? "Failed" : nil)
    let date =
      thread.lifecycle.settled
      ? thread.lifecycle.settledAnchor
      : thread.lifecycle.latestUserMessageAt ?? thread.lifecycle.updatedAt
    time = Self.time(date, now: now)
    let currentID = thread.model["instanceId"].string
    var seen = Set<String>()
    let history = thread.providerHistory.filter { $0 != currentID } + (currentID.map { [$0] } ?? [])
    providers = history.compactMap { id in
      guard seen.insert(id).inserted, let mark = directory.marks[id] else {
        return nil
      }
      let current = id == currentID
      return SidebarProviderMark(
        id: id, driver: mark.driver, name: mark.name,
        initials: current ? mark.initials : nil, accent: mark.accent, current: current)
    }
    var lines = [thread.title, project]
    if let branch = thread.branch { lines.append(branch) }
    if let state = status { lines.append(state) }
    if let until = thread.lifecycle.snoozedUntil, thread.lifecycle.snoozed(at: now) {
      lines.append("Snoozed until " + until.formatted(date: .abbreviated, time: .shortened))
    }
    if thread.lifecycle.pinned { lines.append("Pinned") }
    if draft { lines.append("Unsent draft") }
    if let id = currentID, let provider = directory.marks[id] {
      lines.append(provider.name)
      lines.append(
        directory.modelNames[id]?[thread.model["model"].string ?? ""] ?? thread.model["model"]
          .string ?? "")
    }
    detail = lines.filter { !$0.isEmpty }.joined(separator: "\n")
  }

  static func time(_ date: Date?, now: Date) -> String {
    guard let date else { return "" }
    let seconds = max(0, now.timeIntervalSince(date))
    if seconds < 60 { return "now" }
    if seconds < 3600 { return "\(Int(seconds / 60))m" }
    if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
    return "\(Int(seconds / 86_400))d"
  }
}
