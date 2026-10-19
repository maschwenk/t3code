import Foundation

public struct SplitDiffRow: Equatable, Sendable {
  public let old: DiffLine?
  public let new: DiffLine?
}

public struct SplitDiff: Sendable {
  public let rows: [SplitDiffRow]
  public let limited: Bool

  public init(_ file: DiffFile?, lineLimit: Int = 10_000, characterLimit: Int = 1_000_000) {
    var rows: [SplitDiffRow] = []
    var deletions: [DiffLine] = []
    var additions: [DiffLine] = []
    var characters = 0
    var limited = false
    func flush() {
      for index in 0..<max(deletions.count, additions.count) {
        rows.append(
          SplitDiffRow(
            old: index < deletions.count ? deletions[index] : nil,
            new: index < additions.count ? additions[index] : nil))
      }
      deletions.removeAll(keepingCapacity: true)
      additions.removeAll(keepingCapacity: true)
    }
    for (index, line) in (file?.lines ?? []).enumerated() {
      let both =
        line.kind == .context || line.kind == .hunk || line.kind == .metadata || line.kind == .gap
      let cost = line.text.utf16.count + (both ? (line.oldText ?? line.text).utf16.count : 0) + 64
      guard index < lineLimit, cost <= characterLimit - characters else {
        limited = true
        break
      }
      characters += cost
      switch line.kind {
      case .deletion:
        if !additions.isEmpty { flush() }
        deletions.append(line)
      case .addition: additions.append(line)
      case .metadata where line.text.hasPrefix("\\ No newline at end of file"):
        // This marker belongs to the preceding side; it must not split a replacement block.
        if !additions.isEmpty {
          additions.append(line)
        } else if !deletions.isEmpty {
          deletions.append(line)
        } else {
          rows.append(SplitDiffRow(old: line, new: line))
        }
      default:
        flush()
        rows.append(SplitDiffRow(old: line, new: line))
      }
    }
    flush()
    self.rows = rows
    self.limited = limited
  }
}
