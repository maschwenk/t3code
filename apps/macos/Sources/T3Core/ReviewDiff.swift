import Foundation

public struct DiffLine: Equatable, Sendable {
  public enum Kind: Sendable { case context, addition, deletion, hunk, metadata, gap }
  public let kind: Kind
  public let text: String
  public let oldLine: Int?
  public let newLine: Int?
  public var oldText: String? = nil
  public var contextID: Int? = nil
}

public struct DiffFile: Equatable, Sendable {
  public var path: String
  public var previousPath: String?
  public var lines: [DiffLine] = []
  public var rawPatch = ""
  public var isDeleted = false
  public var isNew = false
  public var isBinary = false
  public var incomplete = false
  public var additions: Int { lines.lazy.filter { $0.kind == .addition }.count }
  public var deletions: Int { lines.lazy.filter { $0.kind == .deletion }.count }
}

public enum UnifiedDiff {
  public static func parse(_ text: String) -> [DiffFile] {
    var files: [DiffFile] = []
    var file: DiffFile?
    var old = 0
    var new = 0
    var oldRemaining = 0
    var newRemaining = 0
    var start = text.utf8.startIndex
    func finish(at end: String.UTF8View.Index) {
      if var value = file {
        value.rawPatch = String(decoding: text.utf8[start..<end], as: UTF8.self)
        value.incomplete = value.incomplete || oldRemaining > 0 || newRemaining > 0
        files.append(value)
      }
      file = nil
      oldRemaining = 0
      newRemaining = 0
    }
    // Split on LF only: a CR in a changed line belongs to the file's contents.
    for raw in text.utf8.split(separator: 10, omittingEmptySubsequences: false) {
      let line = String(decoding: raw, as: UTF8.self)
      if line.hasPrefix("diff --git ") {
        finish(at: raw.startIndex)
        start = raw.startIndex
        let paths = headerPaths(String(line.dropFirst(11)))
        file = DiffFile(path: paths.1, previousPath: paths.0 == paths.1 ? nil : paths.0)
        continue
      }
      guard file != nil else { continue }
      if line.hasPrefix("@@ ") {
        if oldRemaining > 0 || newRemaining > 0 { file?.incomplete = true }
        let text = line as NSString
        if let match = hunk.firstMatch(in: line, range: NSRange(location: 0, length: text.length)) {
          func number(_ index: Int, default fallback: Int = 1) -> Int {
            let range = match.range(at: index)
            return range.location == NSNotFound ? fallback : Int(text.substring(with: range)) ?? 0
          }
          old = number(1)
          new = number(3)
          oldRemaining = number(2)
          newRemaining = number(4)
          file?.lines.append(DiffLine(kind: .hunk, text: line, oldLine: nil, newLine: nil))
          continue
        }
        file?.incomplete = true
      }
      if line.hasPrefix("\\ No newline at end of file") {
        file?.lines.append(DiffLine(kind: .metadata, text: line, oldLine: nil, newLine: nil))
        continue
      }
      if oldRemaining > 0 || newRemaining > 0 {
        let kind: DiffLine.Kind?
        switch raw.first {
        case 32 where oldRemaining > 0 && newRemaining > 0: kind = .context
        case 43 where newRemaining > 0: kind = .addition
        case 45 where oldRemaining > 0: kind = .deletion
        default: kind = nil
        }
        if let kind {
          file?.lines.append(
            DiffLine(
              kind: kind, text: String(decoding: raw.dropFirst(), as: UTF8.self),
              oldLine: kind == .addition ? nil : old, newLine: kind == .deletion ? nil : new))
          if kind != .addition {
            old += 1
            oldRemaining -= 1
          }
          if kind != .deletion {
            new += 1
            newRemaining -= 1
          }
          continue
        }
        file?.incomplete = true
        oldRemaining = 0
        newRemaining = 0
      }
      if line.hasPrefix("--- ") {
        let path = patchPath(String(line.dropFirst(4)), prefix: "a/")
        if path == "/dev/null" { file?.isNew = true }
        if path != "/dev/null", path != file?.path { file?.previousPath = path }
      } else if line.hasPrefix("+++ ") {
        let path = patchPath(String(line.dropFirst(4)), prefix: "b/")
        if path == "/dev/null" { file?.isDeleted = true } else { file?.path = path }
      } else if line.hasPrefix("rename from ") {
        file?.previousPath = unquote(String(line.dropFirst(12)))
      } else if line.hasPrefix("rename to ") {
        file?.path = unquote(String(line.dropFirst(10)))
      } else if line.hasPrefix("Binary files ") || line == "GIT binary patch" {
        file?.isBinary = true
      } else if line.hasPrefix("deleted file mode ") {
        file?.isDeleted = true
      } else if line.hasPrefix("new file mode ") {
        file?.isNew = true
      }
      if !line.isEmpty {
        file?.lines.append(DiffLine(kind: .metadata, text: line, oldLine: nil, newLine: nil))
      }
    }
    finish(at: text.utf8.endIndex)
    return files
  }

