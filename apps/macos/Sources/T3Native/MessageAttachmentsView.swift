import AppKit
import T3Core

@MainActor final class MessageAttachmentsView: NSStackView {
  static func height(_ attachments: [JSON]) -> CGFloat {
    let images = attachments.filter { $0["type"].string == "image" }.count
    let files = attachments.count - images
    let imageRows = (images + 1) / 2
    return CGFloat(imageRows * 108 + files * 30 - (attachments.isEmpty ? 0 : 6))
  }

  init(
    attachments: [JSON], store: ClientStore, previews: AttachmentPreviews,
    download: @escaping (JSON) -> Void
  ) {
    super.init(frame: .zero)
    orientation = .vertical
    alignment = .leading
    spacing = 6
    let environment = store.environmentKey
    let items = attachments.map { attachment in
      AttachmentPreviewItem(name: attachment["name"].string ?? "Attachment") { [weak store] in
        guard let store, store.environmentKey == environment else {
          throw T3Error("Reconnect to this attachment’s environment to preview it.")
        }
        return try store.attachmentPreviewRequest(attachment)
      }
    }
    let images = attachments.indices.filter { attachments[$0]["type"].string == "image" }
    for offset in stride(from: 0, to: images.count, by: 2) {
      let row = NSStackView()
      row.spacing = 8
      for index in images[offset..<min(offset + 2, images.count)] {
        let thumbnail = AttachmentThumbnail(item: items[index], cache: previews.cache) {
          [weak self] in
          previews.show(items, index: index, from: self?.window)
        }
        thumbnail.widthAnchor.constraint(equalToConstant: 101).isActive = true
        thumbnail.heightAnchor.constraint(equalToConstant: 76).isActive = true
        let save = ActionButton(items[index].name + " ↓") { download(attachments[index]) }
        save.bezelStyle = .inline
        save.font = .systemFont(ofSize: 10)
        save.cell?.lineBreakMode = .byTruncatingMiddle
        save.setAccessibilityLabel("Download " + items[index].name)
        save.toolTip = "Download " + items[index].name
        save.widthAnchor.constraint(equalToConstant: 101).isActive = true
        save.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let tile = NSStackView(views: [thumbnail, save])
        tile.orientation = .vertical
        tile.spacing = 6
        row.addArrangedSubview(tile)
      }
      addArrangedSubview(row)
    }
    for index in attachments.indices where attachments[index]["type"].string != "image" {
      let attachment = attachments[index]
      let name = items[index].name
      let open = ActionButton(name) { [weak self] in
        previews.show(items, index: index, from: self?.window)
      }
      open.bezelStyle = .inline
      open.alignment = .left
      open.font = .systemFont(ofSize: 12)
      open.cell?.lineBreakMode = .byTruncatingMiddle
      open.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
      open.imagePosition = .imageLeading
      open.setAccessibilityLabel("Preview " + name)
      open.toolTip =
        name + " · "
        + ByteCountFormatter.string(
          fromByteCount: Int64(attachment["sizeBytes"].int ?? 0), countStyle: .file)
      let save = ActionButton("") { download(attachment) }
      save.bezelStyle = .inline
      save.image = NSImage(systemSymbolName: "arrow.down.to.line", accessibilityDescription: nil)
      save.setAccessibilityLabel("Download " + name)
      save.toolTip = "Download " + name
      let row = NSStackView(views: [open, save])
      row.spacing = 6
      row.heightAnchor.constraint(equalToConstant: 24).isActive = true
      addArrangedSubview(row)
      row.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor).isActive = true
    }
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
