import AppKit
import Testing

@testable import T3Markdown

@MainActor @Test func blocksKeepTheirContentAndStructure() throws {
  let source = """
    # Heading

    A **bold** paragraph with `inline_code` and [link](https://example.test).

    3. Three
    4. Four
       - Nested

    - [x] Done
    - [ ] Remaining

    > Quoted text

    ```swift
    let greeting = "hello"
    print(greeting)
    ```
    """
  let rendered = MarkdownRenderer.render(source, width: 600)
  #expect(rendered.text.string.contains("Heading\n"))
  #expect(rendered.text.string.contains("3.\tThree"))
  #expect(rendered.text.string.contains("4.\tFour"))
  #expect(rendered.text.string.contains("•\tNested"))
  #expect(rendered.text.string.contains("☑\tDone"))
  #expect(rendered.text.string.contains("☐\tRemaining"))
  #expect(rendered.codeBlocks.count == 1)
  #expect(rendered.codeBlocks[0].code == "let greeting = \"hello\"\nprint(greeting)\n")
  let string = rendered.text.string as NSString
  let headingFont = try #require(
    rendered.text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
  let paragraphFont = try #require(
    rendered.text.attribute(.font, at: string.range(of: "paragraph").location, effectiveRange: nil)
      as? NSFont)
  #expect(headingFont.pointSize > paragraphFont.pointSize)
  let link =
    rendered.text.attribute(.link, at: string.range(of: "link").location, effectiveRange: nil)
    as? URL
  #expect(link?.absoluteString == "https://example.test")
  #expect(MarkdownRenderer.height(of: rendered.text, width: 600) > 150)
}

@MainActor @Test func gfmTablesUseNativeTextTablesAndReflow() throws {
  let source = """
    | Name | Description |
    | :--- | ---: |
    | First | A longer description that should wrap as the available space gets smaller. |
    | Second | **Formatted** content |
    """
  let wide = MarkdownRenderer.render(source, width: 700)
  let narrow = MarkdownRenderer.render(source, width: 240)
  let style = try #require(
    wide.text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
  let block = try #require(style.textBlocks.first as? NSTextTableBlock)
  #expect(block.table.numberOfColumns == 2)
  #expect(wide.text.string.contains("First\nA longer description"))
  #expect(
    MarkdownRenderer.height(of: narrow.text, width: 240)
      > MarkdownRenderer.height(of: wide.text, width: 700))
  let description = (wide.text.string as NSString).range(of: "Description")
  let aligned = try #require(
    wide.text.attribute(.paragraphStyle, at: description.location, effectiveRange: nil)
      as? NSParagraphStyle)
  #expect(aligned.alignment == .right)
}

@MainActor @Test func incompleteStreamingCodeAndUnicodeRemainCopyable() throws {
  let code = "// 🌊 café\nlet value = \"**literal**\""
  let rendered = MarkdownRenderer.render("```swift\n" + code, width: 340)
  let block = try #require(rendered.codeBlocks.first)
  #expect(block.code.trimmingCharacters(in: .newlines) == code)
  #expect(NSMaxRange(block.range) <= rendered.text.length)
  #expect(rendered.text.attributedSubstring(from: block.range).string.contains("**literal**"))
  #expect(MarkdownRenderer.height(of: rendered.text, width: 340).isFinite)
}

@MainActor @Test func markupDoesNotActivateExecutableSchemesOrHTML() throws {
  let rendered = MarkdownRenderer.render(
    "[bad](javascript:alert%281%29) <script>bad()</script> ![Image description](https://example.test/picture.png)",
    width: 400)
  #expect(rendered.text.string.contains("bad"))
  #expect(rendered.text.string.contains("[Image description]"))
  #expect(rendered.text.attribute(.link, at: 0, effectiveRange: nil) == nil)
  #expect(rendered.text.string.contains("<script>"))
}

@MainActor @Test func cardHeadingsRemainBelowTheTitleWithoutChangingCopyableContent() throws {
  let source = "# Details\n\n## Steps\n\n```swift\nlet value = 1\n```\n"
  let normal = MarkdownRenderer.render(source, width: 500)
  let card = MarkdownRenderer.render(source, width: 500, headingLevelOffset: 3)
  #expect(card.text.string == normal.text.string)
  #expect(card.codeBlocks.first?.code == "let value = 1\n")
  let normalFont = try #require(normal.text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
  let cardFont = try #require(card.text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
  #expect(cardFont.pointSize < normalFont.pointSize)
  #expect(
    MarkdownRenderer.height(of: card.text, width: 500)
      < MarkdownRenderer.height(of: normal.text, width: 500))
}