  private static let hunk = try! NSRegularExpression(
    pattern: "^@@ -([0-9]+)(?:,([0-9]+))? \\+([0-9]+)(?:,([0-9]+))? @@")

  private static func patchPath(_ source: String, prefix: String) -> String {
    let value = unquote(
      source.split(separator: "\t", maxSplits: 1).first.map(String.init) ?? source)
    return value.hasPrefix(prefix) ? String(value.dropFirst(prefix.count)) : value
  }

  private static func headerPaths(_ source: String) -> (String, String) {
    if source.hasPrefix("\"") {
      var escaped = false
      for index in source.indices.dropFirst() {
        let character = source[index]
        if character == "\"" && !escaped {
          let end = source.index(after: index)
          return (
            patchPath(String(source[..<end]), prefix: "a/"),
            patchPath(String(source[end...]).trimmingCharacters(in: .whitespaces), prefix: "b/")
          )
        }
        escaped = character == "\\" && !escaped
      }
    }
    // Git leaves spaces unquoted. Prefer an equal pair before the rename fallback.
    var search = source.startIndex..<source.endIndex
    var fallback: (String, String)?
    while let split = source.range(of: " b/", range: search) {
      let pair = (
        patchPath(String(source[..<split.lowerBound]), prefix: "a/"),
        patchPath(String(source[source.index(after: split.lowerBound)...]), prefix: "b/")
      )
      if pair.0 == pair.1 { return pair }
      fallback = pair
      search = split.upperBound..<source.endIndex
    }
    return fallback ?? (source, source)
  }

  static func unquote(_ value: String) -> String {
    guard value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
    let bytes = Array(value.utf8.dropFirst().dropLast())
    var decoded: [UInt8] = []
    var index = 0
    while index < bytes.count {
      let byte = bytes[index]
      index += 1
      guard byte == 92, index < bytes.count else {
        decoded.append(byte)
        continue
      }
      let next = bytes[index]
      index += 1
      if (48...55).contains(next) {
        var octal = Int(next - 48)
        for _ in 0..<2 where index < bytes.count && (48...55).contains(bytes[index]) {
          octal = octal * 8 + Int(bytes[index] - 48)
          index += 1
        }
        decoded.append(UInt8(truncatingIfNeeded: octal))
      } else {
        decoded.append([97: 7, 98: 8, 116: 9, 110: 10, 118: 11, 102: 12, 114: 13][next] ?? next)
      }
    }
    return String(decoding: decoded, as: UTF8.self)
  }
}

public struct ReviewFile: Equatable, Sendable {
  public let path: String
  public let previousPath: String?
  public let additions: Int
  public let deletions: Int
  public init(path: String, previousPath: String?, additions: Int, deletions: Int) {
    self.path = path
    self.previousPath = previousPath
    self.additions = additions
    self.deletions = deletions
  }
  public init(_ patch: DiffFile) {
    self.init(
      path: patch.path, previousPath: patch.previousPath,
      additions: patch.additions, deletions: patch.deletions)
  }
  public var input: [String: JSON] {
    ["path": .string(path), "previousPath": previousPath.map(JSON.string) ?? .null]
  }
}

public struct ReviewSource: Equatable, Sendable {
  public let kind: String
  public let title: String
  public let baseRef: String?
  public let hash: String
  public let truncated: Bool
  public let completeFileList: Bool
  public let files: [ReviewFile]

  public init(
    kind: String, title: String, hash: String, patches: [DiffFile], outputLimited: Bool = false
  ) {
    self.kind = kind
    self.title = title
    self.hash = hash
    baseRef = nil
    truncated = outputLimited || patches.contains(where: \.incomplete)
    completeFileList = !truncated
    files = patches.map(ReviewFile.init).sorted {
      $0.path.localizedStandardCompare($1.path) == .orderedAscending
    }
  }

  public init(_ value: JSON) throws {
    kind = try value.requiredString("kind")
    title = try value.requiredString("title")
    baseRef = value["baseRef"].string
    hash = try value.requiredString("diffHash")
    truncated = value["truncated"].bool
    completeFileList = value["files"] != .null
    let list: [ReviewFile]
    if completeFileList {
      list = try value["files"].array.map {
        ReviewFile(
          path: try $0.requiredString("path"), previousPath: $0["previousPath"].string,
          additions: $0["additions"].int ?? 0, deletions: $0["deletions"].int ?? 0)
      }
    } else {
      list = UnifiedDiff.parse(value["diff"].string ?? "").map {
        ReviewFile(
          path: $0.path, previousPath: $0.previousPath,
          additions: $0.additions, deletions: $0.deletions)
      }
    }
    var seen: Set<String> = []
    files = list.filter { seen.insert($0.path).inserted }
      .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
  }
}

public struct ReviewSnapshot: Sendable {
  public let root: String
  public let sources: [ReviewSource]
  public init(root: String, sources: [ReviewSource]) {
    self.root = root
    self.sources = sources
  }
  public init(_ value: JSON) throws {
    root = try value.requiredString("cwd")
    sources = try value["sources"].array.map(ReviewSource.init)
  }
}
