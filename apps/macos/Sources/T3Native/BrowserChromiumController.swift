import AppKit
import Combine
import Security
import T3Core

@MainActor final class BrowserChromiumController: ObservableObject {
  @Published var enabled: Bool {
    didSet {
      UserDefaults.standard.set(enabled, forKey: "T3NativeChromiumBrowserEnabled")
      if !enabled { stop() }
      onChange?()
    }
  }
  @Published private(set) var state = "Stopped"
  @Published private(set) var error: String?
  @Published private(set) var extensions: [JSON] = []
  @Published var nativeRecordingActive = false
  var environmentID: String?
  @Published private(set) var downloads: [String: JSON] = [:]
  var activeDownloadCount: Int {
    downloads.values.filter { $0["state"].string == "downloading" }.count
  }
  private(set) var pages: [String: JSON] = [:]
  var onEvent: ((String, JSON) -> Void)?
  var onChange: (() -> Void)?
  private var process: Process?
  private var input: FileHandle?
  private var output: FileHandle?
  private var diagnostics: FileHandle?
  private var token = ""
  private var generation = UUID()
  private var buffer = Data()
  private var pending: [String: CheckedContinuation<JSON, any Error>] = [:]
  private var timeouts: [String: Task<Void, Never>] = [:]
  var available: Bool { FileManager.default.isExecutableFile(atPath: executable.path) }
  var running: Bool { process?.isRunning == true }
  var passwordStatus: String {
    guard
      let installed = extensions.first(where: {
        $0["id"].string == "aeblfdkhhhdcdjpifhhbdiojplfjncoa"
      })
    else {
      return "1Password extension is not installed"
    }
    if let failure = installed["loadError"].string { return "1Password: " + failure }
    return installed["enabled"].bool
      ? "1Password extension installed" : "1Password extension disabled"
  }
  private var executable: URL {
    Bundle.main.bundleURL.appendingPathComponent(
      "Contents/Resources/chromium-helper/T3 Browser.app/Contents/MacOS/Electron")
  }
  init() { enabled = UserDefaults.standard.bool(forKey: "T3NativeChromiumBrowserEnabled") }
  isolated deinit {
    output?.readabilityHandler = nil
    diagnostics?.readabilityHandler = nil
    try? input?.close()
    if process?.isRunning == true { process?.terminate() }
    for task in timeouts.values { task.cancel() }
  }
  static func pageKey(environment: String, thread: String, tab: String) -> String {
    [environment, thread, tab].joined(separator: "\n")
  }
  func owns(environment: String, thread: String, tab: String) -> Bool {
    pages[Self.pageKey(environment: environment, thread: thread, tab: tab)] != nil
  }
  func context(environment: String, thread: String, tab: String) -> [String: JSON] {
    ["environmentID": .string(environment), "threadId": .string(thread), "tabId": .string(tab)]
  }
  private func launch() throws {
    guard !running else { return }
    guard available else {
      throw T3Error(
        "The packaged Chromium helper is unavailable. Build T3 Browser with the native app first.")
    }
    #if !arch(arm64)
      throw T3Error("T3 Browser requires Apple Silicon.")
    #endif
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw T3Error("Could not authenticate the browser helper.")
    }
    token = bytes.map { String(format: "%02x", $0) }.joined()
    let owner = UUID()
    generation = owner
    buffer = Data()
    let process = Process()
    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    process.executableURL = executable
    var environment = ProcessInfo.processInfo.environment
    environment.removeValue(forKey: "ELECTRON_RUN_AS_NODE")
    environment.removeValue(forKey: "NODE_OPTIONS")
    environment["T3_CHROMIUM_TOKEN"] = token
    environment["T3_CHROMIUM_STATE"] =
      FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/T3Native/Chromium").path
    process.environment = environment
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr
    stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      Task { @MainActor [weak self] in self?.receive(data, generation: owner) }
    }
    // Electron and extension diagnostics never enter the credential-bearing wire.
    stderr.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
    process.terminationHandler = { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self, self.generation == owner else { return }
        self.stop()
      }
    }
    self.process = process
    input = stdin.fileHandleForWriting
    output = stdout.fileHandleForReading
    diagnostics = stderr.fileHandleForReading
    do {
      try process.run()
      state = "Starting Chromium"
      error = nil
      onChange?()
    } catch {
      stop()
      throw error
    }
  }
  func request(_ method: String, input payload: JSON = .object([:]), milliseconds: Int = 60_000)
    async throws -> JSON
  {
    try Task.checkCancellation()
    try launch()
    let id = UUID().uuidString
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        pending[id] = continuation
        timeouts[id] = Task { [weak self] in
          do { try await Task.sleep(for: .milliseconds(max(1, min(120_000, milliseconds)))) } catch
          { return }
          guard let self, let pending = self.pending.removeValue(forKey: id) else { return }
          self.timeouts.removeValue(forKey: id)
          self.interrupt(payload)
          pending.resume(
            throwing: BrowserAutomationError(
              "PreviewAutomationTimeoutError", "Chromium operation timed out."))
        }
        do { try write(id: id, method: method, payload: payload) } catch {
          pending.removeValue(forKey: id)?.resume(throwing: error)
          timeouts.removeValue(forKey: id)?.cancel()
        }
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
        self.timeouts.removeValue(forKey: id)?.cancel()
        self.interrupt(payload)
      }
    }
  }
  private func write(id: String, method: String, payload: JSON) throws {
    let message = JSON.object([
      "token": .string(token), "id": .string(id),
      "method": .string(method), "input": payload,
    ])
    var data = try message.data()
    guard data.count <= 1024 * 1024 else { throw T3Error("The Chromium command is too large.") }
    data.append(10)
    guard let input else { throw BrowserAutomationError.interrupted }
    try input.write(contentsOf: data)
  }
  private func interrupt(_ payload: JSON) {
    guard payload["tabId"].string != nil else { return }
    try? write(id: UUID().uuidString, method: "stop", payload: payload)
  }
  private func receive(_ data: Data, generation owner: UUID) {
    guard generation == owner, !data.isEmpty else { return }
    buffer.append(data)
    guard buffer.count <= 24 * 1024 * 1024 else {
      error = "Chromium exceeded its message limit."
      stop()
      return
    }
    while let end = buffer.firstIndex(of: 10) {
      let line = buffer[..<end]
      buffer.removeSubrange(...end)
      let prefix = Data("T3CHROMIUM ".utf8)
      guard line.starts(with: prefix),
        let value = try? JSON.decode(Data(line.dropFirst(prefix.count))),
        value["token"].string == token
      else { continue }
      if let id = value["id"].string {
        timeouts.removeValue(forKey: id)?.cancel()
        guard let continuation = pending.removeValue(forKey: id) else { continue }
        if let message = value["error"]["message"].string {
          continuation.resume(
            throwing: BrowserAutomationError(
              value["error"]["_tag"].string ?? "PreviewAutomationActionFailedError", message))
        } else {
          let result = value["result"]
          if let environment = result["environmentID"].string,
            let thread = result["threadId"].string,
            let tab = result["tabId"].string
          {
            pages[Self.pageKey(environment: environment, thread: thread, tab: tab)] = result
          }
          continuation.resume(returning: result)
        }
      } else if let event = value["event"].string {
        let payload = value["value"]
        if event == "ready" { state = "Chromium ready" }
        if event == "extensions" { extensions = payload.array }
        if event == "download", let id = payload["id"].string { downloads[id] = payload }
        if event == "page", let environment = payload["environmentID"].string,
          let thread = payload["threadId"].string, let tab = payload["tabId"].string
        {
          pages[Self.pageKey(environment: environment, thread: thread, tab: tab)] = payload
        }
        if event == "closed", let environment = payload["environmentID"].string,
          let thread = payload["threadId"].string, let tab = payload["tabId"].string
        {
          pages.removeValue(
            forKey: Self.pageKey(environment: environment, thread: thread, tab: tab))
        }
        onEvent?(event, payload)
        onChange?()
      }
    }
  }
  func stop() {
    generation = UUID()
    if running { try? write(id: UUID().uuidString, method: "stopHelper", payload: .object([:])) }
    let oldProcess = process
    let oldOutput = output
    let oldDiagnostics = diagnostics
    // EOF requests extension/native-host cleanup. Keep draining output until
    // the owned child exits, then terminate only that child if it gets stuck.
    try? input?.close()
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(2))
      if oldProcess?.isRunning == true { oldProcess?.terminate() }
      oldOutput?.readabilityHandler = nil
      oldDiagnostics?.readabilityHandler = nil
      try? oldOutput?.close()
      try? oldDiagnostics?.close()
    }
    process = nil
    input = nil
    output = nil
    diagnostics = nil
    buffer = Data()
    pages = [:]
    extensions = []
    downloads = [:]
    for task in timeouts.values { task.cancel() }
    timeouts = [:]
    let waiting = pending.values
    pending = [:]
    for continuation in waiting {
      continuation.resume(throwing: BrowserAutomationError.interrupted)
    }
    state = "Stopped"
    onChange?()
  }
  func finishBeforeQuit(window: NSWindow?) async -> Bool {
    guard running else { return true }
    do {
      let active = try await request("downloads", milliseconds: 10_000).array
      guard !active.isEmpty else { return true }
      let alert = NSAlert()
      alert.messageText = "Chromium downloads are still running"
      alert.informativeText = "Quitting cancels \(active.count) Chromium browser download(s)."
      alert.addButton(withTitle: "Keep downloading")
      alert.addButton(withTitle: "Quit and cancel downloads")
      let response =
        if let window, window.isVisible { await alert.beginSheetModal(for: window) } else {
          alert.runModal()
        }
      guard response == .alertSecondButtonReturn else { return false }
      _ = try await request("cancelDownloads", milliseconds: 10_000)
      return true
    } catch {
      self.error = error.localizedDescription
      return !running
    }
  }
  func removeExtension() async {
    do {
      extensions = try await request("removeExtension").array
      error = nil
    } catch { self.error = error.localizedDescription }
    onChange?()
  }
  func clearProfile(_ profile: String, kinds: BrowserProfiles.DataKinds) async throws {
    guard let environmentID else {
      throw T3Error("Connect to the profile's environment before clearing Chromium data.")
    }
    let kind: String =
      switch kinds {
      case .all: "all"
      case .cookies: "cookies"
      case .cache: "cache"
      }
    _ = try await request(
      "clearProfile",
      input: .object([
        "environmentID": .string(environmentID),
        "profileId": .string(profile), "kinds": .string(kind),
      ]))
  }
  func install() async {
    do {
      extensions = try await request("install", milliseconds: 120_000).array
      error = nil
    } catch { self.error = error.localizedDescription }
    onChange?()
  }
  func importSelectedProfile(window: NSWindow?) async {
    let picker = NSOpenPanel()
    picker.title = "Import 1Password Extension"
    picker.message =
      "Select the existing Chrome, Edge, Brave, Vivaldi, Opera or Arc profile containing 1Password. Only its extension package is copied; cookies and passwords are not imported."
    picker.canChooseDirectories = true
    picker.canChooseFiles = false
    picker.allowsMultipleSelection = false
    picker.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Application Support/Google/Chrome")
    let result: NSApplication.ModalResponse
    if let window {
      result = await picker.beginSheetModal(for: window)
    } else {
      result = await picker.begin()
    }
    guard result == .OK, let file = picker.url else { return }
    do {
      extensions = try await request(
        "import", input: .object(["profilePath": .string(file.path)]), milliseconds: 120_000
      ).array
      error = nil
    } catch { self.error = error.localizedDescription }
    onChange?()
  }
  func refreshExtensions() async {
    guard running else { return }
    do { extensions = try await request("extensions").array } catch {
      self.error = error.localizedDescription
    }
  }
}
