import AppKit
import T3Core

extension ParitySmoke {
  @MainActor static func reviewChanges(
    connection: RPCConnection, settings: ConnectionSettings, threadID: String, projectID: String
  ) async throws {
    guard settings.endpoint.host == "127.0.0.1" || settings.endpoint.host == "localhost" else {
      throw T3Error("Review smoke requires a local isolated server.")
    }
    let original = try await connection.call(
      "orchestration.getThreadProjection", payload: .object(["threadId": .string(threadID)]))
    guard original["thread"]["projectId"].string == projectID else {
      throw T3Error("Review smoke requires a thread in the isolated project.")
    }
    let drafts = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: drafts) }
    let store = ClientStore(draftDirectory: drafts)
    store.connect(settings, selecting: threadID)
    defer { store.disconnect() }
    try await waitForStore(store) { store.canEditThread && store.selectedID == threadID }
    guard let location = store.workspaceLocation else { throw T3Error("Missing workspace.") }
    let fixtureRoot = Arguments.value("--review-fixture-root") ?? location.root
    let root = URL(fileURLWithPath: fixtureRoot).appendingPathComponent(
      "native-review-" + UUID().uuidString.lowercased(), isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    func write(_ path: String, _ text: String) throws {
      try Data(text.utf8).write(to: root.appendingPathComponent(path))
    }
    func git(_ arguments: [String]) throws {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
      process.arguments = ["-c", "core.fsmonitor=false", "-C", root.path] + arguments
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      try process.run()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        throw T3Error("Review fixture git command failed.")
      }
    }
    try git(["init", "-b", "main"])
    try git(["config", "user.name", "Native Review Smoke"])
    try git(["config", "user.email", "native-review@example.invalid"])
    try git(["config", "core.autocrlf", "false"])
    try git(["config", "core.fsmonitor", "false"])
    try write("changed.txt", "old\r\ncontext\r\n")
    try write("deleted.txt", "removed\n")
    try write("old name.txt", "unchanged renamed contents\n")
    try write("whitespace.txt", "let answer = 42\n")
    let contextBefore = (1...80).map { "context line \($0)" }
    try write("context.txt", contextBefore.joined(separator: "\n") + "\n")
    try Data([0, 1, 2, 3]).write(to: root.appendingPathComponent("binary.bin"))
    try git(["add", "."])
    try git(["-c", "commit.gpgsign=false", "commit", "-m", "Initial review fixture"])
    try git(["checkout", "-b", "feature"])
    try write("branch.txt", "committed on feature\n")
    try git(["add", "branch.txt"])
    try git(["-c", "commit.gpgsign=false", "commit", "-m", "Branch review fixture"])
    try write("changed.txt", "new 日本語 👋\r\ncontext\r\n")
    try FileManager.default.removeItem(at: root.appendingPathComponent("deleted.txt"))
    try git(["mv", "old name.txt", "new name.txt"])
    try write("新 file.txt", "new untracked file without final newline")
    try write("whitespace.txt", "let   answer   =   42\n")
    var contextAfter = contextBefore
    contextAfter[39] = "changed context line 40"
    let contextContents = contextAfter.joined(separator: "\n") + "\n"
    try write("context.txt", contextContents)
    try Data([0, 4, 5, 6]).write(to: root.appendingPathComponent("binary.bin"))
    try write(
      "large.txt",
      String(repeating: "A long added line in the large patch fixture.\n", count: 50_000))

    let reviewID = UUID().uuidString
    let template = try ThreadSummary(
      .object([
        "id": .string(reviewID), "projectId": .string(projectID),
        "title": .string("Native change review verification"),
        "modelSelection": store.selectedThread?.model ?? .null,
        "worktreePath": .string(root.path), "runtimeMode": .string("approval-required"),
      ]))
    _ = try await connection.call(
      "orchestration.dispatchCommand",
      payload: Commands.newThread(
        template: template, id: reviewID, title: template.title, inheritWorkspace: true))
    try await waitForStore(store) { store.shell.threads[reviewID] != nil }
    store.select(reviewID)
    try await waitForStore(store) { store.canEditThread && store.selectedID == reviewID }
    let changes = ReviewChanges(store: store)
    store.onChange = { changes.refreshContext(active: true) }
    defer {
      store.onChange = nil
      changes.refreshContext(active: false)
    }
    changes.refreshContext(active: true)
    reviewProgress("working-tree file list")
    try await waitForChanges(changes) { !changes.loading && !changes.loadingFile }
    let names = Set(changes.source?.files.map(\.path) ?? [])
    guard
      names
        == Set([
          "binary.bin", "changed.txt", "context.txt", "deleted.txt", "large.txt", "new name.txt",
          "whitespace.txt",
          "新 file.txt",
        ]), changes.source?.completeFileList == true
    else {
      throw T3Error("Changed-file list was incomplete: \(names.sorted()).")
    }
    changes.selectFile("changed.txt")
    reviewProgress("Unicode and line numbers")
    try await waitForChanges(changes) { !changes.loadingFile }
    guard
      changes.patch?.lines.contains(where: {
        $0.kind == .addition && $0.text == "new 日本語 👋\r" && $0.newLine == 1
      }) == true
    else { throw T3Error("The real Git patch lost Unicode, CRLF or line numbers.") }
    let display = ReviewText.render(changes.patch)
    guard display.text.string.contains("new 日本語 👋"), !display.limited else {
      throw T3Error("Native diff text did not render the actual patch.")
    }
    let split = SplitReviewView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
    split.setWrapped(true)
    guard !split.render(changes.patch), split.oldText.string.contains("old\r\n"),
      split.newText.string.contains("new 日本語 👋\r\n")
    else { throw T3Error("The split view lost one side of the actual patch.") }
    split.setWrapped(false)
    guard split.oldScroll.hasHorizontalScroller && split.newScroll.hasHorizontalScroller else {
      throw T3Error("The split diff cannot scroll unwrapped lines.")
    }
    reviewProgress("context expansion and concurrent edits")
    changes.selectFile("context.txt")
    try await waitForChanges(changes) { !changes.loadingFile }
    let copied = changes.rawPatch
    changes.expandContext(0)
    try await waitForChanges(changes) { !changes.loadingContext }
    guard changes.hasExpandedContext, changes.rawPatch == copied,
      changes.displayPatch?.lines.contains(where: { $0.text == "context line 20" }) == true
    else {
      throw T3Error("Context expansion did not load surrounding lines or changed the copied patch.")
    }
    changes.collapseContext()
    guard !changes.hasExpandedContext else { throw T3Error("Context could not be collapsed.") }
    changes.loadFile()
    try await waitForChanges(changes) { !changes.loadingFile }
    try write("context.txt", contextContents + "unseen edit outside the patch\n")
    changes.expandContext()
    try await waitForChanges(changes, allowsError: true) { !changes.loadingContext }
    guard changes.contextError != nil, changes.patch != nil, !changes.hasExpandedContext else {
      throw T3Error("An edit during context loading was mixed into an older patch.")
    }
    try write("context.txt", contextContents)
    for (name, check) in [
      ("deleted.txt", { (file: DiffFile) in file.isDeleted }),
      ("new name.txt", { (file: DiffFile) in file.previousPath == "old name.txt" }),
      ("binary.bin", { (file: DiffFile) in file.isBinary }),
      (
        "新 file.txt",
        { (file: DiffFile) in
          file.additions == 1 && file.lines.last?.text == "\\ No newline at end of file"
        }
      ),
    ] {
      changes.selectFile(name)
      try await waitForChanges(changes) { !changes.loadingFile }
      guard let patch = changes.patch, check(patch) else {
        throw T3Error("Incorrect patch for \(name).")
      }
    }
    changes.selectFile("large.txt")
    reviewProgress("large per-file patch")
    try await waitForChanges(changes) { !changes.loadingFile }
    guard changes.file?.additions == 50_000,
      changes.truncated || ReviewText.render(changes.patch).limited,
      SplitReviewText(changes.patch).limited
    else { throw T3Error("Large patches must preserve full stats and expose the display limit.") }
    changes.selectSource("branch-range")
    changes.compare(baseRef: "main", ignoreWhitespace: true)
    reviewProgress("branch comparison and whitespace filtering")
    try await waitForChanges(changes) { !changes.loading && !changes.loadingFile }
    guard changes.source?.files.contains(where: { $0.path == "branch.txt" }) == true,
      changes.source?.files.contains(where: { $0.path == "whitespace.txt" }) == false
    else { throw T3Error("Branch comparison or whitespace filtering failed.") }
    changes.selectFile("context.txt")
    try await waitForChanges(changes) { !changes.loadingFile }
    changes.expandContext()
    try await waitForChanges(changes) { !changes.loadingContext }
    guard changes.displayPatch?.lines.compactMap(\.oldLine) == Array(1...80),
      changes.displayPatch?.lines.compactMap(\.newLine) == Array(1...80)
    else { throw T3Error("Branch context did not preserve both full-file line sequences.") }
    changes.compare(baseRef: "does-not-exist-native-review", ignoreWhitespace: false)
    reviewProgress("invalid base reference")
    try await waitForChanges(changes, allowsError: true) { !changes.loading }
    guard changes.error != nil, changes.patch == nil else {
      throw T3Error("Invalid comparisons kept an obsolete patch.")
    }
    changes.compare(baseRef: "main", ignoreWhitespace: false)
    reviewProgress("retry and selection cancellation")
    try await waitForChanges(changes) { !changes.loading && !changes.loadingFile }
    changes.selectFile("large.txt")
    changes.selectFile("changed.txt")
    try await waitForChanges(changes) { !changes.loadingFile }
    guard changes.patch?.path == "changed.txt" else {
      throw T3Error("A late file read replaced selection.")
    }
    changes.refreshContext(active: false)
    try write("changed.txt", "after reopening\n")
    changes.refreshContext(active: true)
    reviewProgress("reopen refreshed patch")
    try await waitForChanges(changes) { !changes.loading && !changes.loadingFile }
    guard changes.rawPatch.contains("+after reopening") else {
      throw T3Error("Reopening retained a stale patch.")
    }
    changes.selectFile("large.txt")
    store.selectedID = nil
    changes.refreshContext(active: true)
    guard changes.location == nil, changes.patch == nil, changes.snapshot == nil else {
      throw T3Error("Navigating away retained the previous workspace's review.")
    }
    let final = try await connection.call(
      "orchestration.getThreadProjection", payload: .object(["threadId": .string(reviewID)]))
    guard final["runs"].array.isEmpty else {
      throw T3Error("Review smoke unexpectedly started inference.")
    }
    print(
      "Review smoke passed: working-tree/branch comparison, complete stats, per-file patches, unified/split rendering, Unicode/CRLF, rename/delete/binary/untracked files, whitespace filter, large patch bounds, invalid-ref recovery, stale selection cancellation, hide/reopen refresh, navigation isolation, no inference. Fixture \(root.path), thread \(reviewID)."
    )
  }

  @MainActor private static func waitForChanges(
    _ changes: ReviewChanges, allowsError: Bool = false,
    until predicate: @escaping @MainActor () -> Bool
  ) async throws {
    let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    changes.onChange = { continuation.yield(()) }
    let timeout = Task {
      try await Task.sleep(for: .seconds(25))
      continuation.finish()
    }
    defer {
      changes.onChange = nil
      timeout.cancel()
      continuation.finish()
    }
    continuation.yield(())
    for await _ in stream {
      if !allowsError, let error = changes.error ?? changes.fileError ?? changes.contextError {
        throw T3Error(error)
      }
      if predicate() { return }
    }
    throw T3Error("Timed out waiting for Changes.")
  }
  private static func reviewProgress(_ value: String) {
    FileHandle.standardError.write(Data("Review smoke: \(value)\n".utf8))
  }
}
