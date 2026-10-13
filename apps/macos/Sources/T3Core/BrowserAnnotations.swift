import Foundation

public struct BrowserAnnotationPoint: Codable, Equatable, Sendable {
  public var x: Double
  public var y: Double
  public init(x: Double, y: Double) {
    self.x = x
    self.y = y
  }
}
public struct BrowserAnnotation: Codable, Equatable, Sendable {
  public enum Tool: String, Codable, Sendable { case pen, rectangle, arrow }
  public var tool: Tool
  public var points: [BrowserAnnotationPoint]
  public var width: Double
  public init(tool: Tool, points: [BrowserAnnotationPoint], width: Double = 3) {
    self.tool = tool
    self.points = points
    self.width = width
  }
}
public struct BrowserAnnotationDocument: Codable, Equatable, Sendable {
  public let version: Int
  public let pageURL: String
  public let capturedAt: Date
  public var annotations: [BrowserAnnotation]
  public init(pageURL: String, capturedAt: Date = Date(), annotations: [BrowserAnnotation] = []) {
    version = 1
    self.pageURL = pageURL
    self.capturedAt = capturedAt
    self.annotations = annotations
  }
  public func validate() throws {
    guard version == 1, pageURL.utf8.count <= 8192, annotations.count <= 1000,
      capturedAt.timeIntervalSince1970.isFinite
    else { throw T3Error("Invalid annotation document.") }
    var count = 0
    for annotation in annotations {
      count += annotation.points.count
      guard (0.5...16).contains(annotation.width), annotation.width.isFinite,
        annotation.points.count >= 2, count <= 100_000,
        annotation.tool == .pen || annotation.points.count == 2,
        annotation.points.allSatisfy({
          $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y)
        })
      else { throw T3Error("Invalid annotation geometry.") }
    }
  }
  public func serialized() throws -> Data {
    try validate()
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(self)
  }
  public static func deserialize(_ data: Data) throws -> Self {
    guard data.count <= 8 * 1024 * 1024 else { throw T3Error("Annotation document is too large.") }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let document = try decoder.decode(Self.self, from: data)
    try document.validate()
    return document
  }
}
