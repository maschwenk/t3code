import AppKit
import Combine
import Foundation
import T3Core
import UserNotifications

enum NativeAppearance: String, Codable, CaseIterable {
  case system, light, dark
  var name: String { rawValue.capitalized }
  var appKitAppearance: NSAppearance? {
    switch self {
    case .system: nil
    case .light: NSAppearance(named: .aqua)
    case .dark: NSAppearance(named: .darkAqua)
    }
  }
}

enum NativeChatWidth: String, Codable, CaseIterable {
  case comfortable, wide, full
  var name: String { rawValue.capitalized }
  var maximumWidth: CGFloat? {
    switch self {
    case .comfortable: 880
    case .wide: 1200
    case .full: nil
    }
  }
}

enum NativeNotificationMode: String, Codable, CaseIterable {
  case off, notifications, sound
  case notificationsAndSound = "notifications-and-sound"
  var name: String {
    switch self {
    case .off: "Off"
    case .notifications: "Notifications only"
    case .sound: "Sound only"
    case .notificationsAndSound: "Notifications with sound"
    }
  }
  var showsBanner: Bool { self == .notifications || self == .notificationsAndSound }
  var playsSound: Bool { self == .sound || self == .notificationsAndSound }
}

struct NativeAppearanceValues: Codable, Equatable {
  var appearance: NativeAppearance = .system
  var interfaceFont = ""
  var interfaceFontSize = 16
  var codeFont = ""
  var codeFontSize = 13
  var chatWidth: NativeChatWidth = .comfortable
  var wordWrap = true

  private enum CodingKeys: String, CodingKey {
    case appearance, interfaceFont, interfaceFontSize, codeFont, codeFontSize, chatWidth, wordWrap
  }
  init() {}
  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    appearance = try c.decodeIfPresent(NativeAppearance.self, forKey: .appearance) ?? .system
    interfaceFont = try c.decodeIfPresent(String.self, forKey: .interfaceFont) ?? ""
    interfaceFontSize = try c.decodeIfPresent(Int.self, forKey: .interfaceFontSize) ?? 16
    codeFont = try c.decodeIfPresent(String.self, forKey: .codeFont) ?? ""
    codeFontSize = try c.decodeIfPresent(Int.self, forKey: .codeFontSize) ?? 13
    chatWidth = try c.decodeIfPresent(NativeChatWidth.self, forKey: .chatWidth) ?? .comfortable
    wordWrap = try c.decodeIfPresent(Bool.self, forKey: .wordWrap) ?? true
  }
  func validated() throws -> Self {
    guard (12...20).contains(interfaceFontSize), (10...18).contains(codeFontSize),
      interfaceFont.utf16.count <= 200, codeFont.utf16.count <= 200,
      !(interfaceFont + codeFont).unicodeScalars.contains(
        where: CharacterSet.controlCharacters.contains)
    else { throw T3Error("Choose an interface size from 12 to 20 and a code size from 10 to 18.") }
    var result = self
    result.interfaceFont = interfaceFont.trimmingCharacters(in: .whitespacesAndNewlines)
    result.codeFont = codeFont.trimmingCharacters(in: .whitespacesAndNewlines)
    return result
  }
  var resolvedInterfaceFont: NSFont {
    NSFont(name: interfaceFont, size: CGFloat(interfaceFontSize))
      ?? NSFont.systemFont(ofSize: CGFloat(interfaceFontSize))
  }
  var resolvedCodeFont: NSFont {
    NSFont(name: codeFont, size: CGFloat(codeFontSize))
      ?? NSFont.monospacedSystemFont(ofSize: CGFloat(codeFontSize), weight: .regular)
  }
}

