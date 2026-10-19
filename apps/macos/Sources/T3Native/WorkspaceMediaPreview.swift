import AVKit
import AppKit
import T3Core
import UniformTypeIdentifiers
import WebKit

@MainActor private final class MediaScriptHandler: NSObject, WKScriptMessageHandler {
  weak var owner: WorkspaceMediaPreview?
  func userContentController(
    _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    owner?.receive(message)
  }
}

@MainActor final class WorkspaceMediaPreview: NSView, WKNavigationDelegate, WKUIDelegate {
  var onOpenLink: ((URL) -> Void)?
  private let canvas = NSView()
  private let status = NSTextField(wrappingLabelWithString: "")
  private let retry = NSButton(title: "Retry preview", target: nil, action: nil)
  private let save = NSButton(title: "Save…", target: nil, action: nil)
  private let downloadStatus = NSTextField(labelWithString: "")
  private let feedback = NSStackView()
  private var request: WorkspaceMediaRequest?
  private var generation = UUID()
  private var task: Task<Void, Never>?
  private var web: WKWebView?
  private var assetURL: URL?
  private var failedLoad = false
  private var player: AVPlayer?
  private var playerView: AVPlayerView?
  private var itemObservation: NSKeyValueObservation?
  private var rateObservation: NSKeyValueObservation?
  private var failureObserver: NSObjectProtocol?
  private var playbackRate: Float = 0
  private var recovery = MediaPlaybackRecovery()

