import AppKit
import Charts
import SwiftUI
import T3Core

@MainActor final class UsagePageController: NSViewController {
  let model: UsagePageModel
  init(store: ClientStore) {
    model = UsagePageModel(store: store)
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func loadView() { view = NSHostingView(rootView: UsagePage(model: model)) }
}

private func usageColor(_ driver: String) -> Color {
  switch driver {
  case "claude", "claudeAgent": Color(red: 0.72, green: 0.43, blue: 0.32)
  case "codex": Color.gray
  case "cursor": Color.purple
  case "grok": Color.blue
  case "opencode": Color.green
  default: Color.orange
  }
}

private struct UsagePage: View {
  @Environment(\.colorScheme) private var colorScheme
  @ObservedObject var model: UsagePageModel
  @State private var breakdownByTime = false
  @State private var selectedModel: UsageBreakdown?
  @State private var redeemAccount: UsageAccount?

  var body: some View {
    VStack(spacing: 0) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 16) {
          breadcrumb
          Spacer(minLength: 12)
          controls
        }
        VStack(alignment: .leading, spacing: 12) {
          breadcrumb
          controls
        }
      }
      .padding(.horizontal, 22).padding(.top, 46).padding(.bottom, 16)
      Divider().opacity(0.4)
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          if !model.connected {
            ContentUnavailableView(
              "Connect to view usage", systemImage: "chart.bar",
              description: Text("Usage comes from your connected T3 environment."))
          } else {
            if let error = model.error {
              message(error, symbol: "exclamationmark.triangle", color: .orange)
            }
            if let notice = model.notice { message(notice, symbol: "info.circle") }
            if model.metric == .limits {
              limits
            } else if let history = model.history {
              historyContent(history)
            } else if model.busy {
              Text("Loading usage…").foregroundStyle(.secondary)
            }
            if !model.busy, model.error != nil { Button("Retry") { model.refresh() } }
          }
        }
        .frame(maxWidth: 1_060, alignment: .leading)
        .padding(24).frame(maxWidth: .infinity)
      }
    }
    .background(Color(white: colorScheme == .dark ? 0.045 : 0.99))
    .sheet(item: $selectedModel) { detail in
      UsageModelDetail(detail: detail) { selectedModel = nil }
    }
    .confirmationDialog(
      "Use a reset credit?",
      isPresented: Binding(
        get: { redeemAccount != nil }, set: { if !$0 { redeemAccount = nil } }),
      titleVisibility: .visible
    ) {
      if let account = redeemAccount {
        Button("Use credit") {
          model.redeem(account)
          redeemAccount = nil
        }
      }
      Button("Cancel", role: .cancel) { redeemAccount = nil }
    } message: {
      Text(
        "This redeems one credit on \(redeemAccount?.name ?? "this account") and clears its current rate-limit windows. It cannot be undone."
      )
    }
  }

  private var breadcrumb: some View {
    HStack(spacing: 10) {
      Button {
        model.onClose?()
      } label: {
        Image(systemName: "chevron.left")
      }
      .buttonStyle(.plain).help("Back to conversation").accessibilityLabel("Back to conversation")
      .keyboardShortcut(.cancelAction)
      Text("Usage").fontWeight(.medium)
      Text("/").foregroundStyle(.tertiary)
      Text(model.connected ? model.limits.environmentLabel : "Disconnected")
        .foregroundStyle(.secondary).lineLimit(1)
    }.font(.system(size: 13))
  }

  private var controls: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 10) {
        metricPicker
        periodPicker
        refreshButton
      }
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          metricPicker
          Spacer()
          refreshButton
        }
        periodPicker
      }
    }.controlSize(.small)
  }
  private var metricPicker: some View {
    Picker(
      "Usage metric", selection: Binding(get: { model.metric }, set: { model.select(metric: $0) })
    ) {
      ForEach(UsageMetric.allCases, id: \.self) { Text($0.title).tag($0) }
    }.pickerStyle(.segmented).labelsHidden().frame(width: 200)
  }
  private var periodPicker: some View {
    Picker(
      "Usage period", selection: Binding(get: { model.period }, set: { model.select(period: $0) })
    ) {
      ForEach(UsagePeriod.allCases, id: \.self) { Text($0.title).tag($0) }
    }.pickerStyle(.segmented).labelsHidden().frame(width: 260).disabled(model.metric == .limits)
  }
  private var refreshButton: some View {
    Button {
      model.refresh()
    } label: {
      Image(systemName: "arrow.clockwise")
    }
    .buttonStyle(.plain).disabled(!model.connected || model.busy)
    .accessibilityLabel("Refresh usage").help(model.busy ? "Refreshing…" : "Refresh usage")
  }

  private var limits: some View {
    VStack(alignment: .leading, spacing: 26) {
      if model.pools.isEmpty && model.limits.notices.isEmpty {
        ContentUnavailableView(
          model.busy ? "Checking account limits…" : "No subscription limits reported",
          systemImage: "gauge.with.dots.needle.33percent",
          description: Text("Accounts appear here when the connected provider reports a quota."))
      }
      ForEach(model.pools) { pool in
        VStack(alignment: .leading, spacing: 12) {
          Label(
            UsageFormat.provider(pool.driver),
            systemImage: pool.driver == "claudeAgent" ? "asterisk" : "circle.hexagongrid"
          )
          .font(.system(size: 14, weight: .medium)).foregroundStyle(usageColor(pool.driver))
          ForEach(pool.windows) { window in
            UsageLimitRow(window: window, driver: pool.driver, now: model.now, busy: model.busy) {
              redeemAccount = $0
            }
          }
        }
      }
      ForEach(model.limits.notices, id: \.self) {
        message($0, symbol: "exclamationmark.triangle", color: .orange)
      }
      ForEach(model.limits.links) { link in
        Link(destination: link.url) { Label(link.label, systemImage: "arrow.up.right.square") }
      }
      if model.busy { Text("Refreshing limits…").font(.caption).foregroundStyle(.secondary) }
      if let checked = model.limits.accounts.compactMap(\.checkedAt).min() {
        Text("Checked \(checked.formatted(date: .abbreviated, time: .shortened))")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder private func historyContent(_ history: UsageHistory) -> some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: .firstTextBaseline) {
        Text(history.totals.display(model.metric)).font(.system(size: 32, weight: .semibold))
          .monospacedDigit()
        Text(model.metric == .cost ? "API-equivalent cost" : "tokens").foregroundStyle(.secondary)
        Spacer()
        Text("\(history.sessions) sessions").foregroundStyle(.secondary)
      }
      if model.metric == .cost {
        Text(
          "API-equivalent cost based on recorded usage. Subscription charges are billed separately."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
        ForEach(history.providers) { provider in
          VStack(alignment: .leading, spacing: 10) {
            HStack {
              Circle().fill(usageColor(provider.provider)).frame(width: 7, height: 7)
              Text(provider.name)
            }
            Text(provider.totals.display(model.metric)).font(.title2).monospacedDigit()
            Text("\(UsageFormat.tokens(provider.totals.records)) responses").font(.caption)
              .foregroundStyle(.secondary)
          }.frame(maxWidth: .infinity, alignment: .leading).padding(16).usageCard()
        }
      }
      if history.totals.records == 0 {
        ContentUnavailableView("No recorded usage in this period", systemImage: "chart.bar")
      } else {
        UsageHistoryChart(history: history, metric: model.metric)
        tokenCategories(history.totals)
        HStack {
          Text("Breakdown").font(.headline)
          Spacer()
          Picker("Breakdown", selection: $breakdownByTime) {
            Text("By model").tag(false)
            Text(history.window.hourly ? "By hour" : "By day").tag(true)
          }.pickerStyle(.segmented).labelsHidden().frame(width: 170)
        }
        LazyVStack(spacing: 0) {
          ForEach(
            breakdownByTime
              ? Array(history.periods.reversed())
              : history.models.sorted {
                $0.totals.value(model.metric) > $1.totals.value(model.metric)
              }
          ) { row in
            Button {
              if !breakdownByTime { selectedModel = row }
            } label: {
              HStack(spacing: 14) {
                if !breakdownByTime {
                  Circle().fill(usageColor(row.provider)).frame(width: 7, height: 7)
                }
                VStack(alignment: .leading, spacing: 4) {
                  Text(breakdownByTime ? history.window.label(row.name) : row.name).lineLimit(1)
                    .foregroundStyle(.primary)
                  if !breakdownByTime {
                    Text(UsageFormat.provider(row.provider)).font(.caption).foregroundStyle(
                      .secondary)
                  }
                }
                Spacer(minLength: 12)
                Text(row.totals.display(model.metric)).monospacedDigit().foregroundStyle(.primary)
                if !breakdownByTime {
                  Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
              }.padding(.vertical, 11).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(breakdownByTime)
            Divider().opacity(0.4)
          }
        }
      }
      if history.totals.unpriced > 0 {
        message(
          "\(UsageFormat.tokens(history.totals.unpriced)) responses have no known price. Their tokens are included; their costs are excluded.",
          symbol: "info.circle")
      }
      if history.pricing != "fresh" {
        message(
          history.pricing == "cached"
            ? "Prices are from the cached rate table."
            : "The price table is unavailable. Only reported costs are included.",
          symbol: "info.circle")
      }
      ForEach(history.notices, id: \.self) {
        message($0, symbol: "exclamationmark.triangle", color: .orange)
      }
      if let readAt = history.readAt {
        Text(
          "\(history.window.timeZone.identifier) · Updated \(readAt.formatted(date: .abbreviated, time: .shortened))\(model.busy ? " · Refreshing…" : "")"
        )
        .font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private func tokenCategories(_ totals: UsageTotals) -> some View {
    let costs = model.metric == .cost
    var categories: [(String, Double)] = [
      ("Input", costs ? totals.inputCost : totals.input),
      ("Cache read", costs ? totals.cacheReadCost : totals.cached),
      ("Cache write", costs ? totals.cacheWriteCost : totals.cacheWrite),
      ("Output", costs ? totals.outputCost : totals.output),
    ]
    let unclassified =
      totals.cost - totals.inputCost - totals.cacheReadCost - totals.cacheWriteCost
      - totals.outputCost
    if costs && unclassified > 0.005 { categories.append(("Unclassified", unclassified)) }
    return LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], alignment: .leading, spacing: 14)
    {
      ForEach(categories, id: \.0) { label, value in
        VStack(alignment: .leading, spacing: 6) {
          Text(label).font(.caption).foregroundStyle(.secondary)
          Text(costs ? UsageFormat.cost(value) : UsageFormat.tokens(value)).monospacedDigit()
        }
      }
    }.padding(16).usageCard()
  }

  private func message(_ text: String, symbol: String, color: Color = .secondary) -> some View {
    Label(text, systemImage: symbol).font(.system(size: 12)).foregroundStyle(color)
      .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
  }
}

private struct UsageLimitRow: View {
  let window: UsagePoolWindow
  let driver: String
  let now: Date
  let busy: Bool
  let redeem: (UsageAccount) -> Void
  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 20) {
        summary.frame(width: 150, alignment: .leading)
        bars.frame(minWidth: CGFloat(min(3, window.columns.count)) * 155)
      }
      VStack(alignment: .leading, spacing: 14) {
        summary
        bars
      }
    }.padding(18).usageCard()
  }
  private var summary: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(window.label).font(.system(size: 13, weight: .medium))
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text("\(window.remaining)%").font(.system(size: 28, weight: .semibold)).monospacedDigit()
        Text("left").foregroundStyle(.secondary).font(.system(size: 12))
        if let pace = window.pace {
          Image(systemName: "gauge.with.dots.needle.33percent").font(.caption).foregroundStyle(
            .secondary
          ).help(pace)
        }
      }
      if window.columns.count > 1, let recovery = window.nextRecovery, recovery > 0 {
        Text("↻ +\(recovery)%").font(.caption).foregroundStyle(.secondary)
          .help(
            window.nextReset.map {
              "Pool restored at " + $0.formatted(date: .abbreviated, time: .shortened)
            } ?? "Next reset")
      }
    }.fixedSize(horizontal: true, vertical: false)
  }
  private var bars: some View {
    LazyVGrid(
      columns: Array(
        repeating: GridItem(.flexible(minimum: 60), spacing: 5), count: min(3, window.columns.count)
      ), spacing: 6
    ) {
      ForEach(window.columns) { member in
        UsageAccountBar(
          member: member, color: usageColor(driver), now: now, showName: window.columns.count > 1,
          busy: busy, redeem: redeem)
      }
    }
  }
}

