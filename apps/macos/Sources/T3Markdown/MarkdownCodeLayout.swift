import AppKit

extension MarkdownRenderer {
  /// Changes only TextKit styles/geometry. Content, highlights, links, and source offsets stay intact.
  public static func settingCodeWrapping(
    _ wraps: Bool, at index: Int, in rendered: RenderedMarkdown, width: CGFloat
  ) -> RenderedMarkdown {
    guard rendered.codeBlocks.indices.contains(index),
      let range = rendered.codeBlocks[index].surfaceRange
    else { return rendered }
    let original = rendered.codeBlocks[index]
    let text = NSMutableAttributedString(attributedString: rendered.text)
    let font =
      text.attribute(.font, at: original.range.location, effectiveRange: nil) as? NSFont
      ?? rendered.configuration.codeFont()
    let naturalWidth =
      original.code.split(separator: "\n", omittingEmptySubsequences: false)
      .reduce(CGFloat(0)) {
        max($0, (String($1) as NSString).size(withAttributes: [.font: font]).width)
      } + 28
    let surfaceWidth = wraps ? max(120, width) : max(width, naturalWidth)
    let table = NSTextTable()
    table.numberOfColumns = 1
    table.layoutAlgorithm = .fixedLayoutAlgorithm
    table.setValue(surfaceWidth, type: .absoluteValueType, for: .width)
    let cell = NSTextTableBlock(
      table: table, startingRow: 0, rowSpan: 1, startingColumn: 0, columnSpan: 1)
    cell.setWidth(14, type: .absoluteValueType, for: .padding)
    rendered.text.enumerateAttribute(.paragraphStyle, in: range) { value, subrange, _ in
      guard let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
      else { return }
      style.textBlocks = [cell]
      style.lineBreakMode = wraps ? .byCharWrapping : .byClipping
      text.addAttribute(.paragraphStyle, value: style, range: subrange)
    }
    text.addAttribute(.t3BlockLayoutWidth, value: surfaceWidth, range: range)
    var blocks = rendered.codeBlocks
    blocks[index] = RenderedCodeBlock(
      range: original.range, code: original.code, language: original.language,
      surfaceRange: range, headerRange: original.headerRange, contentWidth: surfaceWidth,
      wraps: wraps)
    let contentWidth = max(
      width, blocks.map(\.contentWidth).max() ?? width,
      rendered.tables.map(\.contentWidth).max() ?? width)
    return RenderedMarkdown(
      text: text, codeBlocks: blocks, tasks: rendered.tasks, tables: rendered.tables,
      contentWidth: contentWidth, configuration: rendered.configuration)
  }
}
