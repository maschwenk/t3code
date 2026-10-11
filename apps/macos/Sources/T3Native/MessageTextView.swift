import AppKit
import T3Markdown

@MainActor final class MessageTextView: NSTextView, NSTextViewDelegate {
  var onOpenLink: ((URL) -> Void)?
  private let rendered: RenderedMarkdown

  init(rendered: RenderedMarkdown, width: CGFloat, height: CGFloat) {
    self.rendered = rendered
    let storage = NSTextStorage(attributedString: rendered.text)
    let layout = NSLayoutManager()
    let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
    container.lineFragmentPadding = 0
    container.widthTracksTextView = true
    storage.addLayoutManager(layout)
    layout.addTextContainer(container)
    super.init(frame: NSRect(x: 0, y: 0, width: width, height: height), textContainer: container)
    delegate = self
    isEditable = false
    isSelectable = true
    isRichText = true
    drawsBackground = false
    textContainerInset = .zero
    isHorizontallyResizable = false
    isVerticallyResizable = false
    linkTextAttributes = [
      .foregroundColor: NSColor.linkColor
    ]
    setAccessibilityLabel("Message content")
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private func open(_ url: URL) {
    if let onOpenLink { onOpenLink(url) } else { NSWorkspace.shared.open(url) }
  }
  func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
    guard let url = link as? URL else { return false }
    open(url)
    return true
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    let menu = NSMenu()
    menu.autoenablesItems = false
    guard let layoutManager, let textContainer else { return menu }
    let point = convert(event.locationInWindow, from: nil)
    let index = layoutManager.characterIndex(
      for: NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y),
      in: textContainer, fractionOfDistanceBetweenInsertionPoints: nil)
    if let code = rendered.codeBlocks.first(where: { NSLocationInRange(index, $0.range) }) {
      menu.addItem(
        ActionMenuItem("Copy code") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(code.code, forType: .string)
        })
    }
    if index < rendered.text.length,
      let link = rendered.text.attribute(.link, at: index, effectiveRange: nil) as? URL
    {
      if link.scheme == "t3-markdown-task" {
        menu.addItem(ActionMenuItem("Toggle task") { [weak self] in self?.open(link) })
      } else {
        menu.addItem(ActionMenuItem("Open link") { [weak self] in self?.open(link) })
        menu.addItem(
          ActionMenuItem("Copy link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link.absoluteString, forType: .string)
          })
      }
    }
    if !menu.items.isEmpty { menu.addItem(.separator()) }
    let copy = NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
    copy.target = self
    copy.isEnabled = selectedRange().length > 0
    menu.addItem(copy)
    let select = NSMenuItem(
      title: "Select all", action: #selector(selectAll(_:)), keyEquivalent: "")
    select.target = self
    menu.addItem(select)
    return menu
  }
}
