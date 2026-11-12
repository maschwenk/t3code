import FluidAudioASR
import Foundation
import Synchronization
import UIKit

enum ParakeetStatus: Equatable {
  case missing
  /// No progress once the files are in and Core ML is compiling them for this device.
  case downloading(Double?)
  case ready

  var record: [String: Any] {
    switch self {
    case .missing: return ["state": "missing"]
    case .ready: return ["state": "ready"]
    case .downloading(let progress):
      var record: [String: Any] = ["state": "downloading"]
      record["progress"] = progress
      return record
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

  private struct Download {
    let task: Task<Bool, Error>
    var progress: Double? = 0
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
      _ = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) {
        [unowned self] _ in self.unload()
      }
    }
  }

  var status: ParakeetStatus {
    if let download = state.withLock({ $0.download }) { return .downloading(download.progress) }
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
    defer {
      state.withLock { $0.download = nil }
      notify()
    }
    do {
      try Self.excludeFromBackup()
      try await AsrModels.download(to: Self.directory, version: Self.version) { self.report($0) }
      return true
    } catch _ where Task.isCancelled {
      // Cancelling leaves nothing behind; a failed download keeps its partial files to resume.
      try? FileManager.default.removeItem(at: Self.directory)
      return false
    }
  }

  private func report(_ update: DownloadProgress) {
    let changed = state.withLock { state in
      guard var download = state.download, let current = download.progress else { return false }
      let next: Double?
      switch update.phase {
      case .listing: return false
      // A repository download fills the first half of FluidAudio's fraction; compiling fills the rest.
      case .downloading: next = min(1, update.fractionCompleted * 2)
      case .compiling: next = nil
      }
      if let next, (next * 100).rounded(.down) <= (current * 100).rounded(.down) { return false }
      download.progress = next
      state.download = download
      return true
    }
    if changed { notify() }
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
