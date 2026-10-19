import AppKit
import T3Core

@MainActor final class RequestsPanel: NSStackView {
  private let store: ClientStore
  private var previous: [PendingRequest] = []
  private var previousReady = false
  private var previousBusy: Set<String> = []
  private var previousPage = -1
  private var previousRequestID: String?
  private var previousImporting = false
  private var previousEditingQueue = false
  private var collapsedQuestion: String?
  private var autoAdvance: Task<Void, Never>?
  private var progressLabel: NSTextField?
  private var answerButtons: [String: [ActionButton]] = [:]
  private var submitButton: ActionButton?

  init(store: ClientStore) {
    self.store = store
    super.init(frame: .zero)
    orientation = .vertical
    alignment = .leading
    spacing = 8
    wantsLayer = true
    layer?.cornerRadius = 10
    edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func refresh(force: Bool = false) {
    let requests = store.thread?.pendingRequests ?? []
    let busy = Set(
      store.commandsInFlight.filter { $0.hasPrefix((store.selectedID ?? "") + ":request:") })
    let request = store.selectedRequest
    let page = request.map(store.questionIndex) ?? 0
    let importing = store.importingAttachments.contains(store.composerDraftID ?? "")
    guard
      force || previous != requests || previousReady != store.canEditThread
        || previousBusy != busy || previousPage != page
        || previousEditingQueue != (store.queuedEdit != nil)
        || previousRequestID != request?.id || previousImporting != importing
    else {
      if let request, request.isQuestion { updateAnswers(request) }
      return
    }
    if previousPage != page || previous != requests || previousRequestID != request?.id {
      autoAdvance?.cancel()
    }
    previousPage = page
    previousRequestID = request?.id
    previousImporting = importing
    previousEditingQueue = store.queuedEdit != nil
    previous = requests
    previousReady = store.canEditThread
    previousBusy = busy
    isHidden = requests.isEmpty
    for view in arrangedSubviews {
      removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    answerButtons = [:]
    progressLabel = nil
    submitButton = nil
    guard let request else { return }
    layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    let title = NSTextField(labelWithString: request.title)
    title.font = .systemFont(ofSize: 12, weight: .semibold)
    title.textColor = .systemOrange
    let top = NSStackView(views: [title, NSView()])
    top.spacing = 8
    if requests.count > 1 {
      let switcher = NSPopUpButton()
      switcher.menu?.autoenablesItems = false
      for (index, candidate) in requests.enumerated() {
        let item = ActionMenuItem("\(index + 1)/\(requests.count) · \(candidate.title)") {
          [weak self] in
          self?.store.selectRequest(candidate.id)
          self?.refresh(force: true)
        }
        item.representedObject = candidate.id
        switcher.menu?.addItem(item)
      }
      switcher.selectItem(at: requests.firstIndex(of: request) ?? 0)
      top.addArrangedSubview(switcher)
    }
    addArrangedSubview(top)
    stretch(top)
    let enabled = request.canRespond && store.canEditThread && !responding(request)
    if !request.canRespond {
      let unavailable = label(
        request.reason ?? "Provider process is gone. Interrupt or restart the run to respond.")
      addArrangedSubview(unavailable)
      stretch(unavailable)
    }
    if request.isQuestion {
      buildQuestions(request, enabled: enabled)
    } else {
      let text = NSTextView()
      text.isEditable = false
      text.isSelectable = true
      text.drawsBackground = false
      text.font =
        request.kind == "mcp-elicitation"
        ? .systemFont(ofSize: 12) : .monospacedSystemFont(ofSize: 12, weight: .regular)
      text.string = request.detail
      text.isVerticallyResizable = true
      text.autoresizingMask = [.width]
      text.textContainer?.widthTracksTextView = true
      text.setAccessibilityLabel("Approval details")
      let scroll = NSScrollView()
      scroll.documentView = text
      scroll.hasVerticalScroller = true
      scroll.drawsBackground = false
      scroll.heightAnchor.constraint(equalToConstant: 58).isActive = true
      addArrangedSubview(scroll)
      stretch(scroll)
      let buttons = NSStackView()
      buttons.spacing = 6
      for option in request.options {
        guard let decision = option["decision"].string else { continue }
        let warning = option["warning"].string
        let button = ActionButton(
          (warning == nil ? "" : "⚠ ") + (option["label"].string ?? decision)
        ) { [weak store] in store?.respond(request, decision: decision) }
        button.toolTip = warning
        button.isEnabled = enabled
        button.controlSize = .small
        buttons.addArrangedSubview(button)
        if let warning {
          let text = label(warning)
          text.textColor = .systemOrange
          addArrangedSubview(text)
          stretch(text)
        }
      }
      addArrangedSubview(buttons)
    }
  }

  private func buildQuestions(_ request: PendingRequest, enabled: Bool) {
    let progress = store.questionProgress(request)
    let question = progress.question
    guard let id = question["id"].string else { return }
    let key = request.id + ":" + id
    let collapsed = collapsedQuestion == key
    let toggle = ActionButton(question["header"].string ?? "Question") { [weak self] in
      guard let self else { return }
      self.collapsedQuestion = collapsed ? nil : key
      self.refresh(force: true)
      self.store.onChange?()
    }
    toggle.isBordered = false
    toggle.font = .systemFont(ofSize: 12, weight: .semibold)
    toggle.image = NSImage(
      systemSymbolName: collapsed ? "chevron.right" : "chevron.down", accessibilityDescription: nil)
    toggle.imagePosition = .imageLeading
    toggle.toolTip =
      collapsed ? "Show the question and its options" : "Hide the question and its options"
    let count = NSTextField(labelWithString: "")
    count.font = .systemFont(ofSize: 11)
    count.textColor = .secondaryLabelColor
    progressLabel = count
    let heading = NSStackView(views: [toggle, NSView(), count])
    addArrangedSubview(heading)
    stretch(heading)
    if !collapsed {
      let content = NSStackView()
      content.orientation = .vertical
      content.alignment = .leading
      content.spacing = 8
      let prompt = label(question["question"].string ?? "")
      prompt.font = .systemFont(ofSize: 12, weight: .medium)
      content.addArrangedSubview(prompt)
      prompt.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -6).isActive = true
      if question["multiSelect"].bool {
        content.addArrangedSubview(label("Select one or more options."))
      }
      for (index, option) in question["options"].array.enumerated() {
        let value = option["value"].string ?? option["label"].string ?? ""
        let description = option["description"].string ?? ""
        let button = ActionButton(
          (index < 9 ? "\(index + 1). " : "") + (option["label"].string ?? value)
        ) { [weak self] in
          self?.choose(value, question: question, request: request)
        }
        button.setButtonType(question["multiSelect"].bool ? .switch : .radio)
        button.toolTip = description
        button.isEnabled = enabled && store.queuedEdit == nil
        content.addArrangedSubview(button)
        answerButtons[id, default: []].append(button)
        if !description.isEmpty {
          let detail = label(description)
          detail.textColor = .secondaryLabelColor
          content.addArrangedSubview(detail)
          detail.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -6).isActive = true
        }
      }
      let hint = label(
        question["allowCustomAnswer"] == .bool(false)
          ? "Choose an option to continue." : "Or write your answer in the composer below.")
      hint.textColor = .secondaryLabelColor
      content.addArrangedSubview(hint)
      let scroll = NSScrollView()
      scroll.documentView = content
      scroll.hasVerticalScroller = true
      scroll.drawsBackground = false
      content.translatesAutoresizingMaskIntoConstraints = false
      content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
      content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor).isActive = true
      content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor).isActive = true
      scroll.heightAnchor.constraint(
        equalToConstant: CGFloat(min(240, max(85, (3 + question["options"].array.count * 2) * 21)))
      ).isActive = true
      addArrangedSubview(scroll)
      stretch(scroll)
    } else {
      let summary = NSTextField(labelWithString: question["question"].string ?? "")
      summary.lineBreakMode = .byTruncatingTail
      summary.font = .systemFont(ofSize: 11)
      addArrangedSubview(summary)
      stretch(summary)
    }
    let submit = ActionButton("") { [weak store] in store?.advanceQuestion(request) }
    submitButton = submit
    let buttons = NSStackView()
    if progress.index > 0 {
      let back = ActionButton("Previous") { [weak store] in
        store?.setQuestionPage(progress.index - 1, request: request)
      }
      back.isEnabled =
        !responding(request) && !store.importingAttachments.contains(store.composerDraftID ?? "")
      buttons.addArrangedSubview(back)
    }
    buttons.addArrangedSubview(submit)
    if request.dismissible {
      let dismiss = ActionButton("Dismiss") { [weak store] in store?.dismiss(request) }
      dismiss.isEnabled = store.canEditThread && !responding(request)
      buttons.addArrangedSubview(dismiss)
    }
    addArrangedSubview(buttons)
    updateAnswers(request)
  }

  private func choose(_ value: String, question: JSON, request: PendingRequest) {
    store.chooseQuestionOption(value, request: request, question: question)
    updateAnswers(request)
    autoAdvance?.cancel()
    guard !question["multiSelect"].bool, let questionID = question["id"].string else { return }
    let environment = store.environmentKey
    let thread = store.selectedID
    autoAdvance = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
      guard let self, self.store.environmentKey == environment, self.store.selectedID == thread,
        self.store.questionRequest?.id == request.id,
        self.store.activeQuestion?["id"].string == questionID,
        self.store.questionDrafts[request.id]?[questionID]?.selected == [value],
        self.store.questionDrafts[request.id]?[questionID]?.custom.isEmpty == true
      else { return }
      self.store.advanceQuestion(request)
    }
  }

  func handleNumberKey(_ event: NSEvent) -> Bool {
    guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
      !(window?.firstResponder is NSTextView), let digit = Int(event.characters ?? ""),
      (1...9).contains(digit),
      let request = store.questionRequest, request.canRespond, store.canEditThread,
      !responding(request)
    else { return false }
    let question = store.questionProgress(request).question
    guard let id = question["id"].string, collapsedQuestion != request.id + ":" + id,
      question["options"].array.indices.contains(digit - 1)
    else { return false }
    let option = question["options"].array[digit - 1]
    choose(
      option["value"].string ?? option["label"].string ?? "", question: question, request: request)
    return true
  }

  private func updateAnswers(_ request: PendingRequest) {
    let progress = store.questionProgress(request)
    let question = progress.question
    if let id = question["id"].string {
      let draft = store.questionDrafts[request.id]?[id] ?? QuestionDraft()
      for (index, button) in (answerButtons[id] ?? []).enumerated() {
        let option = question["options"].array[index]
        let value = option["value"].string ?? option["label"].string ?? ""
        button.state =
          draft.custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draft.selected.contains(value) ? .on : .off
      }
    }
    progressLabel?.stringValue =
      "\(progress.index + 1)/\(request.questions.count) · \(progress.answeredCount) answered"
    submitButton?.title =
      responding(request) ? "Sending…" : progress.isLast ? "Submit answers" : "Next"
    submitButton?.isEnabled =
      store.canEditThread && request.canRespond && !responding(request)
      && store.queuedEdit == nil && progress.answer != nil
      && (!progress.isLast || progress.answers != nil)
  }

  private func responding(_ request: PendingRequest) -> Bool {
    store.commandsInFlight.contains((store.selectedID ?? "") + ":request:" + request.id)
  }
  private func label(_ text: String) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = .systemFont(ofSize: 11)
    label.isSelectable = true
    return label
  }
  private func stretch(_ view: NSView) {
    view.widthAnchor.constraint(equalTo: widthAnchor, constant: -24).isActive = true
  }
}
