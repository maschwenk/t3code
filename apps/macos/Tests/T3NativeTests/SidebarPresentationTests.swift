import AppKit
import T3Core
import Testing

@testable import T3Native

@Test func sidebarIdentitiesMatchTheElectronUnicodeAndTimeRules() {
  #expect(SidebarProjectIdentity(name: "owner_claude_cathedral").text == "OC")
  #expect(SidebarProjectIdentity(name: " Ｔ３ Code ").text == "T3")
  #expect(SidebarProjectIdentity(name: "").text == "PR")
  #expect(SidebarProjectIdentity(name: "owner_claude_cathedral").color == "rose")
  #expect(SidebarProviderMark.initials("Claude Cathedral") == "CC")
  #expect(SidebarProviderMark.initials("😀account") == "😀A")
  let now = Date(timeIntervalSince1970: 10_000_000)
  #expect(SidebarThreadPresentation.time(now.addingTimeInterval(60), now: now) == "now")
  #expect(SidebarThreadPresentation.time(now.addingTimeInterval(-59), now: now) == "now")
  #expect(SidebarThreadPresentation.time(now.addingTimeInterval(-3600), now: now) == "1h")
  #expect(SidebarThreadPresentation.time(now.addingTimeInterval(-86_400), now: now) == "1d")
}

private func sidebarFixture(settled: Bool = false) throws -> SidebarThreadPresentation {
  var catalog = ProviderCatalog()
  try catalog.apply(
    .object([
      "type": .string("snapshot"),
      "config": .object([
        "providers": .array(
          ["one", "two"].map { id in
            .object([
              "instanceId": .string(id), "displayName": .string("Claude " + id),
              "driver": .string("claudeAgent"),
              "models": .array([
                .object([
                  "slug": .string("fable"), "name": .string("Fable"),
                ])
              ]),
            ])
          })
      ]),
    ]))
  let thread = try ThreadSummary(
    .object([
      "id": .string("t"), "projectId": .string("p"),
      "title": .string("A long task title that must still leave room for the activity status"),
      "branch": .string("max/a-long-branch-with-important-information-at-the-end"),
      "latestUserMessageAt": .string("2026-10-11T12:00:00Z"),
      "updatedAt": .string("2026-10-11T14:00:00Z"),
      "providerInstanceHistory": .array([.string("two"), .string("one"), .string("two")]),
      "modelSelection": .object(["instanceId": .string("two"), "model": .string("fable")]),
      "settledOverride": settled ? .string("settled") : .null,
      "settledAt": settled ? .string("2026-10-11T14:00:00Z") : .null,
    ]))
  return SidebarThreadPresentation(
    thread: thread, project: "owner_claude_cathedral",
    identity: SidebarProjectIdentity(name: "owner_claude_cathedral"),
    directory: SidebarProviderDirectory(catalog), draft: true, enabled: true,
    now: ThreadDates.parse("2026-10-11T15:00:00Z")!)
}

@Test func sidebarHistoryKeepsCurrentAccountLastAndUsesTheCorrectTimeAnchor() throws {
  let active = try sidebarFixture()
  #expect(active.providers.map(\.id) == ["one", "two"])
  #expect(active.providers.first?.initials == nil)
  #expect(active.providers.last?.initials == "CT")
  #expect(active.time == "3h")
  #expect(active.detail.contains("Claude two\nFable"))
  #expect(active.detail.contains("Unsent draft"))
  let settled = try sidebarFixture(settled: true)
  #expect(settled.compact)
  #expect(settled.time == "1h")
}

@MainActor @Test func reusedSidebarCellsKeepCardAndHistoryTextInsideNarrowRows() throws {
  let cell = SidebarThreadCell(frame: NSRect(x: 0, y: 0, width: 220, height: 78))
  let card = try sidebarFixture()
  let history = try sidebarFixture(settled: true)
  func labels(_ view: NSView) -> [NSTextField] {
    view.subviews.flatMap { child in (child as? NSTextField).map { [$0] } ?? labels(child) }
  }
  for value in [card, history, card, history, card] {
    cell.setFrameSize(NSSize(width: value.compact ? 220 : 285, height: value.compact ? 36 : 78))
    cell.configure(value, enabled: true, quickAction: {}, snoozeAction: {})
    cell.layoutSubtreeIfNeeded()
    let title = try #require(labels(cell).first { $0.stringValue == value.thread.title })
    let frame = cell.convert(title.bounds, from: title)
    #expect(frame.minX >= 0 && frame.maxX <= cell.bounds.maxX + 0.5)
    #expect(frame.minY >= 0 && frame.maxY <= cell.bounds.maxY + 0.5)
    #expect(frame.width > 70)
    #expect(labels(cell).filter { $0.stringValue == value.thread.title }.count == 1)
  }
}
