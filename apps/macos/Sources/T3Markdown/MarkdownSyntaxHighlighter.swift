import AppKit

@MainActor enum MarkdownSyntaxHighlighter {
  // One lexical pass prevents keywords inside strings/comments being recolored.
  private static let tokens = try! NSRegularExpression(
    pattern:
      #"(?<comment>/\*[\s\S]*?(?:\*/|$)|//[^\n]*|#[^\n]*)|(?<string>"(?:\\.|[^"\\])*"?|'(?:\\.|[^'\\])*'?|`(?:\\.|[^`\\])*`?)|(?<number>\b(?:0[xX][\da-fA-F]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)\b)|(?<word>[A-Za-z_$][\w$]*)"#
  )
  private static let keywords = Set(
    ("actor as async await break case catch class const continue def defer do else enum export extends "
      + "false final for from func function guard if import in init interface is let match mut new nil "
      + "null of override package private protocol public raise return self static struct super switch "
      + "throw throws true try type typeof undefined var void when where while yield fn impl pub use "
      + "select insert update delete into values join on create table and or not set with").split(
        separator: " "
      ).map(String.init))
  private static let supported = Set([
    "swift", "js", "javascript", "jsx", "ts", "typescript", "tsx", "json", "jsonc", "python", "py",
    "bash", "sh", "shell", "zsh", "ruby", "rb", "rust", "rs", "go", "golang", "c", "cpp", "c++",
    "java", "kotlin", "kt", "sql", "yaml", "yml", "css", "scss", "html", "xml",
  ])

  static func apply(to text: NSMutableAttributedString, language: String?) {
    guard let language = language?.lowercased().split(separator: " ").first.map(String.init),
      supported.contains(language), text.length > 0, text.length <= 150_000
    else { return }
    let hashComments = ["python", "py", "bash", "sh", "shell", "zsh", "ruby", "rb", "yaml", "yml"]
      .contains(language)
    let source = text.string as NSString
    tokens.enumerateMatches(in: text.string, range: NSRange(location: 0, length: text.length)) {
      match, _, _ in
      guard let match else { return }
      let token: String
      let color: NSColor
      if match.range(withName: "comment").location != NSNotFound {
        if source.substring(with: match.range).hasPrefix("#"), !hashComments { return }
        token = "comment"
        color = MarkdownPalette.codeSecondary
      } else if match.range(withName: "string").location != NSNotFound {
        token = "string"
        color = NSColor(srgbRed: 0.63, green: 0.82, blue: 0.60, alpha: 1)
      } else if match.range(withName: "number").location != NSNotFound {
        token = "number"
        color = NSColor(srgbRed: 0.91, green: 0.71, blue: 0.48, alpha: 1)
      } else {
        let word = source.substring(with: match.range)
        if keywords.contains(word) || (language == "sql" && keywords.contains(word.lowercased())) {
          token = "keyword"
          color = NSColor(srgbRed: 0.77, green: 0.65, blue: 0.93, alpha: 1)
        } else if word.first?.isUppercase == true {
          token = "type"
          color = NSColor(srgbRed: 0.47, green: 0.79, blue: 0.85, alpha: 1)
        } else {
          return
        }
      }
      text.addAttributes([.foregroundColor: color, .t3SyntaxToken: token], range: match.range)
    }
  }
}
