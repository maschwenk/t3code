import AppKit
import T3Core
import WebKit

@MainActor enum BrowserCapture {
  static func image(
    web: WKWebView, cursor: BrowserAgentCursor, mouse: Bool = true,
    keys: Bool = true, deterministic: Bool = true
  ) async throws -> NSImage {
    guard web.bounds.width > 0, web.bounds.height > 0 else {
      throw T3Error("Browser viewport is empty.")
    }
    let configuration = WKSnapshotConfiguration()
    configuration.snapshotWidth = min(1_600, web.bounds.width) as NSNumber
    let image = try await web.takeSnapshot(configuration: configuration)
    let composed = NSImage(size: image.size, flipped: true) { rect in
      image.draw(
        in: rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
      cursor.drawCapture(size: rect.size, mouse: mouse, keys: keys, deterministic: deterministic)
      return true
    }
    // Materialize now; later rendering must not pick up another cursor position.
    guard let data = composed.tiffRepresentation, let frozen = NSImage(data: data) else {
      throw T3Error("Could not compose the browser screenshot.")
    }
    return frozen
  }
}