private struct UsageAccountBar: View {
  let member: UsagePoolWindow.Member
  let color: Color
  let now: Date
  let showName: Bool
  let busy: Bool
  let redeem: (UsageAccount) -> Void
  @State private var open = false
  @State private var showEmail = false
  var body: some View {
    Button {
      open.toggle()
    } label: {
      GeometryReader { geometry in
        ZStack(alignment: .leading) {
          color.opacity(0.1)
          Canvas { context, size in
            let fillWidth = size.width * Double(member.window?.remaining ?? 0) / 100
            context.clip(
              to: Path(
                CGRect(x: fillWidth, y: 0, width: size.width - fillWidth, height: size.height)))
            var path = Path()
            for x in stride(from: -size.height, through: size.width, by: 7) {
              path.move(to: CGPoint(x: x, y: size.height))
              path.addLine(to: CGPoint(x: x + size.height, y: 0))
            }
            context.stroke(path, with: .color(color.opacity(0.3)), lineWidth: 1)
          }
          color.opacity(0.55).frame(
            width: geometry.size.width * Double(member.window?.remaining ?? 0) / 100)
          HStack(spacing: 5) {
            Text(
              (showName ? member.account.name + "  " : "")
                + (member.window.map { "\($0.remaining)%" } ?? "Not reported")
            )
            .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            if let reset = member.window?.resetDescription(at: now) {
              Text("↻ " + reset).font(.system(size: 10)).padding(.horizontal, 5).padding(
                .vertical, 3
              )
              .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 4))
              .foregroundStyle(.white)
            }
          }.font(.system(size: 11, weight: .medium)).padding(.horizontal, 8)
        }.clipShape(RoundedRectangle(cornerRadius: 6))
      }.frame(height: 34)
    }.buttonStyle(.plain).help(description).accessibilityLabel(description)
      .popover(isPresented: $open) {
        VStack(alignment: .leading, spacing: 12) {
          Text(member.account.name).font(.headline)
          if let email = member.account.email {
            Button(showEmail ? email : "Reveal account email") { showEmail.toggle() }.buttonStyle(
              .link)
          }
          if let plan = member.account.plan { Text(plan).foregroundStyle(.secondary) }
          if let source = member.account.source {
            Text("Via " + source).foregroundStyle(.secondary)
          }
          Divider()
          Text(
            member.window.map { "\($0.remaining)% left" }
              ?? "This account has not reported this window.")
          if let reset = member.window?.resetsAt {
            Text("Resets " + reset.formatted(date: .abbreviated, time: .shortened))
          }
          if let checked = member.account.checkedAt {
            Text("Checked " + checked.formatted(date: .abbreviated, time: .shortened))
              .foregroundStyle(.secondary)
          }
          if let credits = member.account.credits, credits > 0 {
            Divider()
            Text("\(credits) reset \(credits == 1 ? "credit" : "credits") banked")
            if let expiry = member.account.creditExpiresAt {
              Text("Next expires " + expiry.formatted(date: .abbreviated, time: .shortened))
                .foregroundStyle(.secondary)
            }
            if member.account.redeemInput != nil {
              Button("Use reset…") {
                open = false
                redeem(member.account)
              }.disabled(busy)
            }
          }
        }.font(.system(size: 12)).padding(18).frame(width: 300, alignment: .leading)
      }
  }
  private var description: String {
    member.account.name + ": "
      + (member.window.map {
        "\($0.label), \($0.remaining)% left"
          + ($0.resetDescription(at: now).map { ", " + $0 } ?? "")
      } ?? "Not reported")
  }
}

