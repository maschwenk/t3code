import Foundation

public struct TerminalSummary: Equatable, Sendable {
  public let id: String
  public let label: String
  public let status: String
  public let hasRunningSubprocess: Bool
  public init(_ value: JSON) throws {
    id = try value.requiredString("terminalId")
    label = value["label"].string ?? id
    status = try value.requiredString("status")
    hasRunningSubprocess = value["hasRunningSubprocess"].bool
  }
}

/// Metadata is environment-wide. Keep only this thread, without moving tabs on activity updates.
public struct TerminalDirectory: Sendable {
  public let threadID: String
  public private(set) var terminals: [TerminalSummary] = []
  public private(set) var receivedSnapshot = false
  public init(threadID: String) { self.threadID = threadID }

  @discardableResult public mutating func apply(_ event: JSON) throws -> Bool {
    switch try event.requiredString("type") {
    case "snapshot":
      terminals = try event["terminals"].array.filter { $0["threadId"].string == threadID }
        .map(TerminalSummary.init)
        .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
      receivedSnapshot = true
      return true
    case "upsert":
      let value = event["terminal"]
      guard value["threadId"].string == threadID else { return false }
      let terminal = try TerminalSummary(value)
      if let index = terminals.firstIndex(where: { $0.id == terminal.id }) {
        guard terminals[index] != terminal else { return false }
        terminals[index] = terminal
      } else {
        terminals.append(terminal)
      }
      return true
    case "remove":
      guard event["threadId"].string == threadID else { return false }
      let id = try event.requiredString("terminalId")
      let count = terminals.count
      terminals.removeAll { $0.id == id }
      return terminals.count != count
    default: return false
    }
  }
}
