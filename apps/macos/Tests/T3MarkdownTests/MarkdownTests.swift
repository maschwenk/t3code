import AppKit
import Testing

@testable import T3Markdown

@MainActor @Test func editableTasksLocateExactSourceMarkersAcrossUnicodeAndNestedLists() throws {
  for newline in ["\n", "\r\n", "\r"] {
    let source = [
      "# 🦉 café", "", "- [ ] first", "  - [X] second", "", "> 1. [x] quoted", "",
      "```md", "- [ ] code, never editable", "```", "", "- [ ] fourth with [ ] literal",
    ].joined(separator: newline)
    let rendered = MarkdownRenderer.render(source, width: 360, taskLinks: true)
    #expect(
      rendered.tasks.count == 4,
      "newline=\(newline.debugDescription), tasks=\(rendered.tasks.map(\.sourceOffset)), text=\(rendered.text.string.debugDescription)"
    )
    for (marker, checked) in [
      ("[ ] first", false), ("[X] second", true), ("[x] quoted", true), ("[ ] fourth", false),
    ] {
      let expected = (source as NSString).range(of: marker).location
      let task = try #require(rendered.tasks.first(where: { $0.sourceOffset == expected }))
      #expect(task.checked == checked)
      #expect(rendered.text.attributedSubstring(from: task.range).string == (checked ? "☑" : "☐"))
      #expect(
        (rendered.text.attribute(.link, at: task.range.location, effectiveRange: nil) as? URL)?
          .lastPathComponent == String(expected))
    }
    let readonly = MarkdownRenderer.render(source, width: 360)
    #expect(readonly.tasks.isEmpty)
    #expect(readonly.text.string == rendered.text.string)
  }
}

@MainActor @Test func workspaceLinkResolutionControlsTheRenderedDestination() {
  let rendered = MarkdownRenderer.render("[sibling](../notes.md) [blocked](custom:run)", width: 400)
  { destination in
    destination == "../notes.md" ? URL(fileURLWithPath: "/repo/notes.md") : nil
  }
  let text = rendered.text.string as NSString
  #expect(
    (rendered.text.attribute(.link, at: text.range(of: "sibling").location, effectiveRange: nil)
      as? URL)?.path == "/repo/notes.md")
  #expect(
    rendered.text.attribute(.link, at: text.range(of: "blocked").location, effectiveRange: nil)
      == nil)
}

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

@MainActor @Test func polishedCodeHasExactSelectableContentAndLexicalHighlighting() throws {
  let code = "// 🌊 let greeting = 17\nlet greeting: String = \"return 42\"\nprint(greeting)\n"
  let rendered = MarkdownRenderer.render(
    "```swift\n" + code + "```", width: 420, configuration: .message)
  let block = try #require(rendered.codeBlocks.first)
  #expect(rendered.text.attributedSubstring(from: block.range).string == code)
  let surface = try #require(block.surfaceRange)
  let header = try #require(block.headerRange)
  #expect(header.location == surface.location)
  #expect(NSMaxRange(header) == block.range.location)
  #expect(NSMaxRange(surface) == NSMaxRange(block.range))
  let text = rendered.text.string as NSString
  for (sample, token) in [
    ("// 🌊 let greeting = 17", "comment"), ("let greeting:", "keyword"),
    ("String", "type"), ("\"return 42\"", "string"),
  ] {
    let range = text.range(of: sample)
    #expect(
      rendered.text.attribute(.t3SyntaxToken, at: range.location, effectiveRange: nil) as? String
        == token)
  }
  let literal = text.range(of: "42")
  #expect(
    rendered.text.attribute(.t3SyntaxToken, at: literal.location, effectiveRange: nil) as? String
      == "string")
  let style = try #require(
    rendered.text.attribute(.paragraphStyle, at: block.range.location, effectiveRange: nil)
      as? NSParagraphStyle)
  #expect(style.textBlocks.first is NSTextTableBlock)
  #expect(style.paragraphSpacing == 0)
  #expect(style.lineBreakMode == .byCharWrapping)
  #expect(
    MarkdownRenderer.height(of: rendered.text, width: 420)
      > MarkdownRenderer.height(
        of: NSAttributedString(
          string: code,
          attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)]),
        width: 420))
}

