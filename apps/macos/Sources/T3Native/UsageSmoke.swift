import Foundation
import T3Core

extension ParitySmoke {
  @MainActor static func usage(settings: ConnectionSettings, connection: RPCConnection) async throws
  {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "T3UsageSmoke." + UUID().uuidString
    guard let preferences = UserDefaults(suiteName: suite) else {
      throw T3Error("Could not isolate usage preferences.")
    }
    defer {
      preferences.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
    }
    preferences.set("cost", forKey: "usageMetric")
    preferences.set(1, forKey: "usagePeriod")
    let store = ClientStore(draftDirectory: directory, preferences: preferences)
    let model = UsagePageModel(store: store, preferences: preferences)
    defer {
      store.onChange = nil
      model.synchronize(active: false)
      store.disconnect()
    }
    store.connect(settings)
    try await waitForStore(store) { store.ready && store.catalogReady }
    store.onChange = { model.synchronize(active: true) }
    model.synchronize(active: true)
    try await waitForUsage(model) { !$0.busy && $0.history != nil }
    guard let first = model.history else { throw T3Error("Missing usage history.") }
    let raw = try await connection.call("server.getUsageSummary", payload: first.window.input)
    let expected = try UsageHistory(raw, window: first.window)
    guard first.totals == expected.totals, first.sessions == expected.sessions,
      first.series == expected.series
    else { throw T3Error("Native usage disagrees with the server summary.") }
    print("Usage smoke: live summary and hourly buckets")
    model.select(metric: .tokens)
    guard model.history == first, !model.busy else {
      throw T3Error("Metric switching did not reuse the loaded report.")
    }
    model.select(period: .week)
    model.select(period: .month)
    try await waitForUsage(model) { !$0.busy && $0.history?.window.periods.count == 30 }
    guard model.period == .month, model.history?.window.hourly == false else {
      throw T3Error("An older period replaced the selected report.")
    }
    print("Usage smoke: cached metrics and period cancellation")
    model.select(metric: .limits)
    try await waitForUsage(model) { !$0.busy }
    guard model.limits == store.usageLimits else {
      throw T3Error("Limits did not follow the provider configuration.")
    }
    print("Usage smoke: provider limits")
    let oldSession = store.usageSessionID
    model.select(metric: .cost)
    model.refresh()
    store.disconnect()
    model.synchronize(active: true)
    guard !model.connected, model.history == nil, model.pools.isEmpty else {
      throw T3Error("Disconnected usage remained visible as current.")
    }
    store.connect(settings)
    try await waitForStore(store) { store.ready && store.catalogReady }
    store.onChange = { model.synchronize(active: true) }
    model.synchronize(active: true)
    try await waitForUsage(model) { !$0.busy && $0.history != nil }
    do {
      _ = try await store.usageCall(
        "server.getUsageSummary", payload: first.window.input, session: oldSession)
      throw T3Error("A request from the previous connection was accepted.")
    } catch let error as T3Error where error.message == "Connect to load usage." {}
    let restored = UsagePageModel(store: store, preferences: preferences)
    guard restored.metric == .cost && restored.period == .month else {
      throw T3Error("Usage preferences did not survive a new page.")
    }
    print(
      "Usage smoke passed: live summary agreement, hourly/monthly periods, metric cache, rapid period changes, provider limits, disconnect/reconnect isolation, saved preferences. No inference or credit redemption."
    )
  }

  @MainActor private static func waitForUsage(
    _ model: UsagePageModel, until condition: (UsagePageModel) -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(90)
    while !condition(model) {
      if let error = model.error { throw T3Error(error) }
      guard Date() < deadline else { throw T3Error("Usage page timed out.") }
      try await Task.sleep(for: .milliseconds(50))
    }
    if let error = model.error { throw T3Error(error) }
  }
}
