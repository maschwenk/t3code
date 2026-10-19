import Foundation
import Testing

@testable import T3Native

@Test func browserDownloadsPreserveExistingFilesUntilCompleteAndOnCancellation() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let target = directory.appendingPathComponent("report.txt")
  try Data("original".utf8).write(to: target)
  let cancelled = try BrowserDownloadFile(destination: target)
  try Data("incomplete".utf8).write(to: cancelled.partial)
  #expect(try String(contentsOf: target, encoding: .utf8) == "original")
  cancelled.discard()
  #expect(try String(contentsOf: target, encoding: .utf8) == "original")
  #expect(!FileManager.default.fileExists(atPath: cancelled.directory.path))
  let finished = try BrowserDownloadFile(destination: target)
  try Data("complete".utf8).write(to: finished.partial)
  try finished.finish()
  #expect(try String(contentsOf: target, encoding: .utf8) == "complete")
  #expect(!FileManager.default.fileExists(atPath: finished.directory.path))
}

@Test func browserDownloadsRetainBytesIfAnUnapprovedFileAppearsAtTheDestination() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let target = directory.appendingPathComponent("new.txt")
  let download = try BrowserDownloadFile(destination: target)
  try Data("downloaded".utf8).write(to: download.partial)
  try Data("created while downloading".utf8).write(to: target)
  #expect(throws: (any Error).self) { try download.finish() }
  #expect(try String(contentsOf: target, encoding: .utf8) == "created while downloading")
  #expect(try String(contentsOf: download.partial, encoding: .utf8) == "downloaded")
}

@Test func browserDownloadNamesCannotEscapeTheirDirectory() throws {
  let directory = URL(fileURLWithPath: "/private/tmp/downloads", isDirectory: true)
  for suggestion in [
    "../../report.txt", "C:\\secret\\report.txt", ".", "..", "\n\0",
    String(repeating: "🖼️", count: 200),
  ] {
    let name = BrowserDownloadFile.name(suggestion)
    #expect(!name.isEmpty)
    #expect(name.utf8.count <= 180)
    #expect(
      directory.appendingPathComponent(name).standardizedFileURL.deletingLastPathComponent()
        == directory)
  }
}
