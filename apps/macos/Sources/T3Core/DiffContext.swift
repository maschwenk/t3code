import Foundation

public struct DiffContext: Sendable {
  public struct Gap: Sendable {
    public let id: Int
    public let count: Int
    fileprivate let oldStart: Int
    fileprivate let newStart: Int
    fileprivate let before: Bool
    fileprivate let after: Bool
  }
  private enum Part: Sendable {
    case line(DiffLine)
    case gap(Gap)
  }
  private let original: DiffFile
  private let old: ContextLines
  private let new: ContextLines
  private let parts: [Part]
  public let gaps: [Gap]

  public init(_ file: DiffFile, oldContents: String, newContents: String, ignoreWhitespace: Bool)
    throws
  {
    guard !file.incomplete, !file.isBinary else {
      throw T3Error("Refresh this file before expanding its context.")
    }
    let old = try ContextLines(oldContents)
    let new = try ContextLines(newContents)
    var parts: [Part] = []
    var gaps: [Gap] = []
    var oldCursor = 0
    var newCursor = 0
    var expected: (old: Int, new: Int)?
    var hunkCount = 0
    func same(_ a: ArraySlice<UInt8>, _ b: ArraySlice<UInt8>, whitespace: Bool) -> Bool {
      if a.elementsEqual(b) { return true }
      guard whitespace else { return false }
      func significant(_ byte: UInt8) -> Bool { byte != 32 && !(9...13).contains(byte) }
      return a.lazy.filter(significant).elementsEqual(b.lazy.filter(significant))
    }
    func finishHunk() throws {
      if let expected, oldCursor != expected.old || newCursor != expected.new { throw Self.changed }
    }
    func appendGap(toOld: Int, toNew: Int, after: Bool) throws {
      let count = toOld - oldCursor
      guard count >= 0, count == toNew - newCursor,
        toOld <= old.count, toNew <= new.count
      else { throw Self.changed }
      for offset in 0..<count {
        guard
          same(
            old.line(oldCursor + offset), new.line(newCursor + offset), whitespace: ignoreWhitespace
          ),
          old.terminated(oldCursor + offset) == new.terminated(newCursor + offset)
        else { throw Self.changed }
      }
      if count > 0 {
        let gap = Gap(
          id: hunkCount, count: count, oldStart: oldCursor, newStart: newCursor,
          before: hunkCount == 0, after: after)
        parts.append(.gap(gap))
        gaps.append(gap)
      }
      oldCursor = toOld
      newCursor = toNew
    }
    for (index, line) in file.lines.enumerated() {
      if line.kind == .hunk {
        try finishHunk()
        guard let hunk = ContextHunk(line.text) else { throw Self.changed }
        try appendGap(toOld: hunk.oldOffset, toNew: hunk.newOffset, after: false)
        expected = (hunk.oldOffset + hunk.oldCount, hunk.newOffset + hunk.newCount)
        hunkCount += 1
      }
      var displayed = line
      let patchBytes = Array(line.text.utf8)[...]
      let hasMarker =
        index + 1 < file.lines.count
        && file.lines[index + 1].kind == .metadata
        && file.lines[index + 1].text.hasPrefix("\\ No newline at end of file")
      if let number = line.oldLine {
        guard number == oldCursor + 1, oldCursor < old.count,
          same(
            old.line(oldCursor), patchBytes, whitespace: line.kind == .context && ignoreWhitespace),
          old.terminated(oldCursor) != hasMarker
        else { throw Self.changed }
        if line.kind == .context { displayed.oldText = old.text(oldCursor) }
        oldCursor += 1
      }
      if let number = line.newLine {
        guard number == newCursor + 1, newCursor < new.count,
          same(
            new.line(newCursor), patchBytes, whitespace: line.kind == .context && ignoreWhitespace),
          new.terminated(newCursor) != hasMarker
        else { throw Self.changed }
        if line.kind == .context {
          displayed = DiffLine(
            kind: .context, text: new.text(newCursor), oldLine: line.oldLine,
            newLine: line.newLine, oldText: displayed.oldText)
        }
        newCursor += 1
      }
      parts.append(.line(displayed))
    }
    try finishHunk()
    try appendGap(toOld: old.count, toNew: new.count, after: true)
    original = file
    self.old = old
    self.new = new
    self.parts = parts
    self.gaps = gaps
  }

