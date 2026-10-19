import Foundation
import Testing

@testable import T3Core

@Test func mediaAssetsUseTheCorrectWorkspaceOrSingleHostFileGrant() throws {
  let thread = try ThreadSummary(
    .object([
      "id": .string("thread"), "projectId": .string("project"), "title": .string("Preview"),
      "worktreePath": .string("/repo/work"),
    ]))
  let location = try #require(
    WorkspaceLocation(environment: "remote", thread: thread, project: .null))
  for (path, absolute, tag) in [
    ("docs/page.html", "/repo/work/docs/page.html", "workspace-file"),
    ("sound.wav", "/repo/work/sound.wav", "media-file"),
    ("video.mp4", "/repo/work/video.mp4", "media-file"),
    ("/repo/work/docs/page.html", "/repo/work/docs/page.html", "workspace-file"),
    ("../report.pdf", "/repo/report.pdf", "media-file"),
    ("/repo/work-other/page.html", "/repo/work-other/page.html", "media-file"),
    ("/repo/Work/page.html", "/repo/Work/page.html", "media-file"),
  ] {
    let resource = WorkspaceMediaRequest.resource(path: path, at: location)
    #expect(resource["_tag"].string == tag)
    #expect(resource["path"].string == absolute)
    #expect(resource["threadId"].string == "thread")
  }
  let endpoint = URL(string: "https://host.test")!
  let url = try WorkspaceMediaRequest.freshURL(
    .object(["relativeUrl": .string("/api/assets/signed/My%20File.pdf?token=a%2Bb")]),
    endpoint: endpoint, revision: 7)
  let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
  #expect(parts.host == "host.test")
  #expect(parts.path == "/api/assets/signed/My File.pdf")
  #expect(parts.queryItems?.first(where: { $0.name == "token" })?.value == "a+b")
  #expect(parts.queryItems?.first(where: { $0.name == "workspace-revision" })?.value == "7")
  for invalid in [
    "https://different.test/api/assets/file", "//different.test/api/assets/file",
    "/api/auth/secret",
  ] {
    #expect(throws: T3Error.self) {
      try WorkspaceMediaRequest.freshURL(
        .object(["relativeUrl": .string(invalid)]), endpoint: endpoint, revision: 1)
    }
  }
}

@Test func playbackRetriesPreservePauseAndPositionWithoutRetryingBadMediaForever() {
  var playback = MediaPlaybackRecovery()
  playback.capture(position: 42.5, rate: 1.5)
  let refresh1 = playback.refreshAfterFailure()
  #expect(refresh1)
  let refresh2 = playback.refreshAfterFailure()
  #expect(!refresh2)
  #expect(playback.position == 42.5)
  #expect(playback.rate == 1.5)
  playback.capture(position: .nan, rate: 0)
  #expect(playback.position == 42.5)
  #expect(playback.rate == 0)
  let refresh3 = playback.refreshAfterFailure()
  #expect(!refresh3)
  playback.retry()
  let refresh4 = playback.refreshAfterFailure()
  #expect(refresh4)
  playback.capture(position: 45, rate: 1)
  let refresh5 = playback.refreshAfterFailure()
  #expect(refresh5)
  let refresh6 = playback.refreshAfterFailure()
  #expect(!refresh6)
  playback.capture(position: .infinity, rate: .infinity)
  #expect(playback.position == 45)
  #expect(playback.rate == 0)
}

@Test func htmlSourcePreferenceIsIndependentOfMarkdownAndTables() throws {
  let name = "T3MediaTests-" + UUID().uuidString
  let defaults = try #require(UserDefaults(suiteName: name))
  defer { defaults.removePersistentDomain(forName: name) }
  let preferences = FilePreviewPreferences(defaults: defaults)
  #expect(preferences.rendered(.html))
  preferences.setRendered(false, for: .html)
  #expect(!FilePreviewPreferences(defaults: defaults).rendered(.html))
  #expect(preferences.rendered(.csv))
  #expect(!preferences.rendered(.markdown))
}
