import AppKit
import QuickLookUI
import T3Core

@MainActor struct AttachmentPreviewItem {
  let name: String
  let request: () throws -> AttachmentPreviewRequest
}

@MainActor final class AttachmentPreviews {
  let cache = AttachmentPreviewCache()
  private var controller: AttachmentPreviewWindow?
  private var environment = ""

  func updateEnvironment(_ next: String) {
    guard next != environment else { return }
    controller?.close()
    controller = nil
    environment = next
  }

  func show(_ items: [AttachmentPreviewItem], index: Int, from parent: NSWindow?) {
    guard items.indices.contains(index) else { return }
    controller?.close()
    let next = AttachmentPreviewWindow(items: items, index: index, cache: cache)
    controller = next
    next.showWindow(nil)
    if let parent, let window = next.window {
      window.setFrameOrigin(
        NSPoint(
          x: parent.frame.midX - window.frame.width / 2,
          y: parent.frame.midY - window.frame.height / 2))
    }
    next.window?.makeKeyAndOrderFront(nil)
  }
}

@MainActor final class AttachmentThumbnail: NSView {
  private let button: ActionButton
  private let item: AttachmentPreviewItem
  private let cache: AttachmentPreviewCache
  private var task: Task<Void, Never>?
  private var loaded = false

  init(item: AttachmentPreviewItem, cache: AttachmentPreviewCache, open: @escaping () -> Void) {
    self.item = item
    self.cache = cache
    button = ActionButton("", action: open)
    super.init(frame: .zero)
    button.isBordered = false
    button.imagePosition = .imageOnly
    button.imageScaling = .scaleProportionallyUpOrDown
    button.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
    button.setAccessibilityLabel("Preview " + item.name)
    button.toolTip = item.name
    wantsLayer = true
    layer?.cornerRadius = 6
    layer?.masksToBounds = true
    addSubview(button)
    button.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      button.leadingAnchor.constraint(equalTo: leadingAnchor),
      button.trailingAnchor.constraint(equalTo: trailingAnchor),
      button.topAnchor.constraint(equalTo: topAnchor),
      button.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil {
      task?.cancel()
      task = nil
    } else if !loaded && task == nil {
      do {
        let request = try item.request()
        task = Task { [weak self, cache] in
          do {
            let image = try await cache.thumbnail(for: request)
            guard !Task.isCancelled, let self else { return }
            self.button.image = NSImage(cgImage: image, size: .zero)
            self.loaded = true
          } catch {
            guard !Task.isCancelled else { return }
            self?.button.toolTip = "\(request.name) — \(error.localizedDescription)"
          }
          self?.task = nil
        }
      } catch { button.toolTip = error.localizedDescription }
    }
  }
}

@MainActor private final class PreviewPanel: NSPanel {
  var navigate: ((Int) -> Bool)?
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if !event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.option) {
      if event.keyCode == 123, navigate?(-1) == true {
        return true
      }
      if event.keyCode == 124, navigate?(1) == true {
        return true
      }
    }
    return super.performKeyEquivalent(with: event)
  }
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 {
      close()
    } else if event.keyCode == 123, navigate?(-1) == true {
      return
    } else if event.keyCode == 124, navigate?(1) == true {
      return
    } else {
      super.keyDown(with: event)
    }
  }
  override func cancelOperation(_ sender: Any?) { close() }
}

private final class PreviewItem: NSObject, QLPreviewItem {
  let file: AttachmentPreviewFile
  let name: String
  init(file: AttachmentPreviewFile, name: String) {
    self.file = file
    self.name = name
  }
  var previewItemURL: URL? { file.url }
  var previewItemTitle: String? { name }
}

@MainActor private final class AttachmentPreviewWindow: NSWindowController, NSWindowDelegate {
  private let items: [AttachmentPreviewItem]
  private var index: Int
  private let cache: AttachmentPreviewCache
  private let preview = QLPreviewView(frame: .zero, style: .normal)!
  private let status = NSTextField(wrappingLabelWithString: "Loading preview…")
  private let caption = NSTextField(labelWithString: "")
  private let previous = NSButton(title: "Previous", target: nil, action: nil)
  private let next = NSButton(title: "Next", target: nil, action: nil)
  private let save = NSButton(title: "Save…", target: nil, action: nil)
  private let retry = NSButton(title: "Retry", target: nil, action: nil)
  private var task: Task<Void, Never>?
  private var generation = UUID()
  private var current: PreviewItem?

