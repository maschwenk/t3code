import Foundation

public enum JSON: Codable, Sendable, Equatable {
  case object([String: JSON])
  case array([JSON])
  case string(String)
  case number(Double)
  case bool(Bool)
  case null

  public init(from decoder: any Decoder) throws {
    let value = try decoder.singleValueContainer()
    if value.decodeNil() {
      self = .null
    } else if let x = try? value.decode(Bool.self) {
      self = .bool(x)
    } else if let x = try? value.decode(String.self) {
      self = .string(x)
    } else if let x = try? value.decode(Double.self) {
      self = .number(x)
    } else if let x = try? value.decode([JSON].self) {
      self = .array(x)
    } else {
      self = .object(try value.decode([String: JSON].self))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var value = encoder.singleValueContainer()
    switch self {
    case .object(let x): try value.encode(x)
    case .array(let x): try value.encode(x)
    case .string(let x): try value.encode(x)
    case .number(let x): try value.encode(x)
    case .bool(let x): try value.encode(x)
    case .null: try value.encodeNil()
    }
  }

  public subscript(_ key: String) -> JSON {
    guard case .object(let x) = self else { return .null }
    return x[key] ?? .null
  }
  public var string: String? { if case .string(let x) = self { x } else { nil } }
  public var array: [JSON] { if case .array(let x) = self { x } else { [] } }
  public var int: Int? {
    if case .number(let x) = self, x.isFinite, x >= 0, x < Double(Int.max) { Int(x) } else { nil }
  }
  public var bool: Bool { self == .bool(true) }
  public func requiredString(_ key: String) throws -> String {
    guard let x = self[key].string else { throw T3Error("Missing field: \(key)") }
    return x
  }
  public func requiredInt(_ key: String) throws -> Int {
    guard let x = self[key].int else { throw T3Error("Missing sequence: \(key)") }
    return x
  }
  public func data() throws -> Data { try JSONEncoder().encode(self) }
  public var displayText: String {
    if let string { return string }
    if self == .null { return "" }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
  }
  public static func decode(_ data: Data) throws -> JSON {
    try JSONDecoder().decode(JSON.self, from: data)
  }
}

public struct T3Error: LocalizedError, Sendable {
  public let message: String
  public let authentication: Bool
  public let remoteCode: String?
  public let remoteFailure: String?
  public init(
    _ message: String, authentication: Bool = false,
    remoteCode: String? = nil, remoteFailure: String? = nil
  ) {
    self.message = message
    self.authentication = authentication
    self.remoteCode = remoteCode
    self.remoteFailure = remoteFailure
  }
  public var errorDescription: String? { message }
}
