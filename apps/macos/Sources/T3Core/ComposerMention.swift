import Foundation

public struct ComposerMention: Equatable, Sendable {
  public enum Kind: String, Sendable { case file, skill, command }
  public let kind: Kind
  public let query: String
  public let range: NSRange

  public static func detect(text: String, cursor: Int) -> Self? {
    let source = text as NSString
    guard cursor >= 0, cursor <= source.length else { return nil }
    let prefix = source.substring(to: cursor) as NSString
    var start = cursor
    while start > 0, !whitespace(prefix.character(at: start - 1)) { start -= 1 }
    let token = prefix.substring(from: start)
    guard let sigil = token.first else { return nil }
    let kind: Kind
    switch sigil {
    case "@": kind = .file
    case "$": kind = .skill
    case "/": kind = .command
    default: return nil
    }
    let query = String(token.dropFirst())
    guard query.utf16.count <= 256 else { return nil }
    if kind == .skill, !query.isEmpty,
      query.range(of: #"^[0-9][0-9_]*(?:[kKmMbBtT]|[eE][0-9]+)?$"#, options: .regularExpression)
        != nil
    {
      return nil
    }
    var end = cursor
    while end < source.length, !whitespace(source.character(at: end)) { end += 1 }
    return Self(kind: kind, query: query, range: NSRange(location: start, length: end - start))
  }

  private static func whitespace(_ unit: UInt16) -> Bool {
    UnicodeScalar(unit).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
  }

  public func insertion(in text: String, replacement: String) -> (
    range: NSRange, replacement: String
  ) {
    let source = text as NSString
    var range = range
    if NSMaxRange(range) < source.length, source.character(at: NSMaxRange(range)) == 32 {
      range.length += 1
    }
    return (range, replacement + " ")
  }

  public enum FileFormat: Sendable { case markdownLink, absoluteLiteral }
  public static func fileReference(path: String, root: String, format: FileFormat = .markdownLink)
    -> String
  {
    if format == .absoluteLiteral {
      if path.hasPrefix("/")
        || path.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil
      {
        return path
      }
      let separator = root.contains("\\") ? "\\" : "/"
      return root + (root.hasSuffix(separator) ? "" : separator) + path
    }
    let basename =
      path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init)
      ?? path
    let label = basename.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
    // Matches serializeComposerFileLink in packages/shared/src/composerTrigger.ts.
    let allowed = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789;/,:@&=+$-_.!~*'"
    )
    return "[\(label)](\(path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path))"
  }
}

public struct ComposerSuggestion: Equatable, Sendable, Identifiable {
  public let id: String
  public let kind: ComposerMention.Kind
  public let name: String
  public let label: String
  public let detail: String
  public let path: String?
  public let isDirectory: Bool
  public var localCommand: String? = nil

  /// Local actions work anywhere; provider commands only expand at the start of a prompt.
  public static func slashItems(
    providerItems: [Self], mention: ComposerMention, localCommandsEnabled: Bool,
    planModeEnabled: Bool, interactionModeSupported: Bool, limit: Int = 40
  ) -> [Self] {
    guard mention.kind == .command else { return [] }
    var items: [Self] = []
    if localCommandsEnabled {
      let names =
        ["model"] + (planModeEnabled && interactionModeSupported ? ["plan", "default"] : [])
      items = names.map { name in
        Self(
          id: "local:" + name, kind: .command, name: name, label: "/" + name,
          detail: name == "model"
            ? "Switch response model for this thread"
            : name == "plan"
              ? "Switch this thread into plan mode"
              : "Switch this thread back to normal build mode",
          path: nil, isDirectory: false, localCommand: name)
      }
    }
    if mention.range.location == 0 {
      items += providerItems.filter { $0.kind == .command && $0.localCommand == nil }
    }
    return ranked(items, query: mention.query, limit: limit)
  }

  public static func files(_ result: JSON, limit: Int = 40) -> [Self] {
    var seen: Set<String> = []
    return result["entries"].array.compactMap { entry in
      guard let path = entry["path"].string, !path.isEmpty, seen.insert(path).inserted,
        ["file", "directory"].contains(entry["kind"].string ?? "")
      else { return nil }
      return Self(
        id: "file:" + path, kind: .file, name: path,
        label: (path as NSString).lastPathComponent, detail: path, path: path,
        isDirectory: entry["kind"].string == "directory")
    }.prefix(max(0, limit)).map { $0 }
  }

