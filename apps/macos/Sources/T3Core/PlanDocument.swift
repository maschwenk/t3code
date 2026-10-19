import Foundation

public struct PlanDocument: Equatable, Sendable {
  public let heading: String?
  public let body: String
  public let preview: String
  public let canCollapse: Bool
  public let filename: String
  public let contents: String
  public var title: String { heading ?? "Proposed plan" }

  public init(_ markdown: String) {
    let trimmed = Self.trimEnd(markdown)
    contents = trimmed + "\n"
    var lines = ArraySlice(
      trimmed.replacingOccurrences(of: "\r\n", with: "\n")
        .components(separatedBy: "\n"))
    heading = lines.lazy.compactMap(Self.heading).first
    var name = (heading ?? "plan").lowercased().replacingOccurrences(
      of: #"[`'".,!?()\[\]{}]+"#, with: "", options: .regularExpression
    )
    .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
    .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    if name.isEmpty { name = "plan" }
    filename = name + ".md"
    canCollapse = markdown.utf16.count > 900 || markdown.components(separatedBy: "\n").count > 20
    if let first = lines.first, Self.heading(first) != nil { lines = lines.dropFirst() }
    lines = lines.drop { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    if let first = lines.first, Self.heading(first)?.lowercased() == "summary" {
      lines = lines.dropFirst().drop { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    body = lines.joined(separator: "\n")
    var previewLines: [String] = []
    var count = 0
    var overflow = false
    for line in lines {
      let line = Self.trimEnd(line)
      let visible = !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      if visible && count == 10 {
        overflow = true
        break
      }
      previewLines.append(line)
      if visible { count += 1 }
    }
    while previewLines.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
      previewLines.removeLast()
    }
    if previewLines.isEmpty {
      preview = heading ?? "Plan preview unavailable."
    } else {
      if overflow { previewLines += ["", "..."] }
      preview = previewLines.joined(separator: "\n")
    }
  }

  public static func heading(_ line: String) -> String? {
    guard line.range(of: #"^\s{0,3}#{1,6}\s+(.+)$"#, options: .regularExpression) != nil else {
      return nil
    }
    let result = line.replacingOccurrences(
      of: #"^\s{0,3}#{1,6}\s+"#, with: "", options: .regularExpression
    )
    .trimmingCharacters(in: .whitespacesAndNewlines)
    return result.isEmpty ? nil : result
  }

  private static func trimEnd(_ value: String) -> String {
    String(value.dropLast(value.reversed().prefix { $0.isWhitespace }.count))
  }

  public func save(to url: URL) async throws {
    let contents = contents
    try await Task.detached {
      try contents.write(to: url, atomically: true, encoding: .utf8)
    }.value
  }
}

public struct WorkspaceLocation: Equatable, Sendable {
  public let environment: String
  public let threadID: String
  public let root: String
  public init?(environment: String, thread: ThreadSummary, project: JSON) {
    guard let root = thread.worktreePath ?? project["workspaceRoot"].string, !root.isEmpty else {
      return nil
    }
    self.environment = environment
    threadID = thread.id
    self.root = root
  }

  public func writeInput(relativePath: String, contents: String) throws -> JSON {
    let path = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty else { throw T3Error("Enter a workspace path.") }
    return .object([
      "cwd": .string(root), "relativePath": .string(path), "contents": .string(contents),
    ])
  }
}