@MainActor @Test func localCodeWrappingReflowsWithoutChangingLinksTasksOrCachedStyles() throws {
  let code = "const 🦉 = \"" + String(repeating: "wide ", count: 36) + "\";\n"
  let source = "- [ ] keep\n\n[notes](file:///repo/notes.md)\n\n```ts\n" + code + "```\n\nEnd."
  let original = MarkdownRenderer.render(
    source, width: 280, taskLinks: true, configuration: .message)
  let unwrapped = MarkdownRenderer.settingCodeWrapping(false, at: 0, in: original, width: 280)
  #expect(unwrapped.text.string == original.text.string)
  #expect(unwrapped.contentWidth > 280)
  #expect(
    MarkdownRenderer.height(of: unwrapped.text, width: 280)
      < MarkdownRenderer.height(of: original.text, width: 280))
  #expect(unwrapped.tasks.map(\.sourceOffset) == original.tasks.map(\.sourceOffset))
  let link = (original.text.string as NSString).range(of: "notes").location
  #expect(
    unwrapped.text.attribute(.link, at: link, effectiveRange: nil) as? URL
      == URL(string: "file:///repo/notes.md"))
  let block = try #require(original.codeBlocks.first)
  let originalStyle = try #require(
    original.text.attribute(.paragraphStyle, at: block.range.location, effectiveRange: nil)
      as? NSParagraphStyle)
  #expect(originalStyle.lineBreakMode == .byCharWrapping)
  let wrapped = MarkdownRenderer.settingCodeWrapping(true, at: 0, in: unwrapped, width: 280)
  #expect(wrapped.codeBlocks.first?.code == code)
  #expect(wrapped.contentWidth == 280)
  #expect(
    MarkdownRenderer.height(of: wrapped.text, width: 280)
      == MarkdownRenderer.height(of: original.text, width: 280))
}

@MainActor @Test func polishedTablesHaveRowRulesCapsulesAndRealCellLinks() throws {
  let source = """
    | Name | Description |
    | :--- | ---: |
    | `alpha()` | [Reference](https://example.test/ref) with a long description that wraps in a narrow cell |
    | Beta | **Bold** detail |
    """
  let wide = MarkdownRenderer.render(source, width: 640, configuration: .message)
  let narrow = MarkdownRenderer.render(source, width: 250, configuration: .message)
  let table = try #require(wide.tables.first)
  #expect(table.columns == 2)
  #expect(table.rows == 3)
  let text = wide.text.string as NSString
  let capsule = text.range(of: "alpha()")
  #expect(wide.text.attribute(.t3InlineCode, at: capsule.location, effectiveRange: nil) != nil)
  let headerStyle = try #require(
    wide.text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
  let header = try #require(headerStyle.textBlocks.first as? NSTextTableBlock)
  #expect(header.width(for: .border, edge: .minX) == 0)
  #expect(header.width(for: .border, edge: .maxY) > 0)
  let bodyStyle = try #require(
    wide.text.attribute(.paragraphStyle, at: capsule.location, effectiveRange: nil)
      as? NSParagraphStyle)
  let body = try #require(bodyStyle.textBlocks.first as? NSTextTableBlock)
  #expect(body.startingRow == 1)
  #expect(body.width(for: .border, edge: .maxY) < header.width(for: .border, edge: .maxY))
  let link = text.range(of: "Reference").location
  #expect(
    wide.text.attribute(.link, at: link, effectiveRange: nil) as? URL
      == URL(string: "https://example.test/ref"))
  #expect(
    MarkdownRenderer.height(of: narrow.text, width: 250)
      > MarkdownRenderer.height(of: wide.text, width: 640))
  var overflow = MarkdownConfiguration.message
  overflow.wrapTables = false
  let natural = MarkdownRenderer.render(source, width: 250, configuration: overflow)
  #expect(natural.contentWidth > 250)
  #expect(
    MarkdownRenderer.height(of: natural.text, width: 250)
      < MarkdownRenderer.height(of: narrow.text, width: 250))
}

@MainActor @Test func polishedTypographyRespectsScaleAndMarkdownLineBreaks() throws {
  let source = "# Reading\n\nA soft\nbreak and a hard  \nbreak with `code`.\n\nAnother paragraph."
  let legacy = MarkdownRenderer.render(source, width: 380)
  let message = MarkdownRenderer.render(source, width: 380, configuration: .message)
  #expect(legacy.text.string.contains("A soft\nbreak"))
  #expect(message.text.string.contains("A soft break and a hard\nbreak"))
  let paragraph = (message.text.string as NSString).range(of: "A soft").location
  let messageStyle = try #require(
    message.text.attribute(.paragraphStyle, at: paragraph, effectiveRange: nil) as? NSParagraphStyle
  )
  let legacyStyle = try #require(
    legacy.text.attribute(.paragraphStyle, at: paragraph, effectiveRange: nil) as? NSParagraphStyle)
  #expect(messageStyle.lineSpacing > legacyStyle.lineSpacing)
  #expect(messageStyle.paragraphSpacing > legacyStyle.paragraphSpacing)
  var larger = MarkdownConfiguration.message
  larger.fontSize = 20
  let scaled = MarkdownRenderer.render(source, width: 380, configuration: larger)
  #expect(
    MarkdownRenderer.height(of: scaled.text, width: 380)
      > MarkdownRenderer.height(of: message.text, width: 380))
}

