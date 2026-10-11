import Combine
import Foundation
import T3Core

@MainActor final class UsagePageModel: ObservableObject {
  @Published private(set) var metric: UsageMetric
  @Published private(set) var period: UsagePeriod
  @Published private(set) var limits = UsageLimitsSnapshot()
  @Published private(set) var pools: [UsagePool] = []
  @Published private(set) var history: UsageHistory?
  @Published private(set) var busy = false
  @Published private(set) var connected = false
  @Published private(set) var error: String?
  @Published private(set) var notice: String?
  @Published private(set) var now = Date()
  var onClose: (() -> Void)?
  private let store: ClientStore
  private let preferences: UserDefaults
  private var active = false
  private var session: UUID?
  private var request = UUID()
  private var task: Task<Void, Never>?
  private var cache: [UsagePeriod: UsageHistory] = [:]
  private var limitsRefreshedAt: Date?

  init(store: ClientStore, preferences: UserDefaults = .standard) {
    self.store = store
    self.preferences = preferences
    metric = UsageMetric(rawValue: preferences.string(forKey: "usageMetric") ?? "") ?? .limits
    period = UsagePeriod(rawValue: preferences.integer(forKey: "usagePeriod")) ?? .month
  }

  func synchronize(active: Bool) {
    let reopened = active && !self.active
    self.active = active
    let ready = store.ready && store.catalogReady
    let changed = session != store.usageSessionID || connected != ready
    if changed {
      cancel()
      session = store.usageSessionID
      connected = ready
      cache = [:]
      history = nil
      error = nil
      notice = nil
      limitsRefreshedAt = nil
      limits = ready ? store.usageLimits : UsageLimitsSnapshot()
      pools = limits.pools(at: now)
    }
    if ready && limits != store.usageLimits {
      limits = store.usageLimits
      now = Date()
      pools = limits.pools(at: now)
    }
    if !active {
      cancel()
      return
    }
    if ready && (changed || reopened) { load(automatic: true) }
  }

  func select(metric: UsageMetric) {
    guard metric != self.metric else { return }
    cancel()
    self.metric = metric
    error = nil
    preferences.set(metric.rawValue, forKey: "usageMetric")
    load(automatic: true)
  }

  func select(period: UsagePeriod) {
    guard period != self.period else { return }
    cancel()
    self.period = period
    history = cache[period]
    error = nil
    preferences.set(period.rawValue, forKey: "usagePeriod")
    load(automatic: true)
  }

  func refresh() { load(automatic: false) }

  private func cancel() {
    request = UUID()
    task?.cancel()
    task = nil
    busy = false
  }

  private func load(automatic: Bool) {
    guard active, connected, !busy, let session else { return }
    now = Date()
    pools = limits.pools(at: now)
    if metric == .limits, automatic, let date = limitsRefreshedAt, now.timeIntervalSince(date) < 300
    {
      return
    }
    if metric != .limits, automatic, let cached = cache[period],
      let date = cached.readAt, now.timeIntervalSince(date) < 300
    {
      history = cached
      return
    }
    let request = UUID()
    self.request = request
    let metric = metric
    let period = period
    let window = period.window(at: now)
    busy = true
    error = nil
    notice = nil
    task = Task { [weak self, store] in
      guard let self else { return }
      defer {
        if self.request == request {
          busy = false
          task = nil
        }
      }
      do {
        if metric == .limits {
          _ = try await store.usageCall("server.refreshProviders", session: session)
          guard self.request == request else { return }
          limitsRefreshedAt = Date()
          limits = store.usageLimits
          pools = limits.pools(at: now)
        } else {
          if !automatic {
            do { _ = try await store.usageCall("server.refreshUsageRates", session: session) } catch
            {
              try Task.checkCancellation()
              guard self.request == request else { return }
              notice = "Could not refresh prices. Showing the server’s available rates."
            }
          }
          let value = try await store.usageCall(
            "server.getUsageSummary", payload: window.input, session: session)
          let parsed = try await Task.detached { try UsageHistory(value, window: window) }.value
          try Task.checkCancellation()
          guard self.request == request else { return }
          cache[period] = parsed
          history = parsed
        }
      } catch {
        guard !Task.isCancelled, self.request == request else { return }
        self.error = error.localizedDescription
      }
    }
  }

  func redeem(_ account: UsageAccount) {
    guard active, connected, !busy, let session, let input = account.redeemInput,
      limits.accounts.contains(where: {
        $0.id == account.id && $0.redeemInput == input && ($0.credits ?? 0) > 0
      })
    else { return }
    let request = UUID()
    self.request = request
    busy = true
    error = nil
    task = Task { [weak self, store] in
      guard let self else { return }
      defer {
        if self.request == request {
          busy = false
          task = nil
        }
      }
      do {
        let result = try await store.usageCall(
          "provider.consumeResetCredit", payload: input, session: session)
        guard self.request == request else { return }
        switch result["outcome"].string {
        case "reset": notice = "Reset applied."
        case "alreadyRedeemed": notice = "That credit was already redeemed."
        case "noCredit": notice = "No reset credit left."
        case "nothingToReset": notice = "Nothing to reset right now."
        default: notice = "The provider returned an unknown reset outcome. Refresh to check usage."
        }
        if let warning = result["warning"].string { notice = warning }
        // Config events publish the new limits; do not retry the redemption on an uncertain result.
        limitsRefreshedAt = nil
      } catch {
        guard !Task.isCancelled, self.request == request else { return }
        self.error = error.localizedDescription
      }
    }
  }
}
