import AppKit

/// Render once per content/width/preference change, then reuse the attributed result.
public struct MarkdownConfiguration: Equatable, Sendable {
  public var fontName: String
  public var codeFontName: String
  public var fontSize: CGFloat
  public var codeFontSize: CGFloat
  public var lineSpacing: CGFloat
  public var paragraphSpacing: CGFloat
  public var wrapCode: Bool
  public var wrapTables: Bool
  public var polished: Bool

  public init(
    fontSize: CGFloat = 14, codeFontSize: CGFloat = 12.5, lineSpacing: CGFloat = 3,
    paragraphSpacing: CGFloat = 8, wrapCode: Bool = true, wrapTables: Bool = true,
    polished: Bool = false, fontName: String = "", codeFontName: String = ""
  ) {
    self.fontName = fontName
    self.codeFontName = codeFontName
    self.fontSize = fontSize
    self.codeFontSize = codeFontSize
    self.lineSpacing = lineSpacing
    self.paragraphSpacing = paragraphSpacing
    self.wrapCode = wrapCode
    self.wrapTables = wrapTables
    self.polished = polished
  }

  @MainActor func bodyFont(size: CGFloat? = nil, weight: NSFont.Weight = .regular) -> NSFont {
    let size = size ?? fontSize
    guard !fontName.isEmpty, let font = NSFont(name: fontName, size: size) else {
      return .systemFont(ofSize: size, weight: weight)
    }
    return weight == .regular
      ? font : NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
  }

  @MainActor func codeFont(size: CGFloat? = nil) -> NSFont {
    let size = size ?? codeFontSize
    return codeFontName.isEmpty
      ? .monospacedSystemFont(ofSize: size, weight: .regular)
      : NSFont(name: codeFontName, size: size)
        ?? .monospacedSystemFont(ofSize: size, weight: .regular)
  }

  public static let message = MarkdownConfiguration(
    fontSize: 15, codeFontSize: 13, lineSpacing: 5, paragraphSpacing: 14, polished: true)
}

extension NSAttributedString.Key {
  public static let t3InlineCode = NSAttributedString.Key("T3InlineCode")
  public static let t3BlockLayoutWidth = NSAttributedString.Key("T3BlockLayoutWidth")
  public static let t3SyntaxToken = NSAttributedString.Key("T3SyntaxToken")
}

@MainActor public enum MarkdownPalette {
  public static let codeBackground = NSColor(srgbRed: 0.075, green: 0.085, blue: 0.105, alpha: 1)
  public static let codeBorder = NSColor(srgbRed: 0.22, green: 0.24, blue: 0.28, alpha: 1)
  public static let codeText = NSColor(srgbRed: 0.86, green: 0.88, blue: 0.92, alpha: 1)
  public static let codeSecondary = NSColor(srgbRed: 0.57, green: 0.62, blue: 0.70, alpha: 1)
}

/// Inline code stays real text, including inside native table cells.
@MainActor public final class MarkdownLayoutManager: NSLayoutManager {
  public override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
    guard let storage = textStorage, let container = textContainers.first else { return }
    let capsuleColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.13)
    let visible = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
    storage.enumerateAttribute(.t3InlineCode, in: visible) { value, range, _ in
      guard value != nil else { return }
      let glyphs = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
      self.enumerateEnclosingRects(
        forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
        in: container
      ) { rect, _ in
        let capsule = rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -3, dy: 0)
        capsuleColor.setFill()
        NSBezierPath(roundedRect: capsule, xRadius: 4, yRadius: 4).fill()
      }
    }
    super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
  }
}

/// TextKit tables need an expanded container to overflow; prose still gets the viewport width.
public final class MarkdownTextContainer: NSTextContainer {
  private let viewportWidth: CGFloat

  public init(text: NSAttributedString, width: CGFloat) {
    viewportWidth = width
    super.init(size: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
    lineFragmentPadding = 0
    widthTracksTextView = false
    updateLayoutWidth(for: text)
  }
  public required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  public func updateLayoutWidth(for text: NSAttributedString) {
    var widest = viewportWidth
    text.enumerateAttribute(.t3BlockLayoutWidth, in: NSRange(location: 0, length: text.length)) {
      value, _, _ in
      if let width = value as? CGFloat { widest = max(widest, width) }
    }
    size = NSSize(width: widest, height: CGFloat.greatestFiniteMagnitude)
  }

  public override var isSimpleRectangularTextContainer: Bool { false }

  public override func lineFragmentRect(
    forProposedRect proposedRect: NSRect, at characterIndex: Int,
    writingDirection baseWritingDirection: NSWritingDirection,
    remaining remainingRect: UnsafeMutablePointer<NSRect>?
  ) -> NSRect {
    var rect = super.lineFragmentRect(
      forProposedRect: proposedRect, at: characterIndex,
      writingDirection: baseWritingDirection, remaining: remainingRect)
    guard let storage = layoutManager?.textStorage, characterIndex < storage.length else {
      return rect
    }
    let allowed =
      storage.attribute(.t3BlockLayoutWidth, at: characterIndex, effectiveRange: nil) as? CGFloat
      ?? viewportWidth
    rect.size.width = max(0, min(rect.width, allowed - rect.minX))
    return rect
  }
}
