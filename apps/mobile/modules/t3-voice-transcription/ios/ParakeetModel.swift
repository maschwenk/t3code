import FluidAudioASR
import Foundation
import Synchronization
import UIKit

enum ParakeetStatus: Equatable {
  case missing
  /// One fraction across the download and the Core ML compile that follows it.
  case downloading(progress: Double, compiling: Bool)
  case ready

  var record: [String: Any] {
    switch self {
    case .missing: return ["state": "missing"]
    case .ready: return ["state": "ready"]
    case .downloading(let progress, let compiling):
      return [
        "state": "downloading",
        "progress": progress,
        "phase": compiling ? "compiling" : "downloading",
      ]
    }
  }
}

private struct ParakeetModelMissing: LocalizedError {
  var errorDescription: String? { "Download Parakeet in Settings → Voice first." }
}

/// Parakeet Ultra on this device: one download shared by every module instance, loaded only
/// while dictation uses it.
final class ParakeetModel: Sendable {
  static let shared = ParakeetModel()

  private static let version = AsrModelVersion.ultra
  private static let idleUnload = Duration.seconds(120)
  private static let directory = AsrModels.defaultCacheDirectory(for: version)
  /// The bytes fill this much of the bar; compiling the models for this device fills the rest.
  /// On Wi-Fi the download takes a minute or two and the first compile about ten.
  private static let downloadShare = 0.4

  /// A model Core ML is compiling. Core ML reports nothing until it returns, so its slot eases
  /// forward by elapsed time and stops short of its end. The encoder is nearly all of the
  /// first-load cost (about ten minutes on an iPhone Duo's Neural Engine); the others take seconds.
  private struct Compile {
    let weight: Double
    let seconds: Double
    let start = ContinuousClock.now

    init(model: String) {
      let encoder = model.contains("Encoder")
      weight = encoder ? 0.85 : 0.05
      seconds = encoder ? 240 : 2
    }

    var eased: Double {
      weight * 0.95 * (1 - exp(-((ContinuousClock.now - start) / .seconds(1)) / seconds))
    }
  }

  private struct Download {
    let task: Task<Bool, Error>
    var progress = 0.0
    var compiling = false
    /// The compile share of models already compiled, out of 1.
    var compiled = 0.0
    var current: Compile?

    var compileProgress: Double {
      ParakeetModel.downloadShare
        + (1 - ParakeetModel.downloadShare) * min(1, compiled + (current?.eased ?? 0))
    }
  }

  private struct State {
    var download: Download?
    var manager: Task<AsrManager, Error>?
    var unload: Task<Void, Never>?
  }

  private let state = Mutex(State())
  private let listener = Mutex<(@Sendable (ParakeetStatus) -> Void)?>(nil)

