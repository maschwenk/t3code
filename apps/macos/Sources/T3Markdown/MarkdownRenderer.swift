import AppKit
import Markdown

public struct RenderedCodeBlock {
  public let range: NSRange
  public let code: String
  public let language: String?
  public let surfaceRange: NSRange?
  public let headerRange: NSRange?
  public let contentWidth: CGFloat
  public let wraps: Bool
  public init(
    range: NSRange, code: String, language: String?, surfaceRange: NSRange? = nil,
    headerRange: NSRange? = nil, contentWidth: CGFloat = 0, wraps: Bool = true
  ) {
    self.range = range
    self.code = code
    self.language = language
    self.surfaceRange = surfaceRange
    self.headerRange = headerRange
    self.contentWidth = contentWidth
    self.wraps = wraps
  }
}

public struct RenderedMarkdownTable {
  public let range: NSRange
  public let columns: Int
  public let rows: Int
  public let contentWidth: CGFloat
}

public struct RenderedMarkdownTask {
  public let range: NSRange
  public let sourceOffset: Int
  public let checked: Bool
}

public struct RenderedMarkdown {
  public let text: NSAttributedString
  public let codeBlocks: [RenderedCodeBlock]
  public let tasks: [RenderedMarkdownTask]
  public let tables: [RenderedMarkdownTable]
  public let contentWidth: CGFloat
  public let configuration: MarkdownConfiguration
  public init(
    text: NSAttributedString, codeBlocks: [RenderedCodeBlock], tasks: [RenderedMarkdownTask] = [],
    tables: [RenderedMarkdownTable] = [], contentWidth: CGFloat = 0,
    configuration: MarkdownConfiguration = MarkdownConfiguration()
  ) {
    self.text = text
    self.codeBlocks = codeBlocks
    self.tasks = tasks
    self.tables = tables
    self.contentWidth = contentWidth
    self.configuration = configuration
  }
}

@MainActor public enum MarkdownRenderer {
  public static func render(
    _ source: String, width: CGFloat, headingLevelOffset: Int = 0,
    taskLinks: Bool = false, configuration: MarkdownConfiguration = MarkdownConfiguration(),
    resolveLink: ((String) -> URL?)? = nil
  ) -> RenderedMarkdown {
    let renderer = Renderer(
      source: source, width: width, headingLevelOffset: headingLevelOffset,
      taskLinks: taskLinks, configuration: configuration, resolveLink: resolveLink)
    for block in Document(parsing: source).children { renderer.block(block) }
    return RenderedMarkdown(
      text: renderer.output, codeBlocks: renderer.codeBlocks, tasks: renderer.tasks,
      tables: renderer.tables, contentWidth: renderer.contentWidth, configuration: configuration)
  }

  public static func height(of text: NSAttributedString, width: CGFloat) -> CGFloat {
    let storage = NSTextStorage(attributedString: text)
    let layout = MarkdownLayoutManager()
    let container = MarkdownTextContainer(text: text, width: width)
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
    var code = false
    var header = false
  }
  let width: CGFloat
  let headingLevelOffset: Int
  let output = NSMutableAttributedString(string: "")
  var codeBlocks: [RenderedCodeBlock] = []
  var tasks: [RenderedMarkdownTask] = []
  var tables: [RenderedMarkdownTable] = []
  var contentWidth: CGFloat
  private let configuration: MarkdownConfiguration
  private let source: NSString
  private var lineStarts: [Int] = []
  private let taskLinks: Bool
  private let resolveLink: ((String) -> URL?)?
  init(
    source: String, width: CGFloat, headingLevelOffset: Int, taskLinks: Bool,
    configuration: MarkdownConfiguration, resolveLink: ((String) -> URL?)?
  ) {
    self.source = source as NSString
    self.taskLinks = taskLinks
    self.configuration = configuration
    self.contentWidth = max(120, width)
    self.resolveLink = resolveLink
    lineStarts = [0]
    var previous: UInt16 = 0
    for (index, unit) in source.utf16.enumerated() {
      if unit == 10 && previous == 13 {
        lineStarts[lineStarts.count - 1] = index + 1
      } else if unit == 10 || unit == 13 {
        lineStarts.append(index + 1)
      }
      previous = unit
    }
    self.width = max(120, width)
    self.headingLevelOffset = min(5, max(0, headingLevelOffset))
  }

