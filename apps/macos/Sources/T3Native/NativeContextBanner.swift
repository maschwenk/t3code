import AppKit
import T3Core

/// Mount above the composer and refresh after accepted store updates.
@MainActor final class NativeContextBanner: NSStackView {
  var onCompact: (() -> Void)?
  private let store: ClientStore
  private var connection: RPCConnection?
  private var endpoint: URL?
  private var revision = UUID()
  private var subscription: Task<Void, Never>?
  private var providers = ContextCompactionProviders()
  private var dismissals = ContextResumeDismissals()
  private var displayedUsage: ContextUsage?
  private var canCompact = false
  private var ageTimer: Timer?
  private var timerReport: String?
  private let resume = NSStackView()
  private let meter = NSStackView()
  private let subtitle = NSTextField(labelWithString: "")
  private let gauge = ContextUsageGauge()
  private lazy var compactButton = ComposerPill("", height: 28) { [weak self] in self?.compact() }
  private lazy var keepButton = ComposerPill("", height: 28) { [weak self] in self?.dismiss() }
  private lazy var meterButton = ActionButton("Context") { [weak self] in self?.showDetails() }

  init(store: ClientStore) {
    self.store = store
    super.init(frame: .zero)
    orientation = .vertical
    alignment = .leading
    spacing = 8
    translatesAutoresizingMaskIntoConstraints = false
    setHuggingPriority(.required, for: .vertical)
    resume.orientation = .horizontal
    resume.distribution = .fill
    resume.alignment = .centerY
    resume.spacing = 10
    resume.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 8)
    resume.wantsLayer = true
    resume.layer?.cornerRadius = 12
    let icon = NSImageView(
      image: NSImage(
        systemSymbolName: "arrow.down.right.and.arrow.up.left", accessibilityDescription: nil)!)
    icon.contentTintColor = .secondaryLabelColor
    icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
    let title = NSTextField(labelWithString: "Resume with less context")
    title.font = .systemFont(ofSize: 13, weight: .medium)
    title.setContentCompressionResistancePriority(.required, for: .horizontal)
    subtitle.font = .systemFont(ofSize: 12)
    subtitle.textColor = .secondaryLabelColor
    subtitle.lineBreakMode = .byTruncatingTail
    subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    subtitle.setContentHuggingPriority(.defaultLow, for: .horizontal)
    compactButton.title = "Compact"
    compactButton.contentTintColor = .labelColor
    compactButton.alignment = .center
    compactButton.setContentCompressionResistancePriority(.required, for: .horizontal)
    keepButton.title = ""
    keepButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
    keepButton.imagePosition = .imageOnly
    keepButton.setAccessibilityLabel("Keep full history")
    keepButton.toolTip = "Dismiss this reminder and keep full history"
    keepButton.widthAnchor.constraint(equalToConstant: 36).isActive = true
    resume.addArrangedSubview(icon)
    resume.addArrangedSubview(title)
    resume.addArrangedSubview(subtitle)
    resume.addArrangedSubview(compactButton)
    resume.addArrangedSubview(keepButton)
    addArrangedSubview(resume)
    resume.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    meter.orientation = .horizontal
    meter.alignment = .centerY
    meter.spacing = 6
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    meter.addArrangedSubview(spacer)
    meter.addArrangedSubview(gauge)
    meterButton.bezelStyle = .inline
    meterButton.font = .systemFont(ofSize: 11)
    meter.addArrangedSubview(meterButton)
    addArrangedSubview(meter)
    meter.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    gauge.widthAnchor.constraint(equalToConstant: 18).isActive = true
    gauge.heightAnchor.constraint(equalToConstant: 18).isActive = true
    refresh()
    updateAppearance()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  deinit { subscription?.cancel() }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateAppearance()
  }

  private func updateAppearance() {
    let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    resume.layer?.backgroundColor = NSColor(calibratedWhite: dark ? 0.065 : 0.98, alpha: 1).cgColor
    resume.layer?.borderColor = NSColor(calibratedWhite: dark ? 0.13 : 0.88, alpha: 1).cgColor
    resume.layer?.borderWidth = 1
  }

  func refresh() {
    refreshConnection()
    let execution = store.execution
    displayedUsage = store.isNewConversation ? nil : execution.contextUsage
    guard let usage = displayedUsage, let threadID = store.selectedID else {
      let reserveMeter =
        !store.isNewConversation && store.selectedThread != nil
        && store.thread?.synchronized != true
        && providers.reportsContextWindow(
          instance: store.selectedThread?.model["instanceId"].string) != false
      isHidden = !reserveMeter
      resume.isHidden = true
      meterButton.title = "Loading context…"
      meterButton.isEnabled = false
      gauge.usage = nil
      ageTimer?.invalidate()
      timerReport = nil
      return
    }
    isHidden = false
    meterButton.isEnabled = true
    let selectedProvider = execution.selectedProviderThread
    let instance =
      selectedProvider["providerInstanceId"].string
      ?? store.selectedThread?.model["instanceId"].string
    let driver =
      selectedProvider["driver"].string
      ?? store.catalog.provider(for: store.selectedThread?.model ?? .null)?.driver
    let dismissalKey =
      "t3native:resume-compaction-dismissed:\(store.environmentKey):\(instance ?? "claudeAgent")"
    if execution.hasDismissedResumeCompaction && !UserDefaults.standard.bool(forKey: dismissalKey) {
      UserDefaults.standard.set(true, forKey: dismissalKey)
    }
    canCompact =
      store.canEditThread && !store.composerBusy && execution.activeRunID == nil
      && execution.hasCompactableConversation && store.thread?.pendingRequests.isEmpty == true
      && store.planFollowUp == nil && store.queuedEdit == nil
      && !store.importingAttachments.contains(store.composerDraftID ?? "")
      && store.catalogReady && connection === store.browserConnection
      && endpoint == store.browserEndpoint
      && driver.map {
        providers.supportsCompact(driver: $0, instance: instance, lockedInstance: instance)
      } == true
    compactButton.isEnabled = canCompact
    compactButton.toolTip =
      canCompact
      ? "Summarize earlier context before continuing"
      : "Compaction requires an idle connected thread and a compatible provider with /compact support."
    resume.isHidden =
      !usage.shouldOfferResume(provider: driver)
      || execution.activeRunID != nil
      || store.thread?.pendingRequests.contains(where: \.isQuestion) == true
      || UserDefaults.standard.bool(forKey: dismissalKey)
      || dismissals.contains(environment: store.environmentKey, thread: threadID, usage: usage)
    subtitle.stringValue = "\(ContextUsage.formatTokens(usage.usedTokens)) tokens from earlier"
    gauge.usage = usage
    let percent = usage.formattedPercentage.map { " · \($0)" } ?? ""
    meterButton.title = "\(ContextUsage.formatTokens(usage.usedTokens)) tokens\(percent)"
    meterButton.contentTintColor = usage.isOverloaded ? .systemRed : .secondaryLabelColor
    meterButton.setAccessibilityLabel("Context usage: \(meterButton.title)")
    meterButton.toolTip = "Show context usage and compaction options"
    scheduleAgeRefresh(usage, driver: driver)
  }

  private func refreshConnection() {
    guard connection !== store.browserConnection || endpoint != store.browserEndpoint else {
      return
    }
    subscription?.cancel()
    subscription = nil
    revision = UUID()
    connection = store.browserConnection
    endpoint = store.browserEndpoint
    providers = ContextCompactionProviders()
    guard let connection, let endpoint else { return }
    let gate = NativeSettingsResponseGate(
      connection: connection, endpoint: endpoint, revision: revision)
    subscription = Task { [weak self] in
      do {
        guard !Task.isCancelled, let currentStore = self?.store,
          let currentRevision = self?.revision,
          gate.accepts(
            connection: currentStore.browserConnection, endpoint: currentStore.browserEndpoint,
            revision: currentRevision)
        else { return }
        let stream = try await connection.subscribe("subscribeServerConfig")
        defer { Task { await connection.cancel(stream.id) } }
        for try await event in stream.values {
          guard !Task.isCancelled, let self,
            gate.accepts(
              connection: store.browserConnection, endpoint: store.browserEndpoint,
              revision: revision)
          else { return }
          providers.apply(event)
          refresh()
        }
        throw T3Error("Context capability updates ended. Reconnect to compact context.")
      } catch {
        guard !Task.isCancelled, let self,
          gate.accepts(
            connection: store.browserConnection, endpoint: store.browserEndpoint, revision: revision
          )
        else { return }
        providers = ContextCompactionProviders()
        refresh()
        meterButton.toolTip = "Context capabilities unavailable: \(error.localizedDescription)"
      }
    }
  }

  private func scheduleAgeRefresh(_ usage: ContextUsage, driver: String?) {
    let key = "\(store.environmentKey):\(store.selectedID ?? ""):\(usage.updatedAt):\(driver ?? "")"
    guard key != timerReport else { return }
    timerReport = key
    ageTimer?.invalidate()
    guard driver == "claudeAgent", usage.usedTokens >= 100_000,
      let reported = ThreadDates.parse(usage.updatedAt)
    else { return }
    let delay = reported.addingTimeInterval(70 * 60).timeIntervalSinceNow
    guard delay > 0 else { return }
    ageTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
      Task { @MainActor [weak self] in self?.refresh() }
    }
  }
  private func dismiss() {
    guard let usage = displayedUsage, let thread = store.selectedID else { return }
    dismissals.dismiss(environment: store.environmentKey, thread: thread, usage: usage)
    refresh()
  }
  private func compact() {
    refresh()
    guard canCompact else { return }
    onCompact?()
  }
  private func showDetails() {
    refresh()
    guard let usage = displayedUsage else { return }
    let menu = NSMenu()
    func detail(_ text: String) {
      let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
      item.isEnabled = false
      menu.addItem(item)
    }
    let model =
      store.catalog.model(for: store.selectedThread?.model ?? .null)?.name
      ?? store.selectedThread?.model["model"].string
    detail(model ?? "Context window")
    detail("Used: \(ContextUsage.formatTokens(usage.usedTokens)) tokens")
    if let max = usage.maxTokens { detail("Capacity: \(ContextUsage.formatTokens(max)) tokens") }
    if let remaining = usage.remainingTokens {
      detail("Remaining: \(ContextUsage.formatTokens(remaining)) tokens")
    }
    for (key, label) in [
      ("totalProcessedTokens", "Total processed"), ("inputTokens", "Input"),
      ("cachedInputTokens", "Cached input"), ("outputTokens", "Output"),
      ("reasoningOutputTokens", "Reasoning output"), ("lastUsedTokens", "Last request"),
      ("lastInputTokens", "Last input"), ("lastCachedInputTokens", "Last cached input"),
      ("lastOutputTokens", "Last output"), ("lastReasoningOutputTokens", "Last reasoning output"),
      ("toolUses", "Tool uses"),
    ] {
      if let value = usage.number(key) { detail("\(label): \(ContextUsage.formatTokens(value))") }
    }
    if let duration = usage.number("durationMs") {
      detail("Duration: \(String(format: "%.1f", duration / 1000)) seconds")
    }
    if let percent = usage.formattedPercentage { detail("Context used: \(percent)") }
    if case .number(let amount) = usage.fields["cost"]["amount"], amount.isFinite,
      let currency = usage.fields["cost"]["currency"].string
    {
      detail(
        "Cost: \(currency) \(String(format: abs(amount) > 0 && abs(amount) < 0.01 ? "%.4f" : "%.2f", amount))"
      )
    }
    if usage.compactsAutomatically == true {
      if let threshold = usage.number("autoCompactThreshold"), threshold > 0 {
        detail("Compacts automatically at \(String(format: "%.0f", threshold)) tokens.")
      } else {
        detail(
          model.map { "Context for \($0) compacts automatically when needed." }
            ?? "Context compacts automatically when needed.")
      }
    }
    menu.addItem(.separator())
    let compact = ActionMenuItem("Compact context") { [weak self] in self?.compact() }
    compact.isEnabled = canCompact
    menu.addItem(compact)
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: meterButton.bounds.maxY + 3), in: meterButton)
  }
}

@MainActor private final class ContextUsageGauge: NSView {
  var usage: ContextUsage? { didSet { if oldValue != usage { needsDisplay = true } } }
  override func draw(_ dirtyRect: NSRect) {
    let rect = bounds.insetBy(dx: 2, dy: 2)
    let base = NSBezierPath(ovalIn: rect)
    base.lineWidth = 2
    NSColor.separatorColor.setStroke()
    base.stroke()
    guard let usage, let percent = usage.usedPercentage, percent > 0 else { return }
    let arc = NSBezierPath()
    arc.lineWidth = 2
    arc.lineCapStyle = .round
    arc.appendArc(
      withCenter: NSPoint(x: bounds.midX, y: bounds.midY), radius: rect.width / 2,
      startAngle: 90, endAngle: 90 - CGFloat(percent) * 3.6, clockwise: true)
    (usage.isOverloaded ? NSColor.systemRed : NSColor.secondaryLabelColor).setStroke()
    arc.stroke()
  }
}
