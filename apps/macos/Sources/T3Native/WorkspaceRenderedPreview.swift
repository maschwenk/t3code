import AppKit
import T3Core
import T3Markdown

@MainActor private final class MarkdownPreviewCanvas: NSView {
  override var isFlipped: Bool { true }
}

@MainActor final class WorkspaceRenderedPreview: NSView, NSTableViewDataSource, NSTableViewDelegate
{
  var onTask: ((WorkspaceFileID, String, Int, Bool) -> Void)?
  var onFileLink: ((WorkspaceFileID, URL) -> Void)?
  var fileLinkMenu: ((WorkspaceFileID, URL) -> NSMenu?)?
  private let scroll = NSScrollView()
  private let notice = NSTextField(wrappingLabelWithString: "")
  private let table = NSTableView()
  private var source = ""
  private var file: WorkspaceFileID?
  private var editable = false
  private var kind = FilePreviewKind.source
  private var displayedSource: String?
  private var displayedFile: WorkspaceFileID?
  private var displayedEditable = false
  private var displayedWidth: CGFloat = 0
  private var renderTask: Task<Void, Never>?
  private var text: MessageTextView?
  private var rows: [[String]] = []
  private var rowHeights: [CGFloat] = []

  init() {
    super.init(frame: .zero)
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = true
    scroll.autohidesScrollers = true
    scroll.drawsBackground = false
    notice.font = .systemFont(ofSize: 11)
    notice.textColor = .secondaryLabelColor
    notice.isHidden = true
    let stack = NSStackView(views: [notice, scroll])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
      notice.widthAnchor.constraint(equalTo: stack.widthAnchor),
      scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
    ])
    table.dataSource = self
    table.delegate = self
    table.usesAlternatingRowBackgroundColors = true
    table.columnAutoresizingStyle = .noColumnAutoresizing
    table.allowsColumnResizing = false
    table.intercellSpacing = NSSize(width: 12, height: 8)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func show(_ document: WorkspaceFileDocument, id: WorkspaceFileID, editable: Bool) {
    source = document.contents
    file = id
    self.editable = editable
    kind = FilePreviewKind(path: id.path)
    needsLayout = true
    render()
  }
  override func layout() {
    super.layout()
    if displayedFile != file || displayedSource != source {
      render()
      return
    }
    if abs(bounds.width - displayedWidth) > 1 && kind == .markdown {
      renderTask?.cancel()
      renderTask = Task { [weak self] in
        do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
        self?.render()
      }
    }
  }
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    displayedSource = nil
    render()
  }

  private func render() {
    guard let file, bounds.width > 0 else { return }
    let changedFile = displayedFile != file
    let width = max(120, bounds.width - 36)
    guard
      changedFile || displayedSource != source || displayedEditable != editable
        || (kind == .markdown && abs(displayedWidth - bounds.width) > 1)
    else { return }
    let origin = changedFile ? NSPoint.zero : scroll.contentView.bounds.origin
    let selection = changedFile ? NSRange(location: 0, length: 0) : text?.selectedRange()
    let sameText = displayedSource == source
    displayedFile = file
    displayedSource = source
    displayedWidth = bounds.width
    displayedEditable = editable
    if kind == .markdown {
      notice.isHidden = true
      let source = source
      let rendered = MarkdownRenderer.render(source, width: width, taskLinks: editable) {
        WorkspaceMarkdown.link($0, filePath: file.path, root: file.root)
      }
      let height = MarkdownRenderer.height(of: rendered.text, width: width)
      let content = MessageTextView(rendered: rendered, width: width, height: max(20, height))
      content.setAccessibilityLabel("Rendered Markdown")
      content.onOpenLink = { [weak self] url in
        guard let self, self.file == file, self.source == source else { return }
        if url.scheme == "t3-markdown-task",
          let offset = Int(url.lastPathComponent),
          let task = rendered.tasks.first(where: { $0.sourceOffset == offset })
        {
          self.onTask?(file, source, offset, !task.checked)
        } else if url.isFileURL {
          self.onFileLink?(file, url)
        } else if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
          NSWorkspace.shared.open(url)
        }
      }
      content.fileLinkMenu = { [weak self] url in
        guard let self, self.file == file, self.source == source else { return nil }
        return self.fileLinkMenu?(file, url)
      }
      let canvas = MarkdownPreviewCanvas(
        frame: NSRect(x: 0, y: 0, width: bounds.width - 16, height: height + 32))
      content.frame.origin = NSPoint(x: 10, y: 16)
      canvas.addSubview(content)
      text = content
      scroll.documentView = canvas
      if sameText, let selection, NSMaxRange(selection) <= rendered.text.length {
        content.setSelectedRange(selection)
      }
    } else if let delimiter = kind.delimiter {
      text = nil
      let preview = DelimitedFilePreview(source, delimiter: delimiter)
      rows = Array(preview.rows.dropFirst())
      notice.stringValue =
        "Table limited to 100 rows, 30 columns and 2,000 characters per cell. Switch to source for the rest."
      notice.isHidden = !preview.truncated
      for column in table.tableColumns { table.removeTableColumn(column) }
      let count = preview.rows.map(\.count).max() ?? 0
      let font = NSFont.systemFont(ofSize: 12)
      let paragraph = NSMutableParagraphStyle()
      paragraph.lineBreakMode = .byWordWrapping
      let attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]
      for index in 0..<count {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(index)))
        column.title = preview.rows.first.flatMap { index < $0.count ? $0[index] : nil } ?? ""
        let widest = preview.rows.reduce(CGFloat(0)) { width, row in
          index < row.count
            ? max(width, (row[index] as NSString).size(withAttributes: attributes).width) : width
        }
        column.width = min(320, max(96, widest + 20))
        table.addTableColumn(column)
      }
      rowHeights = rows.map { row in
        var height: CGFloat = 22
        for (index, cell) in row.enumerated() where index < table.tableColumns.count {
          let rect = (cell as NSString).boundingRect(
            with: NSSize(
              width: table.tableColumns[index].width - 12, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
          height = max(height, ceil(rect.height) + 8)
        }
        return height
      }
      table.setAccessibilityLabel("Table preview: " + file.path)
      scroll.documentView = table
      table.reloadData()
    }
    scroll.contentView.scroll(
      to: NSPoint(
        x: origin.x,
        y: min(
          origin.y,
          max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentSize.height))))
    scroll.reflectScrolledClipView(scroll.contentView)
  }

  func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
  func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { rowHeights[row] }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    guard let column = tableColumn, let index = Int(column.identifier.rawValue) else { return nil }
    let id = NSUserInterfaceItemIdentifier("table-cell")
    let cell =
      (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? NSTableCellView()
    if cell.textField == nil {
      cell.identifier = id
      let label = NSTextField(wrappingLabelWithString: "")
      label.font = .systemFont(ofSize: 12)
      label.isSelectable = true
      cell.textField = label
      cell.addSubview(label)
      label.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
        label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
        label.topAnchor.constraint(equalTo: cell.topAnchor, constant: 4),
      ])
    }
    cell.textField?.stringValue = index < rows[row].count ? rows[row][index] : ""
    cell.toolTip = cell.textField?.stringValue
    return cell
  }
}
