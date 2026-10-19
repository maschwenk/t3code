import AppKit
import SwiftUI

@MainActor final class BrowserDownloadsWindow: NSWindowController {
  init(downloads: BrowserDownloads) {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 540, height: 420),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    super.init(window: window)
    window.title = "Browser Downloads"
    window.isReleasedWhenClosed = false
    window.minSize = NSSize(width: 440, height: 300)
    window.contentView = NSHostingView(rootView: BrowserDownloadsView(downloads: downloads))
    window.center()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private struct BrowserDownloadsView: View {
  @ObservedObject var downloads: BrowserDownloads
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Button("Agent downloads folder", action: downloads.revealAgentFolder)
        Spacer()
        Button("Clear finished", action: downloads.clearFinished).disabled(downloads.items.isEmpty)
      }.padding(16)
      Divider()
      if downloads.items.isEmpty {
        ContentUnavailableView(
          "No downloads yet", systemImage: "arrow.down.circle",
          description: Text(
            "Downloads from this session appear here. Agent downloads are saved automatically."))
      } else {
        List(downloads.items) { item in
          HStack {
            VStack(alignment: .leading, spacing: 6) {
              Text(item.name).lineLimit(1).truncationMode(.middle)
              Text(status(item)).font(.caption).foregroundStyle(.secondary)
              if item.state == .downloading, item.total > 0 {
                ProgressView(value: min(1, Double(item.received) / Double(item.total)))
              }
              if let error = item.error {
                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
              }
            }
            Spacer()
            if item.state == .choosing || item.state == .downloading {
              Button("Cancel") { downloads.cancel(item.id) }
            } else if item.file != nil {
              Button("Show in Finder") { downloads.reveal(item) }
            }
          }.padding(.vertical, 6)
        }
      }
    }
  }
  private func status(_ item: BrowserDownloadItem) -> String {
    switch item.state {
    case .choosing: "Waiting for a save location…"
    case .downloading:
      ByteCountFormatter.string(fromByteCount: item.received, countStyle: .file)
        + (item.total > 0
          ? " of " + ByteCountFormatter.string(fromByteCount: item.total, countStyle: .file)
          : " downloaded")
    case .finished: "Downloaded"
    case .cancelled: "Cancelled"
    case .failed:
      item.file == nil
        ? "Download failed. Try the download again from the page."
        : "Downloaded to a temporary file"
    }
  }
}