  func block(_ node: any Markup, style suppliedStyle: Style? = nil, prefix: String = "") {
    var style = suppliedStyle ?? Style()
    if suppliedStyle == nil { style.font = configuration.bodyFont() }
    switch node {
    case let heading as Heading:
      var headingStyle = style
      headingStyle.font = configuration.bodyFont(
        size: [22.0, 19, 17, 15, 14, 14][min(5, max(0, heading.level + headingLevelOffset - 1))]
          * configuration.fontSize / 14,
        weight: .semibold)
      paragraph(
        inline(heading, style: headingStyle), style: headingStyle, prefix: prefix,
        before: configuration.polished ? 18 : 10)
    case let paragraph as Paragraph:
      self.paragraph(inline(paragraph, style: style), style: style, prefix: prefix)
    case let code as CodeBlock:
      renderCode(code, style: style, prefix: prefix)
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
      let sourceTask = item.checkbox != nil || start != nil ? taskMarker(item) : nil
      let checkbox = item.checkbox ?? (start != nil ? sourceTask?.checkbox : nil)
      let marker: String
      switch checkbox {
      case .checked: marker = "☑"
      case .unchecked: marker = "☐"
      case nil: marker = start.map { "\($0 + UInt(index))." } ?? "•"
      }
      var itemStyle = style
      itemStyle.indent = min(width - 60, itemStyle.indent + 22)
      let start = output.length
      for (blockIndex, child) in item.children.enumerated() {
        if blockIndex == 0, item.checkbox == nil, checkbox != nil,
          let paragraph = child as? Paragraph
        {
          // swift-markdown recognizes unordered tasks; GFM also permits ordered tasks.
          let text = NSMutableAttributedString(
            attributedString: inline(paragraph, style: itemStyle))
          let prefix = (text.string as NSString).range(
            of: #"^\[[ xX]\](?:[ \t]+|$)"#, options: .regularExpression)
          if prefix.location == 0 { text.deleteCharacters(in: prefix) }
          self.paragraph(text, style: itemStyle, prefix: marker + "\t")
        } else {
          block(child, style: itemStyle, prefix: blockIndex == 0 ? marker + "\t" : "")
        }
      }
      if taskLinks, let checkbox, let offset = sourceTask?.offset,
        output.length > start
      {
        let range = NSRange(location: start, length: 1)
        tasks.append(
          RenderedMarkdownTask(range: range, sourceOffset: offset, checked: checkbox == .checked))
        output.addAttribute(
          .link, value: URL(string: "t3-markdown-task://toggle/\(offset)")!, range: range)
      }
    }
  }

  private static let taskPattern = try! NSRegularExpression(
    pattern: #"^(?:[-+*]|[0-9]{1,9}[.)])[ \t]+(\[[ xX]\])(?:[ \t]+|$)"#)

  private func taskMarker(_ item: ListItem) -> (offset: Int, checkbox: Checkbox)? {
    guard let location = item.range?.lowerBound, location.line > 0,
      location.line <= lineStarts.count
    else { return nil }
    let start = lineStarts[location.line - 1]
    let end = location.line < lineStarts.count ? lineStarts[location.line] : source.length
    let line = source.substring(with: NSRange(location: start, length: end - start))
    let bytes = Array(line.utf8)
    let column = max(0, location.column - 1)
    guard column < bytes.count else { return nil }
    let prefix = String(decoding: bytes.prefix(column), as: UTF8.self).utf16.count
    let remainder = String(decoding: bytes.dropFirst(column), as: UTF8.self) as NSString
    guard
      let match = Self.taskPattern.firstMatch(
        in: remainder as String, range: NSRange(location: 0, length: remainder.length))
    else { return nil }
    let offset = start + prefix + match.range(at: 1).location
    return (offset, source.character(at: offset + 1) == 32 ? .unchecked : .checked)
  }

  private func paragraph(
    _ text: NSAttributedString, style: Style, prefix: String = "", before: CGFloat = 0,
    after: CGFloat? = nil
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
    paragraph.lineSpacing = style.code ? 3 : configuration.lineSpacing
    paragraph.paragraphSpacing = after ?? configuration.paragraphSpacing
    paragraph.paragraphSpacingBefore = before
    paragraph.headIndent = style.indent
    paragraph.firstLineHeadIndent = prefix.isEmpty ? style.indent : max(0, style.indent - 22)
    paragraph.tabStops = [NSTextTab(textAlignment: .left, location: style.indent)]
    paragraph.defaultTabInterval = 24
    paragraph.alignment = style.alignment
    if style.code && configuration.polished {
      paragraph.lineBreakMode = configuration.wrapCode ? .byCharWrapping : .byClipping
      paragraph.defaultTabInterval = configuration.codeFontSize * 2.4
    }
    if style.header {
      paragraph.minimumLineHeight = 27
      paragraph.maximumLineHeight = 27
    }
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
      case is SoftBreak:
        result.append(
          NSAttributedString(
            string: configuration.polished ? " " : "\n", attributes: attributes(style)))
      case is LineBreak:
        result.append(NSAttributedString(string: "\n", attributes: attributes(style)))
      case let code as InlineCode:
        var attrs = attributes(style)
        attrs[.font] = configuration.codeFont(size: max(11, style.font.pointSize - 1))
        if configuration.polished {
          attrs[.t3InlineCode] = true
        } else {
          attrs[.backgroundColor] = NSColor.quaternaryLabelColor.withAlphaComponent(0.12)
        }
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
          text.addAttributes(
            [.link: url, .underlineStyle: NSUnderlineStyle.single.rawValue],
            range: NSRange(location: 0, length: text.length))
        }
        result.append(text)
      case let image as Markdown.Image:
        let label = image.plainText.isEmpty ? "Image" : image.plainText
        var attrs = attributes(style)
        if let source = image.source, let url = safeURL(source) {
          attrs[.link] = url
          attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        result.append(NSAttributedString(string: "[" + label + "]", attributes: attrs))
      case let html as InlineHTML:
        result.append(NSAttributedString(string: html.rawHTML, attributes: attributes(style)))
      default: result.append(inline(child, style: style))
      }
    }
    return result
  }