  public func render(expanded: [Int: Int]) -> (file: DiffFile, limited: Bool) {
    var file = original
    file.lines = []
    var characters = 0
    var limited = false
    func append(_ line: DiffLine) -> Bool {
      let cost = line.text.utf16.count + (line.oldText?.utf16.count ?? line.text.utf16.count) + 64
      guard file.lines.count < 10_000, cost <= 1_000_000 - characters else {
        limited = true
        return false
      }
      characters += cost
      file.lines.append(line)
      return true
    }
    func context(_ gap: Gap, _ range: Range<Int>) -> Bool {
      for offset in range {
        let oldIndex = gap.oldStart + offset
        let newIndex = gap.newStart + offset
        let line = DiffLine(
          kind: .context, text: new.text(newIndex), oldLine: oldIndex + 1,
          newLine: newIndex + 1, oldText: old.text(oldIndex))
        if !append(line) { return false }
      }
      return true
    }
    for part in parts {
      switch part {
      case .line(let line): if !append(line) { return (file, limited) }
      case .gap(let gap):
        let count = max(0, min(gap.count, expanded[gap.id] ?? 0))
        let leading = gap.after ? count : gap.before ? 0 : (count + 1) / 2
        let trailing = count - leading
        if !context(gap, 0..<leading) { return (file, limited) }
        if count < gap.count,
          !append(Self.gapLine(gap.id, "Show more context · \(gap.count - count) unchanged lines"))
        {
          return (file, limited)
        }
        if !context(gap, (gap.count - trailing)..<gap.count) { return (file, limited) }
      }
    }
    return (file, limited)
  }

  /// Hunk offsets reveal interior gaps before full contents are fetched. The tail is loaded on demand.
  public static func preview(_ file: DiffFile) -> DiffFile {
    var result = file
    result.lines = []
    var oldEnd = 0
    var newEnd = 0
    var id = 0
    for line in file.lines {
      if line.kind == .hunk, let hunk = ContextHunk(line.text) {
        let count = hunk.oldOffset - oldEnd
        if count > 0, count == hunk.newOffset - newEnd {
          result.lines.append(gapLine(id, "Show more context · \(count) unchanged lines"))
        }
        oldEnd = hunk.oldOffset + hunk.oldCount
        newEnd = hunk.newOffset + hunk.newCount
        id += 1
      }
      result.lines.append(line)
    }
    result.lines.append(gapLine(id, "Show remaining context"))
    return result
  }

  private static func gapLine(_ id: Int, _ title: String) -> DiffLine {
    DiffLine(kind: .gap, text: title, oldLine: nil, newLine: nil, contextID: id)
  }
  private static var changed: T3Error {
    T3Error(
      "The file changed since this patch was loaded. Refresh Changes before expanding context.")
  }
}

private struct ContextLines: Sendable {
  let bytes: [UInt8]
  let starts: [Int]
  var count: Int { starts.count }
  init(_ text: String) throws {
    guard text.utf8.count <= 1_000_000 else {
      throw T3Error("This file exceeds the 1 MB context limit.")
    }
    bytes = Array(text.utf8)
    var starts: [Int] = bytes.isEmpty ? [] : [0]
    for index in bytes.indices where bytes[index] == 10 && index + 1 < bytes.count {
      starts.append(index + 1)
    }
    self.starts = starts
  }
  private func end(_ index: Int) -> Int { index + 1 < count ? starts[index + 1] : bytes.count }
  func terminated(_ index: Int) -> Bool { bytes[end(index) - 1] == 10 }
  func line(_ index: Int) -> ArraySlice<UInt8> {
    bytes[starts[index]..<(end(index) - (terminated(index) ? 1 : 0))]
  }
  func text(_ index: Int) -> String { String(decoding: line(index), as: UTF8.self) }
}

private struct ContextHunk {
  let oldOffset: Int
  let oldCount: Int
  let newOffset: Int
  let newCount: Int
  private static let pattern = try! NSRegularExpression(
    pattern: "^@@ -([0-9]+)(?:,([0-9]+))? \\+([0-9]+)(?:,([0-9]+))? @@")
  init?(_ line: String) {
    let text = line as NSString
    guard
      let match = Self.pattern.firstMatch(
        in: line, range: NSRange(location: 0, length: text.length))
    else { return nil }
    func number(_ index: Int) -> Int? {
      let range = match.range(at: index)
      return range.location == NSNotFound ? 1 : Int(text.substring(with: range))
    }
    guard let old = number(1), let oldCount = number(2), let new = number(3),
      let newCount = number(4),
      old < Int.max - oldCount, new < Int.max - newCount,
      oldCount == 0 || old > 0, newCount == 0 || new > 0
    else { return nil }
    oldOffset = old - (oldCount == 0 ? 0 : 1)
    self.oldCount = oldCount
    newOffset = new - (newCount == 0 ? 0 : 1)
    self.newCount = newCount
  }
}
