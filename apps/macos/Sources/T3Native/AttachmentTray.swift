import AppKit
import T3Core

@MainActor private final class AttachmentRows: NSStackView {
  override var isFlipped: Bool { true }
}

@MainActor final class AttachmentTray: NSScrollView {
  private let store: ClientStore
  private let rows = AttachmentRows()
  private var fingerprint = ""
  private var trayHeight: NSLayoutConstraint!
  init(store: ClientStore) {
    self.store = store
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
    let importing = store.importingAttachments.contains(store.selectedID ?? "")
    let sending = store.sending.contains(store.selectedID ?? "")
    let key =
      (store.selectedID ?? "") + "\(importing):\(sending):"
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
    for attachment in attachments {
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
      let icon = NSImageView(
        image: NSImage(
          systemSymbolName: attachment.type == "image" ? "photo" : "doc",
          accessibilityDescription: nil)!)
      icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
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
    isHidden = attachments.isEmpty && !importing
    trayHeight.constant = min(126, CGFloat(attachments.count * 42 + (importing ? 24 : 0)))
  }
}
