import AVFoundation
import AppKit
import JavaScriptCore
import T3Core
import Testing
import WebKit

@testable import T3Native

@MainActor private final class BrowserArtifactFixture: NSObject, WKNavigationDelegate {
  let web: WKWebView
  let automation: BrowserAutomationPage
  let viewport = BrowserViewportView(frame: NSRect(x: 0, y: 0, width: 600, height: 420))
  let window: NSWindow
  private var continuation: CheckedContinuation<Void, any Error>?
  override init() {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    web = WKWebView(
      frame: NSRect(x: 0, y: 0, width: 600, height: 420), configuration: configuration)
    automation = BrowserAutomationPage(web: web)
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 420),
      styleMask: [.borderless], backing: .buffered, defer: false)
    super.init()
    window.isReleasedWhenClosed = false
    window.contentView = viewport
    viewport.show(web)
    viewport.layoutSubtreeIfNeeded()
    web.navigationDelegate = self
  }
  func load() async throws {
    try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
      web.loadHTMLString(
        """
        <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>body{margin:0;background:white;height:2400px}#clip{position:absolute;top:1600px;left:80px;width:180px;height:80px;overflow:hidden}button{margin-left:120px;width:140px;height:60px}input{position:absolute;left:40px;top:60px}</style>
        <input id="draft"><div id="clip"><button id="target">target</button></div>
        <script>window.clicks=0;document.querySelector('#target').onclick=()=>{window.clicks++}</script>
        """, baseURL: URL(string: "https://native-fixture.test"))
    }
  }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    continuation?.resume()
    continuation = nil
  }
  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: any Error
  ) {
    continuation?.resume(throwing: error)
    continuation = nil
  }
  func query(_ operation: String, _ input: JSON = .object([:])) async throws -> JSON {
    try await automation.query(
      operation, input: input, deadline: BrowserAutomationDeadline(milliseconds: 5000))
  }
  func image(_ options: BrowserRecordingOptions = .init()) async throws -> NSImage {
    try await BrowserCapture.image(
      web: web, cursor: automation.cursor, mouse: options.showMouse,
      keys: options.showKeys)
  }
  func close() {
    automation.interrupt()
    web.stopLoading()
    web.navigationDelegate = nil
    window.close()
  }
}

@MainActor @Test func browserCursorUsesScrolledClippedZoomedFixtureCoordinates() async throws {
  let fixture = BrowserArtifactFixture()
  defer { fixture.close() }
  try await fixture.load()
  fixture.web.pageZoom = 1.5
  fixture.viewport.setting = try BrowserViewport(width: 400, height: 500)
  fixture.viewport.layoutSubtreeIfNeeded()
  let target = try await fixture.query("pointer", .object(["selector": .string("#target")]))
  guard case .number(let x) = target["x"], case .number(let y) = target["y"] else {
    throw T3Error("The fixture target has no clipped visible point.")
  }
  #expect(x >= 80 && x < 260)
  #expect(y >= 0 && Double(y) < fixture.web.bounds.height / fixture.web.pageZoom)
  let cursor = fixture.automation.cursor
  cursor.reduceMotionOverride = false
  _ = try cursor.move(css: CGPoint(x: 10, y: 10), zoom: fixture.web.pageZoom, animate: false)
  let duration = try cursor.move(css: CGPoint(x: x, y: y), zoom: fixture.web.pageZoom)
  #expect(duration == 0.24)
  #expect(cursor.movementAnimation != nil)
  #expect(cursor.target == CGPoint(x: Double(x) * 1.5, y: Double(y) * 1.5))
  let shown = cursor.convert(cursor.target!, to: fixture.viewport)
  #expect(fixture.viewport.bounds.contains(shown))
  #expect(cursor.hitTest(.zero) == nil)
  #expect(cursor.contentGeometryFlipped)
  let first = try await fixture.image()
  let second = try await fixture.image(.init(showMouse: false, showKeys: false))
  let firstData = try BrowserAnnotationRenderer.png(first)
  let secondData = try BrowserAnnotationRenderer.png(second)
  #expect(firstData != secondData)
  try browserArtifactEvidence(firstData, name: "cursor-fixture.png")
  // Capture never hides the cursor or removes its animation.
  #expect(!cursor.isHidden)
  #expect(cursor.target != nil)
  cursor.reduceMotionOverride = true
  #expect(try cursor.move(css: CGPoint(x: 20, y: 20), zoom: 1.5) == 0)
  #expect(cursor.movementAnimation == nil)
  #expect(throws: (any Error).self) { try cursor.move(css: CGPoint(x: -1, y: 20), zoom: 1.5) }
  fixture.automation.interrupt()
  #expect(cursor.isHidden)
}