struct NativeNotificationValues: Codable, Equatable {
  var mode: NativeNotificationMode = .off
  var completion = true
  var attention = true
  var failure = true
  var whileAppActive = false
  private enum CodingKeys: String, CodingKey {
    case mode, completion, attention, failure, whileAppActive
  }
  init() {}
  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    mode = try c.decodeIfPresent(NativeNotificationMode.self, forKey: .mode) ?? .off
    completion = try c.decodeIfPresent(Bool.self, forKey: .completion) ?? true
    attention = try c.decodeIfPresent(Bool.self, forKey: .attention) ?? true
    failure = try c.decodeIfPresent(Bool.self, forKey: .failure) ?? true
    whileAppActive = try c.decodeIfPresent(Bool.self, forKey: .whileAppActive) ?? false
  }
  func allows(_ kind: NativeThreadNotification.Kind) -> Bool {
    guard mode != .off else { return false }
    switch kind {
    case .completion: return completion
    case .attention: return attention
    case .failure: return failure
    }
  }
}

struct NativePreferenceValues: Codable, Equatable {
  var appearance = NativeAppearanceValues()
  var notifications = NativeNotificationValues()
  private enum CodingKeys: String, CodingKey { case appearance, notifications }
  init() {}
  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    appearance = try c.decodeIfPresent(NativeAppearanceValues.self, forKey: .appearance) ?? .init()
    notifications =
      try c.decodeIfPresent(NativeNotificationValues.self, forKey: .notifications) ?? .init()
  }
}

@MainActor final class NativePreferences: ObservableObject {
  static let shared = NativePreferences()
  @Published private(set) var values = NativePreferenceValues()
  @Published private(set) var error: String?
  let file: URL
  private let changes = PassthroughSubject<NativePreferenceValues, Never>()
  var appearance: NativeAppearanceValues { values.appearance }
  var notifications: NativeNotificationValues { values.notifications }

  init(file: URL? = nil) {
    self.file =
      file
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("T3Native/native-preferences.json")
    guard FileManager.default.fileExists(atPath: self.file.path) else { return }
    do {
      var restored = try JSONDecoder().decode(
        NativePreferenceValues.self, from: Data(contentsOf: self.file))
      restored.appearance = try restored.appearance.validated()
      values = restored
    } catch { self.error = "Native preferences could not be read: " + error.localizedDescription }
  }

  func update(_ change: (inout NativePreferenceValues) throws -> Void) throws {
    do {
      var next = values
      try change(&next)
      next.appearance = try next.appearance.validated()
      guard next != values else { return }
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try JSONEncoder().encode(next).write(to: file, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
      values = next
      error = nil
      changes.send(next)
    } catch {
      self.error = "Native preferences could not be saved: " + error.localizedDescription
      throw error
    }
  }

  /// Emits after a successful save. Retain the returned token for the lifetime of the observer.
  func observeChanges(_ change: @escaping (NativePreferenceValues) -> Void) -> AnyCancellable {
    changes.sink(receiveValue: change)
  }
}

struct NativeThreadNotification: Equatable {
  enum Kind { case completion, attention, failure }
  let id: String
  let threadID: String
  let title: String
  let body: String
  let kind: Kind
}

/// Consumes the actual shell contract. Snapshots seed silently, and sequence replay never alerts.
struct NativeNotificationTransitionTracker {
  private struct State {
    var raw: JSON
    var delivered: Set<String> = []
    init(raw: JSON, delivered: Set<String> = []) {
      self.raw = raw
      self.delivered = delivered
      if let request = raw["pendingRuntimeRequest"]["id"].string {
        self.delivered.insert("request:" + request)
      }
      let run = raw["latestRunId"].string ?? ""
      if raw["status"].string == "failed" {
        self.delivered.insert(
          (raw["lastErrorClass"].string == "usage_limit" ? "limited:" : "failed:") + run)
      }
      if let completed = raw["latestRunCompletedAt"].string {
        self.delivered.insert("completed:" + run + ":" + completed)
      }
    }
  }
  private var previous: [String: State] = [:]
  private var sequence = -1
  mutating func reset() {
    previous = [:]
    sequence = -1
  }

