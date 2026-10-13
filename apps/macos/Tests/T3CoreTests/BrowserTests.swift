import Foundation
import Testing

@testable import T3Core

@Test func browserAddressesUseHTTPForLoopbackAndRejectCredentialsAndOtherSchemes() throws {
  #expect(
    try BrowserURL.normalize(" localhost:3000/page?q=a#section ").absoluteString
      == "http://localhost:3000/page?q=a#section")
  #expect(try BrowserURL.normalize("127.0.1.2:8080").scheme == "http")
  #expect(try BrowserURL.normalize("[::1]:8080").scheme == "http")
  #expect(try BrowserURL.normalize("example.com").absoluteString == "https://example.com/")
  for invalid in [
    "", "file:///tmp/test", "javascript:alert(1)", "https://user:secret@example.com",
    "https://example.com:0", "https://example.com:65536",
  ] {
    #expect(throws: T3Error.self) { try BrowserURL.normalize(invalid) }
  }
}

@Test func browserLocalLinksFollowTheConnectedMachineAndNeverPublicRelays() throws {
  let local = try BrowserURL.normalize("localhost:3000/page?q=a#section")
  for host in ["192.168.1.2", "100.101.1.2", "dev.local", "mac.tail123.ts.net", "[fd00::2]"] {
    let environment = URL(string: "https://\(host):4773")!
    let resolved = try BrowserURL.resolve(local, environment: environment)
    #expect(resolved.host == environment.host)
    #expect(resolved.port == 3000)
    #expect(resolved.path == "/page")
    #expect(resolved.query == "q=a")
    #expect(resolved.fragment == "section")
  }
  for host in ["relay.example.com", "127.example.com", "192.168.bad.1.2", "8.8.8.8"] {
    #expect(throws: T3Error.self) {
      try BrowserURL.resolve(local, environment: URL(string: "https://\(host)")!)
    }
  }
  let publicURL = try BrowserURL.normalize("https://127.example.com/page")
  #expect(
    try BrowserURL.resolve(publicURL, environment: URL(string: "https://192.168.1.2")!) == publicURL
  )
  #expect(
    try BrowserURL.resolve(local, environment: URL(string: "http://127.0.0.1:4773")!).host
      == "localhost")
}

private func browserTab(_ id: String, thread: String = "one", url: String = "https://example.com/")
  -> JSON
{
  .object([
    "threadId": .string(thread), "tabId": .string(id), "profileId": .string("work"),
    "viewport": .object(["_tag": .string("fill")]),
    "navStatus": .object(["_tag": .string("Success"), "url": .string(url), "title": .string(id)]),
  ])
}
private func browserList(_ tabs: [JSON], revision: Int, epoch: String = "boot") -> JSON {
  .object([
    "sessions": .array(tabs), "revision": .number(Double(revision)), "serverEpoch": .string(epoch),
  ])
}
private func browserEvent(
  _ type: String, id: String, revision: Int, thread: String = "one", epoch: String = "boot"
) -> JSON {
  .object([
    "type": .string(type), "threadId": .string(thread), "tabId": .string(id),
    "serverEpoch": .string(epoch), "revision": .number(Double(revision)),
    "snapshot": browserTab(id, thread: thread), "url": .string("https://example.com/failed"),
    "title": .string("Failed"), "code": .number(-1004),
    "description": .string("Connection refused"),
  ])
}

@Test func browserSnapshotRacePreservesNewTabsAndRejectsStaleListsAndOtherThreads() throws {
  var directory = BrowserDirectory(threadID: "one")
  try directory.apply(browserEvent("opened", id: "second", revision: 4))
  try directory.snapshot(
    browserList([browserTab("first"), browserTab("foreign", thread: "two")], revision: 3))
  #expect(directory.tabs.map(\.id) == ["first", "second"])
  try directory.snapshot(browserList([], revision: 2))
  try directory.apply(browserEvent("closed", id: "second", revision: 99, thread: "two"))
  #expect(directory.tabs.map(\.id) == ["first", "second"])
  try directory.apply(browserEvent("closed", id: "first", revision: 5))
  try directory.apply(browserEvent("opened", id: "first", revision: 4))
  #expect(directory.tabs.map(\.id) == ["second"])
  #expect(throws: T3Error.self) {
    try directory.apply(browserEvent("opened", id: "restart", revision: 1, epoch: "reboot"))
  }
  try directory.snapshot(browserList([], revision: 0, epoch: "reboot"))
  #expect(directory.tabs.isEmpty)
}

@Test func browserFailedEventsKeepTabIdentityProfileAndViewport() throws {
  var directory = BrowserDirectory(threadID: "one")
  try directory.snapshot(browserList([browserTab("first")], revision: 1))
  try directory.apply(browserEvent("failed", id: "first", revision: 2))
  let tab = try #require(directory.tabs.first)
  #expect(tab.status["_tag"].string == "LoadFailed")
  #expect(tab.url?.path == "/failed")
  #expect(tab.profileID == "work")
  #expect(tab.viewport["_tag"].string == "fill")
}
