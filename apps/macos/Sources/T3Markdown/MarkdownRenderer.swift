import AppKit
import Markdown

public struct RenderedCodeBlock {
  public let range: NSRange
  public let code: String
  public let language: String?
}

public struct RenderedMarkdown {
  public let text: NSAttributedString
  public let codeBlocks: [RenderedCodeBlock]
  public init(text: NSAttributedString, codeBlocks: [RenderedCodeBlock]) {
    self.text = text
    self.codeBlocks = codeBlocks
  }
}

@MainActor public enum MarkdownRenderer {
  public static func render(_ source: String, width: CGFloat) -> RenderedMarkdown {
    let renderer = Renderer(width: width)
    for block in Document(parsing: source).children { renderer.block(block) }
    return RenderedMarkdown(text: renderer.output, codeBlocks: renderer.codeBlocks)
  }

  public static func height(of text: NSAttributedString, width: CGFloat) -> CGFloat {
    let storage = NSTextStorage(attributedString: text)
    let layout = NSLayoutManager()
    let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
    container.lineFragmentPadding = 0
    storage.addLayoutManager(layout)
    layout.addTextContainer(container)
    layout.ensureLayout(for: container)
    return ceil(layout.usedRect(for: container).height)
  }
}

@MainActor private final class Renderer {
  struct Style {
    var font = NSFont.systemFont(ofSize: 14)
    var color = NSColor.labelColor
    var indent: CGFloat = 0
    var quote = false
    var tableBlock: NSTextTableBlock?
    var alignment = NSTextAlignment.left
  }
  let width: CGFloat
  let output = NSMutableAttributedString(string: "")
  var codeBlocks: [RenderedCodeBlock] = []
  init(width: CGFloat) { self.width = max(120, width) }

  func block(_ node: any Markup, style: Style = Style(), prefix: String = "") {
    switch node {
    case let heading as Heading:
      var headingStyle = style
      headingStyle.font = .systemFont(
        ofSize: [22.0, 19, 17, 15, 14, 14][min(5, max(0, heading.level - 1))], weight: .semibold)
      paragraph(
        inline(heading, style: headingStyle), style: headingStyle, prefix: prefix, before: 10)
    case let paragraph as Paragraph:
      self.paragraph(inline(paragraph, style: style), style: style, prefix: prefix)
    case let code as CodeBlock:
      var codeStyle = style
      codeStyle.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
      codeStyle.indent = min(width - 60, codeStyle.indent + 10)
      if let language = code.language, !language.isEmpty {
        var labelStyle = style
        labelStyle.font = .systemFont(ofSize: 10, weight: .medium)
        labelStyle.color = .secondaryLabelColor
        paragraph(
          NSAttributedString(string: language, attributes: attributes(labelStyle)),
          style: labelStyle, prefix: prefix, after: 2)
      }
      let start = output.length
      let text = NSMutableAttributedString(string: code.code, attributes: attributes(codeStyle))
      text.addAttribute(
        .backgroundColor, value: NSColor.quaternaryLabelColor.withAlphaComponent(0.08),
        range: NSRange(location: 0, length: text.length))
      paragraph(text, style: codeStyle, prefix: code.language == nil ? prefix : "")
      codeBlocks.append(
        RenderedCodeBlock(
          range: NSRange(location: start, length: output.length - start), code: code.code,
          language: code.language))
    case let quote as BlockQuote:
      var quoted = style
      quoted.indent = min(width - 60, quoted.indent + 18)
      quoted.quote = true
      quoted.color = .secondaryLabelColor
      for child in quote.children { block(child, style: quoted) }
    case let ordered as OrderedList:
      list(ordered, style: style, start: ordered.startIndex)
    case let unordered as UnorderedList:
      list(unordered, style: style, start: nil)
    case let table as Table:
      renderTable(table, style: style)
    case is ThematicBreak:
      var ruleStyle = style
      ruleStyle.color = .separatorColor
      paragraph(
        NSAttributedString(
          string: String(repeating: "─", count: max(4, Int((width - style.indent) / 9))),
          attributes: attributes(ruleStyle)), style: ruleStyle)
    case let html as HTMLBlock:
      paragraph(
        NSAttributedString(string: html.rawHTML, attributes: attributes(style)), style: style,
        prefix: prefix)
    default:
      for child in node.children { block(child, style: style, prefix: prefix) }
    }
  }

  private func list(_ node: any Markup, style: Style, start: UInt?) {
    for (index, child) in node.children.enumerated() {
      guard let item = child as? ListItem else { continue }
      let marker: String
      switch item.checkbox {
      case .checked: marker = "☑"
      case .unchecked: marker = "☐"
      case nil: marker = start.map { "\($0 + UInt(index))." } ?? "•"
      }
      var itemStyle = style
      itemStyle.indent = min(width - 60, itemStyle.indent + 22)
      for (blockIndex, child) in item.children.enumerated() {
        block(child, style: itemStyle, prefix: blockIndex == 0 ? marker + "\t" : "")
      }
    }
  }