  private init() {
    // The weights take about 600 MB once loaded; give them back rather than be terminated.
    for name in [
      UIApplication.didReceiveMemoryWarningNotification,
      UIApplication.didEnterBackgroundNotification,
    ] {
      _ = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [unowned self] _ in
        self.unload()
      }
    }
    // A download the app was killed during leaves files that Settings has no Delete for.
    if !AsrModels.modelsExist(at: Self.directory, version: Self.version) {
      try? FileManager.default.removeItem(at: Self.directory)
    }
  }

  var status: ParakeetStatus {
    if let download = state.withLock({ $0.download }) {
      return .downloading(progress: download.progress, compiling: download.compiling)
    }
    return AsrModels.modelsExist(at: Self.directory, version: Self.version) ? .ready : .missing
  }

  func setListener(_ next: @escaping @Sendable (ParakeetStatus) -> Void) {
    listener.withLock { $0 = next }
  }

  /// Resolves false when cancelled. A second call joins the download already running.
  func download() async throws -> Bool {
    let task = state.withLock { state in
      if let download = state.download { return download.task }
      let task = Task { try await self.fetch() }
      state.download = Download(task: task)
      return task
    }
    notify()
    return try await task.value
  }

  func cancelDownload() {
    state.withLock { $0.download?.task }?.cancel()
  }

  func delete() async throws {
    unload()
    let download = state.withLock { $0.download?.task }
    download?.cancel()
    _ = try? await download?.value
    if FileManager.default.fileExists(atPath: Self.directory.path) {
      try FileManager.default.removeItem(at: Self.directory)
    }
    notify()
  }

  func prepare() async throws {
    _ = try await manager()
  }

  func transcribe(_ pcm: Data) async throws -> String {
    let manager = try await manager()
    let samples = pcm.withUnsafeBytes { raw in
      (0..<raw.count / 2).map { Float(raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self)) / 32768 }
    }
    var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
    defer { scheduleUnload() }
    return try await manager.transcribe(samples, decoderState: &decoderState).text
  }

  private func fetch() async throws -> Bool {
    let ticker = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        self?.advance { $0.current == nil ? nil : $0.compileProgress }
      }
    }
    defer {
      ticker.cancel()
      state.withLock { $0.download = nil }
      notify()
    }
    do {
      try Self.excludeFromBackup()
      try await AsrModels.download(to: Self.directory, version: Self.version) { self.report($0) }
      return true
    } catch {
      // Settings only offers Delete for a ready model, so an unfinished download keeps nothing.
      try? FileManager.default.removeItem(at: Self.directory)
      if Task.isCancelled { return false }
      throw error
    }
  }

  /// FluidAudio downloads the repository, then loads each model on its own, which compiles it for
  /// this device: a compile start names the model and an empty name marks it done.
  private func report(_ update: DownloadProgress) {
    advance { download in
      switch update.phase {
      case .listing:
        return nil
      case .downloading:
        // A repository download fills the first half of FluidAudio's fraction. Each later model
        // re-checks the cache with a download update, which must not move the bar back.
        guard !download.compiling else { return nil }
        return Self.downloadShare * min(1, update.fractionCompleted * 2)
      case .compiling(let model) where model.isEmpty:
        download.compiled += download.current?.weight ?? 0
        download.current = nil
        return download.compileProgress
      case .compiling(let model):
        download.compiling = true
        download.current = Compile(model: model)
        return download.compileProgress
      }
    }
  }

  /// Applies a change to the running download and reports it once the bar moves a whole percent.
  private func advance(_ change: (inout Download) -> Double?) {
    let moved = state.withLock { state in
      guard let before = state.download else { return false }
      var download = before
      if let next = change(&download) { download.progress = max(before.progress, min(1, next)) }
      state.download = download
      return (download.progress * 100).rounded(.down) > (before.progress * 100).rounded(.down)
        || download.compiling != before.compiling
    }
    if moved { notify() }
  }

  private func manager() async throws -> AsrManager {
    let task = state.withLock { state in
      state.unload?.cancel()
      state.unload = nil
      if let manager = state.manager { return manager }
      let manager = Task {
        guard AsrModels.modelsExist(at: Self.directory, version: Self.version) else {
          throw ParakeetModelMissing()
        }
        let models = try await AsrModels.load(from: Self.directory, version: Self.version)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        return manager
      }
      state.manager = manager
      return manager
    }
    do {
      let manager = try await task.value
      scheduleUnload()
      return manager
    } catch {
      state.withLock { if $0.manager == task { $0.manager = nil } }
      throw error
    }
  }

  private func scheduleUnload() {
    state.withLock { state in
      guard let manager = state.manager else { return }
      state.unload?.cancel()
      state.unload = Task {
        try? await Task.sleep(for: Self.idleUnload)
        guard !Task.isCancelled else { return }
        self.state.withLock { if $0.manager == manager { $0.manager = nil } }
      }
    }
  }

  private func unload() {
    state.withLock { state in
      state.manager = nil
      state.unload?.cancel()
      state.unload = nil
    }
  }

  private func notify() {
    let status = self.status
    listener.withLock { $0 }?(status)
  }

  private static func excludeFromBackup() throws {
    var root = directory.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try root.setResourceValues(values)
  }
}
