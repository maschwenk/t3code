import AVFoundation
import AppKit
import T3Core

struct BrowserRecordingOptions: Equatable {
  var framesPerSecond = 30
  var showMouse = true
  var showKeys = true
  func validate() throws {
    guard [30, 60].contains(framesPerSecond) else { throw T3Error("Choose 30 or 60 fps.") }
  }
}

// Browser frames stay on this machine. Only the finished artifact uses attachment upload.
@MainActor final class BrowserRecording {
  enum State: Equatable {
    case idle, recording, finishing
    case saved(URL)
    case failed(String)
  }
  private(set) var state: State = .idle
  private(set) var frameCount = 0
  private(set) var startedAt: Date?
  var readyToStop: Bool { state == .recording && writer != nil }
  private(set) var options = BrowserRecordingOptions()
  var onChange: (() -> Void)?
  private var changeWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
  private var writer: AVAssetWriter?
  private var input: AVAssetWriterInput?
  private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
  private var task: Task<Void, Never>?
  private var file: URL?
  private var startTime = 0.0
  private var dimensions = CGSize.zero
  private var revision = UUID()
  var active: Bool { state == .recording || state == .finishing }

  func start(
    options: BrowserRecordingOptions, directory: URL,
    capture: @escaping @MainActor (BrowserRecordingOptions) async throws -> NSImage
  ) async throws {
    guard !active else { throw T3Error("A browser recording is already in progress.") }
    try options.validate()
    let revision = UUID()
    self.revision = revision
    self.options = options
    startedAt = Date()
    frameCount = 0
    state = .recording
    changed()
    do {
      let image = try await capture(options)
      try Task.checkCancellation()
      guard self.revision == revision, state == .recording else { throw CancellationError() }
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      let file = directory.appendingPathComponent("Browser recording " + UUID().uuidString + ".mp4")
      self.file = file
      let writer = try AVAssetWriter(outputURL: file, fileType: .mp4)
      self.writer = writer
      dimensions = CGSize(
        width: max(2, floor(image.size.width / 2) * 2),
        height: max(2, floor(image.size.height / 2) * 2))
      let input = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [
          AVVideoCodecKey: AVVideoCodecType.h264,
          AVVideoWidthKey: dimensions.width, AVVideoHeightKey: dimensions.height,
          AVVideoCompressionPropertiesKey: [
            AVVideoExpectedSourceFrameRateKey: options.framesPerSecond,
            AVVideoAverageBitRateKey: 4_000_000,
            AVVideoMaxKeyFrameIntervalKey: options.framesPerSecond,
          ],
        ])
      input.expectsMediaDataInRealTime = true
      guard writer.canAdd(input) else { throw T3Error("Video encoding is unavailable.") }
      writer.add(input)
      self.input = input
      adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
          kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
          kCVPixelBufferWidthKey as String: Int(dimensions.width),
          kCVPixelBufferHeightKey as String: Int(dimensions.height),
          kCVPixelBufferCGImageCompatibilityKey as String: true,
          kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ])
      guard writer.startWriting() else {
        throw writer.error ?? T3Error("Could not start video encoding.")
      }
      writer.startSession(atSourceTime: .zero)
      startTime = ProcessInfo.processInfo.systemUptime
      try append(image, seconds: 0)
      changed()
      task = Task { [weak self] in
        guard let self else { return }
        let interval = 1.0 / Double(options.framesPerSecond)
        var next = startTime + interval
        do {
          while state == .recording, self.revision == revision, !Task.isCancelled {
            let wait = next - ProcessInfo.processInfo.systemUptime
            if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
            // One capture at a time, with writer backpressure. Never accumulate image frames.
            guard writer.status == .writing else {
              throw writer.error ?? T3Error("Browser encoder stopped.")
            }
            if input.isReadyForMoreMediaData {
              let image = try await capture(options)
              guard self.revision == revision, state == .recording, !Task.isCancelled else {
                return
              }
              try append(image, seconds: ProcessInfo.processInfo.systemUptime - startTime)
            }
            next = max(next + interval, ProcessInfo.processInfo.systemUptime)
            let nearSizeLimit =
              frameCount % options.framesPerSecond == 0
              && ((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) >= 48 * 1024
                * 1024
            if ProcessInfo.processInfo.systemUptime - startTime >= 600 || nearSizeLimit {
              _ = try await stop()
              return
            }
          }
        } catch {
          if self.revision == revision, !Task.isCancelled {
            cancel()
            state = .failed(error.localizedDescription)
            changed()
          }
        }
      }
    } catch {
      if self.revision == revision {
        cancel()
        state = .failed(error.localizedDescription)
        changed()
      }
      throw error
    }
  }

  private func append(_ image: NSImage, seconds: Double) throws {
    guard let writer, let input, let adaptor, writer.status == .writing else {
      throw self.writer?.error ?? T3Error("Browser encoder stopped.")
    }
    guard input.isReadyForMoreMediaData else { return }
    var buffer: CVPixelBuffer?
    if let pool = adaptor.pixelBufferPool {
      guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess else {
        throw T3Error("Could not allocate a recording frame.")
      }
    }
    guard let buffer else { throw T3Error("Recording frame pool is unavailable.") }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard
      let context = CGContext(
        data: CVPixelBufferGetBaseAddress(buffer),
        width: Int(dimensions.width), height: Int(dimensions.height), bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue),
      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else { throw T3Error("Could not render a recording frame.") }
    context.setFillColor(NSColor.black.cgColor)
    context.fill(CGRect(origin: .zero, size: dimensions))
    let scale = min(dimensions.width / image.size.width, dimensions.height / image.size.height)
    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    context.draw(
      cgImage,
      in: CGRect(
        x: (dimensions.width - size.width) / 2,
        y: (dimensions.height - size.height) / 2, width: size.width, height: size.height))
    guard
      adaptor.append(
        buffer, withPresentationTime: CMTime(seconds: seconds, preferredTimescale: 60_000))
    else { throw writer.error ?? T3Error("Could not append browser video frame.") }
    frameCount += 1
  }

  @discardableResult func stop() async throws -> URL {
    guard state == .recording, let writer, let input, let file else {
      throw T3Error("There is no browser recording to finish.")
    }
    state = .finishing
    let revision = revision
    task?.cancel()
    task = nil
    changed()
    input.markAsFinished()
    await writer.finishWriting()
    guard self.revision == revision else { throw CancellationError() }
    guard writer.status == .completed else {
      let error = writer.error ?? T3Error("Could not save the browser recording.")
      cancel()
      state = .failed(error.localizedDescription)
      changed()
      throw error
    }
    self.writer = nil
    self.input = nil
    adaptor = nil
    self.file = nil
    state = .saved(file)
    changed()
    return file
  }
  func cancel() {
    revision = UUID()
    task?.cancel()
    task = nil
    writer?.cancelWriting()
    writer = nil
    input = nil
    adaptor = nil
    if let file { try? FileManager.default.removeItem(at: file) }
    file = nil
    state = .idle
    startedAt = nil
    changed()
  }
  private func changed() {
    let waiters = Array(changeWaiters.values)
    changeWaiters = [:]
    for waiter in waiters { waiter.resume() }
    onChange?()
  }
  func finishForQuit() async throws -> URL {
    while active {
      if readyToStop { return try await stop() }
      await withCheckedContinuation { changeWaiters[UUID()] = $0 }
    }
    switch state {
    case .saved(let file): return file
    case .failed(let message): throw T3Error(message)
    default: throw T3Error("The recording was cancelled before it could be saved.")
    }
  }
  isolated deinit { cancel() }
}

@MainActor enum BrowserArtifacts {
  static var directory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("T3Native/BrowserArtifacts", isDirectory: true)
  }
}
