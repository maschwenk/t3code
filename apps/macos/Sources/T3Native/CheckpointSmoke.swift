import AppKit
import T3Core

extension ParitySmoke {
  @MainActor static func checkpointReview(
    connection: RPCConnection, settings: ConnectionSettings, threadID: String, projectID: String
  ) async throws {
    let projection = try await connection.call(
      "orchestration.getThreadProjection", payload: .object(["threadId": .string(threadID)]))
    guard projection["thread"]["projectId"].string == projectID else {
      throw T3Error("Checkpoint review smoke requires a thread in the isolated project.")
    }
    let index = ThreadCheckpoints(projection)
    guard let latest = index.items.first, latest.unavailableReason == nil else {
      throw T3Error(
        "Checkpoint smoke needs an existing completed turn with a ready saved checkpoint.")
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ClientStore(draftDirectory: directory)
    store.connect(settings, selecting: threadID)
    defer { store.disconnect() }
    try await waitForStore(store) { store.canEditThread && store.selectedID == threadID }
    let changes = ReviewChanges(store: store)
    store.onChange = { changes.refreshContext(active: true) }
    defer {
      store.onChange = nil
      changes.refreshContext(active: false)
    }
    changes.refreshContext(active: true)
    changes.selectSource("latest-turn")
    try await waitForCheckpointReview(changes) { !changes.loading && !changes.loadingFile }
    for full in [false, true] {
      changes.selectSource(full ? "full-thread" : "latest-turn")
      try await waitForCheckpointReview(changes) { !changes.loading && !changes.loadingFile }
      let request = try CheckpointDiffRequest(latest, fullThread: full, ignoreWhitespace: false)
      let result = try await connection.call(request.method, payload: request.input)
      let exact = try request.validate(result)
      let files = UnifiedDiff.parse(exact)
      guard
        changes.source?.files
          == files.map(ReviewFile.init).sorted(by: {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
          })
      else {
        throw T3Error("Saved diff file list disagrees with the checkpoint RPC.")
      }
      for file in files {
        changes.selectFile(file.path)
        guard changes.rawPatch == file.rawPatch, changes.patch == file, !changes.loadingFile else {
          throw T3Error("Switching saved-diff files did not reuse the fetched comparison.")
        }
        guard ReviewText.render(changes.patch).text.string.contains(file.lines.last?.text ?? "")
        else {
          throw T3Error("Checkpoint text did not render.")
        }
        let split = SplitReviewText(file)
        let removed = file.lines.first(where: { $0.kind == .deletion })?.text ?? ""
        let added = file.lines.first(where: { $0.kind == .addition })?.text ?? ""
        guard
          split.limited || split.old.string.contains(removed) && split.new.string.contains(added)
        else { throw T3Error("The split checkpoint diff lost changed lines.") }
        if !file.isDeleted && !file.isBinary, let absolutePath = changes.absolutePath,
          let location = store.workspaceLocation
        {
          _ = try await store.readWorkspaceFile(absolutePath, at: location)
        }
      }
    }
    let entries = ConversationTimeline.entries(
      from: store.thread?.rows ?? [], activeRunID: nil,
      checkpoints: store.thread?.checkpoints.items ?? [])
    if !latest.files.isEmpty {
      guard entries.contains(.changes(latest)) else {
        throw T3Error("The checkpoint has no timeline review entry point.")
      }
    }
    changes.openCheckpoint(latest.id, filePath: latest.files.first?.path)
    try await waitForCheckpointReview(changes) { !changes.loading && !changes.loadingFile }
    let previous = changes.patchRevision
    changes.openCheckpoint(latest.id, filePath: latest.files.first?.path)
    guard changes.patchRevision == previous else {
      throw T3Error("Reopening the same checkpoint refetched its patch.")
    }
    changes.compare(baseRef: "", ignoreWhitespace: true)
    try await waitForCheckpointReview(changes) { !changes.loading && !changes.loadingFile }
    changes.openCheckpoint("missing-checkpoint-native-smoke")
    guard changes.error != nil, changes.patch == nil, changes.snapshot == nil else {
      throw T3Error("A removed checkpoint left an obsolete diff visible.")
    }
    changes.openCheckpoint(latest.id)
    try await waitForCheckpointReview(changes) { !changes.loading && !changes.loadingFile }
    // Model a rollback snapshot locally; the actual server history stays unchanged.
    guard case .object(var rolledBack) = projection else { throw T3Error("Invalid projection.") }
    rolledBack["checkpoints"] = .array(
      projection["checkpoints"].array.filter { $0["id"].string != latest.id })
    var state = ThreadState(id: threadID)
    _ = try state.apply(
      .object([
        "kind": .string("snapshot"), "snapshotSequence": .number(1),
        "projection": .object(rolledBack),
      ]))
    store.thread = state
    changes.refreshContext(active: true)
    guard changes.error != nil, changes.patch == nil,
      !changes.checkpoints.contains(where: { $0.id == latest.id })
    else {
      throw T3Error("Rollback did not invalidate the selected checkpoint.")
    }
    store.connect(settings, selecting: threadID)
    try await waitForStore(store) { store.canEditThread && store.selectedID == threadID }
    store.onChange = { changes.refreshContext(active: true) }
    changes.refreshContext(active: true)
    changes.selectSource("latest-turn")
    try await waitForCheckpointReview(changes) { !changes.loading && !changes.loadingFile }
    changes.refresh()
    store.selectedID = nil
    changes.refreshContext(active: true)
    guard changes.checkpoints.isEmpty, changes.patch == nil, changes.snapshot == nil else {
      throw T3Error("Checkpoint review leaked across navigation.")
    }
    let final = try await connection.call(
      "orchestration.getThreadProjection", payload: .object(["threadId": .string(threadID)]))
    guard final["runs"] == projection["runs"], final["checkpoints"] == projection["checkpoints"]
    else {
      throw T3Error("Read-only review changed thread history.")
    }
    print(
      "Checkpoint smoke passed: real latest-turn/full-thread RPCs, exact per-file patches reused on selection, timeline card, whitespace filter, missing checkpoint, local rollback snapshot invalidation, reconnect recovery, navigation isolation, unchanged server history; thread \(threadID), latest turn \(latest.turnCount), changed files \(latest.files.count)."
    )
  }

  @MainActor private static func waitForCheckpointReview(
    _ changes: ReviewChanges, until predicate: @escaping @MainActor () -> Bool
  ) async throws {
    let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    changes.onChange = { continuation.yield(()) }
    let timeout = Task {
      try await Task.sleep(for: .seconds(20))
      continuation.finish()
    }
    defer {
      changes.onChange = nil
      timeout.cancel()
      continuation.finish()
    }
    continuation.yield(())
    for await _ in stream {
      if let error = changes.error ?? changes.fileError { throw T3Error(error) }
      if predicate() { return }
    }
    throw T3Error("Timed out waiting for checkpoint review.")
  }
}