  init() {
    super.init(frame: .zero)
    retry.target = self
    retry.action = #selector(retryPreview)
    save.target = self
    save.action = #selector(saveMedia)
    downloadStatus.font = .systemFont(ofSize: 11)
    downloadStatus.textColor = .secondaryLabelColor
    downloadStatus.lineBreakMode = .byTruncatingMiddle
    let controls = NSStackView(views: [downloadStatus, NSView(), save])
    status.alignment = .center
    feedback.orientation = .vertical
    feedback.spacing = 10
    feedback.addArrangedSubview(status)
    feedback.addArrangedSubview(retry)
    for child in [canvas, feedback, controls] {
      addSubview(child)
      child.translatesAutoresizingMaskIntoConstraints = false
    }
    NSLayoutConstraint.activate([
      canvas.leadingAnchor.constraint(equalTo: leadingAnchor),
      canvas.trailingAnchor.constraint(equalTo: trailingAnchor),
      canvas.topAnchor.constraint(equalTo: topAnchor),
      canvas.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -8),
      controls.leadingAnchor.constraint(equalTo: leadingAnchor),
      controls.trailingAnchor.constraint(equalTo: trailingAnchor),
      controls.bottomAnchor.constraint(equalTo: bottomAnchor),
      feedback.centerXAnchor.constraint(equalTo: canvas.centerXAnchor),
      feedback.centerYAnchor.constraint(equalTo: canvas.centerYAnchor),
      feedback.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40),
    ])
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil { clear() }
  }

  func show(_ next: WorkspaceMediaRequest) {
    guard request?.key != next.key else { return }
    if request?.key.file == next.key.file, request?.key.threadID == next.key.threadID {
      capturePlayback()
      recovery.retry()
    } else {
      recovery = MediaPlaybackRecovery()
      playbackRate = 0
    }
    request = next
    load()
  }

  func clear() {
    request = nil
    assetURL = nil
    generation = UUID()
    task?.cancel()
    task = nil
    removePlayer()
    removeWeb()
  }

  @objc private func retryPreview() {
    capturePlayback()
    recovery.retry()
    load()
  }

  @objc private func saveMedia() {
    guard let request, let window else { return }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = request.name
    panel.allowedContentTypes = [
      UTType(filenameExtension: (request.name as NSString).pathExtension) ?? .data
    ]
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let destination = panel.url, let self else { return }
      self.save.isEnabled = false
      self.downloadStatus.stringValue = "Saving…"
      Task {
        defer { self.save.isEnabled = true }
        do {
          try await request.save(to: destination)
          self.downloadStatus.stringValue = "Saved " + request.name
        } catch {
          self.downloadStatus.stringValue = "Could not save " + request.name + ". Try again."
        }
      }
    }
  }

  private func load() {
    guard let request else { return }
    task?.cancel()
    generation = UUID()
    let generation = generation
    assetURL = nil
    failedLoad = false
    stopObserving()
    player?.pause()
    player?.replaceCurrentItem(with: nil)
    removeWeb()
    if !request.kind.playable { removePlayer() }
    status.stringValue = "Loading preview…"
    feedback.isHidden = false
    retry.isHidden = true
    canvas.isHidden = true
    task = Task { [weak self] in
      do {
        let url = try await request.load()
        guard !Task.isCancelled, let self, self.generation == generation else { return }
        self.assetURL = url
        if request.kind.playable {
          self.installPlayer(url)
        } else {
          self.installWeb(url, request: request)
        }
      } catch {
        guard !Task.isCancelled, let self, self.generation == generation else { return }
        self.failed()
      }
    }
  }

  private func install(_ child: NSView) {
    canvas.addSubview(child)
    child.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      child.leadingAnchor.constraint(equalTo: canvas.leadingAnchor),
      child.trailingAnchor.constraint(equalTo: canvas.trailingAnchor),
      child.topAnchor.constraint(equalTo: canvas.topAnchor),
      child.bottomAnchor.constraint(equalTo: canvas.bottomAnchor),
    ])
  }

  private func installWeb(_ url: URL, request: WorkspaceMediaRequest) {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let handler = MediaScriptHandler()
    handler.owner = self
    configuration.userContentController.add(handler, name: "filePreview")
    let web = WKWebView(frame: .zero, configuration: configuration)
    self.web = web
    web.navigationDelegate = self
    web.uiDelegate = self
    web.allowsMagnification = true
    web.setAccessibilityLabel("Preview " + request.name)
    install(web)
    if request.kind == .pdf {
      web.load(URLRequest(url: url))
    } else {
      web.loadHTMLString(
        WorkspaceMediaDocument.html(
          kind: request.kind, url: url, title: request.name, nonce: UUID().uuidString),
        baseURL: nil)
    }
  }

  private func installPlayer(_ url: URL) {
    if player == nil {
      let player = AVPlayer()
      let view = AVPlayerView()
      view.player = player
      view.controlsStyle = .inline
      view.showsFullScreenToggleButton = true
      view.allowsPictureInPicturePlayback = true
      view.setAccessibilityLabel("Media preview")
      self.player = player
      playerView = view
      install(view)
    }
    guard let player else { return }
    let item = AVPlayerItem(url: url)
    let id = ObjectIdentifier(item)
    player.replaceCurrentItem(with: item)
    itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
      let status = item.status.rawValue
      Task { @MainActor [weak self] in
        guard let self, let current = self.player?.currentItem, ObjectIdentifier(current) == id
        else { return }
        if status == AVPlayerItem.Status.readyToPlay.rawValue {
          self.readyToPlay()
        } else if status == AVPlayerItem.Status.failed.rawValue {
          self.playbackFailed()
        }
      }
    }
    rateObservation = player.observe(\.rate, options: [.new]) { [weak self] player, change in
      let rate = change.newValue ?? 0
      let failed = player.currentItem?.status == .failed
      Task { @MainActor [weak self] in
        guard let self, let current = self.player?.currentItem, ObjectIdentifier(current) == id,
          !failed
        else { return }
        self.playbackRate = rate
      }
    }
    failureObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self, let current = self.player?.currentItem, ObjectIdentifier(current) == id
        else { return }
        self.playbackFailed()
      }
    }
  }

  private func readyToPlay() {
    guard let player, let item = player.currentItem else { return }
    ready()
    let id = ObjectIdentifier(item)
    let duration = item.duration.seconds
    let position = duration.isFinite ? min(recovery.position, max(0, duration)) : recovery.position
    let rate = recovery.rate
    if position > 0 {
      player.seek(to: CMTime(seconds: position, preferredTimescale: 600)) { [weak self] finished in
        Task { @MainActor [weak self] in
          guard finished, let self, let current = self.player?.currentItem,
            ObjectIdentifier(current) == id
          else { return }
          if rate > 0 { self.player?.playImmediately(atRate: rate) }
        }
      }
    } else if rate > 0 {
      player.playImmediately(atRate: rate)
    }
  }

  private func capturePlayback() {
    guard let player, player.currentItem != nil else { return }
    recovery.capture(position: player.currentTime().seconds, rate: playbackRate)
  }

  private func playbackFailed() {
    capturePlayback()
    if recovery.refreshAfterFailure() { load() } else { failed() }
  }

  private func stopObserving() {
    itemObservation?.invalidate()
    rateObservation?.invalidate()
    itemObservation = nil
    rateObservation = nil
    if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
    failureObserver = nil
  }

  private func removePlayer() {
    stopObserving()
    player?.pause()
    player?.replaceCurrentItem(with: nil)
    playerView?.player = nil
    playerView?.removeFromSuperview()
    playerView = nil
    player = nil
  }

  private func removeWeb() {
    web?.stopLoading()
    web?.navigationDelegate = nil
    web?.uiDelegate = nil
    web?.configuration.userContentController.removeScriptMessageHandler(forName: "filePreview")
    web?.removeFromSuperview()
    web = nil
  }

  private func ready() {
    guard !failedLoad else { return }
    feedback.isHidden = true
    canvas.isHidden = false
  }
  private func failed() {
    failedLoad = true
    status.stringValue = "This file could not be previewed. Retry or open it with another app."
    feedback.isHidden = false
    retry.isHidden = false
    canvas.isHidden = true
  }

  fileprivate func receive(_ message: WKScriptMessage) {
    guard message.webView === web, message.frameInfo.isMainFrame,
      let body = message.body as? [String: String]
    else { return }
    if body["status"] == "ready" { ready() }
    if body["status"] == "failed" { failed() }
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    if webView === web, request?.kind == .pdf { ready() }
  }
  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error)
  {
    if webView === web, !cancelledNavigation(error) { failed() }
  }
  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: any Error
  ) {
    if webView === web, !cancelledNavigation(error) { failed() }
  }
  private func cancelledNavigation(_ error: any Error) -> Bool {
    let error = error as NSError
    return (error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled)
      || (error.domain == "WebKitErrorDomain" && error.code == 102)
  }
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    if webView === web { failed() }
  }
  func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async
    -> WKNavigationResponsePolicy
  {
    guard webView === web else { return .cancel }
    if let response = navigationResponse.response as? HTTPURLResponse, response.statusCode >= 400,
      response.url == assetURL || navigationResponse.isForMainFrame
    {
      failed()
      return .cancel
    }
    if request?.kind == .pdf, navigationResponse.isForMainFrame,
      navigationResponse.response.mimeType != "application/pdf"
    {
      failed()
      return .cancel
    }
    return .allow
  }
  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async
    -> WKNavigationActionPolicy
  {
    guard webView === web, let url = navigationAction.request.url else { return .cancel }
    let scheme = url.scheme?.lowercased() ?? ""
    if request?.kind == .html, navigationAction.targetFrame?.isMainFrame == false,
      ["http", "https", "about"].contains(scheme)
    {
      return .allow
    }
    if request?.kind == .pdf, var document = URLComponents(url: url, resolvingAgainstBaseURL: false)
    {
      document.fragment = nil
      if document.url == assetURL { return .allow }
    }
    if navigationAction.navigationType == .linkActivated,
      ["http", "https", "mailto"].contains(scheme)
    {
      onOpenLink?(url)
      return .cancel
    }
    return ["http", "https", "about"].contains(scheme) ? .allow : .cancel
  }
  func webView(
    _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    if webView === web, navigationAction.navigationType == .linkActivated,
      let url = navigationAction.request.url,
      ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "")
    {
      onOpenLink?(url)
    }
    return nil
  }
}