  mutating func receive(_ event: JSON) -> [NativeThreadNotification] {
    if event["kind"].string == "snapshot" {
      guard case .array = event["snapshot"]["threads"],
        let stamp = event["snapshot"]["snapshotSequence"].int
      else { return [] }
      previous = Dictionary(
        event["snapshot"]["threads"].array.compactMap { raw in
          raw["id"].string.map { ($0, State(raw: raw, delivered: previous[$0]?.delivered ?? [])) }
        }, uniquingKeysWith: { _, last in last })
      sequence = stamp
      return []
    }
    guard let stamp = event["sequence"].int, stamp > sequence else { return [] }
    sequence = stamp
    if event["kind"].string == "thread.removed", let id = event["threadId"].string {
      previous.removeValue(forKey: id)
      return []
    }
    guard event["kind"].string == "thread.updated", let id = event["thread"]["id"].string else {
      return []
    }
    let raw = event["thread"]
    guard var prior = previous[id] else {
      previous[id] = State(raw: raw)
      return []
    }
    let old = prior.raw
    prior.raw = raw
    defer { previous[id] = prior }
    guard raw["archivedAt"] == .null, raw["deletedAt"] == .null,
      event["location"].string != "archive",
      raw["lineage"]["relationshipToParent"].string != "subagent"
    else { return [] }
    let run = raw["latestRunId"].string ?? ""
    let request = raw["pendingRuntimeRequest"]
    let kind: NativeThreadNotification.Kind
    let signature: String
    let title: String
    if let requestID = request["id"].string, request["kind"].string != "auth_refresh",
      request != old["pendingRuntimeRequest"]
    {
      kind = .attention
      signature = "request:" + requestID
      title = request["kind"].string == "user_input" ? "Input needed" : "Approval needed"
    } else if raw["status"].string == "failed", raw["lastErrorClass"].string == "usage_limit",
      old["status"] != raw["status"] || old["latestRunId"] != raw["latestRunId"]
        || old["lastErrorClass"] != raw["lastErrorClass"]
    {
      kind = .attention
      signature = "limited:" + run
      title = "Usage limit reached"
    } else if raw["status"].string == "failed", raw["lastErrorClass"].string != "usage_limit",
      old["status"] != raw["status"] || old["latestRunId"] != raw["latestRunId"]
    {
      kind = .failure
      signature = "failed:" + run
      title = "Thread failed"
    } else if ["idle", "completed"].contains(raw["status"].string ?? ""),
      raw["activityRunStatus"] == .null,
      let completed = raw["latestRunCompletedAt"].string,
      ThreadDates.parse(completed) != nil,
      raw["latestRunCompletedAt"] != old["latestRunCompletedAt"],
      !run.isEmpty,
      !raw["pendingBackgroundTasks"].array.contains(where: { $0["kind"].string != "command" })
    {
      kind = .completion
      signature = "completed:" + run + ":" + completed
      title = "Thread completed"
    } else {
      return []
    }
    guard prior.delivered.insert(signature).inserted else { return [] }
    // One run can contain several input requests; bound dedup state to the current run.
    if old["latestRunId"] != raw["latestRunId"] { prior.delivered = [signature] }
    return [
      .init(
        id: id + ":" + signature, threadID: id, title: title,
        body: raw["title"].string ?? "Thread", kind: kind)
    ]
  }
}

@MainActor
final class NativeNotificationPresenter: NSObject, ObservableObject,
  UNUserNotificationCenterDelegate
{
  private let store: ClientStore
  private let preferences: NativePreferences
  private var tracker = NativeNotificationTransitionTracker()
  private var connection: RPCConnection?
  private var endpoint: URL?
  @Published private(set) var error: String?
  var onOpenThread: ((URL, String) -> Void)?

  init(store: ClientStore, preferences: NativePreferences = .shared) {
    self.store = store
    self.preferences = preferences
    super.init()
  }

  /// Register once at app startup to handle clicks on notifications delivered in an earlier session.
  func activate() {
    if Bundle.main.bundleURL.pathExtension == "app" {
      UNUserNotificationCenter.current().delegate = self
    }
  }

  /// Parent calls on connection changes and before forwarding shell events.
  func refreshConnection() {
    guard connection !== store.browserConnection || endpoint != store.browserEndpoint else {
      return
    }
    connection = store.browserConnection
    endpoint = store.browserEndpoint
    tracker.reset()
  }

  /// Forward accepted shell events, including the initial snapshot, using their issuing connection.
  func receive(_ event: JSON, connection issued: RPCConnection, endpoint issuedEndpoint: URL) {
    refreshConnection()
    guard connection === issued, endpoint == issuedEndpoint else { return }
    for notice in tracker.receive(event) {
      guard preferences.notifications.allows(notice.kind),
        preferences.notifications.whileAppActive || NSApp?.isActive != true
      else { continue }
      Task { await present(notice, connection: issued, endpoint: issuedEndpoint) }
    }
  }

  static func requestAuthorization() async throws -> Bool {
    guard Bundle.main.bundleURL.pathExtension == "app" else {
      throw T3Error("Notification permission is available in the installed native app.")
    }
    let center = UNUserNotificationCenter.current()
    return try await center.requestAuthorization(options: [.alert, .sound])
  }

  private func present(
    _ notice: NativeThreadNotification, connection issued: RPCConnection,
    endpoint issuedEndpoint: URL
  ) async {
    guard store.browserConnection === issued, store.browserEndpoint == issuedEndpoint,
      preferences.notifications.allows(notice.kind),
      preferences.notifications.whileAppActive || NSApp?.isActive != true
    else { return }
    let mode = preferences.notifications.mode
    if !mode.showsBanner {
      if mode.playsSound { NSSound(named: .init("Glass"))?.play() }
      return
    }
    guard Bundle.main.bundleURL.pathExtension == "app" else { return }
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    let settings = await center.notificationSettings()
    guard store.browserConnection === issued, store.browserEndpoint == issuedEndpoint,
      preferences.notifications.allows(notice.kind), preferences.notifications.mode.showsBanner,
      preferences.notifications.whileAppActive || NSApp?.isActive != true
    else { return }
    guard
      settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    else {
      error = "Enable notifications for T3 Native in System Settings."
      return
    }
    let content = UNMutableNotificationContent()
    content.title = notice.title
    content.body = notice.body
    if preferences.notifications.mode.playsSound { content.sound = .default }
    content.userInfo = ["endpoint": issuedEndpoint.absoluteString, "threadID": notice.threadID]
    do {
      try await center.add(
        UNNotificationRequest(
          identifier: issuedEndpoint.absoluteString + ":" + notice.id,
          content: content, trigger: nil))
      guard store.browserConnection === issued, store.browserEndpoint == issuedEndpoint else {
        return
      }
      error = nil
    } catch {
      guard store.browserConnection === issued, store.browserEndpoint == issuedEndpoint else {
        return
      }
      self.error = "Notification could not be delivered: " + error.localizedDescription
    }
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let endpoint = response.notification.request.content.userInfo["endpoint"] as? String
    let thread = response.notification.request.content.userInfo["threadID"] as? String
    Task { @MainActor [weak self] in
      if let endpoint, let url = URL(string: endpoint), let thread {
        self?.onOpenThread?(url, thread)
      }
    }
    completionHandler()
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    let notificationEndpoint = notification.request.content.userInfo["endpoint"] as? String
    return await MainActor.run {
      let choices = preferences.notifications
      guard choices.whileAppActive, choices.mode.showsBanner,
        notificationEndpoint == store.browserEndpoint?.absoluteString
      else { return [] }
      return choices.mode.playsSound ? [.banner, .sound] : [.banner]
    }
  }
}
