import Foundation
import T3Core

@MainActor enum ProjectSmoke {
  static func run(settings: ConnectionSettings, root: String) async throws {
    guard ["localhost", "127.0.0.1"].contains(settings.endpoint.host),
      root.hasPrefix("/tmp/t3-native-evidence/")
        || root.hasPrefix("/private/tmp/t3-native-evidence/")
    else { throw T3Error("Project smoke requires a local server and an isolated evidence folder.") }
    let directory = URL(fileURLWithPath: root).appendingPathComponent(
      "project-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let preferences = UserDefaults(suiteName: "t3-project-smoke-" + UUID().uuidString)!
    let store = ClientStore(
      draftDirectory: directory.appendingPathComponent("drafts"), preferences: preferences)
    store.connect(settings)
    defer { store.disconnect() }
    try await ParitySmoke.waitForStore(store) { store.ready && store.catalogReady }
    let session = store.projectSessionID
    let browsed = try await store.browseProjectFolders(directory.path, session: session)
    let canonicalRoot = try browsed.requiredString("parentPath")
    let project = try await store.openProject(canonicalRoot, session: session)
    let duplicate = try await store.openProject(canonicalRoot, session: session)
    guard project["id"] == duplicate["id"] else {
      throw T3Error("Opening a folder duplicated its project.")
    }
    store.selectedID = nil
    store.showArchives(true)
    store.newThread(project: project)
    store.newThread(project: project)
    try await ParitySmoke.waitForStore(store) { !store.creatingThread && store.canEditThread }
    guard let first = store.selectedThread, !store.showingArchives,
      first.projectID == project["id"].string,
      first.worktreePath == nil,
      first.runtimeMode == store.catalog.defaultRuntimeMode(projectID: first.projectID),
      store.shell.threads.values.filter({ $0.projectID == first.projectID }).count == 1
    else { throw T3Error("New thread without a template or duplicate-click protection failed.") }
    store.drafts[first.id] = "Preserve this draft"
    store.newThread(projectID: first.projectID)
    try await ParitySmoke.waitForStore(store) {
      !store.creatingThread && store.selectedID != first.id && store.canEditThread
    }
    guard store.selectedThread?.model == first.model,
      store.drafts[first.id] == "Preserve this draft"
    else {
      throw T3Error("New thread did not preserve the previous model and draft.")
    }
    let second = store.selectedID
    store.newThread(projectID: first.projectID)
    store.select(first.id)
    try await ParitySmoke.waitForStore(store) {
      !store.creatingThread
        && store.shell.threads.values.filter({ $0.projectID == first.projectID }).count == 3
    }
    guard store.selectedID == first.id,
      store.shell.threads.values.filter({ $0.projectID == first.projectID }).count == 3
    else {
      throw T3Error(
        "A delayed create changed the user's selection or created the wrong number of threads.")
    }
    guard let second else { throw T3Error("Missing second thread.") }
    store.select(second)
    guard let managedRoot = store.catalog.newProjectsRoot,
      managedRoot.contains("/t3code-native-macos/.t3/")
    else { throw T3Error("Managed project smoke requires the isolated server's .t3 folder.") }
    let created = try await store.createProject(
      "Native project check " + UUID().uuidString, session: session)
    guard let createdRoot = created.project["workspaceRoot"].string,
      createdRoot.hasPrefix(managedRoot + "/"),
      FileManager.default.fileExists(atPath: createdRoot + "/README.md")
    else { throw T3Error("New project was not created in the server's configured folder.") }
    if store.catalog.scratchWorkspaceRoot != nil {
      store.selectedID = nil
      store.newThread()
      try await ParitySmoke.waitForStore(store) { !store.creatingThread && store.canEditThread }
      guard store.workspaceLocation?.root == store.catalog.scratchWorkspaceRoot else {
        throw T3Error("New thread without a project did not use Scratch.")
      }
      print("PASS: new thread without a project uses Scratch.")
    } else {
      print("Scratch is unavailable on this server; the UI opens the project picker instead.")
    }
    store.disconnect()
    do {
      _ = try await store.browseProjectFolders(canonicalRoot, session: session)
      throw T3Error("An old project picker used a disconnected session.")
    } catch let error as T3Error where error.message.contains("connection changed") {}
    print(
      "PASS: server folder browsing, duplicate project reuse, first thread without a template, duplicate-click guard, model and draft preservation, navigation during create, managed project creation, and disconnected picker rejection."
    )
    print("Project fixture: \(project["id"].string ?? "missing") at \(canonicalRoot)")
  }
}