  private func safeURL(_ destination: String) -> URL? {
    if let resolveLink { return resolveLink(destination) }
    guard let url = URL(string: destination), let scheme = url.scheme?.lowercased(),
      ["http", "https", "mailto", "file"].contains(scheme)
    else { return nil }
    return url
  }

  private func renderCode(_ code: CodeBlock, style: Style, prefix: String) {
    var codeStyle = style
    codeStyle.font = configuration.codeFont()
    codeStyle.indent = min(width - 60, style.indent + 10)
    codeStyle.code = true
    let surfaceStart = output.length
    var headerRange: NSRange?
    var surfaceWidth = width - style.indent
    if configuration.polished {
      codeStyle.color = MarkdownPalette.codeText
      codeStyle.indent = 0
      if !configuration.wrapCode {
        surfaceWidth = max(surfaceWidth, longestLine(code.code, font: codeStyle.font) + 28)
      }
      let table = NSTextTable()
      table.numberOfColumns = 1
      table.layoutAlgorithm = .fixedLayoutAlgorithm
      table.setValue(surfaceWidth, type: .absoluteValueType, for: .width)
      let cell = NSTextTableBlock(
        table: table, startingRow: 0, rowSpan: 1, startingColumn: 0, columnSpan: 1)
      cell.setWidth(14, type: .absoluteValueType, for: .padding)
      codeStyle.tableBlock = cell
      var headerStyle = codeStyle
      headerStyle.font = .systemFont(ofSize: 11, weight: .medium)
      headerStyle.header = true
      // Reserve header space without adding button titles to selected/copied code.
      paragraph(NSAttributedString(string: ""), style: headerStyle, after: 0)
      headerRange = NSRange(location: surfaceStart, length: output.length - surfaceStart)
    } else if let language = code.language, !language.isEmpty {
      var labelStyle = style
      labelStyle.font = .systemFont(ofSize: 10, weight: .medium)
      labelStyle.color = .secondaryLabelColor
      paragraph(
        NSAttributedString(string: language, attributes: attributes(labelStyle)),
        style: labelStyle, prefix: prefix, after: 2)
    }
    let start = output.length
    let text = NSMutableAttributedString(string: code.code, attributes: attributes(codeStyle))
    if configuration.polished {
      MarkdownSyntaxHighlighter.apply(to: text, language: code.language)
    } else {
      text.addAttribute(
        .backgroundColor,
        value: NSColor.quaternaryLabelColor.withAlphaComponent(0.08),
        range: NSRange(location: 0, length: text.length))
    }
    paragraph(
      text, style: codeStyle,
      prefix: configuration.polished || code.language != nil ? "" : prefix,
      after: configuration.polished ? 0 : nil)
    if configuration.polished {
      output.addAttribute(
        .t3BlockLayoutWidth, value: surfaceWidth,
        range: NSRange(location: surfaceStart, length: output.length - surfaceStart))
    }
    codeBlocks.append(
      RenderedCodeBlock(
        range: NSRange(location: start, length: output.length - start), code: code.code,
        language: code.language,
        surfaceRange: configuration.polished
          ? NSRange(location: surfaceStart, length: output.length - surfaceStart) : nil,
        headerRange: headerRange, contentWidth: surfaceWidth, wraps: configuration.wrapCode))
    contentWidth = max(contentWidth, surfaceWidth + style.indent)
    if configuration.polished {
      paragraph(NSAttributedString(string: ""), style: style, after: 4)
    }
  }

