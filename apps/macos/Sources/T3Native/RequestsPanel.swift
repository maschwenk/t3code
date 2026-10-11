import AppKit
import T3Core

@MainActor final class RequestsPanel: NSStackView {
  private let store: ClientStore
  private var previous: [PendingRequest] = []
  private var previousReady = false
  private var previousBusy: Set<String> = []
  private var selectedRequestID: String?
  private var answerButtons: [String: [ActionButton]] = [:]
  private var answerFields: [String: ActionTextField] = [:]
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
    guard
      force || previous != requests || previousReady != store.canEditThread
        || previousBusy != store.commandsInFlight
    else { return }
    previous = requests
    previousReady = store.canEditThread
    previousBusy = store.commandsInFlight
    isHidden = requests.isEmpty
    for view in arrangedSubviews {
      removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    answerButtons = [:]
    answerFields = [:]
    submitButton = nil
    guard let request = requests.first(where: { $0.id == selectedRequestID }) ?? requests.first
    else { return }
    selectedRequestID = request.id
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
          self?.selectedRequestID = candidate.id
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
    let content = NSStackView()
    content.orientation = .vertical
    content.alignment = .leading
    content.spacing = 8
    for question in request.questions {
      guard let id = question["id"].string else { continue }
      let prompt = label(question["question"].string ?? "")
      prompt.font = .systemFont(ofSize: 12, weight: .medium)
      content.addArrangedSubview(prompt)
      prompt.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -6).isActive = true
      for option in question["options"].array {
        let value = option["value"].string ?? option["label"].string ?? ""
        let description = option["description"].string ?? ""
        let button = ActionButton(option["label"].string ?? value) { [weak self] in
          self?.choose(value, question: question, request: request)
        }
        button.setButtonType(question["multiSelect"].bool ? .switch : .radio)
        button.toolTip = description
        button.isEnabled = enabled
        content.addArrangedSubview(button)
        answerButtons[id, default: []].append(button)
        if !description.isEmpty {
          let detail = label(description)
          detail.textColor = .secondaryLabelColor
          content.addArrangedSubview(detail)
          detail.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -6).isActive = true
        }
      }
      if question["allowCustomAnswer"] != .bool(false) {
        let field = ActionTextField(frame: .zero)
        field.placeholderString = "Type your answer…"
        field.setAccessibilityLabel(question["question"].string ?? "Answer")
        field.isEnabled = enabled
        field.changed = { [weak self] text in
          guard let self else { return }
          var draft = store.questionDrafts[request.id]?[id] ?? QuestionDraft()
          draft.custom = text
          if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { draft.selected = [] }
          store.questionDrafts[request.id, default: [:]][id] = draft
          updateAnswers(request)
        }
        content.addArrangedSubview(field)
        field.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -6).isActive = true
        answerFields[id] = field
      }
    }
    let scroll = NSScrollView()
    scroll.documentView = content
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    content.translatesAutoresizingMaskIntoConstraints = false
    content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
    content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor).isActive = true
    content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor).isActive = true
    let lines = request.questions.reduce(0) { $0 + 2 + $1["options"].array.count * 2 }
    scroll.heightAnchor.constraint(equalToConstant: CGFloat(min(240, max(85, lines * 21))))
      .isActive = true
    addArrangedSubview(scroll)
    stretch(scroll)
    let submit = ActionButton(responding(request) ? "Sending…" : "Submit answers") { [weak store] in
      store?.respond(request)
    }
    submitButton = submit
    let buttons = NSStackView(views: [submit])
    if request.dismissible {
      let dismiss = ActionButton("Dismiss") { [weak store] in store?.dismiss(request) }
      dismiss.isEnabled = store.canEditThread && !responding(request)
      buttons.addArrangedSubview(dismiss)
    }
    addArrangedSubview(buttons)
    updateAnswers(request)
  }

  private func choose(_ value: String, question: JSON, request: PendingRequest) {
    guard let id = question["id"].string else { return }
    var draft = store.questionDrafts[request.id]?[id] ?? QuestionDraft()
    if !draft.custom.isEmpty, let threadID = store.selectedID {
      let old = store.drafts[threadID] ?? ""
      store.drafts[threadID] = old.isEmpty ? draft.custom : old + "\n\n" + draft.custom
    }
    draft.custom = ""
    if question["multiSelect"].bool {
      if draft.selected.contains(value) {
        draft.selected.removeAll { $0 == value }
      } else {
        draft.selected.append(value)
      }
    } else {
      draft.selected = [value]
    }
    store.questionDrafts[request.id, default: [:]][id] = draft
    updateAnswers(request)
    store.onChange?()
  }

  private func updateAnswers(_ request: PendingRequest) {
    let drafts = store.questionDrafts[request.id] ?? [:]
    for question in request.questions {
      guard let id = question["id"].string else { continue }
      let draft = drafts[id] ?? QuestionDraft()
      for (index, button) in (answerButtons[id] ?? []).enumerated() {
        let option = question["options"].array[index]
        let value = option["value"].string ?? option["label"].string ?? ""
        button.state = draft.selected.contains(value) ? .on : .off
      }
      if let field = answerFields[id], field.stringValue != draft.custom {
        field.stringValue = draft.custom
      }
    }
    submitButton?.isEnabled =
      store.canEditThread && request.canRespond && !responding(request)
      && request.answers(from: drafts) != nil
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
