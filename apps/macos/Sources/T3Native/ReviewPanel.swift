import AppKit
import T3Core

@MainActor
final class ReviewPanel: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
  NSTextViewDelegate, NSSearchFieldDelegate
{
  private let store: ClientStore
  let changes: ReviewChanges
  var onClose: (() -> Void)?
  var onOpenFile: ((URL, WorkspaceLocation) -> Void)?
  private let sources = NSPopUpButton(frame: .zero, pullsDown: false)
  private let base = NSTextField()
  private let whitespace = NSButton(
    checkboxWithTitle: "Ignore whitespace", target: nil, action: nil)
  private let wrap = NSButton(checkboxWithTitle: "Wrap lines", target: nil, action: nil)
  private let layoutStyle = NSSegmentedControl(
    labels: ["Unified", "Split"], trackingMode: .selectOne, target: nil, action: nil)
  private let search = NSSearchField()
  private let table = NSTableView()
  private let summary = NSTextField(wrappingLabelWithString: "")
  private let status = NSTextField(wrappingLabelWithString: "")
  private let path = NSTextField(labelWithString: "Select a changed file")
  private let text = NSTextView()
  private let scroll = NSScrollView()
  private let splitDiff = SplitReviewView(frame: .zero)
  private let openButton = NSButton(title: "Open file", target: nil, action: nil)
  private let copyButton = NSButton(title: "Copy patch", target: nil, action: nil)
  private let retryButton = NSButton(title: "Retry file", target: nil, action: nil)
  private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
  private let expandButton = NSButton(title: "Expand all context", target: nil, action: nil)
  private let collapseButton = NSButton(title: "Collapse context", target: nil, action: nil)
  private var filtered: [ReviewFile] = []
  private var displayedFiles: [ReviewFile] = []
  private var displayedSources: [String] = []
  private var renderedRevision: UUID?
  private var renderedFile: UUID?
  private var location: WorkspaceLocation?
  private var updating = false
  private var displayLimited = false

  init(store: ClientStore) {
    self.store = store
    changes = ReviewChanges(store: store)
    super.init(nibName: nil, bundle: nil)
    changes.onChange = { [weak self] in self?.refresh() }
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func loadView() {
    let surface = SurfaceView(sidebar: true)
    view = surface
    let heading = NSTextField(labelWithString: "Changes")
    heading.font = .systemFont(ofSize: 14, weight: .semibold)
    let close = NSButton(title: "Close", target: self, action: #selector(closePanel))
    refreshButton.target = self
    refreshButton.action = #selector(reload)
    let header = NSStackView(views: [heading, NSView(), refreshButton, close])
    sources.target = self
    sources.action = #selector(selectSource)
    sources.setAccessibilityLabel("Change comparison")
    base.placeholderString = "Automatic base branch"
    base.setAccessibilityLabel("Base branch or revision")
    base.target = self
    base.action = #selector(compare)
    let compareButton = NSButton(title: "Compare", target: self, action: #selector(compare))
    let comparison = NSStackView(views: [base, compareButton])
    base.setContentHuggingPriority(.defaultLow, for: .horizontal)
    whitespace.target = self
    whitespace.action = #selector(compare)
    wrap.target = self
    wrap.action = #selector(toggleWrap)
    wrap.state = UserDefaults.standard.bool(forKey: "reviewWrapLines") ? .on : .off
    layoutStyle.target = self
    layoutStyle.action = #selector(changeLayout)
    layoutStyle.selectedSegment =
      UserDefaults.standard.string(forKey: "reviewDiffLayout") == "split" ? 1 : 0
    layoutStyle.setAccessibilityLabel("Diff layout")
    let options = NSStackView(views: [layoutStyle, NSView(), wrap])
    let sourceOptions = NSStackView(views: [sources, whitespace])
    sources.setContentHuggingPriority(.defaultLow, for: .horizontal)
    search.placeholderString = "Filter changed files"
    search.setAccessibilityLabel("Filter changed files")
    search.delegate = self
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("change"))
    table.addTableColumn(column)
    table.headerView = nil
    table.rowHeight = 42
    table.intercellSpacing = NSSize(width: 0, height: 2)
    table.dataSource = self
    table.delegate = self
    table.setAccessibilityLabel("Changed files")
    let filesScroll = NSScrollView()
    filesScroll.documentView = table
    filesScroll.hasVerticalScroller = true
    filesScroll.autohidesScrollers = true
    summary.font = .systemFont(ofSize: 11)
    summary.textColor = .secondaryLabelColor
    let browser = stack([search, summary, filesScroll])
    path.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
    path.lineBreakMode = .byTruncatingMiddle
    path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    for (button, action) in [
      (openButton, #selector(openFile)), (copyButton, #selector(copyPatch)),
      (retryButton, #selector(retryFile)),
    ] {
      button.target = self
      button.action = action
    }
    let actions = NSStackView(views: [path, NSView(), copyButton, openButton])
    status.font = .systemFont(ofSize: 11)
    status.textColor = .secondaryLabelColor
    status.maximumNumberOfLines = 4
    text.isEditable = false
    text.isSelectable = true
    text.isRichText = false
    text.isAutomaticLinkDetectionEnabled = false
    text.usesFindBar = true
    text.isIncrementalSearchingEnabled = true
    text.isVerticallyResizable = true
    text.textContainerInset = NSSize(width: 8, height: 8)
    text.delegate = self
    text.setAccessibilityLabel("File diff, old and new line numbers")
    text.linkTextAttributes = [:]
    scroll.documentView = text
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    splitDiff.onOpenLine = { [weak self] line in self?.open(line: line) }
    splitDiff.onExpandContext = { [weak self] id in self?.changes.expandContext(id) }
    expandButton.target = self
    expandButton.action = #selector(expandContext)
    collapseButton.target = self
    collapseButton.action = #selector(collapseContext)
    let contextActions = NSStackView(views: [expandButton, collapseButton, NSView()])
    let detail = stack([actions, contextActions, status, retryButton, scroll, splitDiff])
    let split = NSSplitView()
    split.isVertical = false
    split.dividerStyle = .thin
    split.addArrangedSubview(browser)
    split.addArrangedSubview(detail)
    let content = stack([header, sourceOptions, comparison, options, split])
    surface.addSubview(content)
    content.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      content.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 12),
      content.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -12),
      content.topAnchor.constraint(equalTo: surface.topAnchor, constant: 46),
      content.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -12),
      browser.heightAnchor.constraint(greaterThanOrEqualToConstant: 110),
      detail.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
    ])
    let height = browser.heightAnchor.constraint(equalToConstant: 200)
    height.priority = .defaultLow
    height.isActive = true
    applyWrap()
    refresh()
  }

  private func stack(_ children: [NSView]) -> NSStackView {
    let result = NSStackView(views: children)
    result.orientation = .vertical
    result.alignment = .leading
    result.spacing = 8
    for child in children {
      child.widthAnchor.constraint(equalTo: result.widthAnchor).isActive = true
    }
    return result
  }

  func refreshContext(active: Bool) { changes.refreshContext(active: active) }
  func openCheckpoint(_ id: String, filePath: String?) {
    search.stringValue = ""
    changes.openCheckpoint(id, filePath: filePath)
    refresh()
  }
  func focus() { view.window?.makeFirstResponder(search) }
  func find() {
    if layoutStyle.selectedSegment == 1 {
      splitDiff.find()
      return
    }
    view.window?.makeFirstResponder(text)
    let item = NSMenuItem()
    item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
    text.performFindPanelAction(item)
  }

  private func refresh() {
    guard isViewLoaded else { return }
    updating = true
    defer { updating = false }
    if location != changes.location {
      location = changes.location
      search.stringValue = ""
      base.stringValue = changes.baseRef
    }
    let comparisons = changes.comparisons
    let keys = comparisons.map { $0.id + ":" + $0.title }
    if keys != displayedSources {
      displayedSources = keys
      sources.removeAllItems()
      sources.addItems(withTitles: comparisons.map(\.title))
    }
    if let index = comparisons.firstIndex(where: { $0.id == changes.sourceKind }) {
      sources.selectItem(at: index)
    } else {
      sources.select(nil)
      sources.title = "Saved changes unavailable"
    }
    sources.isEnabled = !changes.loading
    table.isEnabled = !changes.loading
    base.isHidden = changes.sourceKind != "branch-range"
    base.superview?.isHidden = base.isHidden
    whitespace.state = changes.ignoreWhitespace ? .on : .off
    refreshButton.isEnabled = changes.canRefresh
    refreshButton.title = changes.loading ? "Refreshing…" : "Refresh"
    filtered = (changes.source?.files ?? []).filter {
      search.stringValue.isEmpty || $0.path.localizedCaseInsensitiveContains(search.stringValue)
        || $0.previousPath?.localizedCaseInsensitiveContains(search.stringValue) == true
    }
    if displayedFiles != filtered {
      displayedFiles = filtered
      table.reloadData()
    }
    if let index = filtered.firstIndex(where: { $0.path == changes.selectedPath }) {
      table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    } else {
      table.deselectAll(nil)
    }
    let files = changes.source?.files ?? []
    let totals = files.reduce((0, 0)) { ($0.0 + $1.additions, $0.1 + $1.deletions) }
    summary.stringValue = "\(files.count) files   +\(totals.0)  −\(totals.1)"
    if changes.source?.completeFileList == false && changes.source?.truncated == true {
      summary.stringValue += " · File list is incomplete"
    }
    path.stringValue = changes.file?.path ?? "Select a changed file"
    path.toolTip = changes.file.map { file in
      file.previousPath.map { "\($0) → \(file.path)" } ?? file.path
    }
    copyButton.isEnabled = !changes.rawPatch.isEmpty
    openButton.isEnabled = changes.patch != nil && changes.patch?.isDeleted != true
    retryButton.isHidden = changes.fileError == nil
    retryButton.isEnabled = changes.canRefresh
    expandButton.superview?.isHidden = !changes.canExpandContext
    expandButton.isEnabled = !changes.loadingContext
    expandButton.title = changes.loadingContext ? "Loading context…" : "Expand all context"
    collapseButton.isEnabled = changes.hasExpandedContext || changes.loadingContext
    if renderedRevision != changes.patchRevision {
      renderedRevision = changes.patchRevision
      render()
    }
    status.textColor =
      changes.error != nil || changes.fileError != nil || changes.contextError != nil
      ? .systemOrange : .secondaryLabelColor
    if let error = changes.error ?? changes.fileError ?? changes.contextError {
      status.stringValue = error
    } else if changes.loading {
      status.stringValue = "Loading changes…"
    } else if changes.loadingFile {
      status.stringValue = "Loading patch…"
    } else if changes.loadingContext {
      status.stringValue = "Loading unchanged context…"
    } else if !store.ready {
      status.stringValue = "Connect to review changes."
    } else if changes.location == nil {
      status.stringValue = "Select a thread to review its workspace."
    } else if !changes.isCheckpoint && changes.snapshot?.sources.isEmpty == true {
      status.stringValue = "This workspace has no supported repository."
    } else if files.isEmpty {
      status.stringValue = "No changes in this comparison."
    } else if changes.truncated || displayLimited || changes.contextLimited
      || changes.isCheckpoint && changes.source?.truncated == true
    {
      status.stringValue =
        "This patch is incomplete or too large to display in full. Open the file to inspect it. Copy patch includes the loaded patch."
    } else if changes.patch?.isBinary == true {
      status.stringValue = "Binary file changed. Open file to preview the current version."
    } else {
      status.stringValue =
        "Old → new line numbers. Click a new line number to open the current file."
    }
  }

  private func render() {
    let preservePosition = renderedFile == changes.fileRevision
    renderedFile = changes.fileRevision
    let split = layoutStyle.selectedSegment == 1
    scroll.isHidden = split
    splitDiff.isHidden = !split
    if split {
      displayLimited = splitDiff.render(changes.displayPatch, preservePosition: preservePosition)
    } else {
      let position = preservePosition ? ReviewText.capturePosition(text, in: scroll) : []
      let rendered = ReviewText.render(changes.displayPatch)
      displayLimited = rendered.limited
      text.textStorage?.setAttributedString(rendered.text)
      if preservePosition {
        ReviewText.restorePosition(position, text: text, scroll: scroll)
      } else {
        text.scrollToBeginningOfDocument(nil)
      }
    }
  }

  func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    guard filtered.indices.contains(row) else { return nil }
    let file = filtered[row]
    let name = NSTextField(labelWithString: (file.path as NSString).lastPathComponent)
    name.font = .systemFont(ofSize: 12, weight: .medium)
    name.lineBreakMode = .byTruncatingMiddle
    let parent = NSTextField(
      labelWithString: file.previousPath.map { "\($0) → \(file.path)" } ?? file.path)
    parent.font = .systemFont(ofSize: 10)
    parent.textColor = .secondaryLabelColor
    parent.lineBreakMode = .byTruncatingMiddle
    let labels = NSStackView(views: [name, parent])
    labels.orientation = .vertical
    labels.alignment = .leading
    labels.spacing = 2
    let counts = NSTextField(labelWithString: "+\(file.additions)  −\(file.deletions)")
    counts.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    counts.setContentCompressionResistancePriority(.required, for: .horizontal)
    let result = NSStackView(views: [labels, NSView(), counts])
    result.toolTip = parent.stringValue
    result.setAccessibilityLabel(
      "\(parent.stringValue), \(file.additions) added, \(file.deletions) removed")
    return result
  }
  func tableViewSelectionDidChange(_ notification: Notification) {
    guard !updating, filtered.indices.contains(table.selectedRow) else { return }
    changes.selectFile(filtered[table.selectedRow].path)
  }
  func controlTextDidChange(_ obj: Notification) { refresh() }
  func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
    if let string = link as? String, string.hasPrefix("context:"), let id = Int(string.dropFirst(8))
    {
      changes.expandContext(id)
      return true
    }
    guard let string = link as? String, let line = Int(string) else { return false }
    open(line: line)
    return true
  }
  private func open(line: Int? = nil) {
    guard changes.patch?.isDeleted != true, let location = changes.location,
      let path = changes.absolutePath
    else { return }
    var url = URLComponents(url: URL(fileURLWithPath: path), resolvingAgainstBaseURL: false)
    if let line { url?.fragment = "L\(line)" }
    if let url = url?.url { onOpenFile?(url, location) }
  }
  @objc private func openFile() { open() }
  @objc private func closePanel() { onClose?() }
  @objc private func reload() { changes.refresh() }
  @objc private func retryFile() { changes.loadFile() }
  @objc private func expandContext() { changes.expandContext() }
  @objc private func collapseContext() { changes.collapseContext() }
  @objc private func selectSource() {
    let comparisons = changes.comparisons
    guard comparisons.indices.contains(sources.indexOfSelectedItem)
    else { return }
    changes.selectSource(comparisons[sources.indexOfSelectedItem].id)
  }
  @objc private func compare() {
    changes.compare(baseRef: base.stringValue, ignoreWhitespace: whitespace.state == .on)
  }
  @objc private func copyPatch() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(changes.rawPatch, forType: .string)
  }
  @objc private func toggleWrap() {
    UserDefaults.standard.set(wrap.state == .on, forKey: "reviewWrapLines")
    applyWrap()
  }
  @objc private func changeLayout() {
    UserDefaults.standard.set(
      layoutStyle.selectedSegment == 1 ? "split" : "unified", forKey: "reviewDiffLayout")
    renderedFile = nil
    render()
    refresh()
  }
  private func applyWrap() {
    let wrap = wrap.state == .on
    splitDiff.setWrapped(wrap)
    text.isHorizontallyResizable = !wrap
    text.autoresizingMask = wrap ? [.width] : []
    text.textContainer?.widthTracksTextView = wrap
    text.textContainer?.containerSize = NSSize(
      width: wrap ? max(1, scroll.contentSize.width - 16) : CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude)
    if wrap {
      text.setFrameSize(NSSize(width: scroll.contentSize.width, height: text.frame.height))
    }
    scroll.hasHorizontalScroller = !wrap
  }
}
