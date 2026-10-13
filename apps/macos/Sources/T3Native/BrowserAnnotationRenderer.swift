import AppKit
import T3Core

@MainActor enum BrowserAnnotationRenderer {
  static func png(_ image: NSImage) throws -> Data {
    guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
      let data = bitmap.representation(using: .png, properties: [:])
    else { throw T3Error("Could not encode browser screenshot.") }
    return data
  }
  static func draw(_ annotations: [BrowserAnnotation], size: CGSize) {
    NSColor.systemRed.setStroke()
    for annotation in annotations {
      let points = annotation.points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
      guard let first = points.first, let last = points.last, points.count > 1 else { continue }
      let path = NSBezierPath()
      path.lineWidth = annotation.width
      path.lineCapStyle = .round
      path.lineJoinStyle = .round
      switch annotation.tool {
      case .pen:
        path.move(to: first)
        for point in points.dropFirst() { path.line(to: point) }
      case .rectangle:
        path.appendRect(
          CGRect(
            x: min(first.x, last.x), y: min(first.y, last.y),
            width: abs(first.x - last.x), height: abs(first.y - last.y)))
      case .arrow:
        path.move(to: first)
        path.line(to: last)
        let angle = atan2(last.y - first.y, last.x - first.x)
        for direction in [-1.0, 1.0] {
          path.move(to: last)
          path.line(
            to: CGPoint(
              x: last.x - 14 * cos(angle + direction * .pi / 6),
              y: last.y - 14 * sin(angle + direction * .pi / 6)))
        }
      }
      path.stroke()
    }
  }
  static func render(_ image: NSImage, document: BrowserAnnotationDocument) throws -> NSImage {
    try document.validate()
    let composed = NSImage(size: image.size, flipped: true) { rect in
      image.draw(
        in: rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
      draw(document.annotations, size: rect.size)
      return true
    }
    guard let image = NSImage(data: try png(composed)) else {
      throw T3Error("Could not render annotations.")
    }
    return image
  }
  static func save(_ image: NSImage, document: BrowserAnnotationDocument, directory: URL) throws
    -> URL
  {
    let image = try render(image, document: document)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let stem = "Annotated browser " + UUID().uuidString
    let pngURL = directory.appendingPathComponent(stem + ".png")
    let metadata = directory.appendingPathComponent(stem + ".json")
    do {
      try png(image).write(to: pngURL, options: .atomic)
      try document.serialized().write(to: metadata, options: .atomic)
    } catch {
      try? FileManager.default.removeItem(at: pngURL)
      try? FileManager.default.removeItem(at: metadata)
      throw error
    }
    return pngURL
  }
}
