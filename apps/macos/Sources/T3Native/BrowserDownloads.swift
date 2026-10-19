import AppKit
import Combine
import T3Core
import WebKit

struct BrowserDownloadFile {
  let destination: URL
  let directory: URL
  let partial: URL
  let replaceExisting: Bool
  init(destination: URL) throws {
    self.destination = destination
    replaceExisting = FileManager.default.fileExists(atPath: destination.path)
    directory = destination.deletingLastPathComponent().appendingPathComponent(
      ".t3-download-" + UUID().uuidString)
    partial = directory.appendingPathComponent(destination.lastPathComponent)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  }
  func finish() throws {
    if replaceExisting && FileManager.default.fileExists(atPath: destination.path) {
      _ = try FileManager.default.replaceItemAt(destination, withItemAt: partial)
    } else {
      try FileManager.default.moveItem(at: partial, to: destination)
    }
    discard()
  }
  func discard() { try? FileManager.default.removeItem(at: directory) }
  static func name(_ suggestion: String) -> String {
    let component =
      suggestion.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(
        String.init) ?? "download"
    let clean = component.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
    let name = String(String.UnicodeScalarView(clean)).trimmingCharacters(
      in: .whitespacesAndNewlines)
    if name.isEmpty || name == "." || name == ".." { return "download" }
    // Leave room for the unique prefix and multibyte filenames on APFS.
    var result = ""
    for character in name {
      if result.utf8.count + String(character).utf8.count > 180 { break }
      result.append(character)
    }
    return result.isEmpty ? "download" : result
  }
}

struct BrowserDownloadItem: Identifiable {
  enum State { case choosing, downloading, finished, cancelled, failed }
  let id: UUID
  var name = "Download"
  var state: State = .choosing
  var received: Int64 = 0
  var total: Int64 = 0
  var file: URL?
  var error: String?
}

