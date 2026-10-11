import Foundation

public enum ConversationEntry: Sendable, Equatable, Identifiable {
  case item(TimelineRow)
  case work(TimelineWorkGroup)

  public var id: String {
    switch self {
    case .item(let row): row.id
    case .work(let group): group.id
    }
  }

  public var item: TimelineRow? {
    if case .item(let row) = self { row } else { nil }
  }
}

public struct TimelineWorkGroup: Sendable, Equatable, Identifiable {
  public let id: String
  public let entries: [TimelineRow]
  public let expanded: Bool
  public let active: Bool
  public let summary: String

  fileprivate init(entries: [TimelineRow], expanded: Bool, active: Bool) {
    self.entries = entries
    self.expanded = expanded
    self.active = active
    id = "work:" + entries[0].id
    let latest = entries.last(where: { $0.streaming }) ?? entries[entries.count - 1]
    if active || entries.count == 1 {
      let inProgress = active && latest.streaming
      let completed = latest.item["status"].string == "completed"
      let label: String
      switch latest.kind {
      case "reasoning": label = inProgress ? "Thinking" : "Thought"
      case "command_execution":
        let command =
          latest.item["input"].string?.split(separator: "\n").first.map(String.init) ?? "command"
        let verb = inProgress ? "Running" : completed ? "Ran" : "Command"
        label = "\(verb) \(command)"
      case "file_change":
        label =
          (inProgress ? "Editing " : completed ? "Edited " : "File change: ")
          + (latest.item["fileName"].string ?? "file")
      case "file_search":
        label = inProgress ? "Searching files" : completed ? "Searched files" : "File search"
      case "web_search":
        label = inProgress ? "Searching the web" : completed ? "Searched the web" : "Web search"
      default: label = (inProgress ? "Using " : completed ? "Used " : "Tool: ") + latest.title
      }
      summary =
        String(label.prefix(180)) + (entries.count > 1 ? " · \(entries.count) activities" : "")
    } else {
      let categories: [(String, String)] = [
        ("command_execution", "command"), ("file_change", "file change"),
        ("file_search", "file search"), ("web_search", "web search"),
        ("dynamic_tool", "tool call"), ("reasoning", "thought"),
      ]
      var counts: [String: Int] = [:]
      for row in entries { counts[row.kind, default: 0] += 1 }
      summary = categories.compactMap { kind, name in
        guard let count = counts[kind] else { return nil }
        return "\(count) \(name)"
          + (count == 1 ? "" : kind == "file_search" || kind == "web_search" ? "es" : "s")
      }.joined(separator: " · ")
    }
  }
}

public enum ConversationTimeline {
  public static func entries(
    from rows: [TimelineRow], activeRunID: String?, expandedItemIDs: Set<String> = []
  ) -> [ConversationEntry] {
    var result: [ConversationEntry] = []
    var work: [TimelineRow] = []
    func flush(trailing: Bool) {
      guard let first = work.first else { return }
      let isCurrentRun =
        !first.inherited && activeRunID != nil && first.item["runId"].string == activeRunID
      let group = TimelineWorkGroup(
        entries: work, expanded: work.contains { expandedItemIDs.contains($0.id) },
        active: isCurrentRun && (trailing || work.contains(where: \.streaming)))
      result.append(.work(group))
      if group.expanded { result.append(contentsOf: work.map(ConversationEntry.item)) }
      work.removeAll(keepingCapacity: true)
    }
    for row in rows {
      // Empty checkpoints do not interrupt otherwise contiguous provider work.
      if row.kind == "checkpoint" && row.item["files"].array.isEmpty { continue }
      if row.canCollapseWork {
        if let first = work.first, !first.sharesWorkContext(with: row) { flush(trailing: false) }
        work.append(row)
      } else {
        flush(trailing: false)
        result.append(.item(row))
      }
    }
    flush(trailing: true)
    return result
  }
}

extension TimelineRow {
  public var failed: Bool {
    item["status"].string == "failed" || item["outputIndicatesFailure"].bool
      || (kind == "command_execution" && item["exitCode"].int.map { $0 != 0 } == true)
      || (kind == "dynamic_tool" && item["output"]["isError"].bool)
  }

  fileprivate var canCollapseWork: Bool {
    ["reasoning", "command_execution", "file_change", "file_search", "web_search", "dynamic_tool"]
      .contains(kind)
      && !failed && !["cancelled", "declined", "interrupted"].contains(item["status"].string ?? "")
      && item["toolNonExecutionKind"].string == nil
  }

  fileprivate func sharesWorkContext(with other: TimelineRow) -> Bool {
    sourceID == other.sourceID && inherited == other.inherited
      && ["runId", "nodeId", "providerThreadId", "providerTurnId", "parentItemId"].allSatisfy {
        item[$0] == other.item[$0]
      }
  }
}
