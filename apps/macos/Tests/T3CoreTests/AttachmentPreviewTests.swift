import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import T3Core

private actor PreviewLoads {
  private var starts = 0
  private var active = 0
  private var maximum = 0
  private var released = false
  private var waiting: [CheckedContinuation<Void, Never>] = []
  private var observer: CheckedContinuation<Void, Never>?
  func load(_ url: URL, bytes: Data) async throws {
    starts += 1
    active += 1
    maximum = max(maximum, active)
    if starts >= 2 {
      observer?.resume()
      observer = nil
    }
    if !released { await withCheckedContinuation { waiting.append($0) } }
    try bytes.write(to: url)
    active -= 1
  }
  func waitForTwo() async {
    if starts < 2 { await withCheckedContinuation { observer = $0 } }
  }
  func release() {
    released = true
    for continuation in waiting { continuation.resume() }
    waiting.removeAll()
  }
  var counts: (starts: Int, maximum: Int) { (starts, maximum) }
}

@Test func previewsDeduplicateLoadsAndSeparateEnvironments() async throws {
  let cache = AttachmentPreviewCache()
  let loads = PreviewLoads()
  func request(_ environment: String) -> AttachmentPreviewRequest {
    AttachmentPreviewRequest(
      key: .remote(environment: environment, attachmentID: "same-id"),
      name: "context.txt"
    ) { url in
      try await loads.load(url, bytes: Data(environment.utf8))
    }
  }
  async let first = cache.file(for: request("first"))
  async let duplicate = cache.file(for: request("first"))
  async let other = cache.file(for: request("other"))
  await loads.waitForTwo()
  await loads.release()
  let (a, b, c) = try await (first, duplicate, other)
  #expect(a === b)
  #expect(a.url != c.url)
  #expect(try Data(contentsOf: a.url) == Data("first".utf8))
  #expect(try Data(contentsOf: c.url) == Data("other".utf8))
  #expect(await loads.counts.starts == 2)
  #expect(
    try FileManager.default.attributesOfItem(atPath: a.url.path)[.posixPermissions] as? Int == 0o600
  )
  #expect(
    try FileManager.default.attributesOfItem(atPath: a.url.deletingLastPathComponent().path)[
      .posixPermissions] as? Int == 0o700)
}

@Test func previewsBoundConcurrentDownloads() async throws {
  let cache = AttachmentPreviewCache()
  let loads = PreviewLoads()
  let work = Task {
    try await withThrowingTaskGroup(of: AttachmentPreviewFile.self) { group in
      for index in 0..<12 {
        group.addTask {
          try await cache.file(
            for: AttachmentPreviewRequest(
              key: .remote(environment: "server", attachmentID: String(index)), name: "file.txt"
            ) { url in try await loads.load(url, bytes: Data("File \(index)".utf8)) })
        }
      }
      var count = 0
      for try await file in group {
        #expect(try String(contentsOf: file.url, encoding: .utf8).hasPrefix("File "))
        count += 1
      }
      return count
    }
  }
  await loads.waitForTwo()
  await loads.release()
  #expect(try await work.value == 12)
  #expect(await loads.counts.starts == 12)
  #expect(await loads.counts.maximum == 2)
}

@Test func cacheEvictionKeepsVisibleFilesAliveAndFailedLoadsCanRetry() async throws {
  let cache = AttachmentPreviewCache(countLimit: 1)
  let key = AttachmentPreviewRequest.Key.remote(environment: "server", attachmentID: "a")
  let good = AttachmentPreviewRequest(key: key, name: "../../context.txt") { url in
    try Data("Preserved preview".utf8).write(to: url)
  }
  do {
    _ = try await cache.file(
      for: AttachmentPreviewRequest(key: key, name: "partial.txt") { url in
        try Data("partial".utf8).write(to: url)
        throw T3Error("Interrupted")
      })
    Issue.record("Failed transfer should throw")
  } catch {}
  let original = try await cache.file(for: good)
  #expect(original.url.lastPathComponent == "context.txt")
  let other = try await cache.file(
    for: AttachmentPreviewRequest(
      key: .remote(environment: "server", attachmentID: "b"), name: "other.txt"
    ) { url in try Data("Other preview".utf8).write(to: url) })
  #expect(original.url.deletingLastPathComponent() != other.url.deletingLastPathComponent())
  #expect(try String(contentsOf: original.url, encoding: .utf8) == "Preserved preview")
  let reloaded = try await cache.file(for: good)
  #expect(original.url != reloaded.url)
  #expect(try Data(contentsOf: reloaded.url) == Data(contentsOf: original.url))
}

@Test func thumbnailsDecodeOnceAtBoundedResolutionWithoutChangingTheOriginal() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let source = root.appendingPathComponent("image.png")
  let context = CGContext(
    data: nil, width: 1600, height: 800, bitsPerComponent: 8,
    bytesPerRow: 6400, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: 1600, height: 800))
  let output = CGImageDestinationCreateWithURL(
    source as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(output, context.makeImage()!, nil)
  #expect(CGImageDestinationFinalize(output))
  let bytes = try Data(contentsOf: source)
  let cache = AttachmentPreviewCache(directory: root)
  let request = AttachmentPreviewRequest.local(source, name: "image.png")
  let image = try await cache.thumbnail(for: request)
  let again = try await cache.thumbnail(for: request)
  #expect(image === again)
  #expect(image.width == 512)
  #expect(image.height == 256)
  let file = try await cache.file(for: request)
  try FileManager.default.removeItem(at: source)
  #expect(try Data(contentsOf: file.url) == bytes)
  let destination = root.appendingPathComponent("saved-image.png")
  try Data("Existing destination".utf8).write(to: destination)
  try await file.save(to: destination)
  #expect(try Data(contentsOf: destination) == bytes)
  #expect(try await cache.thumbnail(for: request) === image)
  let bad = AttachmentPreviewRequest(
    key: .remote(environment: "server", attachmentID: "broken"),
    name: "invalid.png"
  ) { url in
    try Data("Not an image".utf8).write(to: url)
  }
  await #expect(throws: T3Error.self) { try await cache.thumbnail(for: bad) }
  #expect(try await cache.file(for: bad).sizeBytes == 12)
}