@MainActor @Test func unknownAndLargeCodeRemainLiteralWithoutInventedLinksOrTokens() throws {
  for (language, code) in [
    ("unknown", "let café = \"https://example.test\"\n"),
    ("swift", String(repeating: "let value = 1\n", count: 12_000)),
  ] {
    let rendered = MarkdownRenderer.render(
      "```" + language + "\n" + code + "```", width: 320, configuration: .message)
    let block = try #require(rendered.codeBlocks.first)
    #expect(rendered.text.attributedSubstring(from: block.range).string == code)
    #expect(
      rendered.text.attribute(.t3SyntaxToken, at: block.range.location, effectiveRange: nil) == nil)
    #expect(rendered.text.attribute(.link, at: block.range.location, effectiveRange: nil) == nil)
  }
}

@MainActor @Test func overflowingCodeAndTablesLayOutTheirLastGlyphWhileProseStaysBounded() throws {
  var configuration = MarkdownConfiguration.message
  configuration.wrapCode = false
  configuration.wrapTables = false
  let source = """
    Prose still uses the viewport and wraps onto several lines when the window is narrow.

    ```swift
    let value = "\(String(repeating: "abc ", count: 40))CODE_END"
    ```

    | First | Second |
    | --- | --- |
    | \(String(repeating: "long ", count: 24)) | [TABLE_END](https://example.test/table) |

    After the blocks, prose still wraps within the viewport and remains fully selectable.
    """
  let rendered = MarkdownRenderer.render(source, width: 260, configuration: configuration)
  let storage = NSTextStorage(attributedString: rendered.text)
  let layout = MarkdownLayoutManager()
  let container = MarkdownTextContainer(text: rendered.text, width: 260)
  container.lineFragmentPadding = 0
  storage.addLayoutManager(layout)
  layout.addTextContainer(container)
  layout.ensureLayout(for: container)
  let text = rendered.text.string as NSString
  for marker in ["CODE_END", "TABLE_END"] {
    let range = text.range(of: marker)
    let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
    let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
    #expect(rect.width > 0)
    #expect(rect.maxX <= rendered.contentWidth, "\(marker) must fit the scrollable document")
    #expect(rect.maxX > 260, "\(marker) should be reachable by horizontal scrolling: \(rect)")
  }
  let prose = text.range(of: "After the blocks")
  let glyphs = layout.glyphRange(forCharacterRange: prose, actualCharacterRange: nil)
  #expect(layout.boundingRect(forGlyphRange: glyphs, in: container).maxX <= 260)
}

@MainActor @Test func selectedFontFamiliesApplyAcrossReadingAndCodeSurfacesWithFallbacks() throws {
  let source =
    "# Heading\n\nA body with `inline()` text.\n\n| Header |\n| --- |\n| Cell |\n\n```swift\nlet value = 1\n```"
  var selected = MarkdownConfiguration.message
  selected.fontName = "Menlo-Regular"
  selected.codeFontName = "Georgia"
  let rendered = MarkdownRenderer.render(source, width: 380, configuration: selected)
  let text = rendered.text.string as NSString
  let bodyFont = try #require(NSFont(name: selected.fontName, size: selected.fontSize))
  let codeFont = try #require(NSFont(name: selected.codeFontName, size: selected.codeFontSize))
  for marker in ["Heading", "A body", "Header", "Cell"] {
    let font = try #require(
      rendered.text.attribute(.font, at: text.range(of: marker).location, effectiveRange: nil)
        as? NSFont)
    #expect(font.familyName == bodyFont.familyName)
  }
  for marker in ["inline()", "let value"] {
    let font = try #require(
      rendered.text.attribute(.font, at: text.range(of: marker).location, effectiveRange: nil)
        as? NSFont)
    #expect(font.familyName == codeFont.familyName)
  }
  let defaults = MarkdownRenderer.render(source, width: 380, configuration: .message)
  #expect(
    MarkdownRenderer.height(of: defaults.text, width: 380)
      != MarkdownRenderer.height(of: rendered.text, width: 380))
  selected.fontName = "Missing-T3-Font"
  selected.codeFontName = "Missing-T3-Code-Font"
  let fallback = MarkdownRenderer.render(source, width: 380, configuration: selected)
  #expect(fallback.text.string == defaults.text.string)
  #expect(
    MarkdownRenderer.height(of: fallback.text, width: 380)
      == MarkdownRenderer.height(of: defaults.text, width: 380))
}
