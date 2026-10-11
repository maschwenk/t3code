import Foundation
import T3Core

@MainActor final class ClientStore {
  var shell = ShellState()
  private(set) var sortedThreads: [ThreadSummary] = []
  var thread: ThreadState?
  var selectedID: String?
  var status = "Connect to your T3 server"
  var error: String?
  var ready = false
  var loadingHistory = false
  var sending: Set<String> = []
  var drafts: [String: String] = [:]
  var onChange: (() -> Void)?
  private var connection: RPCConnection?
  private var settings: ConnectionSettings?
  private var lifetime: Task<Void, Never>?
  private var detail: Task<Void, Never>?
  private var notification: Task<Void, Never>?
  private var generation = UUID()
  private var selectionGeneration = UUID()
  private var pending: [String: (text: String, command: String, message: String)] = [:]

  func connect(_ settings: ConnectionSettings) {
    disconnect()
    if self.settings?.endpoint != settings.endpoint {
      shell = ShellState()
      sortedThreads = []
      thread = nil
      selectedID = nil
    }
    self.settings = settings
    let generation = self.generation
    lifetime = Task {
      var attempt = 0
      while !Task.isCancelled && self.generation == generation {
        status = attempt == 0 ? "Connecting…" : "Reconnecting…"
        ready = false
        notify()
        let connection = RPCConnection(settings: settings)
        self.connection = connection
        let started = Date()
        do {
          try await connection.open()
          try Task.checkCancellation()
          let subscription = try await connection.subscribe(
            "orchestration.subscribeShell",
            payload: .object(["requestCompletionMarker": .bool(true)]))
          for try await value in subscription.values {
            guard self.generation == generation else { break }
            try shell.apply(value)
            sortedThreads = shell.threads.values.sorted { $0.updatedAt > $1.updatedAt }
            if shell.synchronized {
              if !ready {
                ready = true
                status = "Connected · \(settings.endpoint.host ?? "T3")"
                error = nil
                if let selectedID, shell.threads[selectedID] != nil {
                  select(selectedID, force: true)
                } else if let first = sortedThreads.first {
                  select(first.id)
                }
              }
            }
            notify()
          }
          throw T3Error("Live connection ended.")
        } catch {
          guard self.generation == generation && !Task.isCancelled else {
            await connection.close()
            return
          }
          ready = false
          detail?.cancel()
          self.error = error.localizedDescription
          await connection.close()
          if (error as? T3Error)?.authentication == true {
            status = "Pair again to reconnect"
            notify()
            return
          }
          if Date().timeIntervalSince(started) > 30 { attempt = 0 }
          attempt += 1
          status = "Connection lost · retrying"
          notify()
          do {
            try await Task.sleep(
              for: .seconds(
                min(300, pow(2, Double(min(attempt, 9)))) * Double.random(in: 0.8...1.2)))
          } catch { return }
        }
      }
    }
  }

  func disconnect() {
    generation = UUID()
    selectionGeneration = UUID()
    lifetime?.cancel()
    lifetime = nil
    detail?.cancel()
    detail = nil
    if let connection { Task { await connection.close() } }
    connection = nil
    ready = false
  }

  func retry() { if let settings { connect(settings) } }

  func select(_ id: String, force: Bool = false) {
    guard id != selectedID || force else { return }
    detail?.cancel()
    selectionGeneration = UUID()
    let selection = selectionGeneration
    let generation = generation
    selectedID = id
    if thread?.id != id { thread = ThreadState(id: id) }
    thread?.markUnsynchronized()
    loadingHistory = false
    error = nil
    notify()
    guard let connection, ready else { return }
    detail = Task {
      do {
        let subscription = try await connection.subscribe(
          "orchestration.subscribeThread",
          payload: .object([
            "threadId": .string(id), "requestCompletionMarker": .bool(true),
            "acceptBoundedSnapshot": .bool(true),
          ]))
        defer { Task { await connection.cancel(subscription.id) } }
        for try await value in subscription.values {
          try Task.checkCancellation()
          guard self.generation == generation && selectionGeneration == selection else { return }
          if try thread?.apply(value) == true {
            select(id, force: true)
            return
          }
          notify()
        }
        guard !Task.isCancelled && selectionGeneration == selection && self.generation == generation
        else { return }
        thread?.markUnsynchronized()
        error = "Conversation updates ended. Reconnect to refresh."
        notify()
      } catch {
        guard !Task.isCancelled && selectionGeneration == selection && self.generation == generation
        else { return }
        thread?.markUnsynchronized()
        self.error = error.localizedDescription
        notify()
      }
    }
  }

  func loadOlder() {
    guard let settings, let thread, let cursor = thread.cursor, thread.hasMore, !loadingHistory
    else { return }
    loadingHistory = true
    let selection = selectionGeneration
    notify()
    Task {
      do {
        let page = try await EnvironmentHTTP.read(
          settings.request(
            "/api/orchestration/threads/\(thread.id)/history",
            query: [URLQueryItem(name: "cursor", value: cursor)]))
        guard selectionGeneration == selection else { return }
        try self.thread?.prependHistory(page)
      } catch {
        guard selectionGeneration == selection else { return }
        self.error = error.localizedDescription
      }
      guard selectionGeneration == selection else { return }
      loadingHistory = false
      notify()
    }
  }

  func send() {
    guard let id = selectedID, let connection, ready, thread?.synchronized == true,
      let text = drafts[id], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !sending.contains(id)
    else { return }
    let command =
      pending[id].flatMap { $0.text == text ? $0 : nil } ?? (
        text: text, command: UUID().uuidString, message: UUID().uuidString
      )
    pending[id] = command
    sending.insert(id)
    error = nil
    notify()
    Task {
      defer {
        sending.remove(id)
        notify()
      }
      do {
        _ = try await connection.call(
          "orchestration.dispatchCommand",
          payload: Commands.message(
            threadID: id, text: text, commandID: command.command, messageID: command.message))
        if drafts[id] == text { drafts[id] = "" }
        pending.removeValue(forKey: id)
      } catch {
        self.error =
          error.localizedDescription
          + " Your draft is preserved. Retrying unchanged text reuses the same command."
      }
    }
  }

  func newThread() {
    guard let connection, ready, let template = selectedID.flatMap({ shell.threads[$0] }) else {
      return
    }
    Task {
      do {
        let id = UUID().uuidString
        _ = try await connection.call(
          "orchestration.dispatchCommand", payload: Commands.newThread(template: template, id: id))
        select(id)
      } catch {
        self.error = error.localizedDescription
        notify()
      }
    }
  }

  func stop() {
    guard let connection, ready, let id = selectedID, let run = shell.threads[id]?.activeRunID
    else { return }
    Task {
      do {
        _ = try await connection.call(
          "orchestration.dispatchCommand",
          payload: .object([
            "type": .string("run.interrupt"), "commandId": .string(UUID().uuidString),
            "threadId": .string(id), "runId": .string(run), "holdQueue": .bool(true),
          ]))
      } catch {
        self.error = error.localizedDescription
        notify()
      }
    }
  }

  private func notify() {
    guard notification == nil else { return }
    notification = Task {
      try? await Task.sleep(for: .milliseconds(33))
      notification = nil
      onChange?()
    }
  }
}
