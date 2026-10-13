import Foundation

public struct FileOpenCapabilities: Equatable, Sendable {
  public let editors: [String]
  public let revealTitle: String?
  public var canOpenDefault: Bool { editors.contains("file-manager") }

  public init(_ config: JSON = .null) {
    var seen: Set<String> = []
    editors = config["availableEditors"].array.compactMap(\.string).filter {
      Self.labels[$0] != nil && seen.insert($0).inserted
    }
    if editors.contains("file-manager") && config["shellRevealInFileManager"].bool {
      let kind = config["shellRevealInFileManagerKind"].string
      let os = config["environment"]["platform"]["os"].string
      switch kind ?? (os == "darwin" ? "finder" : os == "win32" ? "file-explorer" : "files") {
      case "finder": revealTitle = "Reveal in Finder"
      case "file-explorer": revealTitle = "Reveal in File Explorer"
      default: revealTitle = "Reveal in Files"
      }
    } else {
      revealTitle = nil
    }
  }

  public func launchInput(
    path: String, root: String, editor: String, reveal: Bool = false,
    position: FileSourcePosition? = nil
  ) throws -> JSON {
    guard editors.contains(editor), !reveal || (editor == "file-manager" && revealTitle != nil)
    else {
      throw T3Error("This environment does not support that file action.")
    }
    guard !path.isEmpty, root.hasPrefix("/") else { throw T3Error("The file path is unavailable.") }
    var absolute = Self.absolutePath(path, root: root)
    if editor != "file-manager", let position {
      absolute += ":\(position.line)" + (position.column.map { ":\($0)" } ?? "")
    }
    var fields: [String: JSON] = ["cwd": .string(absolute), "editor": .string(editor)]
    if reveal { fields["reveal"] = .bool(true) }
    return .object(fields)
  }

  public static func absolutePath(_ path: String, root: String) -> String {
    ((path.hasPrefix("/") ? path : (root as NSString).appendingPathComponent(path)) as NSString)
      .standardizingPath
  }

  public static func label(_ editor: String) -> String { labels[editor] ?? editor }
  private static let labels = [
    "cursor": "Cursor", "trae": "Trae", "kiro": "Kiro", "vscode": "VS Code",
    "vscode-insiders": "VS Code Insiders", "vscodium": "VSCodium", "zed": "Zed",
    "antigravity": "Antigravity", "idea": "IntelliJ IDEA", "aqua": "Aqua", "clion": "CLion",
    "datagrip": "DataGrip", "dataspell": "DataSpell", "goland": "GoLand", "phpstorm": "PhpStorm",
    "pycharm": "PyCharm", "rider": "Rider", "rubymine": "RubyMine", "rustrover": "RustRover",
    "webstorm": "WebStorm", "file-manager": "File Manager",
  ]
}