@MainActor @Test func browserAnnotationsSaveActualFixturePixelsAndMetadata() async throws {
  let fixture = BrowserArtifactFixture()
  defer { fixture.close() }
  try await fixture.load()
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "t3-annotation-test-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let image = try await fixture.image()
  let document = BrowserAnnotationDocument(
    pageURL: fixture.web.url!.absoluteString,
    annotations: [
      .init(tool: .rectangle, points: [.init(x: 0.2, y: 0.3), .init(x: 0.8, y: 0.7)]),
      .init(tool: .arrow, points: [.init(x: 0.1, y: 0.1), .init(x: 0.5, y: 0.5)]),
    ])
  let file = try BrowserAnnotationRenderer.save(image, document: document, directory: directory)
  let png = try Data(contentsOf: file)
  #expect(NSImage(data: png) != nil)
  #expect(png != (try BrowserAnnotationRenderer.png(image)))
  try browserArtifactEvidence(png, name: "annotation-fixture.png")
  let sidecar = file.deletingPathExtension().appendingPathExtension("json")
  #expect(
    try BrowserAnnotationDocument.deserialize(Data(contentsOf: sidecar)).annotations
      == document.annotations)
}

@MainActor @Test(arguments: [30, 60]) func browserRecordingEncodesRealFixtureAndCleansCancellation(
  fps: Int
) async throws {
  let fixture = BrowserArtifactFixture()
  defer { fixture.close() }
  try await fixture.load()
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "t3-recording-test-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let recording = BrowserRecording()
  let options = BrowserRecordingOptions(framesPerSecond: fps)
  var captured = 0
  // Observe real capture completion rather than waiting for an arbitrary sleep.
  let thirdFrame = AsyncStream<Void>.makeStream()
  try await recording.start(options: options, directory: directory) { options in
    let image = try await fixture.image(options)
    captured += 1
    if captured >= 3 {
      thirdFrame.continuation.yield(())
      thirdFrame.continuation.finish()
    }
    return image
  }
  for await _ in thirdFrame.stream { break }
  #expect(recording.frameCount >= 2)
  let file = try await recording.stop()
  #expect(recording.state == .saved(file))
  let asset = AVURLAsset(url: file)
  let tracks = try await asset.loadTracks(withMediaType: .video)
  #expect(tracks.count == 1)
  let size = try await tracks[0].load(.naturalSize)
  #expect(size.width > 0 && size.height > 0)
  let duration = try await asset.load(.duration)
  #expect(duration.seconds > 0)
  let decoded = try await AVAssetImageGenerator(asset: asset).image(at: .zero).image
  #expect(decoded.width == Int(size.width))
  let encoded = try Data(contentsOf: file)
  #expect(encoded.count > 100)
  try browserArtifactEvidence(encoded, name: "recording-\(fps).mp4")
  let savedFiles = try FileManager.default.contentsOfDirectory(atPath: directory.path)
  try await recording.start(options: options, directory: directory) { try await fixture.image($0) }
  recording.cancel()
  #expect(recording.state == .idle)
  #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == savedFiles)
  #expect(throws: (any Error).self) { try BrowserRecordingOptions(framesPerSecond: 15).validate() }
}

@MainActor @Test func browserRecordingCancelledDuringRealSnapshotCannotLeavePartialArtifact()
  async throws
{
  let fixture = BrowserArtifactFixture()
  defer { fixture.close() }
  try await fixture.load()
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "t3-recording-cancel-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let recording = BrowserRecording()
  do {
    try await recording.start(options: .init(), directory: directory) { options in
      let image = try await fixture.image(options)
      recording.cancel()
      return image
    }
    Issue.record("Cancelled startup unexpectedly started encoding.")
  } catch is CancellationError {}
  #expect(!recording.active)
  #expect(!FileManager.default.fileExists(atPath: directory.path))
  try await recording.start(options: .init(), directory: directory) { try await fixture.image($0) }
  recording.cancel()
  #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
}

