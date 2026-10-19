import Foundation

public enum WorkspaceDefaults {
  /// Nil means inherit from t3.json; a present null override masks the environment and legacy value.
  public static func configuredMode(settings: JSON, project: JSON) -> String? {
    if let projectID = project["id"].string,
      case .object(let overrides) = settings["projectSettingsOverrides"][projectID],
      let value = overrides["defaultThreadEnvMode"]
    {
      return mode(value)
    }
    if !settings["projectSettingsFolded"].bool, project["defaultThreadEnvMode"] != .null {
      return mode(project["defaultThreadEnvMode"])
    }
    return mode(settings["defaultThreadEnvMode"])
  }

  /// Invalid files, files over 1 MiB or depth 64, and absent modes defer to the local default.
  public static func fileMode(contents: String) -> String? {
    guard contents.utf8.count <= 1_048_576, let bytes = jsonc(contents) else { return nil }
    var reader = JSONCReader(bytes: bytes)
    guard case .object(let fields) = reader.parse(), validProjectFile(fields) else { return nil }
    return mode(fields["defaultThreadEnvMode"] ?? .null)
  }

  private static func mode(_ value: JSON) -> String? {
    guard let string = value.string, string == "local" || string == "worktree" else { return nil }
    return string
  }

  // Matches packages/contracts/src/t3ProjectFile.ts. Unknown fields are ignored by that decoder.
  private static func validProjectFile(_ fields: [String: JSON]) -> Bool {
    if let schema = fields["$schema"], schema.string == nil { return false }
    if let icon = fields["iconPath"], !nonempty(icon, maxLength: 512) { return false }
    if let value = fields["defaultThreadEnvMode"], mode(value) == nil { return false }
    if let value = fields["worktreeSubmodules"],
      !["recursive", "top-level", "none"].contains(value.string ?? "")
    {
      return false
    }
    if let scripts = fields["scripts"] {
      guard case .array(let values) = scripts, values.count <= 50 else { return false }
      for script in values {
        guard case .object(let fields) = script,
          nonempty(script["name"]), nonempty(script["command"])
        else { return false }
        if let icon = fields["icon"],
          !["play", "test", "lint", "configure", "build", "debug"].contains(icon.string ?? "")
        {
          return false
        }
        if let url = fields["previewUrl"], !nonempty(url) { return false }
        for key in ["runOnWorktreeCreate", "async", "autoOpenPreview"] {
          if let value = fields[key] {
            guard case .bool = value else { return false }
          }
        }
      }
    }
    return true
  }

  private static func nonempty(_ value: JSON, maxLength: Int? = nil) -> Bool {
    guard let string = value.string,
      !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return false }
    return maxLength.map { string.utf16.count <= $0 } ?? true
  }

  private static func jsonc(_ contents: String) -> [UInt8]? {
    let input = Array(contents.utf8)
    var bytes: [UInt8] = []
    bytes.reserveCapacity(input.count)
    var index = 0
    var quoted = false
    var escaped = false
    while index < input.count {
      let byte = input[index]
      if quoted {
        bytes.append(byte)
        if escaped {
          escaped = false
        } else if byte == 92 {
          escaped = true
        } else if byte == 34 {
          quoted = false
        }
        index += 1
      } else if byte == 34 {
        quoted = true
        bytes.append(byte)
        index += 1
      } else if byte == 47 && index + 1 < input.count && input[index + 1] == 47 {
        index += 2
        while index < input.count && input[index] != 10 && input[index] != 13 { index += 1 }
        bytes.append(32)
      } else if byte == 47 && index + 1 < input.count && input[index + 1] == 42 {
        index += 2
        while index + 1 < input.count && !(input[index] == 42 && input[index + 1] == 47) {
          index += 1
        }
        guard index + 1 < input.count else { return nil }
        index += 2
        bytes.append(32)
      } else {
        bytes.append(byte)
        index += 1
      }
    }
    guard !quoted else { return nil }

    var previous: UInt8?
    for index in bytes.indices {
      let byte = bytes[index]
      if quoted {
        if escaped {
          escaped = false
        } else if byte == 92 {
          escaped = true
        } else if byte == 34 {
          quoted = false
        }
      } else if byte == 34 {
        quoted = true
      } else if byte == 44 {
        var next = index + 1
        while next < bytes.count && whitespace(bytes[next]) { next += 1 }
        if next < bytes.count && (bytes[next] == 93 || bytes[next] == 125) {
          guard let previous, ![44, 91, 123, 58].contains(previous) else { return nil }
          bytes[index] = 32
        }
      }
      if !whitespace(byte) { previous = byte }
    }
    return bytes
  }

  private static func whitespace(_ byte: UInt8) -> Bool {
    byte == 32 || byte == 9 || byte == 10 || byte == 13
  }

  // Foundation object decoders keep the first duplicate key. Build objects in source order
  // to match JSON.parse, and let Foundation validate scalar escapes, literals and numbers.
  private struct JSONCReader {
    let bytes: [UInt8]
    var index = 0

    mutating func parse() -> JSON? {
      guard let value = value(depth: 0) else { return nil }
      skipWhitespace()
      return index == bytes.count ? value : nil
    }

    private mutating func skipWhitespace() {
      while index < bytes.count && WorkspaceDefaults.whitespace(bytes[index]) { index += 1 }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
      skipWhitespace()
      guard index < bytes.count, bytes[index] == byte else { return false }
      index += 1
      return true
    }

    private mutating func value(depth: Int) -> JSON? {
      skipWhitespace()
      guard depth <= 64, index < bytes.count else { return nil }
      if consume(123) {
        var fields: [String: JSON] = [:]
        if consume(125) { return .object(fields) }
        while true {
          guard let key = string(), consume(58), let child = value(depth: depth + 1) else {
            return nil
          }
          fields[key] = child
          if consume(125) { return .object(fields) }
          guard consume(44) else { return nil }
        }
      }
      if consume(91) {
        var values: [JSON] = []
        if consume(93) { return .array(values) }
        while true {
          guard let child = value(depth: depth + 1) else { return nil }
          values.append(child)
          if consume(93) { return .array(values) }
          guard consume(44) else { return nil }
        }
      }
      if bytes[index] == 34 { return string().map(JSON.string) }
      let start = index
      while index < bytes.count && !WorkspaceDefaults.whitespace(bytes[index])
        && ![123, 125, 91, 93, 44, 58, 34].contains(bytes[index])
      { index += 1 }
      guard index > start else { return nil }
      return try? JSON.decode(Data(bytes[start..<index]))
    }

    private mutating func string() -> String? {
      skipWhitespace()
      let start = index
      guard consume(34) else { return nil }
      while index < bytes.count {
        let byte = bytes[index]
        index += 1
        if byte == 92 {
          index += 1
        } else if byte == 34 {
          return (try? JSON.decode(Data(bytes[start..<index])))?.string
        }
      }
      return nil
    }
  }
}
