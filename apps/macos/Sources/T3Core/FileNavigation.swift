import Foundation

public struct FileSourcePosition: Equatable, Sendable {
  public let line: Int
  public let column: Int?

  public init(line: Int, column: Int? = nil) {
    self.line = max(1, line)
    self.column = column.map { max(1, $0) }
  }

  public func range(in source: String) -> NSRange {
    let text = source as NSString
    var start = 0
    var currentLine = 1
    var index = 0
    while index < text.length && currentLine < line {
      let unit = text.character(at: index)
      index += 1
      if unit == 13 || unit == 10 {
        if unit == 13 && index < text.length && text.character(at: index) == 10 { index += 1 }
        start = index
        currentLine += 1
      }
    }
    var end = start
    while end < text.length && ![10, 13].contains(text.character(at: end)) { end += 1 }
    guard let column else { return NSRange(location: start, length: end - start) }
    var offset = start + min(column - 1, end - start)
    if offset < end { offset = text.rangeOfComposedCharacterSequence(at: offset).location }
    return NSRange(location: offset, length: 0)
  }
}

public struct WorkspaceFileLink: Equatable, Sendable {
  public let path: String
  public let position: FileSourcePosition?

  public init?(url: URL, root: String) {
    guard let path = WorkspaceMarkdown.workspacePath(url, root: root) else { return nil }
    let parsed = Self.split(
      path, fragment: URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment)
    self.path = parsed.path
    position = parsed.position
  }

  static func split(_ path: String, fragment: String? = nil)
    -> (path: String, position: FileSourcePosition?)
  {
    let text = path as NSString
    let suffix = positionSuffix.firstMatch(
      in: path, range: NSRange(location: 0, length: text.length))
    let fragmentText = (fragment ?? "") as NSString
    let anchor = positionAnchor.firstMatch(
      in: fragmentText as String, range: NSRange(location: 0, length: fragmentText.length))
    guard let match = suffix ?? anchor else { return (path, nil) }
    let matchedText = suffix == nil ? fragmentText : text
    let line = Int(matchedText.substring(with: match.range(at: 1)))
    let column =
      match.range(at: 2).location == NSNotFound
      ? nil : Int(matchedText.substring(with: match.range(at: 2)))
    return (
      suffix.map { text.substring(to: $0.range.location) } ?? path,
      line.flatMap {
        $0 > 0 ? FileSourcePosition(line: $0, column: column.flatMap { $0 > 0 ? $0 : nil }) : nil
      }
    )
  }

  private static let positionSuffix = try! NSRegularExpression(pattern: ":([0-9]+)(?::([0-9]+))?$")
  private static let positionAnchor = try! NSRegularExpression(
    pattern: "^L([0-9]+)(?:C([0-9]+))?$", options: .caseInsensitive)
}
