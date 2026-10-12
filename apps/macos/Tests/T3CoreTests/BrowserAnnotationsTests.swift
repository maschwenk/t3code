import Foundation
import Testing

@testable import T3Core

@Test func browserAnnotationSerializationRoundTripsNormalizedGeometry() throws {
  let document = BrowserAnnotationDocument(
    pageURL: "https://example.test/scrolled",
    capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
    annotations: [
      .init(tool: .pen, points: [.init(x: 0, y: 0), .init(x: 0.4, y: 0.8), .init(x: 1, y: 1)]),
      .init(tool: .rectangle, points: [.init(x: 0.2, y: 0.3), .init(x: 0.8, y: 0.9)]),
      .init(tool: .arrow, points: [.init(x: 0.5, y: 0.1), .init(x: 0.3, y: 0.7)], width: 6),
    ])
  let data = try document.serialized()
  #expect(try BrowserAnnotationDocument.deserialize(data) == document)
}

@Test func browserAnnotationDeserializationRejectsCorruptAndUnboundedGeometry() throws {
  let data = Data(
    """
    {"version":1,"pageURL":"https://example.test","capturedAt":"2026-10-12T00:00:00Z",
    "annotations":[{"tool":"rectangle","width":3,"points":[{"x":1.1,"y":0},{"x":0,"y":1}]}]}
    """.utf8)
  #expect(throws: (any Error).self) { try BrowserAnnotationDocument.deserialize(data) }
  #expect(throws: (any Error).self) {
    try BrowserAnnotationDocument.deserialize(Data("broken".utf8))
  }
  let document = BrowserAnnotationDocument(
    pageURL: "",
    annotations: [
      .init(tool: .pen, points: Array(repeating: .init(x: 0, y: 0), count: 100_001))
    ])
  #expect(throws: (any Error).self) { try document.serialized() }
}
