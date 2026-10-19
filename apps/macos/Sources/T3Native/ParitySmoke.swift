import AVFoundation
import CoreGraphics
import Foundation
import T3Core
import T3Markdown

enum ParitySmoke {
  @MainActor static func run() async throws {
    guard let file = Arguments.value("--connection-file"),
      let project = Arguments.value("--sandbox-project")
    else {
      throw T3Error(
        "--parity-smoke requires a private --connection-file and an isolated --sandbox-project.")
    }
    let settings = try ConnectionSettings.load(URL(fileURLWithPath: file))
    let connection = RPCConnection(settings: settings)
    let timeout = Task {
      try await Task.sleep(
        for: .seconds(CommandLine.arguments.contains("--plan-smoke") ? 300 : 120))
      await connection.close(error: T3Error("Parity smoke timed out."))
    }
    defer {
      timeout.cancel()
      Task { await connection.close() }
    }
    try await connection.open()
    if let root = Arguments.value("--project-smoke-root") {
      try await ProjectSmoke.run(settings: settings, root: root)
      return
    }
    if CommandLine.arguments.contains("--usage-smoke") {
      try await usage(settings: settings, connection: connection)
      return
    }
    if let threadID = Arguments.value("--checkpoint-review-thread") {
      try await checkpointReview(
        connection: connection, settings: settings, threadID: threadID, projectID: project)
      return
    }
    if let threadID = Arguments.value("--review-thread") {
      try await reviewChanges(
        connection: connection, settings: settings, threadID: threadID, projectID: project)
      return
    }
    if let threadID = Arguments.value("--terminal-thread") {
      try await terminal(
        connection: connection, settings: settings, threadID: threadID, projectID: project)
      return
    }
    if let threadID = Arguments.value("--workspace-resume-thread") {
      try await workspaceProvider(
        settings: settings, connection: connection, threadID: threadID,
        projectID: project, sendPrompt: false)
      return
    }
    if let threadID = Arguments.value("--workspace-thread") {
      try await workspaceFiles(
        settings: settings, connection: connection, threadID: threadID, projectID: project)
      return
    }
    if let threadID = Arguments.value("--plan-card-thread") {
      try await planCard(
        settings: settings, connection: connection, threadID: threadID, projectID: project)
      return
    }
    if let threadID = Arguments.value("--resume-queue-thread") {
      let projection = try await connection.call(
        "orchestration.getThreadProjection", payload: .object(["threadId": .string(threadID)]))
      guard projection["thread"]["projectId"].string == project,
        projection["thread"]["title"].string == "Native queue verification"
      else { throw T3Error("Resume requires the isolated queue test thread.") }
      try await queueSteering(settings: settings, connection: connection, threadID: threadID)
      return
    }
    if let threadID = Arguments.value("--resume-tool-thread") {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "t3-tool-resume-" + UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: directory) }
      let store = ClientStore(draftDirectory: directory)
      store.connect(settings, selecting: threadID)
      defer { store.disconnect() }
      try await waitForStore(store) { store.canEditThread }
      guard store.selectedThread?.projectID == project,
        store.selectedThread?.title == "Native tool output verification"
      else {
        throw T3Error("Resume requires the isolated tool-output test thread.")
      }
      try await toolOutput(store, connection: connection, threadID: threadID, resume: true)
      return
    }
    let configs = try await connection.subscribe("subscribeServerConfig")
    var catalog = ProviderCatalog()
    for try await event in configs.values {
      try catalog.apply(event)
      if event["type"].string == "snapshot" { break }
    }
    await connection.cancel(configs.id)
    guard let provider = catalog.providers.first(where: { $0.id == "codex" && $0.available }),
      let model = provider.models.first(where: { $0.id == "gpt-6.1-sol" }) ?? provider.models.first
    else {
      throw T3Error("Parity smoke requires a configured Codex instance.")
    }
    let id = UUID().uuidString
    let selection = model.selection(instanceID: provider.id)
    let template = try ThreadSummary(
      .object([
        "id": .string(id), "projectId": .string(project),
        "title": .string("Native parity verification"),
        "modelSelection": selection, "runtimeMode": .string("approval-required"),
      ]))
    _ = try await connection.call(
      "orchestration.dispatchCommand",
      payload: Commands.newThread(template: template, id: id, title: "Native parity verification"))
    print("Parity thread: \(id)")
    if CommandLine.arguments.contains("--browser-smoke") {
      try await browser(settings: settings, connection: connection, threadID: id)
      return
    }
    if CommandLine.arguments.contains("--plan-smoke") {
      try await plans(settings: settings, connection: connection, threadID: id)
      return
    }
    if CommandLine.arguments.contains("--attachment-smoke") {
      try await attachments(settings: settings, connection: connection, threadID: id)
      return
    }
    if CommandLine.arguments.contains("--queue-smoke") {
      try await queue(settings: settings, connection: connection, threadID: id)
      return
    }
    if CommandLine.arguments.contains("--question-paging-smoke") {
      try await questions(settings: settings, connection: connection, threadID: id)
      return
    }
    func dispatch(_ type: String, fields: [String: JSON]) async throws {
      var fields = fields
      fields["type"] = .string(type)
      fields["threadId"] = .string(id)
      fields["commandId"] = .string(UUID().uuidString)
      _ = try await connection.call("orchestration.dispatchCommand", payload: .object(fields))
    }
    func verify(_ key: String, _ expected: JSON) async throws {
      let projection = try await connection.call(
        "orchestration.getThreadProjection", payload: .object(["threadId": .string(id)]))
      guard projection["thread"][key] == expected else {
        throw T3Error("Read-back mismatch for \(key).")
      }
    }
    for mode in provider.runtimeModes.isEmpty
      ? ["approval-required", "full-access"] : provider.runtimeModes
    {
      try await dispatch("thread.runtime-mode.set", fields: ["runtimeMode": .string(mode)])
      try await verify("runtimeMode", .string(mode))
    }
    try await dispatch(
      "thread.runtime-mode.set", fields: ["runtimeMode": .string("approval-required")])
    try await verify("runtimeMode", .string("approval-required"))
    if let other = provider.models.first(where: { $0.id != model.id }) {
      let changed = other.selection(instanceID: provider.id, preserving: selection)
      try await dispatch("thread.model-selection.set", fields: ["modelSelection": changed])
      try await verify("modelSelection", changed)
    }
    try await dispatch("thread.model-selection.set", fields: ["modelSelection": selection])
    try await verify("modelSelection", selection)
    try await dispatch("thread.interaction-mode.set", fields: ["interactionMode": .string("plan")])
    try await verify("interactionMode", .string("plan"))
    print("Provider catalog, model/options, runtime modes, and plan mode round trips passed.")
    let draftDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "t3-native-smoke-drafts-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: draftDirectory) }
    let store = ClientStore(draftDirectory: draftDirectory)
    store.connect(settings, selecting: id)
    defer { store.disconnect() }
    try await waitForStore(store) { store.canEditThread && store.catalogReady }
    guard store.selectedID == id else { throw T3Error("Controller selected the wrong thread.") }
    if let descriptor = catalog.model(for: selection)?.descriptors.first(where: {
      $0["type"].string == "select" && $0["options"].array.count > 1
    }), let optionID = descriptor["id"].string, let choice = descriptor["options"].array.last {
      store.setModelOption(optionID, value: choice["id"])
      try await waitForStore(store) {
        store.canEditThread
          && store.selectedThread?.model["options"].array.contains {
            $0["id"].string == optionID && $0["value"] == choice["id"]
          } == true
      }
      store.setModel(selection)
      try await waitForStore(store) {
        store.canEditThread && store.selectedThread?.model == selection
      }
    }
    store.drafts[id] = "Draft survives reconnect"
    store.retry()
    try await waitForStore(store) { store.canEditThread && store.catalogReady }
    guard store.drafts[id] == "Draft survives reconnect" else {
      throw T3Error("Controller lost the draft on reconnect.")
    }
    print("ClientStore model options, shell read-back, and reconnect/draft checks passed.")
    store.disconnect()
    let reopened = ClientStore(draftDirectory: draftDirectory)
    reopened.connect(settings, selecting: id)
    try await waitForStore(reopened) { reopened.canEditThread && reopened.catalogReady }
    guard reopened.drafts[id] == "Draft survives reconnect" else {
      throw T3Error("Draft did not survive a new controller instance.")
    }
    reopened.disconnect()
    store.connect(settings, selecting: id)
    try await waitForStore(store) { store.canEditThread && store.catalogReady }
    print("Draft restored in a fresh app controller.")
    store.rename(id, to: "Native thread lifecycle verification")
    try await waitForStore(store) {
      !store.lifecycleBusy(id)
        && store.selectedThread?.title == "Native thread lifecycle verification"
    }
    store.setPinned(id, true)
    try await waitForStore(store) {
      !store.lifecycleBusy(id) && store.selectedThread?.lifecycle.pinned == true
    }
    store.setSettled(id, true)
    try await waitForStore(store) {
      !store.lifecycleBusy(id) && store.selectedThread?.lifecycle.settled == true
        && store.selectedThread?.lifecycle.pinned == false
    }
    store.setSettled(id, false)
    try await waitForStore(store) {
      !store.lifecycleBusy(id) && store.selectedThread?.lifecycle.settled == false
    }
    let wake = Date().addingTimeInterval(3600)
    store.snooze(id, until: wake)
    try await waitForStore(store) {
      !store.lifecycleBusy(id) && store.selectedThread?.lifecycle.snoozed(at: Date()) == true
    }
    store.setPinned(id, true)
    try await waitForStore(store) {
      !store.lifecycleBusy(id) && store.selectedThread?.lifecycle.pinned == true
        && store.selectedThread?.lifecycle.snoozedUntil == nil
    }
    store.setPinned(id, false)
    try await waitForStore(store) {
      !store.lifecycleBusy(id) && store.selectedThread?.lifecycle.pinned == false
    }
    store.setAutoSettle(id, enabled: false)
    try await waitForStore(store) {
      !store.lifecycleBusy(id) && store.selectedThread?.lifecycle.autoSettleDisabled == true
    }
    store.setAutoSettle(id, enabled: true)
    try await waitForStore(store) {
      !store.lifecycleBusy(id) && store.selectedThread?.lifecycle.autoSettleDisabled == false
    }
    store.markVisibleThreadRead()
    try await waitForStore(store) { store.selectedThread?.lifecycle.lastVisitedAt != nil }
    store.showArchives(true)
    try await waitForStore(store) { store.archives.synchronized }
    store.setArchived(id, true)
    try await waitForStore(store) {
      !store.lifecycleBusy(id) && store.shell.threads[id] == nil
        && store.archives.threads[id] != nil
    }
    store.select(id)
    try await waitForStore(store) { store.thread?.synchronized == true }
    guard !store.canEditThread else { throw T3Error("Archived composer remained editable.") }
    store.setArchived(id, false)
    try await waitForStore(store) {
      !store.lifecycleBusy(id) && store.shell.threads[id] != nil
        && store.archives.threads[id] == nil
    }
    store.showArchives(false)
    store.select(id, force: true)
    try await waitForStore(store) { store.canEditThread }
    guard store.drafts[id] == "Draft survives reconnect" else {
      throw T3Error("Thread lifecycle lost the draft.")
    }
    print(
      "Thread rename, pin/settle/snooze, auto-settle, visit, archive/restore, and draft retention round trips passed."
    )
    if CommandLine.arguments.contains("--tool-output-smoke") {
      try await dispatch(
        "thread.interaction-mode.set", fields: ["interactionMode": .string("default")])
      store.rename(id, to: "Native tool output verification")
      try await waitForStore(store) {
        !store.lifecycleBusy(id) && store.selectedThread?.title == "Native tool output verification"
      }
      try await toolOutput(store, connection: connection, threadID: id)
      return
    }
    let manualQuestion = CommandLine.arguments.contains("--manual-question")
    guard CommandLine.arguments.contains("--question-smoke") || manualQuestion else {
      try await dispatch(
        "thread.interaction-mode.set", fields: ["interactionMode": .string("default")])
      return
    }
    if manualQuestion {
      store.rename(id, to: "Native question UI verification")
      try await waitForStore(store) {
        !store.lifecycleBusy(id) && store.selectedThread?.title == "Native question UI verification"
      }
    }
    let stream = try await connection.subscribe(
      "orchestration.subscribeThread",
      payload: .object([
        "threadId": .string(id), "requestCompletionMarker": .bool(true),
        "acceptBoundedSnapshot": .bool(true),
      ]))
    defer { Task { await connection.cancel(stream.id) } }
    _ = try await connection.call(
      "orchestration.dispatchCommand",
      payload: Commands.message(
        threadID: id,
        text:
          "This is an interaction test. Use the request_user_input tool to ask one question, Which color?, with choices Blue and Green. Wait for the answer, then reply with exactly NATIVE_QUESTION_OK. Do not execute commands, inspect files, or use any other tool.",
        commandID: UUID().uuidString, messageID: UUID().uuidString))
    var state = ThreadState(id: id)
    var answered = Set<String>()
    for try await event in stream.values {
      _ = try state.apply(event)
      for request in state.pendingRequests
      where request.isQuestion && request.canRespond && !answered.contains(request.id) {
        if manualQuestion {
          print(
            "Real provider question is pending in Native question UI verification. Complete it in the app."
          )
          return
        }
        var drafts: [String: QuestionDraft] = [:]
        for question in request.questions {
          guard let questionID = question["id"].string else { continue }
          var draft = QuestionDraft()
          if let option = question["options"].array.first {
            draft.selected = [option["value"].string ?? option["label"].string ?? ""]
          } else {
            draft.custom = "Blue"
          }
          drafts[questionID] = draft
        }
        guard let answers = request.answers(from: drafts) else {
          throw T3Error("Provider question could not be answered.")
        }
        try await waitForStore(store) {
          store.thread?.pendingRequests.contains(where: { $0.id == request.id }) == true
        }
        guard let actual = store.thread?.pendingRequests.first(where: { $0.id == request.id })
        else { throw T3Error("Controller missed the request.") }
        store.questionDrafts[request.id] = drafts
        guard actual.answers(from: drafts) == answers else {
          throw T3Error("Controller question disagrees with wire projection.")
        }
        store.respond(actual)
        try await waitForStore(store) {
          store.thread?.pendingRequests.contains(where: { $0.id == request.id }) == false
        }
        answered.insert(request.id)
        print("Answered one real provider question.")
      }
      if !answered.isEmpty, state.pendingRequests.isEmpty,
        state.rows.contains(where: {
          $0.kind == "assistant_message" && !$0.streaming && $0.text.contains("NATIVE_QUESTION_OK")
        })
      {
        print("Question response, resolved state, and completed provider reply passed.")
        return
      }
    }
    throw T3Error("Question stream ended before verification completed.")
  }

  @MainActor private static func toolOutput(
    _ store: ClientStore, connection: RPCConnection, threadID: String, resume: Bool = false
  ) async throws {
    let stream = try await connection.subscribe(
      "orchestration.subscribeThread",
      payload: .object([
        "threadId": .string(threadID), "requestCompletionMarker": .bool(true),
        "acceptBoundedSnapshot": .bool(true),
      ]))
    defer { Task { await connection.cancel(stream.id) } }
    if !resume {
      _ = try await connection.call(
        "orchestration.dispatchCommand",
        payload: Commands.message(
          threadID: threadID,
          text:
            "This is a tool-output test. Run exactly `printf NATIVE_TOOL_OUTPUT_OK` once with your shell tool, then reply exactly NATIVE_TOOL_DONE. Do not read, write, or modify files, inspect the workspace, use the network, or run any other command.",
          commandID: UUID().uuidString, messageID: UUID().uuidString))
    }
    var state = ThreadState(id: threadID)
    var fetched = false
    var approved = Set<String>()
    for try await event in stream.values {
      _ = try state.apply(event)
      for request in state.pendingRequests where !approved.contains(request.id) {
        guard request.kind == "command", request.canRespond,
          ["printf NATIVE_TOOL_OUTPUT_OK", "/bin/zsh -lc 'printf NATIVE_TOOL_OUTPUT_OK'"].contains(
            request.detail),
          request.options.contains(where: { $0["decision"].string == "accept" })
        else {
          throw T3Error("Tool-output test stopped at an unexpected approval request.")
        }
        try await waitForStore(store) {
          store.thread?.pendingRequests.contains(where: { $0.id == request.id }) == true
        }
        guard let actual = store.thread?.pendingRequests.first(where: { $0.id == request.id })
        else { throw T3Error("Controller missed command approval.") }
        store.respond(actual, decision: "accept")
        try await waitForStore(store) {
          store.thread?.pendingRequests.contains(where: { $0.id == request.id }) == false
        }
        approved.insert(request.id)
        print(
          "ClientStore approved the exact diagnostic printf command once and observed resolution.")
      }
      if !fetched,
        let row = state.rows.first(where: {
          $0.item["outputOmitted"].bool && $0.item["status"].string == "completed"
        })
      {
        try await waitForStore(store) {
          store.thread?.rows.contains(where: {
            $0.id == row.id && $0.item["status"].string == "completed"
          }) == true
        }
        guard let current = store.thread?.rows.first(where: { $0.id == row.id }) else {
          throw T3Error("Controller missed tool output.")
        }
        store.loadOutput(current)
        try await waitForStore(store) {
          store.thread?.rows.contains(where: {
            $0.id == row.id && !$0.item["outputOmitted"].bool
              && $0.item["output"].displayText.contains("NATIVE_TOOL_OUTPUT_OK")
          }) == true
        }
        fetched = true
        print("Real tool output was omitted from the live feed and fetched by ClientStore.")
      }
      if state.rows.contains(where: {
        $0.kind == "assistant_message" && !$0.streaming && $0.text == "NATIVE_TOOL_DONE"
      }) {
        guard fetched else {
          throw T3Error("Provider completed without exercising omitted tool output.")
        }
        print("Tool-output hydration and completed provider reply passed.")
        return
      }
    }
    throw T3Error("Tool-output verification ended before completion.")
  }

  @MainActor private static func attachments(
    settings: ConnectionSettings, connection: RPCConnection, threadID: String
  ) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "t3-attachment-smoke-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("native-attachment.txt")
    let content = Data("NATIVE_ATTACHMENT_BYTES_OK\n".utf8)
    try content.write(to: source)
    let image = directory.appendingPathComponent("native-image.png")
    let imageBytes = Data(
      base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aJ1sAAAAASUVORK5CYII="
    )!
    try imageBytes.write(to: image)
    let drafts = directory.appendingPathComponent("drafts")
    let store = ClientStore(draftDirectory: drafts)
    store.connect(settings, selecting: threadID)
    try await waitForStore(store) { store.canEditThread && store.catalogReady }
    store.rename(threadID, to: "Native attachment verification")
    store.addAttachments([source, image])
    try await waitForStore(store) {
      store.selectedAttachments.count == 2
        && store.selectedAttachments.allSatisfy { store.attachmentUploads[$0.id] == .ready }
    }
    let original = store.selectedAttachments
    try await store.downloadAttachment(
      original[0].wire!, to: directory.appendingPathComponent("download-before.txt"))
    guard try Data(contentsOf: directory.appendingPathComponent("download-before.txt")) == content
    else { throw T3Error("Uploaded bytes changed.") }
    try FileManager.default.removeItem(at: source)
    try FileManager.default.removeItem(at: image)
    guard store.saveDraftsBeforeExit() else {
      throw T3Error("Could not persist the attachment draft.")
    }
    store.disconnect()
    _ = try await connection.call(
      "attachments.delete", payload: .object(["attachmentId": .string(original[0].uploadedID!)]))
    let restored = ClientStore(draftDirectory: drafts)
    restored.connect(settings, selecting: threadID)
    defer { restored.disconnect() }
    try await waitForStore(restored) {
      restored.canEditThread && restored.selectedAttachments.count == 2
        && restored.selectedAttachments.allSatisfy { restored.attachmentUploads[$0.id] == .ready }
    }
    guard restored.selectedAttachments[0].uploadedID != original[0].uploadedID,
      restored.selectedAttachments[1].uploadedID == original[1].uploadedID
    else {
      throw T3Error("Attachment recovery did not replace only the missing upload.")
    }
    restored.drafts[threadID] =
      "This is an attachment delivery test. Reply exactly NATIVE_ATTACHMENT_DONE without opening the attached files or using any tools."
    restored.send()
    try await waitForStore(restored) {
      !restored.sending.contains(threadID) && restored.selectedAttachments.isEmpty
    }
    try await waitForStore(restored) {
      restored.thread?.rows.contains {
        $0.kind == "assistant_message" && !$0.streaming
          && $0.text.contains("NATIVE_ATTACHMENT_DONE")
      } == true
    }
    guard let message = restored.thread?.rows.last(where: { $0.kind == "user_message" }),
      message.item["attachments"].array.count == 2
    else {
      throw T3Error("The accepted message did not contain both attachments.")
    }
    for attachment in message.item["attachments"].array {
      let destination = directory.appendingPathComponent("download-after")
      try await restored.downloadAttachment(attachment, to: destination)
      let expected = attachment["type"].string == "image" ? imageBytes : content
      guard try Data(contentsOf: destination) == expected else {
        throw T3Error("Claimed attachment bytes changed.")
      }
    }
    print(
      "Attachment upload/download, restart after source removal, expired-upload recovery, real send/reply and claimed bytes passed."
    )
  }

  @MainActor private static func questions(
    settings: ConnectionSettings, connection: RPCConnection, threadID: String
  ) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "t3-questions-smoke-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let draftDirectory = directory.appendingPathComponent("drafts")
    let source = directory.appendingPathComponent("question-evidence.txt")
    let bytes = Data("Native question attachment evidence.\n".utf8)
    try bytes.write(to: source)
    var store = ClientStore(draftDirectory: draftDirectory)
    defer { store.disconnect() }
    do {
      _ = try await connection.call(
        "orchestration.dispatchCommand",
        payload: .object([
          "type": .string("thread.interaction-mode.set"), "commandId": .string(UUID().uuidString),
          "threadId": .string(threadID), "interactionMode": .string("plan"),
        ]))
      store.connect(settings, selecting: threadID)
      try await waitForStore(store) { store.canEditThread && store.catalogReady }
      store.rename(threadID, to: "Native question paging verification")
      store.composerText =
        "For a UI test, call request_user_input with exactly two questions in one call. First ask Color? with options Blue (recommended) and Green. Second ask Evidence? with options File and Text; I may supply a custom answer or attached file instead. Wait for both answers, then reply exactly NATIVE_QUESTION_PAGING_DONE. Do not inspect files or run any other tools."
      store.submitComposer()
      try await waitForStore(store) {
        !store.sending.contains(threadID) && store.questionRequest?.questions.count == 2
      }
      guard let request = store.questionRequest, request.canRespond,
        store.catalog.attachmentPolicy.questions,
        let firstID = request.questions[0]["id"].string,
        let secondID = request.questions[1]["id"].string,
        let option = request.questions[0]["options"].array.first
      else {
        throw T3Error(
          "The provider did not issue two answerable questions with attachment support.")
      }
      store.drafts[threadID] = "Separate draft behind the questions."
      let value = option["value"].string ?? option["label"].string ?? "Blue"
      store.chooseQuestionOption(value, request: request, question: request.questions[0])
      store.submitComposer()
      guard store.activeQuestionProgress?.index == 1, store.composerText.isEmpty else {
        throw T3Error("The composer did not advance to the second question.")
      }
      store.composerText = "Saved custom answer for the second question."
      store.addAttachments([source])
      try await waitForStore(store) {
        store.selectedAttachments.count == 1
          && store.selectedAttachments.allSatisfy {
            store.attachmentUploads[$0.id] == .ready
          }
      }
      let attachment = store.selectedAttachments[0]
      store.setQuestionPage(0, request: request)
      guard store.selectedAttachments.isEmpty, store.composerText.isEmpty else {
        throw T3Error("The second question's files leaked into the first question.")
      }
      store.setQuestionPage(1, request: request)
      guard store.composerText == "Saved custom answer for the second question.",
        store.selectedAttachments.map(\.id) == [attachment.id], store.saveDraftsBeforeExit()
      else { throw T3Error("Paging lost the question draft or attachment.") }
      try FileManager.default.removeItem(at: source)
      store.disconnect()
      store = ClientStore(draftDirectory: draftDirectory)
      store.connect(settings, selecting: threadID)
      try await waitForStore(store) {
        store.canEditThread && store.catalogReady && store.activeQuestionProgress?.index == 1
          && store.selectedAttachments.count == 1
          && store.selectedAttachments.allSatisfy { store.attachmentUploads[$0.id] == .ready }
      }
      guard store.composerText == "Saved custom answer for the second question.",
        store.questionDrafts[request.id]?[firstID]?.selected == [value],
        store.drafts[threadID] == "Separate draft behind the questions."
      else { throw T3Error("A question answer or the normal draft did not survive restart.") }
      store.composerText = ""
      guard store.sendBlockReason == nil else {
        throw T3Error("An attachment-only answer was blocked.")
      }
      store.submitComposer()
      try await waitForStore(store) {
        store.questionRequest == nil && !store.questionBusy(request)
          && store.execution.activeRunID == nil
          && store.thread?.rows.contains {
            $0.kind == "assistant_message" && !$0.streaming
              && $0.text.contains("NATIVE_QUESTION_PAGING_DONE")
          } == true
      }
      let projection = try await connection.call(
        "orchestration.getThreadProjection",
        payload: .object(["threadId": .string(threadID)]))
      guard
        let recorded = projection["turnItems"].array.first(where: {
          $0["requestId"].string == request.id
        })?["questionAnswer"],
        recorded["answers"][firstID].string == value,
        recorded["answers"][secondID].string?.contains(attachment.name) == true,
        recorded["attachmentsByQuestionId"][secondID].array.first?["name"].string
          == attachment.name,
        store.composerText == "Separate draft behind the questions.",
        store.selectedAttachments.isEmpty, store.questionDrafts[request.id] == nil,
        store.thread?.rows.first(where: { $0.item["requestId"].string == request.id })?.attachments
          .count == 1
      else {
        throw T3Error(
          "The recorded answer, attachment, or restored main draft differs from the submission.")
      }
      let downloaded = directory.appendingPathComponent("downloaded.txt")
      try await store.downloadAttachment(
        recorded["attachmentsByQuestionId"][secondID].array[0], to: downloaded)
      guard try Data(contentsOf: downloaded) == bytes else {
        throw T3Error("The claimed answer attachment changed bytes.")
      }
      store.composerText =
        "For one more UI test, call request_user_input with one question: Ready? Offer Continue and Stop. After I answer, reply exactly NATIVE_QUESTION_EXTERNAL_DONE. Do not use any other tools."
      store.submitComposer()
      try await waitForStore(store) {
        !store.sending.contains(threadID) && store.questionRequest != nil
      }
      guard let externalRequest = store.questionRequest else {
        throw T3Error("Missing cross-client question.")
      }
      store.drafts[threadID] = "Separate draft behind the questions."
      store.composerText = "Unsent answer superseded by another client."
      let unusedSource = directory.appendingPathComponent("unused-answer.txt")
      try bytes.write(to: unusedSource)
      store.addAttachments([unusedSource])
      try await waitForStore(store) {
        store.selectedAttachments.count == 1
          && store.selectedAttachments.allSatisfy {
            store.attachmentUploads[$0.id] == .ready
          }
      }
      guard let repository = store.attachmentRepository else {
        throw T3Error("Missing answer storage.")
      }
      let unusedFile = try repository.file(store.selectedAttachments[0])
      var externalAnswers: [String: JSON] = [:]
      for question in externalRequest.questions {
        guard let id = question["id"].string, let option = question["options"].array.first else {
          continue
        }
        externalAnswers[id] = .string(
          option["value"].string ?? option["label"].string ?? "Continue")
      }
      _ = try await connection.call(
        "orchestration.dispatchCommand",
        payload: .object([
          "type": .string("runtime-request.respond"), "commandId": .string(UUID().uuidString),
          "threadId": .string(threadID), "requestId": .string(externalRequest.id),
          "answers": .object(externalAnswers),
        ]))
      try await waitForStore(store) {
        store.questionRequest == nil && store.execution.activeRunID == nil
          && store.thread?.rows.contains {
            $0.kind == "assistant_message" && !$0.streaming
              && $0.text.contains("NATIVE_QUESTION_EXTERNAL_DONE")
          } == true
      }
      guard store.questionDrafts[externalRequest.id] == nil,
        !FileManager.default.fileExists(atPath: unusedFile.path),
        store.composerText == "Separate draft behind the questions.",
        let answeredRow = store.thread?.rows.first(where: {
          $0.item["requestId"].string == externalRequest.id
        }), externalAnswers.values.allSatisfy({ answeredRow.text.contains($0.string ?? "") })
      else {
        throw T3Error(
          "Cross-client resolution lost an answer, retained obsolete files, or changed the draft.")
      }
      print(
        "PASS: two real questions, separate answer files, backward/forward paging, restart after source deletion, attachment-only response, claimed bytes, provider completion and cross-client cleanup; normal draft preserved."
      )
    } catch {
      let projection = try? await connection.call(
        "orchestration.getThreadProjection",
        payload: .object(["threadId": .string(threadID)]))
      for run in projection?["runs"].array ?? []
      where ["preparing", "starting", "running", "waiting"].contains(run["status"].string ?? "") {
        _ = try? await connection.call(
          "orchestration.dispatchCommand",
          payload: .object([
            "type": .string("run.interrupt"), "commandId": .string(UUID().uuidString),
            "threadId": .string(threadID), "runId": run["id"], "holdQueue": .bool(true),
          ]))
      }
      throw error
    }
  }

  @MainActor private static func queue(
    settings: ConnectionSettings, connection: RPCConnection, threadID: String
  ) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "t3-queue-smoke-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let draftDirectory = directory.appendingPathComponent("drafts")
    let source = directory.appendingPathComponent("queue-first.txt")
    let extra = directory.appendingPathComponent("queue-extra.txt")
    try Data("First queued attachment\n".utf8).write(to: source)
    try Data("Added while editing\n".utf8).write(to: extra)
    var store = ClientStore(draftDirectory: draftDirectory)
    defer { store.disconnect() }
    do {
      _ = try await connection.call(
        "orchestration.dispatchCommand",
        payload: .object([
          "type": .string("thread.interaction-mode.set"), "commandId": .string(UUID().uuidString),
          "threadId": .string(threadID), "interactionMode": .string("plan"),
        ]))
      store.connect(settings, selecting: threadID)
      try await waitForStore(store) { store.canEditThread && store.catalogReady }
      store.rename(threadID, to: "Native queue verification")
      store.addAttachments([source])
      try await waitForStore(store) {
        store.selectedAttachments.count == 1
          && store.selectedAttachments.allSatisfy { store.attachmentUploads[$0.id] == .ready }
      }
      _ = try await connection.call(
        "orchestration.dispatchCommand",
        payload: Commands.message(
          threadID: threadID,
          text:
            "For a UI queue test, call request_user_input now with one question: Ready? Offer Continue and Stop. Wait for my answer. After Continue, or if I ask to continue after an interruption, reply exactly NATIVE_QUEUE_READY and finish without asking again. Do not inspect files or run commands.",
          commandID: UUID().uuidString, messageID: UUID().uuidString))
      try await waitForStore(store) {
        store.thread?.pendingRequests.contains { $0.isQuestion && $0.canRespond } == true
      }
      guard store.execution.canQueue else {
        throw T3Error("The test provider did not advertise queued messages.")
      }
      store.setDelivery(.queue)
      store.drafts[threadID] =
        "Reply exactly NATIVE_QUEUE_FIRST. Do not open attachments or use tools."
      store.send()
      try await waitForStore(store) {
        !store.sending.contains(threadID) && store.execution.queued.count == 1
      }
      let first = store.execution.queued[0]
      store.drafts[threadID] = "Reply exactly NATIVE_QUEUE_REMOVE. Do not use tools."
      store.send()
      try await waitForStore(store) {
        !store.sending.contains(threadID) && store.execution.queued.count == 2
      }
      let second = store.execution.queued[1]
      store.drafts[threadID] = "Separate normal draft must survive editing."
      store.editQueuedMessage(first)
      guard store.queuedEdit?.attachments.count == 1 else {
        throw T3Error("Queued edit dropped the original attachment.")
      }
      let edited = "Reply exactly NATIVE_QUEUE_EDITED. Do not open attachments or use tools."
      store.composerText = edited
      store.addAttachments([extra])
      try await waitForStore(store) {
        store.selectedAttachments.count == 1
          && store.selectedAttachments.allSatisfy { store.attachmentUploads[$0.id] == .ready }
      }
      store.cancelQueuedEdit()
      store.editQueuedMessage(second)
      let secondEdit = "Unsent edit of the second queued message."
      store.composerText = secondEdit
      store.cancelQueuedEdit()
      guard store.savedQueuedEdits.count == 2,
        store.drafts[threadID] == "Separate normal draft must survive editing."
      else { throw T3Error("Editing a second queued message lost an earlier draft.") }
      store.reopenQueuedEdit(first.id)
      guard store.saveDraftsBeforeExit() else { throw T3Error("Queued edit was not saved.") }
      store.disconnect()
      store = ClientStore(draftDirectory: draftDirectory)
      store.connect(settings, selecting: threadID)
      try await waitForStore(store) {
        store.canEditThread && store.catalogReady && store.queuedEdit != nil
          && store.selectedAttachments.allSatisfy { store.attachmentUploads[$0.id] == .ready }
      }
      guard store.composerText == edited,
        store.drafts[threadID] == "Separate normal draft must survive editing.",
        store.queuedEdit?.attachments.count == 1, store.selectedAttachments.count == 1,
        store.savedQueuedEdits.first?.runID == second.id,
        store.drafts["queued-edit:" + second.id] == secondEdit
      else { throw T3Error("Queued edit and normal draft did not restore separately.") }
      store.send()
      try await waitForStore(store) {
        !store.sending.contains(threadID) && store.queuedEdit == nil
          && store.execution.queued.first?.text == edited
      }
      guard store.execution.queued[0].attachments.count == 2,
        store.drafts[threadID] == "Separate normal draft must survive editing."
      else { throw T3Error("Saving the queued edit lost attachments or the normal draft.") }
      store.reorderQueuedMessage(second.id, before: first.id)
      try await waitForStore(store) {
        !store.queueBusy && store.execution.queued.first?.id == second.id
      }
      store.reorderQueuedMessage(first.id, before: second.id)
      try await waitForStore(store) {
        !store.queueBusy && store.execution.queued.first?.id == first.id
      }
      store.cancelQueuedMessage(second.id)
      try await waitForStore(store) { !store.queueBusy && store.execution.queued.count == 1 }
      store.reopenQueuedEdit(second.id)
      guard store.composerText == secondEdit,
        store.sendBlockReason?.contains("started or was removed") == true
      else { throw T3Error("The cancelled message's saved edit was lost or could be sent.") }
      store.cancelQueuedEdit()
      store.stop()
      try await waitForStore(store) {
        store.execution.activeRunID == nil && store.execution.isHeld
          && store.execution.resumableRunID != nil
      }
      store.resume()
      try await waitForStore(store) {
        store.thread?.pendingRequests.contains { $0.isQuestion && $0.canRespond } == true
          || store.thread?.rows.contains {
            $0.kind == "assistant_message" && !$0.streaming
              && $0.text.contains("NATIVE_QUEUE_EDITED")
          } == true
      }
      if let request = store.thread?.pendingRequests.first(where: { $0.isQuestion && $0.canRespond }
      ) {
        var drafts: [String: QuestionDraft] = [:]
        for question in request.questions {
          guard let id = question["id"].string, let option = question["options"].array.first else {
            continue
          }
          var draft = QuestionDraft()
          draft.selected = [option["value"].string ?? option["label"].string ?? "Continue"]
          drafts[id] = draft
        }
        store.questionDrafts[request.id] = drafts
        store.respond(request)
      }
      try await waitForStore(store) {
        store.execution.queued.isEmpty && store.execution.activeRunID == nil
          && store.thread?.rows.contains {
            $0.kind == "assistant_message" && !$0.streaming
              && $0.text.contains("NATIVE_QUEUE_EDITED")
          } == true
      }
      guard store.drafts[threadID] == "Separate normal draft must survive editing." else {
        throw T3Error("Resume overwrote the normal draft.")
      }
      print(
        "PASS: real queued messages, multiple saved edits and attachments across restart, reorder, cancel, stop/hold, resume and provider reply; separate draft preserved."
      )
    } catch {
      let projection = try? await connection.call(
        "orchestration.getThreadProjection", payload: .object(["threadId": .string(threadID)]))
      for run in projection?["runs"].array ?? [] {
        let status = run["status"].string ?? ""
        if status == "queued" || ["preparing", "starting", "running", "waiting"].contains(status) {
          _ = try? await connection.call(
            "orchestration.dispatchCommand",
            payload: .object([
              "type": .string(status == "queued" ? "queued-run.cancel" : "run.interrupt"),
              "commandId": .string(UUID().uuidString), "threadId": .string(threadID),
              "runId": run["id"],
            ]))
        }
      }
      throw error
    }
  }

  @MainActor private static func queueSteering(
    settings: ConnectionSettings, connection: RPCConnection, threadID: String
  ) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "t3-steer-smoke-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ClientStore(draftDirectory: directory)
    store.connect(settings, selecting: threadID)
    defer { store.disconnect() }
    try await waitForStore(store) { store.canEditThread && store.catalogReady }
    do {
      for (mode, marker) in [
        (MessageDelivery.queue, "NATIVE_PROMOTED"), (.steer, "NATIVE_DIRECT_STEER"),
        (.restart, "NATIVE_RESTARTED"),
      ] {
        store.setDelivery(.auto)
        store.composerText =
          "This is a controlled steering test. Ask one request_user_input question: Ready? with Continue and Stop options, then wait. If a new user message arrives, follow it immediately and do not ask another question. Do not use other tools or inspect any files."
        store.send()
        try await waitForStore(store) {
          store.thread?.pendingRequests.contains { $0.isQuestion && $0.canRespond } == true
        }
        if mode == .restart && !store.execution.canRestart {
          store.stop()
          try await waitForStore(store) { store.execution.activeRunID == nil }
          print(
            "Restart control correctly disabled: the real provider does not advertise interrupt/restart steering."
          )
          break
        }
        guard store.execution.canSteer else {
          throw T3Error("The test provider did not expose a steerable turn.")
        }
        store.setDelivery(mode)
        store.drafts[threadID] =
          "Stop waiting for the previous question. Reply exactly \(marker) and finish without using tools or asking questions."
        store.send()
        if mode == .queue {
          try await waitForStore(store) {
            !store.sending.contains(threadID) && store.execution.queued.count == 1
          }
          store.steerQueuedMessage(store.execution.queued[0].id)
        }
        try await waitForStore(store) {
          !store.queueBusy && !store.sending.contains(threadID) && store.execution.queued.isEmpty
        }
        if mode != .restart,
          let request = store.thread?.pendingRequests.first(where: {
            $0.isQuestion && $0.canRespond
          })
        {
          var drafts: [String: QuestionDraft] = [:]
          for question in request.questions {
            guard let id = question["id"].string, let option = question["options"].array.first
            else { continue }
            var draft = QuestionDraft()
            draft.selected = [option["value"].string ?? option["label"].string ?? "Continue"]
            drafts[id] = draft
          }
          store.questionDrafts[request.id] = drafts
          store.respond(request)
        }
        try await waitForStore(store) {
          !store.queueBusy && store.execution.queued.isEmpty && store.execution.activeRunID == nil
            && store.thread?.rows.contains {
              $0.kind == "assistant_message" && !$0.streaming && $0.text.contains(marker)
            } == true
        }
        print("PASS: \(marker) through real provider.")
      }
    } catch {
      if let run = store.execution.activeRunID {
        _ = try? await connection.call(
          "orchestration.dispatchCommand",
          payload: .object([
            "type": .string("run.interrupt"), "commandId": .string(UUID().uuidString),
            "threadId": .string(threadID), "runId": .string(run), "holdQueue": .bool(true),
          ]))
      }
      for queued in store.execution.queued {
        _ = try? await connection.call(
          "orchestration.dispatchCommand",
          payload: .object([
            "type": .string("queued-run.cancel"), "commandId": .string(UUID().uuidString),
            "threadId": .string(threadID), "runId": .string(queued.id),
          ]))
      }
      throw error
    }
  }

  @MainActor private static func plans(
    settings: ConnectionSettings, connection: RPCConnection, threadID: String
  ) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "t3-plans-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let preferenceDomain = "t3-native-plan-smoke-" + UUID().uuidString
    let preferences = UserDefaults(suiteName: preferenceDomain)!
    defer { preferences.removePersistentDomain(forName: preferenceDomain) }
    var store = ClientStore(draftDirectory: directory, preferences: preferences)
    store.setPlanModeEnabled(true)
    defer { store.disconnect() }
    var targets = Set([threadID])
    func projection(_ id: String) async throws -> JSON {
      try await connection.call(
        "orchestration.getThreadProjection", payload: .object(["threadId": .string(id)]))
    }
    func propose(_ title: String) async throws {
      store.setInteractionMode("plan")
      try await waitForStore(store) {
        store.canEditThread && store.selectedThread?.interactionMode == "plan"
      }
      store.composerText =
        "This is a native plan UI test. Do not use tools, inspect files, or run commands. Return a proposed plan using the native <proposed_plan> format, titled \(title). The plan must have exactly one implementation step: reply exactly NATIVE_PLAN_IMPLEMENTED without doing anything else. Do not implement yet."
      store.send()
      try await waitForStore(store, seconds: 60) {
        !store.sending.contains(threadID) && store.planFollowUp?.title == title
      }
    }
    do {
      store.connect(settings, selecting: threadID)
      try await waitForStore(store) { store.canEditThread && store.catalogReady }
      store.rename(threadID, to: "Native plan verification")
      try await waitForStore(store) { !store.lifecycleBusy(threadID) }
      try await propose("Native plan handoff")
      let initialRun = store.execution.latestRunID
      store.composerText =
        "Refine the plan: change its title to Native refined plan. Keep its sole implementation step of replying exactly NATIVE_PLAN_IMPLEMENTED, with no tools, commands, or file changes. Return only the revised proposed plan."
      store.submitComposer()
      try await waitForStore(store, seconds: 60) {
        !store.sending.contains(threadID) && store.planFollowUp?.title == "Native refined plan"
          && store.execution.latestRunID != initialRun
      }
      guard store.selectedThread?.interactionMode == "plan", store.composerText.isEmpty else {
        throw T3Error("Refining a plan left planning mode or retained the sent draft.")
      }
      print("PASS: real proposed plan and composer refinement in planning mode.")
      for newThread in [true, false] {
        if !newThread {
          store.select(threadID)
          try await waitForStore(store) { store.canEditThread && store.selectedID == threadID }
          try await propose("Native same thread plan")
        }
        guard let plan = store.planFollowUp, let template = store.selectedThread else {
          throw T3Error("Missing actionable plan.")
        }
        let runtime = store.catalog.defaultRuntimeMode(projectID: template.projectID)
        let command = PendingPlanSubmission(
          plan: plan, template: template, draft: "", newThread: newThread,
          defaultRuntimeMode: runtime)
        targets.insert(command.targetThreadID)
        store.disconnect()
        try DraftRepository(directory: directory).save(
          SavedDrafts(messages: [threadID: ""], planSubmissions: [threadID: command]),
          for: settings.endpoint)
        _ = try await connection.call("orchestration.dispatchCommand", payload: command.setup)
        store = ClientStore(draftDirectory: directory, preferences: preferences)
        store.connect(settings, selecting: threadID)
        try await waitForStore(store) {
          store.canEditThread && store.catalogReady && store.pendingPlanSubmission != nil
        }
        guard store.pendingPlanSubmission == command, store.planFollowUp != nil,
          store.sendBlockReason == nil
        else {
          throw T3Error("A partially committed plan send could not be resumed after restart.")
        }
        store.submitComposer()
        try await waitForStore(store, seconds: 60) {
          store.selectedID == command.targetThreadID && store.thread?.synchronized == true
            && !store.sending.contains(threadID) && store.execution.activeRunID == nil
            && store.thread?.rows.contains(where: {
              $0.kind == "assistant_message" && !$0.streaming
                && $0.text.contains("NATIVE_PLAN_IMPLEMENTED")
            }) == true
        }
        // Replaying a send whose reply was lost must succeed even though it completed the source plan.
        for payload in [command.setup, command.message] {
          _ = try await connection.call("orchestration.dispatchCommand", payload: payload)
        }
        let result = try await projection(command.targetThreadID)
        let source = newThread ? try await projection(threadID) : result
        guard result["thread"]["interactionMode"].string == "default",
          result["messages"].array.filter({ $0["id"] == command.message["messageId"] }).count == 1,
          result["runs"].array.first(where: { $0["userMessageId"] == command.message["messageId"] }
          )?["sourcePlanRef"]
            == command.message["sourcePlanRef"],
          source["plans"].array.first(where: { $0["id"].string == plan.id })?["status"].string
            == "completed",
          result["thread"]["modelSelection"] == template.model,
          result["thread"]["branch"].string == template.branch,
          result["thread"]["worktreePath"].string == template.worktreePath
        else {
          throw T3Error(
            "Plan implementation lost its source link, workspace, model, or retry identity.")
        }
        if newThread {
          guard result["thread"]["runtimeMode"].string == runtime,
            source["thread"]["interactionMode"].string == "plan"
          else {
            throw T3Error(
              "New-thread implementation changed the source mode or ignored project defaults.")
          }
        }
        print(
          "PASS: \(newThread ? "new-thread" : "same-thread") implementation \(command.targetThreadID), partial-send restart, stable message, completed source plan, preserved model/workspace and provider reply."
        )
      }
    } catch {
      for id in targets {
        let value = try? await projection(id)
        for run in value?["runs"].array ?? []
        where ["preparing", "starting", "running", "waiting"].contains(run["status"].string ?? "") {
          _ = try? await connection.call(
            "orchestration.dispatchCommand",
            payload: .object([
              "type": .string("run.interrupt"), "commandId": .string(UUID().uuidString),
              "threadId": .string(id), "runId": run["id"], "holdQueue": .bool(true),
            ]))
        }
      }
      throw error
    }
  }

  @MainActor private static func workspaceFiles(
    settings: ConnectionSettings, connection: RPCConnection, threadID: String, projectID: String
  ) async throws {
    let original = try await connection.call(
      "orchestration.getThreadProjection",
      payload: .object(["threadId": .string(threadID)]))
    guard original["thread"]["projectId"].string == projectID,
      original["thread"]["title"].string == "Native plan verification"
    else {
      throw T3Error("Workspace checks require an isolated plan verification thread.")
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "t3-files-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ClientStore(draftDirectory: directory.appendingPathComponent("chat"))
    store.connect(settings, selecting: threadID)
    defer { store.disconnect() }
    try await waitForStore(store) { store.canEditThread }
    guard let location = store.workspaceLocation else { throw T3Error("No workspace.") }
    let folder = "native-files-" + UUID().uuidString.lowercased()
    let path = folder + "/nested/日本語 file.txt"
    let originalContents = "First line\r\n🦉 exact UTF-8\r\n"
    func write(_ path: String, _ contents: String) async throws {
      _ = try await store.workspaceCall(
        "projects.writeFile", at: location,
        fields: [
          "relativePath": .string(path), "contents": .string(contents),
        ])
    }
    try await write(path, originalContents)
    try await write(folder + "/.gitignore", "ignored/\n")
    try await write(folder + "/ignored/hidden.txt", "ignored but browsable\n")
    let files = WorkspaceFiles(store: store, directory: directory.appendingPathComponent("files"))
    files.refreshContext()
    try await waitForFiles(files) { files.directories[""] != nil && !files.loadingTree }
    guard files.directories.count == 1,
      files.directories[""]?.contains(where: { $0.path == folder && $0.isDirectory }) == true
    else {
      throw T3Error("Root listing was missing its fixture or recursively loaded folders.")
    }
    files.loadDirectory(folder)
    files.loadDirectory(folder)
    try await waitForFiles(files) { files.directories[folder] != nil && !files.loadingTree }
    guard files.directories.count == 2,
      files.directories[folder]?.contains(where: { $0.path == folder + "/ignored" && $0.ignored })
        == true
    else {
      throw T3Error("Lazy listing lost ignored directories or loaded descendants.")
    }
    files.loadDirectory(folder + "/nested")
    try await waitForFiles(files) {
      files.directories[folder + "/nested"]?.contains(where: { $0.path == path }) == true
    }
    files.search("日本語 file")
    files.search(folder + "/nested")
    try await waitForFiles(files) { files.searchResults.contains(where: { $0.path == path }) }
    files.search("")
    files.open(path)
    try await waitForFiles(files) { !files.loadingFile && files.document != nil }
    guard files.document?.contents == originalContents else {
      throw T3Error("Read changed Unicode or CRLF bytes.")
    }
    let firstEdit = originalContents + "First edit\n"
    files.edit(originalContents + "temporary typing")
    files.edit(firstEdit)
    try await waitForFiles(files) { !files.pendingSave && files.document?.original == firstEdit }
    guard try await store.readWorkspaceFile(path, at: location).contents == firstEdit else {
      throw T3Error("Debounced autosave did not persist the latest bytes.")
    }
    let switchedEdit = firstEdit + "Flush when changing files\n"
    files.edit(switchedEdit)
    files.open(folder + "/.gitignore")
    try await waitForFiles(files) {
      !files.loadingFile && files.saving.isEmpty && files.drafts.isEmpty
    }
    guard try await store.readWorkspaceFile(path, at: location).contents == switchedEdit else {
      throw T3Error("Switching files did not flush the debounce window.")
    }
    files.open(path)
    try await waitForFiles(files) { !files.loadingFile && files.document?.path == path }
    let recoveryEdit = switchedEdit + "Recover after a disconnected write\n"
    files.edit(recoveryEdit)
    store.disconnect()
    files.refreshContext()
    guard await files.finishSaving() else { throw T3Error("Could not persist disconnected edits.") }
    store.connect(settings, selecting: threadID)
    try await waitForStore(store) { store.canEditThread }
    let restored = WorkspaceFiles(
      store: store, directory: directory.appendingPathComponent("files"))
    restored.refreshContext()
    restored.open(path)
    guard restored.document?.contents == recoveryEdit, restored.document?.requiresRecovery == true
    else {
      throw T3Error("Restart did not recover disconnected file edits.")
    }
    let secondEdit = recoveryEdit + "Typed while saving\n"
    var editedDuringSave = false
    var sawIntermediateConfirmation = false
    restored.onChange = {
      if !restored.saving.isEmpty && !editedDuringSave {
        editedDuringSave = true
        restored.edit(secondEdit)
      }
      if restored.document?.original == recoveryEdit && restored.document?.contents == secondEdit {
        sawIntermediateConfirmation = true
      }
    }
    try await restored.save()
    restored.onChange = nil
    guard editedDuringSave, sawIntermediateConfirmation, restored.document?.contents == secondEdit,
      !restored.pendingSave,
      try await store.readWorkspaceFile(path, at: location).contents == secondEdit
    else {
      throw T3Error("Flushing lost or failed to serialize edits made during a write.")
    }
    let remoteEdit = secondEdit + "agent edit\n"
    try await write(path, remoteEdit)
    restored.edit(secondEdit + "local conflicting edit\n")
    restored.receiveWorkspaceMutation("conflicting-fixture-mutation")
    var rejected = false
    do { try await restored.save() } catch {
      rejected = error.localizedDescription.contains("changed on the server")
    }
    let preserved = try await store.readWorkspaceFile(path, at: location)
    guard rejected, restored.document?.isDirty == true, preserved.contents == remoteEdit else {
      throw T3Error("A conflict or pending mutation replaced unsaved edits.")
    }
    restored.open(path, reload: true)
    try await waitForFiles(restored) {
      !restored.loadingFile && restored.document?.contents == remoteEdit
    }
    let refreshed = remoteEdit + "refresh after a workspace mutation\n"
    try await write(path, refreshed)
    restored.receiveWorkspaceMutation("clean-fixture-mutation")
    try await waitForFiles(restored) {
      !restored.loadingFile && restored.document?.contents == refreshed
    }
    let retriedContents = refreshed + "accepted before reply lost\n"
    restored.edit(retriedContents)
    try await write(path, retriedContents)
    store.disconnect()
    restored.refreshContext()
    guard !restored.canSave else { throw T3Error("Disconnected editor could save.") }
    guard await restored.finishSaving() else {
      throw T3Error("Could not preserve an uncertain save.")
    }
    store.connect(settings, selecting: threadID)
    try await waitForStore(store) { store.canEditThread }
    restored.refreshContext()
    restored.open(path)
    try await restored.save()
    guard !restored.pendingSave else { throw T3Error("Retry did not recognize accepted content.") }
    let closingEdit = retriedContents + "Close before debounce expires\n"
    restored.edit(closingEdit)
    restored.closeEditor()
    guard await restored.finishSaving(),
      try await store.readWorkspaceFile(path, at: location).contents == closingEdit
    else {
      throw T3Error("Closing did not finish the latest write.")
    }
    restored.refreshContext()
    let large = folder + "/large.txt"
    try await write(large, String(repeating: "x", count: 1_048_577))
    restored.open(large)
    try await waitForFiles(restored) { !restored.loadingFile && restored.document?.path == large }
    guard restored.document?.truncated == true, restored.document?.canEdit == false else {
      throw T3Error("Truncated file was editable.")
    }
    restored.edit("must not replace a partial file")
    guard restored.document?.isDirty == false else {
      throw T3Error("Truncated preview accepted an edit.")
    }
    let binary = folder + "/binary.bin"
    try await write(binary, "binary\u{0}data")
    restored.open(binary)
    try await waitForFiles(restored) { !restored.loadingFile }
    guard restored.document == nil, !restored.message.isEmpty else {
      throw T3Error("Binary content was offered as editable text.")
    }
    restored.open(path)
    try await waitForFiles(restored) { !restored.loadingFile && restored.document?.path == path }
    guard restored.document?.contents == closingEdit else {
      throw T3Error("Closing lost saved file bytes.")
    }
    var undoneDuringWrite = false
    restored.onChange = {
      if !restored.saving.isEmpty && !undoneDuringWrite {
        undoneDuringWrite = true
        restored.edit(closingEdit)
      }
    }
    restored.edit(closingEdit + "temporary edit to undo")
    try await restored.save()
    restored.onChange = nil
    guard undoneDuringWrite, !restored.pendingSave,
      try await store.readWorkspaceFile(path, at: location).contents == closingEdit
    else {
      throw T3Error("Undo during an in-flight write did not restore the original server content.")
    }
    try await workspacePreviews(store: store, files: restored, location: location, folder: folder)
    restored.open(path)
    try await waitForFiles(restored) { !restored.loadingFile && restored.document?.path == path }
    let alternateRoot = location.root + "/" + folder + "/alternate"
    try await write(folder + "/alternate/.keep", "isolated workspace fixture\n")
    let alternateID = UUID().uuidString
    let alternate = try ThreadSummary(
      .object([
        "id": .string(alternateID), "projectId": .string(projectID),
        "title": .string("Native workspace switch verification"),
        "modelSelection": store.selectedThread?.model ?? .null,
        "worktreePath": .string(alternateRoot), "runtimeMode": .string("approval-required"),
      ]))
    _ = try await connection.call(
      "orchestration.dispatchCommand",
      payload:
        Commands.newThread(
          template: alternate, id: alternateID,
          title: "Native workspace switch verification", inheritWorkspace: true))
    try await waitForStore(store) { store.shell.threads[alternateID] != nil }
    let originalAccess = try store.workspaceFileAccess(at: location)
    let scopedEdit = closingEdit + "Saved while navigating to another workspace\n"
    restored.edit(scopedEdit)
    store.select(alternateID)
    restored.refreshContext()
    try await waitForStore(store) { store.canEditThread && store.selectedID == alternateID }
    guard await restored.finishSaving(),
      try await originalAccess.read(path).contents == scopedEdit,
      let alternateLocation = store.workspaceLocation, alternateLocation.root == alternateRoot
    else {
      throw T3Error("Navigating workspaces lost the pending save or its original root.")
    }
    var missingInOtherWorkspace = false
    do { _ = try await store.readWorkspaceFile(path, at: alternateLocation) } catch {
      missingInOtherWorkspace = (error as? T3Error)?.remoteCode == "ProjectReadFileError"
    }
    guard missingInOtherWorkspace else {
      throw T3Error("A delayed save reached the other workspace.")
    }
    if CommandLine.arguments.contains("--workspace-provider-smoke") {
      _ = try await store.workspaceCall(
        "projects.writeFile", at: alternateLocation,
        fields: [
          "relativePath": .string("observed.txt"), "contents": .string("Before provider change\n"),
        ])
      try await workspaceProvider(
        settings: settings, connection: connection, threadID: alternateID,
        projectID: projectID, sendPrompt: true)
    }
    store.select(threadID)
    try await waitForStore(store) { store.canEditThread && store.selectedID == threadID }
    restored.refreshContext()
    let final = try await connection.call(
      "orchestration.getThreadProjection",
      payload: .object(["threadId": .string(threadID)]))
    guard final["runs"] == original["runs"] else {
      throw T3Error("Workspace edits changed inference state.")
    }
    print(
      "PASS: lazy/ignored folder listing, path search, 500ms autosave, exact UTF-8/CRLF, switch/close flush, disconnected draft recovery, serialized typing and undo during save, captured workspace across navigation, conflict and pending-refresh preservation, mutation-triggered refresh with injected tokens, lost-reply retry, truncated/binary handling, no inference in source thread; fixture \(folder), alternate thread \(alternateID)."
    )
  }

  @MainActor private static func workspacePreviews(
    store: ClientStore, files: WorkspaceFiles, location: WorkspaceLocation, folder: String
  ) async throws {
    let markdownPath = folder + "/previews/readme.md"
    let markdown = [
      "# Native file previews", "", "🦉 Exact Unicode and line endings.", "",
      "- [ ] Verify autosave", "  - [x] Preserve source bytes", "", "1. [ ] Ordered task", "",
      "| Feature | State |", "| --- | --- |", "| Markdown | Preview |", "| CSV and TSV | Table |",
      "",
      "[Open the data](data.csv)", "", "```swift", "let answer = 42", "```", "",
      "[Jump to the ordered task](readme.md:8:4)", "",
    ].joined(separator: "\r\n")
    let csv = "Name,Note\r\n\"🦉, café\",\"First\r\nSecond \"\"quoted\"\"\"\r\n,\r\n"
    let tsv = "Name\tNote\nT3\t\"Multiple\nlines\"\n"
    for (path, contents) in [
      (markdownPath, markdown), (folder + "/previews/data.csv", csv),
      (folder + "/previews/data.tsv", tsv),
    ] {
      _ = try await store.workspaceCall(
        "projects.writeFile", at: location,
        fields: [
          "relativePath": .string(path), "contents": .string(contents),
        ])
    }
    files.open(markdownPath)
    try await waitForFiles(files) { !files.loadingFile && files.document?.path == markdownPath }
    guard let document = files.document, document.contents == markdown, files.canEditDocument else {
      throw T3Error("Markdown preview source was not preserved or editable.")
    }
    let rendered = MarkdownRenderer.render(document.contents, width: 400, taskLinks: true) {
      WorkspaceMarkdown.link($0, filePath: markdownPath, root: location.root)
    }
    let offset = (markdown as NSString).range(of: "[ ] Verify autosave").location
    guard rendered.tasks.count == 3,
      rendered.tasks.contains(where: { $0.sourceOffset == offset && !$0.checked })
    else {
      throw T3Error("Rendered Markdown lost a task or its source position.")
    }
    let changed = WorkspaceMarkdown.settingTask(markdown, offset: offset, checked: true)
    files.edit(changed)
    try await waitForFiles(files) { !files.pendingSave && files.document?.original == changed }
    guard try await store.readWorkspaceFile(markdownPath, at: location).contents == changed,
      let link = WorkspaceMarkdown.link("data.csv", filePath: markdownPath, root: location.root),
      let csvPath = WorkspaceMarkdown.workspacePath(link, root: location.root),
      csvPath == folder + "/previews/data.csv"
    else { throw T3Error("Markdown task autosave or contextual file link failed.") }
    files.open(csvPath)
    try await waitForFiles(files) { !files.loadingFile && files.document?.path == csvPath }
    let table = DelimitedFilePreview(files.document?.contents ?? "", delimiter: 44)
    guard table.rows == [["Name", "Note"], ["🦉, café", "First\r\nSecond \"quoted\""], ["", ""]],
      !table.truncated, try await store.readWorkspaceFile(csvPath, at: location).contents == csv,
      DelimitedFilePreview(tsv, delimiter: 9).rows == [
        ["Name", "Note"], ["T3", "Multiple\nlines"],
      ]
    else { throw T3Error("Table preview changed quoted cells or its original source.") }
    guard
      let sourceURL = WorkspaceMarkdown.link(
        "readme.md:8:4", filePath: csvPath, root: location.root),
      let sourceLink = WorkspaceFileLink(url: sourceURL, root: location.root)
    else { throw T3Error("Source link could not be resolved.") }
    files.open(sourceLink.path, position: sourceLink.position)
    guard files.revealRequest == nil else {
      throw T3Error("Source reveal ran before loading the file.")
    }
    try await waitForFiles(files) { !files.loadingFile && files.document?.path == markdownPath }
    guard let reveal = files.revealRequest, let contents = files.document?.contents,
      reveal.position == FileSourcePosition(line: 8, column: 4),
      reveal.position.range(in: contents).location
        == (contents as NSString).range(of: "[ ] Ordered task").location
    else { throw T3Error("File navigation lost its source location while loading.") }
    let previewFolder = folder + "/previews"
    files.search("readme")
    files.open(previewFolder)
    try await waitForFiles(files) { !files.loadingFile && !files.loadingTree }
    guard files.selectedDirectory == previewFolder, files.document == nil,
      !files.isSearching,
      files.directories[previewFolder]?.contains(where: { $0.path == markdownPath }) == true,
      files.directories[folder]?.contains(where: { $0.path == previewFolder && $0.isDirectory })
        == true
    else {
      throw T3Error(
        "A folder link did not reveal its ancestors and children: directory=\(files.selectedDirectory ?? "none"), message=\(files.message), search=\(files.isSearching), loaded=\(files.directories.keys.sorted())."
      )
    }
    let changingPath = previewFolder + "/changing.txt"
    let changingURL = URL(fileURLWithPath: location.root).appendingPathComponent(changingPath)
    try FileManager.default.createDirectory(at: changingURL, withIntermediateDirectories: false)
    files.open(changingPath)
    try await waitForFiles(files) { !files.loadingFile && !files.loadingTree }
    guard files.selectedDirectory == changingPath else {
      throw T3Error("A folder named like a file was not recognized.")
    }
    try FileManager.default.removeItem(at: changingURL)
    _ = try await store.workspaceCall(
      "projects.writeFile", at: location,
      fields: ["relativePath": .string(changingPath), "contents": .string("Now a text file\n")])
    files.receiveWorkspaceMutation("folder-became-file")
    try await waitForFiles(files) { files.document?.contents == "Now a text file\n" }
    guard files.selectedDirectory == nil, files.canEditDocument else {
      throw T3Error("A workspace mutation did not replace the folder view with the new file.")
    }
    try await workspaceMedia(store: store, files: files, location: location, folder: previewFolder)
    print(
      "PASS: Markdown task source offsets and exact CRLF/Unicode autosave, relative file and source-position navigation after loading, folder reveal and folder-to-file mutation, CSV/TSV quoted table previews with unchanged source; fixtures \(folder)/previews."
    )
  }

  @MainActor private static func workspaceMedia(
    store: ClientStore, files: WorkspaceFiles, location: WorkspaceLocation, folder: String
  ) async throws {
    let root = URL(fileURLWithPath: location.root)
    let image = Data(
      base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aJ1sAAAAASUVORK5CYII="
    )!
    let html =
      "<!doctype html><html><head><link rel=\"stylesheet\" href=\"theme.css\"></head><body><h1>Native HTML preview</h1><img src=\"pixel.png\"><p id=\"script\">Script pending</p><script>document.getElementById('script').textContent='Script executed';</script></body></html>"
    let htmlPath = folder + "/page.html"
    let pdfPath = folder + "/document.pdf"
    let videoPath = folder + "/video.mp4"
    try await previewVideo(at: root.appendingPathComponent(videoPath))
    var mediaBox = CGRect(x: 0, y: 0, width: 320, height: 240)
    guard
      let context = CGContext(
        root.appendingPathComponent(pdfPath) as CFURL, mediaBox: &mediaBox, nil)
    else {
      throw T3Error("Could not create the isolated PDF fixture.")
    }
    context.beginPDFPage(nil)
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 20, y: 20, width: 280, height: 200))
    context.endPDFPage()
    context.closePDF()
    var wave = Data("RIFF".utf8)
    func word(_ value: UInt32, bytes: Int) {
      for offset in 0..<bytes { wave.append(UInt8(truncatingIfNeeded: value >> (offset * 8))) }
    }
    word(36 + 16000, bytes: 4)
    wave.append(Data("WAVEfmt ".utf8))
    word(16, bytes: 4)
    word(1, bytes: 2)
    word(1, bytes: 2)
    word(8000, bytes: 4)
    word(16000, bytes: 4)
    word(2, bytes: 2)
    word(16, bytes: 2)
    wave.append(Data("data".utf8))
    word(16000, bytes: 4)
    wave.append(Data(repeating: 0, count: 16000))
    for (name, bytes) in [
      ("pixel.png", image), ("page.html", Data(html.utf8)),
      ("theme.css", Data("body { color: #257; font: 20px system-ui; }".utf8)),
      ("sound.wav", wave),
    ] { try bytes.write(to: root.appendingPathComponent(folder + "/" + name)) }
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let downloads = FileManager.default.temporaryDirectory.appendingPathComponent(
      "t3-media-download-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: downloads, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: downloads) }
    for (path, kind, expected) in [
      (folder + "/pixel.png", WorkspaceMediaKind.image, image),
      (folder + "/sound.wav", .audio, wave),
      (videoPath, .video, try Data(contentsOf: root.appendingPathComponent(videoPath))),
      (pdfPath, .pdf, try Data(contentsOf: root.appendingPathComponent(pdfPath))),
      (htmlPath, .html, Data(html.utf8)),
    ] {
      files.open(path)
      try await waitForFiles(files) { !files.loadingFile }
      guard let request = files.mediaRequest, request.kind == kind,
        files.canEditDocument == (kind == .html)
      else { throw T3Error("Media source was not recognized: " + path + " · " + files.message) }
      let url: URL
      do { url = try await request.load() } catch {
        throw T3Error(
          "Signing the \(kind.rawValue) preview failed: \((error as? T3Error)?.remoteCode ?? "unknown") · \(error.localizedDescription)"
        )
      }
      let (data, response) = try await session.data(from: url)
      guard (response as? HTTPURLResponse)?.statusCode == 200, data == expected else {
        throw T3Error("The signed media asset did not preserve its source bytes: " + path)
      }
      if kind == .image {
        let destination = downloads.appendingPathComponent("saved.png")
        try await request.save(to: destination)
        guard try Data(contentsOf: destination) == image else {
          throw T3Error("Media download changed its bytes.")
        }
        let original = Data("Existing destination".utf8)
        try original.write(to: destination)
        var limited = false
        do {
          try await AttachmentHTTP.download(url, to: destination, maximumBytes: 1)
        } catch is T3Error { limited = true }
        guard limited, try Data(contentsOf: destination) == original else {
          throw T3Error("A rejected download replaced the existing destination.")
        }
        try await request.save(to: destination)
        guard try Data(contentsOf: destination) == image,
          try FileManager.default.contentsOfDirectory(atPath: downloads.path) == ["saved.png"]
        else { throw T3Error("Media replacement failed or left a staging file.") }
      }
      if kind.playable {
        var range = URLRequest(url: url)
        range.setValue("bytes=0-43", forHTTPHeaderField: "Range")
        let (prefix, response) = try await session.data(for: range)
        guard (response as? HTTPURLResponse)?.statusCode == 206, prefix == expected.prefix(44)
        else {
          throw T3Error("Media streaming did not honor the byte range.")
        }
        let asset = AVURLAsset(url: url)
        let (playable, duration) = try await asset.load(.isPlayable, .duration)
        guard playable, duration.seconds > 0 else {
          throw T3Error("The platform could not decode the streamed media fixture.")
        }
      }
      if kind == .html {
        let style = url.deletingLastPathComponent().appendingPathComponent("theme.css")
        let (css, response) = try await session.data(from: style)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
          String(data: css, encoding: .utf8)?.contains("system-ui") == true
        else { throw T3Error("The workspace HTML preview could not load a sibling stylesheet.") }
        let changed = html.replacingOccurrences(
          of: "Native HTML preview", with: "Saved HTML preview")
        files.edit(changed)
        try await waitForFiles(files) { !files.pendingSave && files.document?.original == changed }
        guard let refreshed = files.mediaRequest, refreshed.key != request.key else {
          throw T3Error("Saving HTML did not refresh the preview revision.")
        }
        let (saved, _) = try await session.data(from: refreshed.load())
        guard saved == Data(changed.utf8) else {
          throw T3Error("The HTML preview still served pre-save content.")
        }
      }
    }
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent(
      "t3-host-preview-" + UUID().uuidString + ".html")
    defer { try? FileManager.default.removeItem(at: outside) }
    try Data(html.utf8).write(to: outside)
    files.open(outside.path)
    try await waitForFiles(files) { !files.loadingFile }
    guard let host = files.mediaRequest, !files.canEditDocument else {
      throw T3Error("An external HTML file was editable or lacked its host preview.")
    }
    let hostURL: URL
    do { hostURL = try await host.load() } catch {
      throw T3Error(
        "Signing the external HTML preview failed: \((error as? T3Error)?.remoteCode ?? "unknown") · \(error.localizedDescription)"
      )
    }
    let (hostData, hostResponse) = try await session.data(from: hostURL)
    guard (hostResponse as? HTTPURLResponse)?.statusCode == 200, hostData == Data(html.utf8) else {
      throw T3Error("The host HTML file could not be previewed through its single-file grant.")
    }
    let directory = folder + "/folder.png"
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent(directory), withIntermediateDirectories: false)
    files.open(directory)
    try await waitForFiles(files) { !files.loadingFile }
    guard files.selectedDirectory == directory, files.mediaRequest == nil else {
      throw T3Error("A folder extension was incorrectly treated as a media file.")
    }
    print(
      "PASS: real PNG/PDF/HTML/audio/video asset bytes, audio/video range streaming and native decoder metadata, HTML sibling assets and autosave revision, read-only host HTML and media-named folder; fixtures \(folder)."
    )
  }

  @MainActor private static func previewVideo(at url: URL) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
      ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
        kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
      ])
    writer.add(input)
    guard writer.startWriting() else { throw T3Error("The video fixture encoder did not start.") }
    writer.startSession(atSourceTime: .zero)
    var buffer: CVPixelBuffer?
    guard
      CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32ARGB, nil, &buffer)
        == kCVReturnSuccess,
      let buffer
    else { throw T3Error("The video fixture buffer could not be allocated.") }
    CVPixelBufferLockBaseAddress(buffer, [])
    if let address = CVPixelBufferGetBaseAddress(buffer) {
      memset(address, 80, CVPixelBufferGetDataSize(buffer))
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    guard input.isReadyForMoreMediaData, adaptor.append(buffer, withPresentationTime: .zero) else {
      writer.cancelWriting()
      throw T3Error("The video fixture frame could not be encoded.")
    }
    writer.endSession(atSourceTime: CMTime(seconds: 1, preferredTimescale: 600))
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else {
      throw T3Error("The video fixture could not be finalized.")
    }
  }

  @MainActor private static func workspaceProvider(
    settings: ConnectionSettings, connection: RPCConnection, threadID: String,
    projectID: String, sendPrompt: Bool
  ) async throws {
    FileHandle.standardOutput.write(Data("Workspace provider thread: \(threadID)\n".utf8))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "t3-file-provider-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ClientStore(draftDirectory: directory.appendingPathComponent("chat"))
    store.connect(settings, selecting: threadID)
    defer { store.disconnect() }
    try await waitForStore(store) { store.canEditThread }
    guard store.selectedThread?.projectID == projectID,
      store.selectedThread?.title == "Native workspace switch verification",
      let root = store.workspaceLocation?.root, root.contains("/native-files-"),
      root.hasSuffix("/alternate")
    else {
      throw T3Error("Provider workspace verification requires its isolated switch-test thread.")
    }
    let files = WorkspaceFiles(store: store, directory: directory.appendingPathComponent("files"))
    files.refreshContext()
    files.open("observed.txt")
    try await waitForFiles(files) { !files.loadingFile && files.document != nil }
    let initialMutation = store.thread?.workspaceMutationToken
    var approved: Set<String> = []
    var unexpectedApproval = false
    let script = #"printf 'NATIVE_AUTOSAVE_REFRESH\n' > observed.txt"#
    let wrappedScript = #"printf 'NATIVE_AUTOSAVE_REFRESH\\n' > observed.txt"#
    let allowed = Set([
      script, #"/bin/zsh -lc ""# + wrappedScript + #"""#,
      #"/bin/bash -lc ""# + wrappedScript + #"""#,
    ])
    func update() {
      files.refreshContext()
      for request in store.thread?.pendingRequests ?? [] where !approved.contains(request.id) {
        guard request.kind == "command", request.canRespond, allowed.contains(request.detail),
          request.options.contains(where: { $0["decision"].string == "accept" })
        else {
          unexpectedApproval = true
          continue
        }
        approved.insert(request.id)
        store.respond(request, decision: "accept")
      }
      files.onChange?()
    }
    store.onChange = { update() }
    defer { store.onChange = nil }
    update()
    if sendPrompt {
      _ = try await connection.call(
        "orchestration.dispatchCommand",
        payload: Commands.message(
          threadID: threadID,
          text:
            "Sandbox verification: use a shell command to replace observed.txt in the current workspace with exactly NATIVE_AUTOSAVE_REFRESH followed by one newline. Do not modify any other file. Then reply NATIVE_AUTOSAVE_REFRESH_DONE.",
          commandID: UUID().uuidString, messageID: UUID().uuidString))
    }
    try await waitForFiles(files, seconds: 90) {
      unexpectedApproval
        || (files.document?.contents == "NATIVE_AUTOSAVE_REFRESH\n"
          && store.execution.activeRunID == nil
          && store.thread?.rows.contains(where: {
            $0.kind == "assistant_message" && !$0.streaming
              && $0.text.contains("NATIVE_AUTOSAVE_REFRESH_DONE")
          }) == true)
    }
    guard !unexpectedApproval else {
      throw T3Error("Workspace test stopped at an unexpected approval request.")
    }
    guard store.thread?.workspaceMutationToken != initialMutation,
      store.thread?.pendingRequests.isEmpty == true
    else {
      throw T3Error("Provider refresh had no settled mutation or left a pending request.")
    }
    print(
      "PASS: a real provider command changed the open file; its settled tool/checkpoint events automatically refreshed the native document. Approved \(approved.count) exact fixture command(s); no active or pending test run remains."
    )
  }

  @MainActor private static func waitForFiles(
    _ files: WorkspaceFiles, seconds: Int = 15, until predicate: @escaping @MainActor () -> Bool
  ) async throws {
    let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    files.onChange = { continuation.yield(()) }
    let timeout = Task {
      try await Task.sleep(for: .seconds(seconds))
      continuation.finish()
    }
    defer {
      files.onChange = nil
      timeout.cancel()
      continuation.finish()
    }
    continuation.yield(())
    for await _ in stream {
      if predicate() { return }
      if let error = files.storageError { throw T3Error(error) }
    }
    throw T3Error("Timed out waiting for workspace files: \(files.message)")
  }

  @MainActor private static func planCard(
    settings: ConnectionSettings, connection: RPCConnection, threadID: String, projectID: String
  ) async throws {
    let original = try await connection.call(
      "orchestration.getThreadProjection", payload: .object(["threadId": .string(threadID)]))
    guard original["thread"]["projectId"].string == projectID,
      original["thread"]["title"].string == "Native plan verification"
    else {
      throw T3Error("Plan card checks require an isolated plan verification thread.")
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "t3-plan-card-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ClientStore(draftDirectory: directory)
    store.connect(settings, selecting: threadID)
    defer { store.disconnect() }
    try await waitForStore(store) { store.canEditThread && store.catalogReady }
    guard let row = store.thread?.rows.first(where: { $0.kind == "proposed_plan" }),
      let location = store.workspaceLocation, let template = store.selectedThread
    else {
      throw T3Error("The stored plan or its workspace is unavailable.")
    }
    let document = PlanDocument(row.text)
    let downloaded = directory.appendingPathComponent(document.filename)
    try await document.save(to: downloaded)
    guard try Data(contentsOf: downloaded) == Data(document.contents.utf8) else {
      throw T3Error("The local Markdown export changed bytes.")
    }
    let path = "plans/native-plan-card-" + UUID().uuidString.lowercased() + ".md"
    let saved = try await store.savePlan(document, at: location, relativePath: " " + path + " ")
    let read = try await connection.call(
      "projects.readFile",
      payload: .object([
        "cwd": .string(location.root), "relativePath": .string(saved),
      ]))
    guard saved == path, !read["truncated"].bool,
      read["contents"].string == document.contents,
      read["byteLength"].int == document.contents.utf8.count
    else {
      throw T3Error("The workspace export changed path or bytes.")
    }
    var rejected = false
    do {
      _ = try await store.savePlan(
        document, at: location, relativePath: "../outside-" + UUID().uuidString + ".md")
    } catch {
      rejected = (error as? T3Error)?.remoteCode == "ProjectWriteFileError"
    }
    guard rejected else { throw T3Error("The server did not reject an outside-workspace save.") }
    let other = WorkspaceLocation(
      environment: "different-environment", thread: template,
      project: .object(["workspaceRoot": .string(location.root)]))!
    rejected = false
    do { _ = try await store.savePlan(document, at: other, relativePath: path) } catch {
      rejected = error.localizedDescription.contains("workspace changed")
    }
    guard rejected else {
      throw T3Error("A save dialog could write after its environment changed.")
    }
    store.retry()
    try await waitForStore(store) { store.canEditThread && store.catalogReady }
    _ = try await store.savePlan(document, at: location, relativePath: saved)
    let repeated = try await connection.call(
      "projects.readFile",
      payload: .object([
        "cwd": .string(location.root), "relativePath": .string(saved),
      ]))
    guard repeated["contents"] == read["contents"] else {
      throw T3Error("Reconnect/retry changed the exported plan.")
    }
    let longPlan =
      "# Card layout\n\n## Summary\n\n"
      + (1...24).map {
        "- Step \($0): " + String(repeating: "Preserve the full plan. ", count: 8)
      }.joined(separator: "\n\n") + "\n\n**Last step marker**\n"
    let collapsed = PlanCardLayout(markdown: longPlan, width: 340, expanded: false)
    let expanded = PlanCardLayout(markdown: longPlan, width: 340, expanded: true)
    guard collapsed.bodyHeight <= 416, expanded.height > collapsed.height,
      !collapsed.rendered.text.string.contains("Last step marker"),
      expanded.rendered.text.string.contains("Last step marker"),
      collapsed.document.contents == expanded.document.contents
    else {
      throw T3Error("Collapsing the card lost export content or failed to bound its layout.")
    }
    let final = try await connection.call(
      "orchestration.getThreadProjection", payload: .object(["threadId": .string(threadID)]))
    guard final["runs"] == original["runs"] else {
      throw T3Error("Export unexpectedly changed inference state.")
    }
    print(
      "PASS: plan card bounded/collapsed and expanded Markdown layout, exact local and workspace exports, rejected path/environment changes, reconnect/retry, no new inference; saved \(saved)."
    )
  }

  @MainActor static func waitForStore(
    _ store: ClientStore, seconds: Int = 25, until predicate: @escaping @MainActor () -> Bool
  ) async throws {
    let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    store.onChange = { continuation.yield(()) }
    let timeout = Task {
      try await Task.sleep(for: .seconds(seconds))
      continuation.finish()
    }
    defer {
      store.onChange = nil
      timeout.cancel()
      continuation.finish()
    }
    continuation.yield(())
    for await _ in stream {
      if predicate() { return }
      if let error = store.error { throw T3Error(error) }
    }
    throw T3Error("Timed out waiting for ClientStore state.")
  }
}