  init(items: [AttachmentPreviewItem], index: Int, cache: AttachmentPreviewCache) {
    self.items = items
    self.index = index
    self.cache = cache
    let panel = PreviewPanel(
      contentRect: NSRect(x: 0, y: 0, width: 820, height: 650),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    panel.minSize = NSSize(width: 500, height: 380)
    panel.isReleasedWhenClosed = false
    super.init(window: panel)
    panel.delegate = self
    panel.navigate = { [weak self] direction in
      guard let self, self.items.count > 1 else { return false }
      self.navigate(direction)
      return true
    }
    let root = SurfaceView()
    panel.contentView = root
    preview.autostarts = false
    preview.shouldCloseWithWindow = true
    caption.lineBreakMode = .byTruncatingMiddle
    caption.font = .systemFont(ofSize: 12)
    status.alignment = .center
    previous.target = self
    previous.action = #selector(goPrevious)
    next.target = self
    next.action = #selector(goNext)
    save.target = self
    save.action = #selector(saveFile)
    retry.target = self
    retry.action = #selector(load)
    let controls = NSStackView(views: [previous, caption, next, save])
    controls.spacing = 10
    caption.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let feedback = NSStackView(views: [status, retry])
    feedback.orientation = .vertical
    feedback.spacing = 12
    for view in [preview, controls, feedback] {
      root.addSubview(view)
      view.translatesAutoresizingMaskIntoConstraints = false
    }
    NSLayoutConstraint.activate([
      controls.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
      controls.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
      controls.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
      preview.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
      preview.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
      preview.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
      preview.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -12),
      feedback.centerXAnchor.constraint(equalTo: preview.centerXAnchor),
      feedback.centerYAnchor.constraint(equalTo: preview.centerYAnchor),
      feedback.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -60),
    ])
    load()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  @objc private func goPrevious() { navigate(-1) }
  @objc private func goNext() { navigate(1) }
  private func navigate(_ direction: Int) {
    index = (index + direction + items.count) % items.count
    load()
  }
  @objc private func load() {
    task?.cancel()
    generation = UUID()
    let generation = generation
    let item = items[index]
    window?.title = item.name
    caption.stringValue = item.name + (items.count > 1 ? " (\(index + 1)/\(items.count))" : "")
    caption.toolTip = item.name
    previous.isEnabled = items.count > 1
    next.isEnabled = items.count > 1
    preview.previewItem = nil
    preview.isHidden = true
    current = nil
    save.isEnabled = false
    status.stringValue = "Loading preview…"
    status.isHidden = false
    retry.isHidden = true
    do {
      let request = try item.request()
      task = Task { [weak self, cache] in
        do {
          let file = try await cache.file(for: request)
          guard !Task.isCancelled, let self, self.generation == generation else { return }
          let current = PreviewItem(file: file, name: item.name)
          self.current = current
          self.preview.previewItem = current
          self.preview.isHidden = false
          self.status.isHidden = true
          self.save.isEnabled = true
        } catch {
          guard !Task.isCancelled, let self, self.generation == generation else { return }
          self.failed(error)
        }
      }
    } catch { failed(error) }
  }
  private func failed(_ error: Error) {
    status.stringValue = error.localizedDescription
    status.isHidden = false
    retry.isHidden = false
  }
  @objc private func saveFile() {
    guard let window, let current else { return }
    let file = current.file
    let panel = NSSavePanel()
    panel.nameFieldStringValue = current.name
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let destination = panel.url else { return }
      Task {
        do {
          try await file.save(to: destination)
        } catch { self?.failed(error) }
      }
    }
  }
  func windowWillClose(_ notification: Notification) {
    task?.cancel()
    generation = UUID()
    preview.previewItem = nil
    current = nil
  }
}
