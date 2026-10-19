import AppKit
import T3Core

@MainActor private final class AttachmentRows: NSStackView {
  override var isFlipped: Bool { true }
}

@MainActor final class AttachmentTray: NSScrollView {
  private let store: ClientStore
  private let previews: AttachmentPreviews
  private let rows = AttachmentRows()
  private var fingerprint = ""
  private var trayHeight: NSLayoutConstraint!
  init(store: ClientStore, previews: AttachmentPreviews) {
    self.store = store
    self.previews = previews
    super.init(frame: .zero)
    drawsBackground = false
    hasVerticalScroller = true
    autohidesScrollers = true
    rows.orientation = .vertical
    rows.alignment = .leading
    rows.spacing = 4
    documentView = rows
    rows.translatesAutoresizingMaskIntoConstraints = false
    rows.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    trayHeight = heightAnchor.constraint(equalToConstant: 0)
    trayHeight.isActive = true
    setAccessibilityLabel("Message attachments")
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func refresh() {
    let attachments = store.selectedAttachments
    let retained = store.queuedEdit?.attachments ?? []
    let importing = store.importingAttachments.contains(store.composerDraftID ?? "")
    let sending = store.composerBusy
    let key =
      store.environmentKey + (store.composerDraftID ?? "") + "\(importing):\(sending):"
      + retained.compactMap { $0["id"].string }.joined(separator: "|")
      + attachments.map {
        "\($0.id):\(String(describing: store.attachmentUploads[$0.id]))"
      }.joined(separator: "|")
    guard key != fingerprint else { return }
    fingerprint = key
    for child in rows.arrangedSubviews {
      rows.removeArrangedSubview(child)
      child.removeFromSuperview()
    }
    func add(_ view: NSView) {
      rows.addArrangedSubview(view)
      view.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -14).isActive = true
    }
    let environment = store.environmentKey
    let retainedItems = retained.map { attachment in
      AttachmentPreviewItem(name: attachment["name"].string ?? "Attachment") { [weak store] in
        guard let store, store.environmentKey == environment else {
          throw T3Error("Reconnect to preview this file.")
        }
        return try store.attachmentPreviewRequest(attachment)
      }
    }
    for (index, attachment) in retained.enumerated() {
      let item = retainedItems[index]
      let open = ActionButton(item.name) { [weak self] in
        self?.previews.show(retainedItems, index: index, from: self?.window)
      }
      open.bezelStyle = .inline
      open.cell?.lineBreakMode = .byTruncatingMiddle
      open.setAccessibilityLabel("Preview queued attachment " + item.name)
      open.toolTip = "Already attached to the queued message"
      let remove = ActionButton("") { [weak store] in store?.removeQueuedAttachment(attachment) }
      remove.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
      remove.isBordered = false
      remove.isEnabled = !sending
      remove.setAccessibilityLabel("Remove queued attachment " + item.name)
      let row = NSStackView(views: [open, NSView(), remove])
      row.spacing = 8
      row.heightAnchor.constraint(equalToConstant: 38).isActive = true
      if attachment["type"].string == "image" {
        let thumbnail = AttachmentThumbnail(item: item, cache: previews.cache) { [weak self] in
          self?.previews.show(retainedItems, index: index, from: self?.window)
        }
        thumbnail.widthAnchor.constraint(equalToConstant: 36).isActive = true
        thumbnail.heightAnchor.constraint(equalToConstant: 36).isActive = true
        row.insertArrangedSubview(thumbnail, at: 0)
      }
      add(row)
    }
    let repository = store.attachmentRepository
    let items = attachments.map { attachment in
      AttachmentPreviewItem(name: attachment.name) {
        guard let repository else { throw T3Error("The saved attachment is unavailable.") }
        return .local(try repository.file(attachment), name: attachment.name)
      }
    }
    for (index, attachment) in attachments.enumerated() {
      let label = NSTextField(labelWithString: attachment.name)
      label.font = .systemFont(ofSize: 12, weight: .medium)
      label.lineBreakMode = .byTruncatingMiddle
      label.toolTip = attachment.name
      var state = ByteCountFormatter.string(
        fromByteCount: Int64(attachment.sizeBytes), countStyle: .file)
      var failed = false
      switch store.attachmentUploads[attachment.id] {
      case .uploading(let percent): state += " · Uploading \(percent)%"
      case .ready: state += " · Ready"
      case .failed(let reason):
        state = reason
        failed = true
      case nil: state += " · Waiting to upload"
      }
      let detail = NSTextField(labelWithString: state)
      detail.font = .systemFont(ofSize: 10)
      detail.textColor = failed ? .systemOrange : .secondaryLabelColor
      detail.lineBreakMode = .byTruncatingTail
      detail.toolTip = state
      let labels = NSStackView(views: [label, detail])
      labels.orientation = .vertical
      labels.alignment = .leading
      labels.spacing = 2
      label.widthAnchor.constraint(equalTo: labels.widthAnchor).isActive = true
      detail.widthAnchor.constraint(equalTo: labels.widthAnchor).isActive = true
      let open = { [weak self] in self?.previews.show(items, index: index, from: self?.window) }
      let icon: NSView
      if attachment.type == "image" {
        icon = AttachmentThumbnail(item: items[index], cache: previews.cache) { open() }
      } else {
        let button = ActionButton("") { open() }
        button.isBordered = false
        button.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
        button.setAccessibilityLabel("Preview " + attachment.name)
        button.toolTip = "Preview " + attachment.name
        icon = button
      }
      icon.widthAnchor.constraint(equalToConstant: 36).isActive = true
      icon.heightAnchor.constraint(equalToConstant: 36).isActive = true
      let row = NSStackView(views: [icon, labels])
      row.spacing = 8
      row.heightAnchor.constraint(equalToConstant: 38).isActive = true
      if failed {
        let retry = ActionButton("Retry") { [weak store] in store?.retryAttachment(attachment) }
        retry.setAccessibilityLabel("Retry upload of " + attachment.name)
        retry.isEnabled = !sending
        row.addArrangedSubview(retry)
      }
      let remove = ActionButton("") { [weak store] in store?.removeAttachment(attachment) }
      remove.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
      remove.isBordered = false
      remove.isEnabled = !sending
      remove.setAccessibilityLabel("Remove " + attachment.name)
      row.addArrangedSubview(remove)
      add(row)
    }
    if importing { add(NSTextField(labelWithString: "Adding attachments…")) }
    isHidden = attachments.isEmpty && retained.isEmpty && !importing
    trayHeight.constant = min(
      126, CGFloat((attachments.count + retained.count) * 42 + (importing ? 24 : 0)))
  }
}