@MainActor @Test func browserClickResolverTargetsActualClippedFixtureElement() async throws {
  let fixture = BrowserArtifactFixture()
  defer { fixture.close() }
  try await fixture.load()
  let point = try await fixture.query("click", .object(["selector": .string("#target")]))
  guard case .number(let x) = point["x"], case .number(let y) = point["y"] else {
    throw T3Error("The clipped button did not resolve to a visible click point.")
  }
  let hit = try await fixture.automation.run(
    "evaluate",
    input: .object([
      "expression": .string("document.elementFromPoint(\(x),\(y)).id")
    ]),
    deadline: BrowserAutomationDeadline(milliseconds: 5000))
  #expect(hit == .string("target"))
}

private func browserArtifactEvidence(_ data: Data, name: String) throws {
  guard let path = ProcessInfo.processInfo.environment["T3_BROWSER_TEST_EVIDENCE_DIR"] else {
    return
  }
  let directory = URL(fileURLWithPath: path, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  try data.write(to: directory.appendingPathComponent(name), options: .atomic)
}

@MainActor @Test func browserChromiumCursorMovesOnRealScrolledClippedZoomedPageAndSurvivesCapture()
  async throws
{
  let fixture = BrowserArtifactFixture()
  defer { fixture.close() }
  try await fixture.load()
  fixture.web.pageZoom = 1.5
  let target = try await fixture.query("pointer", .object(["selector": .string("#target")]))
  guard case .number(let x) = target["x"], case .number(let y) = target["y"] else {
    throw T3Error("Missing target")
  }
  let module = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("chromium-helper/cursor.mjs")
  let source = try String(contentsOf: module, encoding: .utf8)
  let context = JSContext()!
  guard
    let script = context.evaluateScript(
      source.replacingOccurrences(
        of: "export const cursorSource =", with: "globalThis.cursorSource ="))?.toString()
  else {
    throw T3Error("Could not evaluate the helper cursor module.")
  }
  let before = try await fixture.image()
  _ = try await fixture.web.evaluateJavaScript(script)
  _ = try await fixture.automation.script(
    "return JSON.stringify(await globalThis.__t3AgentCursor.move(x,y));",
    arguments: ["x": x, "y": y], world: .page,
    deadline: BrowserAutomationDeadline(milliseconds: 5000))
  let value =
    try await fixture.web.evaluateJavaScript("globalThis.__t3AgentCursor.state()") as? [String: Any]
  let point = value?["position"] as? [String: Double]
  #expect(point?["x"] == x && point?["y"] == y)
  #expect(value?["visible"] as? Bool == true)
  #expect(value?["animations"] as? Int == 0)
  let after = try await fixture.image()
  let png = try BrowserAnnotationRenderer.png(after)
  #expect(png != (try BrowserAnnotationRenderer.png(before)))
  try browserArtifactEvidence(png, name: "chromium-cursor-fixture.png")
  _ = try await fixture.web.evaluateJavaScript("globalThis.__t3AgentCursor.click()")
  _ = try await fixture.image()
  let visible =
    try await fixture.web.evaluateJavaScript("globalThis.__t3AgentCursor.state().visible") as? Bool
  #expect(visible == true)
  _ = try await fixture.web.evaluateJavaScript("globalThis.__t3AgentCursor.hide()")
  let hidden =
    try await fixture.web.evaluateJavaScript("globalThis.__t3AgentCursor.state().visible") as? Bool
  #expect(hidden == false)
}

@MainActor @Test func browserRecordingQuitSaveWaitsForRealCaptureAndEncoderCompletion() async throws
{
  let fixture = BrowserArtifactFixture()
  defer { fixture.close() }
  try await fixture.load()
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "t3-recording-quit-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let recording = BrowserRecording()
  var finishing: Task<URL, any Error>?
  try await recording.start(options: .init(), directory: directory) { options in
    if finishing == nil { finishing = Task { try await recording.finishForQuit() } }
    return try await fixture.image(options)
  }
  let file = try await finishing!.value
  #expect(recording.state == .saved(file))
  #expect(!recording.active)
  let decoded = try await AVAssetImageGenerator(asset: AVURLAsset(url: file)).image(at: .zero).image
  #expect(decoded.width > 0 && decoded.height > 0)
}