  private func longestLine(_ text: String, font: NSFont) -> CGFloat {
    text.split(separator: "\n", omittingEmptySubsequences: false)
      .reduce(CGFloat(0)) {
        max($0, (String($1) as NSString).size(withAttributes: [.font: font]).width)
      }
  }

  private func renderTable(_ source: Table, style: Style) {
    let start = output.length
    let columns = max(1, source.maxColumnCount)
    let rows = [Array(source.head.children)] + source.body.children.map { Array($0.children) }
    // Build each cell once; measure the same attributed content that TextKit will display.
    let cells = rows.enumerated().map { rowIndex, row in
      row.map { cell -> NSAttributedString in
        var cellStyle = style
        if rowIndex == 0 {
          cellStyle.font = configuration.bodyFont(
            size: configuration.polished ? configuration.fontSize : configuration.fontSize - 1,
            weight: .semibold)
        }
        return inline(cell, style: cellStyle)
      }
    }
    let table = NSTextTable()
    table.numberOfColumns = columns
    table.layoutAlgorithm = .fixedLayoutAlgorithm
    table.collapsesBorders = true
    let availableWidth = max(60, width - style.indent)
    var columnWidths = Array(repeating: availableWidth / CGFloat(columns), count: columns)
    if !configuration.wrapTables {
      for row in cells {
        for (column, cell) in row.enumerated() {
          columnWidths[column] = max(columnWidths[column], cell.size().width + 24)
        }
      }
    }
    let tableWidth = columnWidths.reduce(0, +)
    table.setValue(tableWidth, type: .absoluteValueType, for: .width)
    if !configuration.wrapTables {
      table.setValue(tableWidth, type: .absoluteValueType, for: .minimumWidth)
    }
    contentWidth = max(contentWidth, tableWidth + style.indent)
    for (rowIndex, row) in cells.enumerated() {
      for (column, cell) in row.enumerated() {
        let block = NSTextTableBlock(
          table: table, startingRow: rowIndex, rowSpan: 1, startingColumn: column, columnSpan: 1)
        block.setValue(columnWidths[column], type: .absoluteValueType, for: .width)
        if !configuration.wrapTables {
          block.setValue(columnWidths[column] - 20, type: .absoluteValueType, for: .minimumWidth)
        }
        block.setWidth(configuration.polished ? 10 : 7, type: .absoluteValueType, for: .padding)
        if configuration.polished {
          block.setWidth(0, type: .absoluteValueType, for: .border)
          block.setWidth(
            rowIndex == 0 ? 1 : 0.5, type: .absoluteValueType, for: .border, edge: .maxY)
        } else {
          block.setWidth(0.5, type: .absoluteValueType, for: .border)
        }
        block.setBorderColor(.separatorColor)
        block.backgroundColor =
          rowIndex == 0
          ? NSColor.quaternaryLabelColor.withAlphaComponent(configuration.polished ? 0.05 : 0.08)
          : .clear
        var cellStyle = style
        cellStyle.indent = 0
        cellStyle.tableBlock = block
        if rowIndex == 0 {
          cellStyle.font = configuration.bodyFont(
            size: configuration.polished ? configuration.fontSize : configuration.fontSize - 1,
            weight: .semibold)
        }
        switch source.columnAlignments[column] {
        case .center: cellStyle.alignment = .center
        case .right: cellStyle.alignment = .right
        default: cellStyle.alignment = .left
        }
        paragraph(cell, style: cellStyle, after: 0)
      }
    }
    output.addAttribute(
      .t3BlockLayoutWidth, value: tableWidth,
      range: NSRange(location: start, length: output.length - start))
    tables.append(
      RenderedMarkdownTable(
        range: NSRange(location: start, length: output.length - start), columns: columns,
        rows: rows.count, contentWidth: tableWidth))
    paragraph(NSAttributedString(string: ""), style: style, after: 2)
  }
}