  public static func providerItems(
    _ provider: JSON, cwd: String, kind: ComposerMention.Kind,
    query: String, allowCompact: Bool = false, limit: Int = 40
  ) -> [Self] {
    guard kind != .file, provider["enabled"].bool, provider["installed"].bool,
      provider["status"].string != "disabled", provider["availability"].string != "unavailable"
    else { return [] }
    let snapshot =
      provider["workspaceSnapshots"].array.first { $0["cwd"].string == cwd } ?? provider
    let values = snapshot[kind == .skill ? "skills" : "slashCommands"].array
    var seen: Set<String> = []
    let items: [Self] = values.compactMap { item in
      guard let name = item["name"].string, !name.isEmpty,
        !name.contains(where: { $0.isWhitespace })
      else { return nil }
      if kind == .skill {
        guard item["enabled"].bool, item["userInvocable"] != .bool(false),
          name.range(of: #"^[a-zA-Z0-9][a-zA-Z0-9:_-]*$"#, options: .regularExpression) != nil,
          ComposerMention.detect(text: "$" + name, cursor: name.utf16.count + 1) != nil
        else { return nil }
      } else if name == "compact", !allowCompact {
        return nil
      }
      guard seen.insert(name.lowercased()).inserted else { return nil }
      return Self(
        id: kind.rawValue + ":" + name, kind: kind, name: name,
        label: kind == .command ? "/" + name : item["displayName"].string ?? "$" + name,
        detail: item["shortDescription"].string ?? item["description"].string ?? item["input"][
          "hint"
        ].string ?? item["scope"].string ?? "",
        path: item["path"].string, isDirectory: false)
    }
    return ranked(items, query: query, limit: limit)
  }

  private static func ranked(_ items: [Self], query: String, limit: Int) -> [Self] {
    let query = query.lowercased()
    if query.isEmpty { return Array(items.prefix(max(0, limit))) }
    return items.compactMap { item -> (Self, Int)? in
      if item.name.lowercased() == query { return (item, 0) }
      if item.name.lowercased().hasPrefix(query) { return (item, 1) }
      if item.name.lowercased().contains(query) || item.label.lowercased().contains(query) {
        return (item, 2)
      }
      if item.detail.lowercased().contains(query) { return (item, 3) }
      return nil
    }.sorted {
      if $0.1 != $1.1 { return $0.1 < $1.1 }
      if ($0.0.localCommand != nil) != ($1.0.localCommand != nil) {
        return $0.0.localCommand != nil
      }
      return $0.0.name < $1.0.name
    }
    .prefix(max(0, limit)).map(\.0)
  }

  public func selectionEdit(
    mention: ComposerMention, text: String, root: String,
    fileFormat: ComposerMention.FileFormat = .markdownLink, skillUsesLiteralPath: Bool = false
  ) -> (range: NSRange, replacement: String) {
    if localCommand != nil { return (mention.range, "") }
    return mention.insertion(
      in: text,
      replacement: replacement(
        root: root, fileFormat: fileFormat, skillUsesLiteralPath: skillUsesLiteralPath))
  }

  public func replacement(
    root: String, fileFormat: ComposerMention.FileFormat = .markdownLink,
    skillUsesLiteralPath: Bool = false
  ) -> String {
    if localCommand != nil { return "" }
    return switch kind {
    case .file: ComposerMention.fileReference(path: name, root: root, format: fileFormat)
    case .skill:
      if skillUsesLiteralPath, let path {
        ComposerMention.fileReference(path: path, root: root, format: .absoluteLiteral)
      } else {
        "$" + name
      }
    case .command: "/" + name
    }
  }
}

/// Query identity includes the connection session, draft, thread, provider instance, and worktree.
public struct ComposerCompletionScope: Equatable, Sendable {
  public let environment: String
  public let session: UUID
  public let thread: String
  public let draft: String
  public let provider: String
  public let root: String
  public init(
    environment: String, session: UUID, thread: String, draft: String, provider: String,
    root: String
  ) {
    self.environment = environment
    self.session = session
    self.thread = thread
    self.draft = draft
    self.provider = provider
    self.root = root
  }
}

public struct ComposerCompletionState: Sendable {
  public struct Ticket: Equatable, Sendable {
    fileprivate let revision: UInt64
    public let scope: ComposerCompletionScope
    public let mention: ComposerMention
  }
  public private(set) var mention: ComposerMention?
  private var scope: ComposerCompletionScope?
  private var revision: UInt64 = 0
  private var text = ""
  private var cursor = -1
  private var dismissed: (ComposerMention.Kind, Int, ComposerCompletionScope)?
  public init() {}

  public mutating func refresh(text: String, cursor: Int, scope: ComposerCompletionScope?) {
    if self.text != text || self.cursor != cursor || self.scope != scope { revision &+= 1 }
    self.text = text
    self.cursor = cursor
    self.scope = scope
    guard let scope, let candidate = ComposerMention.detect(text: text, cursor: cursor) else {
      mention = nil
      dismissed = nil
      return
    }
    if let dismissed, dismissed.0 == candidate.kind, dismissed.1 == candidate.range.location,
      dismissed.2 == scope
    {
      mention = nil
      return
    }
    dismissed = nil
    mention = candidate
  }
  public var ticket: Ticket? {
    guard let scope, let mention else { return nil }
    return Ticket(revision: revision, scope: scope, mention: mention)
  }
  public func accepts(_ ticket: Ticket) -> Bool { self.ticket == ticket }
  public mutating func dismiss() {
    if let scope, let mention { dismissed = (mention.kind, mention.range.location, scope) }
    revision &+= 1
    mention = nil
  }
}
