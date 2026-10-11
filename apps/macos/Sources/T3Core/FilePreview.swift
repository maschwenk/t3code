import Foundation

public enum FilePreviewKind: String, Sendable {
  case markdown, csv, tsv, html, source
  public init(path: String) {
    switch (path as NSString).pathExtension.lowercased() {
    case "md", "mdx": self = .markdown
    case "csv": self = .csv
    case "tsv": self = .tsv
    case "htm", "html": self = .html
    default: self = .source
    }
  }
  public var delimiter: UInt16? {
    switch self {
    case .csv: 44
    case .tsv: 9
    default: nil
    }
  }
}

public struct DelimitedFilePreview: Equatable, Sendable {
  public let rows: [[String]]
  public let truncated: Bool
  public init(_ source: String, delimiter: UInt16) {
    let text = Array(source.utf16)
    var rows: [[String]] = []
    var row: [String] = []
    var cell: [UInt16] = []
    var quoted = false
    var truncated = false
    var rowStart = text.first == 0xfeff ? 1 : 0
    var index = rowStart
    func endCell() {
      if row.count < 30 {
        row.append(String(decoding: cell, as: UTF16.self))
      } else {
        truncated = true
      }
      cell.removeAll(keepingCapacity: true)
    }
    while index < text.count {
      let char = text[index]
      if char == 34 {
        if quoted && index + 1 < text.count && text[index + 1] == 34 {
          if cell.count < 2000 { cell.append(34) } else { truncated = true }
          index += 2
          continue
        }
        if quoted || cell.isEmpty {
          quoted.toggle()
          index += 1
          continue
        }
      }
      if !quoted && (char == delimiter || char == 10 || char == 13) {
        endCell()
        if char != delimiter {
          rows.append(row)
          row = []
          if char == 13 && index + 1 < text.count && text[index + 1] == 10 { index += 1 }
          rowStart = index + 1
          if rows.count == 100 {
            self.rows = rows
            self.truncated = truncated || index < text.count - 1
            return
          }
        }
      } else if cell.count < 2000 {
        cell.append(char)
      } else {
        truncated = true
      }
      index += 1
    }
    if rowStart < text.count {
      endCell()
      rows.append(row)
    }
    self.rows = rows
    self.truncated = truncated || quoted
  }
}

public enum WorkspaceMarkdown {
  public static func settingTask(_ source: String, offset: Int, checked: Bool) -> String {
    let text = source as NSString
    guard offset >= 0, offset <= text.length - 3,
      text.character(at: offset) == 91, text.character(at: offset + 2) == 93,
      [32, 88, 120].contains(text.character(at: offset + 1))
    else { return source }
    return text.replacingCharacters(
      in: NSRange(location: offset + 1, length: 1), with: checked ? "x" : " ")
  }

  public static func link(_ destination: String, filePath: String, root: String?) -> URL? {
    var destination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
    if destination.hasPrefix("<") && destination.hasSuffix(">") {
      destination = String(destination.dropFirst().dropLast())
    }
    guard !destination.isEmpty else { return nil }
    if let url = URL(string: destination), let scheme = url.scheme,
      ["http", "https", "mailto", "file"].contains(scheme.lowercased())
    {
      return url
    }
    guard let root else { return nil }
    // Bare filenames with :line look like URL schemes to Foundation.
    if let url = URL(string: destination), url.scheme != nil {
      let parsed = WorkspaceFileLink.split(destination)
      guard parsed.path != destination,
        !(parsed.path as NSString).pathExtension.isEmpty
          || ["Makefile", "Dockerfile", "README", "LICENSE", "AGENTS"].contains(parsed.path)
      else { return nil }
      destination = "./" + destination
    }
    guard let parts = URLComponents(string: destination), parts.host == nil else { return nil }
    if parts.path.isEmpty {
      guard !filePath.isEmpty,
        WorkspaceFileLink.split("", fragment: parts.fragment).position != nil
      else { return nil }
    }
    let base =
      filePath.hasPrefix("/") ? filePath : (root as NSString).appendingPathComponent(filePath)
    let directory = filePath.isEmpty ? root : (base as NSString).deletingLastPathComponent
    let path =
      parts.path.isEmpty
      ? base
      : parts.path.hasPrefix("/")
        ? parts.path
        : (directory as NSString).appendingPathComponent(parts.path)
    var result = URLComponents(
      url: URL(fileURLWithPath: (path as NSString).standardizingPath),
      resolvingAgainstBaseURL: false)
    result?.fragment = parts.fragment
    return result?.url
  }

  public static func workspacePath(_ url: URL, root: String) -> String? {
    guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else {
      return nil
    }
    let path = (url.path as NSString).standardizingPath
    let root = (root as NSString).standardizingPath
    if path == root { return "." }
    let prefix = root == "/" ? "/" : root + "/"
    return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
  }
}

public struct FilePreviewPreferences {
  private let defaults: UserDefaults
  public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
  public func rendered(_ kind: FilePreviewKind) -> Bool {
    switch kind {
    case .markdown: defaults.bool(forKey: "filePreview.renderMarkdown")
    case .csv, .tsv: defaults.object(forKey: "filePreview.renderTable") as? Bool ?? true
    case .html: defaults.object(forKey: "filePreview.renderHTML") as? Bool ?? true
    case .source: false
    }
  }
  public func setRendered(_ value: Bool, for kind: FilePreviewKind) {
    switch kind {
    case .markdown: defaults.set(value, forKey: "filePreview.renderMarkdown")
    case .csv, .tsv: defaults.set(value, forKey: "filePreview.renderTable")
    case .html: defaults.set(value, forKey: "filePreview.renderHTML")
    case .source: break
    }
  }
}
