import AppKit
import T3Core

@MainActor final class QueuePanel: NSStackView, NSTableViewDataSource, NSTableViewDelegate {
  private let store: ClientStore
  private let previews: AttachmentPreviews
  private let table = NSTableView()
  private let scroll = NSScrollView()
  private let header = NSStackView()
  private let editBanner = NSStackView()
  private var listHeight: NSLayoutConstraint!
  private var expanded = true
  private var state: State?
  private let dragType = NSPasteboard.PasteboardType("app.t3.native.queued-run")
  private struct State: Equatable {
    let environment: String
    let thread: String?
    let queued: [QueuedMessage]
    let held: Bool
    let canQueue: Bool
    let canSteer: Bool
    let interrupts: Bool
    let resumable: String?
    let editing: String?
    let savedEdits: [QueuedEdit]
    let returningToQuestion: Bool
    let busy: Bool
    let importing: Bool
    let sending: Bool
  }

  init(store: ClientStore, previews: AttachmentPreviews) {
    self.store = store
    self.previews = previews
    super.init(frame: .zero)
    orientation = .vertical
    alignment = .leading
    spacing = 6
    table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("queue")))
    table.headerView = nil
    table.backgroundColor = .clear
    table.rowHeight = 44
    table.intercellSpacing = NSSize(width: 0, height: 4)
    table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
    table.selectionHighlightStyle = .none
    table.delegate = self
    table.dataSource = self
    table.registerForDraggedTypes([dragType])
    table.setDraggingSourceOperationMask(.move, forLocal: true)
    table.setAccessibilityLabel("Queued messages")
    scroll.documentView = table
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    listHeight = scroll.heightAnchor.constraint(equalToConstant: 0)
    listHeight.isActive = true
    for view in [header, scroll, editBanner] {
      addArrangedSubview(view)
      view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func refresh(force: Bool = false) {
    let execution = store.execution
    let next = State(
      environment: store.environmentKey, thread: store.selectedID,
      queued: execution.queued, held: execution.isHeld,
      canQueue: execution.canQueue, canSteer: execution.canSteer,
      interrupts: execution.steeringInterruptsTools,
      resumable: execution.resumableRunID, editing: store.queuedEdit?.runID,
      savedEdits: store.savedQueuedEdits,
      returningToQuestion: store.selectedRequest?.isQuestion == true,
      busy: store.queueBusy,
      importing: store.importingAttachments.contains(store.composerDraftID ?? ""),
      sending: store.sending.contains(store.selectedID ?? ""))
    guard force || next != state else { return }
    state = next
    for stack in [header, editBanner] {
      for view in stack.arrangedSubviews {
        stack.removeArrangedSubview(view)
        view.removeFromSuperview()
      }
    }
    let toggle = ActionButton("\(next.queued.count) queued" + (next.held ? " · Paused" : "")) {
      [weak self] in
      guard let self else { return }
      self.expanded.toggle()
      self.refresh(force: true)
    }
    toggle.isBordered = false
    toggle.font = .systemFont(ofSize: 12, weight: .medium)
    toggle.image = NSImage(
      systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
    toggle.imagePosition = .imageLeading
    toggle.isHidden = next.queued.isEmpty
    header.addArrangedSubview(toggle)
    header.addArrangedSubview(NSView())
    if next.held || next.resumable != nil {
      let resume = ActionButton(next.resumable == nil ? "Resume queue" : "Resume") { [weak store] in
        store?.resume()
      }
      resume.isEnabled = !next.busy
      header.addArrangedSubview(resume)
    }
    header.isHidden = next.queued.isEmpty && !next.held && next.resumable == nil
    scroll.isHidden = !expanded || next.queued.isEmpty
    listHeight.constant = scroll.isHidden ? 0 : min(144, CGFloat(next.queued.count * 48))
    editBanner.isHidden = next.editing == nil && next.savedEdits.isEmpty
    if let editing = next.editing {
      let waiting = next.queued.contains { $0.id == editing }
      let label = NSTextField(
        wrappingLabelWithString: waiting
          ? "Editing queued message" : "This message has left the queue. Your edit is saved.")
      label.font = .systemFont(ofSize: 12)
      let cancel = ActionButton(next.returningToQuestion ? "Return to question" : "Return to draft")
      { [weak store] in store?.cancelQueuedEdit() }
      cancel.toolTip = "Keep this edit and return to the composer"
      cancel.isEnabled = !next.sending && !next.importing
      editBanner.addArrangedSubview(label)
      editBanner.addArrangedSubview(NSView())
      editBanner.addArrangedSubview(cancel)
    } else if !next.savedEdits.isEmpty {
      let label = NSTextField(labelWithString: "Saved queued edits")
      label.font = .systemFont(ofSize: 12)
      let reopen = NSPopUpButton(frame: .zero, pullsDown: true)
      reopen.addItem(withTitle: "Reopen…")
      for edit in next.savedEdits {
        let text = store.drafts[edit.draftID] ?? "Queued attachment edit"
        reopen.menu?.addItem(
          ActionMenuItem(String(text.prefix(70))) { [weak store] in
            store?.reopenQueuedEdit(edit.runID)
          })
      }
      reopen.setAccessibilityLabel("Reopen saved queued edit")
      reopen.isEnabled = !next.busy && !next.importing
      editBanner.addArrangedSubview(label)
      editBanner.addArrangedSubview(NSView())
      editBanner.addArrangedSubview(reopen)
    }
    isHidden = header.isHidden && editBanner.isHidden
    table.reloadData()
  }

  func numberOfRows(in tableView: NSTableView) -> Int { state?.queued.count ?? 0 }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int)
    -> NSView?
  {
    guard let state, state.queued.indices.contains(index) else { return nil }
    let message = state.queued[index]
    let row = NSStackView()
    row.spacing = 6
    let text = NSTextField(
      wrappingLabelWithString: message.text.isEmpty ? "Attachments" : message.text)
    text.maximumNumberOfLines = 2
    text.lineBreakMode = .byTruncatingTail
    text.font = .systemFont(ofSize: 12)
    text.toolTip = message.text
    text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    if state.editing == message.id { text.textColor = .controlAccentColor }
    row.addArrangedSubview(text)
    func action(_ title: String, symbol: String, enabled: Bool, invoke: @escaping () -> Void) {
      let button = ActionButton("", action: invoke)
      button.bezelStyle = .inline
      button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
      button.toolTip = title
      button.setAccessibilityLabel(title)
      button.isEnabled = enabled && !state.busy
      row.addArrangedSubview(button)
    }
    if !message.attachments.isEmpty {
      let items = message.attachments.map { attachment in
        AttachmentPreviewItem(name: attachment["name"].string ?? "Attachment") { [weak store] in
          guard let store, store.environmentKey == state.environment else {
            throw T3Error("Reconnect to preview this file.")
          }
          return try store.attachmentPreviewRequest(attachment)
        }
      }
      let attachment = ActionButton("\(items.count) 📎") { [weak self] in
        self?.previews.show(items, index: 0, from: self?.window)
      }
      attachment.bezelStyle = .inline
      attachment.setAccessibilityLabel("Preview \(items.count) queued attachments")
      row.addArrangedSubview(attachment)
    }
    action("Move queued message up", symbol: "arrow.up", enabled: state.canQueue && index > 0) {
      [weak store] in
      store?.reorderQueuedMessage(message.id, before: state.queued[index - 1].id)
    }
    action(
      "Move queued message down", symbol: "arrow.down",
      enabled: state.canQueue && index + 1 < state.queued.count
    ) { [weak store] in
      store?.reorderQueuedMessage(
        message.id, before: index + 2 < state.queued.count ? state.queued[index + 2].id : nil)
    }
    action("Edit queued message", symbol: "pencil", enabled: state.editing == nil) { [weak store] in
      store?.editQueuedMessage(message)
    }
    action(
      state.interrupts ? "Steer now (interrupts current tools)" : "Steer now",
      symbol: "arrow.turn.up.right", enabled: state.canSteer
    ) { [weak store] in store?.steerQueuedMessage(message.id) }
    action("Remove queued message", symbol: "xmark", enabled: true) { [weak store] in
      store?.cancelQueuedMessage(message.id)
    }
    let cell = NSView()
    cell.addSubview(row)
    row.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
      row.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
      row.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
    ])
    return cell
  }

  func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (
    any NSPasteboardWriting
  )? {
    guard let state, state.canQueue, !state.busy, state.queued.indices.contains(row) else {
      return nil
    }
    let item = NSPasteboardItem()
    item.setString(
      state.environment + "\n" + (state.thread ?? "") + "\n" + state.queued[row].id,
      forType: dragType)
    return item
  }
  private func draggedRun(_ info: any NSDraggingInfo) -> String? {
    guard let state, !state.busy, state.canQueue,
      let parts = info.draggingPasteboard.string(forType: dragType)?.components(separatedBy: "\n"),
      parts.count == 3, parts[0] == store.environmentKey, parts[1] == store.selectedID,
      state.queued.contains(where: { $0.id == parts[2] })
    else { return nil }
    return parts[2]
  }
  func tableView(
    _ tableView: NSTableView, validateDrop info: any NSDraggingInfo,
    proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation
  ) -> NSDragOperation {
    guard draggedRun(info) != nil else { return [] }
    tableView.setDropRow(row, dropOperation: .above)
    return .move
  }
  func tableView(
    _ tableView: NSTableView, acceptDrop info: any NSDraggingInfo,
    row: Int, dropOperation: NSTableView.DropOperation
  ) -> Bool {
    guard let id = draggedRun(info), let state else { return false }
    let before = state.queued.indices.contains(row) ? state.queued[row].id : nil
    if before != id { store.reorderQueuedMessage(id, before: before) }
    return true
  }
}