@MainActor final class BrowserDownloads: NSObject, ObservableObject, WKDownloadDelegate {
  @Published private(set) var items: [BrowserDownloadItem] = []
  var onChange: (() -> Void)?
  let agentDirectory: URL
  private final class Transfer {
    let id = UUID()
    let download: WKDownload
    let agent: Bool
    weak var window: NSWindow?
    var file: BrowserDownloadFile?
    var cancelled = false
    init(_ download: WKDownload, agent: Bool, window: NSWindow?) {
      self.download = download
      self.agent = agent
      self.window = window
    }
  }
  private var transfers: [ObjectIdentifier: Transfer] = [:]
  private var progressTask: Task<Void, Never>?
  private var prompt: (id: UUID, panel: NSSavePanel)?
  // Injected by the local WebKit smoke; normal use always shows the native save panel.
  var chooseDestination: ((String, NSWindow?) async -> URL?)?
  var activeCount: Int { transfers.count }
  init(agentDirectory: URL? = nil) {
    self.agentDirectory =
      agentDirectory
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("T3Native/BrowserDownloads")
    super.init()
  }
  isolated deinit {
    progressTask?.cancel()
    for transfer in transfers.values {
      transfer.download.cancel(nil)
      transfer.file?.discard()
    }
  }
  func receive(_ download: WKDownload, agent: Bool, window: NSWindow?) {
    guard transfers.count < 8 else {
      download.cancel(nil)
      items.insert(
        BrowserDownloadItem(
          id: UUID(), state: .failed,
          error: "Eight downloads are already running. Try this download again after one finishes."),
        at: 0)
      trimHistory()
      onChange?()
      return
    }
    let transfer = Transfer(download, agent: agent, window: window)
    transfers[ObjectIdentifier(download)] = transfer
    items.insert(BrowserDownloadItem(id: transfer.id), at: 0)
    trimHistory()
    download.delegate = self
    onChange?()
    startProgress()
  }
  private func trimHistory() {
    let active = Set(transfers.values.map(\.id))
    while items.count > 100, let index = items.lastIndex(where: { !active.contains($0.id) }) {
      items.remove(at: index)
    }
  }
  private func update(_ id: UUID, _ change: (inout BrowserDownloadItem) -> Void) {
    guard let index = items.firstIndex(where: { $0.id == id }) else { return }
    change(&items[index])
  }
  private func startProgress() {
    guard progressTask == nil else { return }
    progressTask = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
        guard let self else { break }
        var progressByID: [UUID: (received: Int64, total: Int64)] = [:]
        for transfer in transfers.values {
          let progress = transfer.download.progress
          progressByID[transfer.id] = (progress.completedUnitCount, progress.totalUnitCount)
        }
        var next = items
        var changed = false
        for index in next.indices {
          guard next[index].state == .downloading, let progress = progressByID[next[index].id],
            next[index].received != progress.received || next[index].total != progress.total
          else { continue }
          next[index].received = progress.received
          next[index].total = progress.total
          changed = true
        }
        if changed { items = next }
        if transfers.isEmpty {
          progressTask = nil
          break
        }
      }
    }
  }
  func download(
    _ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String
  ) async -> URL? {
    guard let transfer = transfers[ObjectIdentifier(download)] else { return nil }
    let name = BrowserDownloadFile.name(suggestedFilename)
    update(transfer.id) { $0.name = name }
    do {
      let destination: URL?
      if transfer.agent {
        try FileManager.default.createDirectory(
          at: agentDirectory, withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
        destination = agentDirectory.appendingPathComponent(transfer.id.uuidString + "-" + name)
      } else if let chooseDestination {
        destination = await chooseDestination(name, transfer.window)
      } else {
        while prompt != nil && !transfer.cancelled { try await Task.sleep(for: .milliseconds(50)) }
        guard !transfer.cancelled else { return nil }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        panel.message = "Save browser download"
        prompt = (transfer.id, panel)
        let result: NSApplication.ModalResponse
        if let window = transfer.window, window.isVisible {
          result = await panel.beginSheetModal(for: window)
        } else {
          result = await panel.begin()
        }
        prompt = nil
        destination = result == .OK ? panel.url : nil
      }
      guard !transfer.cancelled, transfers[ObjectIdentifier(download)] === transfer else {
        return nil
      }
      guard let destination else {
        end(transfer, state: .cancelled)
        return nil
      }
      let file = try BrowserDownloadFile(destination: destination)
      transfer.file = file
      update(transfer.id) {
        if !transfer.agent { $0.name = destination.lastPathComponent }
        $0.state = .downloading
        $0.total = response.expectedContentLength
      }
      return file.partial
    } catch {
      end(transfer, state: .failed, error: error.localizedDescription)
      return nil
    }
  }
  func downloadDidFinish(_ download: WKDownload) {
    guard let transfer = transfers[ObjectIdentifier(download)], let file = transfer.file else {
      return
    }
    if transfer.cancelled {
      end(transfer, state: .cancelled)
      return
    }
    do {
      try file.finish()
      end(transfer, state: .finished, file: file.destination)
    } catch {
      // Keep a completed download if its chosen folder becomes unavailable or a new
      // file appears there. Never discard its bytes or overwrite an unapproved file.
      transfer.file = nil
      end(
        transfer, state: .failed,
        error: "Could not save to the chosen location: " + error.localizedDescription,
        file: file.partial)
    }
  }
  func download(_ download: WKDownload, respondTo challenge: URLAuthenticationChallenge) async -> (
    URLSession.AuthChallengeDisposition, URLCredential?
  ) {
    (.performDefaultHandling, nil)
  }
  func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
    guard let transfer = transfers[ObjectIdentifier(download)] else { return }
    end(
      transfer, state: transfer.cancelled ? .cancelled : .failed,
      error: transfer.cancelled ? nil : error.localizedDescription)
  }
  private func end(
    _ transfer: Transfer, state: BrowserDownloadItem.State, error: String? = nil, file: URL? = nil
  ) {
    guard transfers.removeValue(forKey: ObjectIdentifier(transfer.download)) != nil else { return }
    transfer.file?.discard()
    update(transfer.id) {
      $0.state = state
      $0.error = error
      $0.file = file
    }
    onChange?()
  }
  func cancel(_ id: UUID) {
    guard let transfer = transfers.values.first(where: { $0.id == id }), !transfer.cancelled else {
      return
    }
    transfer.cancelled = true
    if prompt?.id == id { prompt?.panel.cancel(nil) }
    transfer.download.cancel { [weak self] _ in self?.end(transfer, state: .cancelled) }
  }
  func clearFinished() {
    let active = Set(transfers.values.map(\.id))
    items.removeAll { !active.contains($0.id) }
    onChange?()
  }
  func reveal(_ item: BrowserDownloadItem) {
    guard let file = item.file else { return }
    guard FileManager.default.fileExists(atPath: file.path) else {
      update(item.id) { $0.error = "This file has been moved or deleted." }
      return
    }
    NSWorkspace.shared.activateFileViewerSelecting([file])
  }
  func revealAgentFolder() {
    do {
      try FileManager.default.createDirectory(
        at: agentDirectory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      NSWorkspace.shared.open(agentDirectory)
    } catch { NSAlert(error: error).runModal() }
  }
  func finishBeforeQuit(window: NSWindow?) async -> Bool {
    guard activeCount > 0 else { return true }
    let alert = NSAlert()
    alert.messageText = "Downloads are still running"
    alert.informativeText = "Quitting cancels \(activeCount) browser download(s)."
    alert.addButton(withTitle: "Keep downloading")
    alert.addButton(withTitle: "Quit and cancel downloads")
    let result =
      if let window, window.isVisible { await alert.beginSheetModal(for: window) } else {
        alert.runModal()
      }
    guard result == .alertSecondButtonReturn else { return false }
    for id in transfers.values.map(\.id) { cancel(id) }
    let end = Date().addingTimeInterval(5)
    while !transfers.isEmpty && Date() < end { try? await Task.sleep(for: .milliseconds(25)) }
    return true
  }
}