  private func paragraph(
    _ text: NSAttributedString, style: Style, prefix: String = "", before: CGFloat = 0,
    after: CGFloat = 8
  ) {
    let start = output.length
    if !prefix.isEmpty {
      output.append(NSAttributedString(string: prefix, attributes: attributes(style)))
    }
    output.append(text)
    if !output.string.hasSuffix("\n") || output.length == start {
      output.append(NSAttributedString(string: "\n", attributes: attributes(style)))
    }
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = 3
    paragraph.paragraphSpacing = after
    paragraph.paragraphSpacingBefore = before
    paragraph.headIndent = style.indent
    paragraph.firstLineHeadIndent = prefix.isEmpty ? style.indent : max(0, style.indent - 22)
    paragraph.tabStops = [NSTextTab(textAlignment: .left, location: style.indent)]
    paragraph.defaultTabInterval = 24
    paragraph.alignment = style.alignment
    if let tableBlock = style.tableBlock { paragraph.textBlocks = [tableBlock] }
    let range = NSRange(location: start, length: output.length - start)
    output.addAttribute(.paragraphStyle, value: paragraph, range: range)
    if style.quote {
      output.addAttribute(
        .backgroundColor, value: NSColor.quaternaryLabelColor.withAlphaComponent(0.04), range: range
      )
    }
  }

  private func attributes(_ style: Style) -> [NSAttributedString.Key: Any] {
    [.font: style.font, .foregroundColor: style.color]
  }

  private func inline(_ node: any Markup, style: Style) -> NSAttributedString {
    let result = NSMutableAttributedString(string: "")
    for child in node.children {
      switch child {
      case let text as Text:
        result.append(NSAttributedString(string: text.string, attributes: attributes(style)))
      case is SoftBreak, is LineBreak:
        result.append(NSAttributedString(string: "\n", attributes: attributes(style)))
      case let code as InlineCode:
        var attrs = attributes(style)
        attrs[.font] = NSFont.monospacedSystemFont(
          ofSize: max(11, style.font.pointSize - 1), weight: .regular)
        attrs[.backgroundColor] = NSColor.quaternaryLabelColor.withAlphaComponent(0.12)
        result.append(NSAttributedString(string: code.code, attributes: attrs))
      case is Strong:
        var strong = style
        strong.font = NSFontManager.shared.convert(style.font, toHaveTrait: .boldFontMask)
        result.append(inline(child, style: strong))
      case is Emphasis:
        var emphasis = style
        emphasis.font = NSFontManager.shared.convert(style.font, toHaveTrait: .italicFontMask)
        result.append(inline(child, style: emphasis))
      case is Strikethrough:
        let text = NSMutableAttributedString(attributedString: inline(child, style: style))
        text.addAttribute(
          .strikethroughStyle, value: NSUnderlineStyle.single.rawValue,
          range: NSRange(location: 0, length: text.length))
        result.append(text)
      case let link as Link:
        let text = NSMutableAttributedString(attributedString: inline(link, style: style))
        if let destination = link.destination, let url = safeURL(destination) {
          text.addAttribute(.link, value: url, range: NSRange(location: 0, length: text.length))
        }
        result.append(text)
      case let image as Markdown.Image:
        let label = image.plainText.isEmpty ? "Image" : image.plainText
        var attrs = attributes(style)
        if let source = image.source, let url = safeURL(source) { attrs[.link] = url }
        result.append(NSAttributedString(string: "[" + label + "]", attributes: attrs))
      case let html as InlineHTML:
        result.append(NSAttributedString(string: html.rawHTML, attributes: attributes(style)))
      default: result.append(inline(child, style: style))
      }
    }
    return result
  }

  private func safeURL(_ destination: String) -> URL? {
    guard let url = URL(string: destination), let scheme = url.scheme?.lowercased(),
      ["http", "https", "mailto", "file"].contains(scheme)
    else { return nil }
    return url
  }

  private func renderTable(_ source: Table, style: Style) {
    let table = NSTextTable()
    table.numberOfColumns = source.maxColumnCount
    table.layoutAlgorithm = .fixedLayoutAlgorithm
    table.collapsesBorders = true
    table.setValue(max(60, width - style.indent), type: .absoluteValueType, for: .width)
    let rows = [Array(source.head.children)] + source.body.children.map { Array($0.children) }
    for (rowIndex, row) in rows.enumerated() {
      for (column, cell) in row.enumerated() {
        let block = NSTextTableBlock(
          table: table, startingRow: rowIndex, rowSpan: 1, startingColumn: column, columnSpan: 1)
        block.setValue(
          100 / CGFloat(max(1, source.maxColumnCount)), type: .percentageValueType, for: .width)
        block.setWidth(7, type: .absoluteValueType, for: .padding)
        block.setWidth(0.5, type: .absoluteValueType, for: .border)
        block.setBorderColor(.separatorColor)
        block.backgroundColor =
          rowIndex == 0 ? NSColor.quaternaryLabelColor.withAlphaComponent(0.08) : .clear
        var cellStyle = style
        cellStyle.indent = 0
        cellStyle.tableBlock = block
        if rowIndex == 0 { cellStyle.font = .systemFont(ofSize: 13, weight: .semibold) }
        switch source.columnAlignments[column] {
        case .center: cellStyle.alignment = .center
        case .right: cellStyle.alignment = .right
        default: cellStyle.alignment = .left
        }
        paragraph(inline(cell, style: cellStyle), style: cellStyle, after: 0)
      }
    }
    paragraph(NSAttributedString(string: ""), style: style, after: 2)
  }
}