private struct UsageHistoryChart: View {
  let history: UsageHistory
  let metric: UsageMetric
  var body: some View {
    Chart(history.series) { point in
      BarMark(x: .value("Period", point.name), y: .value(metric.title, point.totals.value(metric)))
        .foregroundStyle(by: .value("Provider", UsageFormat.provider(point.provider)))
        .accessibilityLabel(
          history.window.label(point.name) + ", " + UsageFormat.provider(point.provider)
        )
        .accessibilityValue(point.totals.display(metric))
    }
    .chartForegroundStyleScale(
      domain: history.providers.map(\.name),
      range: history.providers.map { usageColor($0.provider) }
    )
    .chartXScale(domain: history.window.periods)
    .chartXAxis {
      AxisMarks(
        values: history.window.periods.enumerated().filter {
          $0.offset % max(1, history.window.periods.count / 5) == 0
        }.map(\.element)
      ) { value in
        AxisValueLabel {
          if let text = value.as(String.self) {
            Text(history.window.label(text)).font(.system(size: 9))
          }
        }
      }
    }
    .chartYAxis {
      AxisMarks(position: .leading) { value in
        AxisGridLine().foregroundStyle(.gray.opacity(0.15))
        AxisValueLabel {
          if let number = value.as(Double.self) {
            Text(metric == .cost ? UsageFormat.cost(number) : UsageFormat.tokens(number))
          }
        }
      }
    }
    .frame(height: 220).padding(.vertical, 12)
  }
}

private struct UsageModelDetail: View {
  let detail: UsageBreakdown
  let close: () -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        Text(detail.name).font(.title3)
        Spacer()
        Button("Done", action: close).keyboardShortcut(.cancelAction)
      }
      Text(UsageFormat.provider(detail.provider)).foregroundStyle(.secondary)
      Grid(alignment: .leading, horizontalSpacing: 48, verticalSpacing: 12) {
        row("API-equivalent cost", detail.totals.display(.cost))
        row("Input", UsageFormat.tokens(detail.totals.input))
        row("Cache read", UsageFormat.tokens(detail.totals.cached))
        row("Cache write", UsageFormat.tokens(detail.totals.cacheWrite))
        row("Output", UsageFormat.tokens(detail.totals.output))
        row("Reasoning (included in output)", UsageFormat.tokens(detail.totals.reasoning))
        row("Cache savings", UsageFormat.cost(detail.totals.cacheSavings))
        row("Speed premium", UsageFormat.cost(detail.totals.speedPremium))
        row("Responses without pricing", UsageFormat.tokens(detail.totals.unpriced))
      }
    }.padding(24).frame(minWidth: 460).textSelection(.enabled)
  }
  private func row(_ name: String, _ value: String) -> some View {
    GridRow {
      Text(name).foregroundStyle(.secondary)
      Text(value).monospacedDigit()
    }
  }
}

extension View {
  fileprivate func usageCard() -> some View {
    background(.primary.opacity(0.018), in: RoundedRectangle(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).stroke(.primary.opacity(0.07), lineWidth: 1))
  }
}
