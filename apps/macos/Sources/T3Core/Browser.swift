import Foundation

public enum BrowserURL {
  public static func normalize(_ text: String) throws -> URL {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, text.utf8.count <= 2_048 else {
      throw T3Error("Enter a URL of at most 2,048 characters.")
    }
    let local = URLComponents(string: "http://" + text)?.host.map(loopback) ?? false
    let candidate = text.contains("://") ? text : (local ? "http://" : "https://") + text
    guard var parts = URLComponents(string: candidate), let scheme = parts.scheme?.lowercased(),
      ["https", "http"].contains(scheme), let host = parts.host, !host.isEmpty,
      !host.contains(where: { $0.isWhitespace }), parts.user == nil, parts.password == nil,
      parts.port.map({ (1...65_535).contains($0) }) ?? true
    else { throw T3Error("Enter an HTTP or HTTPS URL without embedded credentials.") }
    if parts.path.isEmpty { parts.path = "/" }
    guard let url = parts.url else { throw T3Error("This URL could not be opened.") }
    return url
  }

  public static func loopback(_ host: String) -> Bool {
    let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
    return ["localhost", "::1", "::", "0.0.0.0"].contains(host) || ipv4(host)?.first == 127
  }

  private static func ipv4(_ host: String) -> [Int]? {
    let tokens = host.split(separator: ".", omittingEmptySubsequences: false)
    guard tokens.count == 4, tokens.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
      return nil
    }
    let parts = tokens.compactMap { Int($0) }
    return parts.count == 4 && parts.allSatisfy({ (0...255).contains($0) }) ? parts : nil
  }

  /// A loopback link names a server on the connected environment, not necessarily this Mac.
  public static func resolve(_ url: URL, environment: URL) throws -> URL {
    guard loopback(url.host ?? "") else { return url }
    guard let host = environment.host, privateHost(host),
      var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else {
      throw T3Error(
        "This local server needs a direct LAN or Tailscale connection to its environment.")
    }
    parts.host =
      loopback(host) ? "localhost" : host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    guard let resolved = parts.url else {
      throw T3Error("Could not resolve the environment’s local server.")
    }
    return resolved
  }

  private static func privateHost(_ host: String) -> Bool {
    let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
    if loopback(host)
      || [".local", ".localhost", ".home.arpa", ".ts.net"].contains(where: host.hasSuffix)
      || host == "home.arpa" || !host.contains(".") && !host.contains(":")
    {
      return true
    }
    if let parts = ipv4(host) {
      return [0, 10, 127].contains(parts[0]) || parts[0] == 192 && parts[1] == 168
        || parts[0] == 172 && (16...31).contains(parts[1])
        || parts[0] == 100 && (64...127).contains(parts[1])
        || parts[0] == 169 && parts[1] == 254 || parts[0] == 198 && (18...19).contains(parts[1])
    }
    if host.contains(":"),
      let first = host.split(separator: ":").first.flatMap({ Int($0, radix: 16) })
    {
      return first & 0xfe00 == 0xfc00 || first & 0xffc0 == 0xfe80
    }
    return false
  }
}

public struct BrowserTab: Sendable, Equatable, Identifiable {
  public let id: String
  public let threadID: String
  public let status: JSON
  public let viewport: JSON
  public let profileID: String?
  public var url: URL? { status["url"].string.flatMap { try? BrowserURL.normalize($0) } }
  public var title: String {
    let title = status["title"].string ?? ""
    return title.isEmpty ? url?.host ?? "Browser" : title
  }
  public init(_ value: JSON) throws {
    id = try value.requiredString("tabId")
    threadID = try value.requiredString("threadId")
    status = value["navStatus"]
    viewport = value["viewport"]
    profileID = value["profileId"].string
  }
}

public struct BrowserDirectory: Sendable {
  public let threadID: String
  public private(set) var tabs: [BrowserTab] = []
  public private(set) var epoch: String?
  public private(set) var revision = 0
  private var pending: [JSON] = []
  public init(threadID: String) { self.threadID = threadID }

  public mutating func snapshot(_ value: JSON) throws {
    let epoch = try value.requiredString("serverEpoch")
    let revision = try value.requiredInt("revision")
    guard self.epoch != epoch || revision >= self.revision else { return }
    tabs = try value["sessions"].array.filter { $0["threadId"].string == threadID }.map(
      BrowserTab.init)
    self.epoch = epoch
    self.revision = revision
    let buffered = pending
    pending = []
    for event in buffered { try apply(event) }
  }

  @discardableResult public mutating func apply(_ event: JSON) throws -> Bool {
    guard event["threadId"].string == threadID else { return false }
    guard let epoch else {
      guard pending.count < 256 else {
        throw T3Error("Browser updates overflowed. Reopen Browser to reconnect.")
      }
      pending.append(event)
      return false
    }
    guard event["serverEpoch"].string == epoch else {
      throw T3Error("The browser server restarted. Reopen Browser to reconnect.")
    }
    let revision = try event.requiredInt("revision")
    guard revision > self.revision else { return false }
    self.revision = revision
    let id = try event.requiredString("tabId")
    switch event["type"].string {
    case "opened", "navigated", "resized":
      let tab = try BrowserTab(event["snapshot"])
      guard tab.threadID == threadID else { return false }
      if let index = tabs.firstIndex(where: { $0.id == tab.id }) {
        tabs[index] = tab
      } else {
        tabs.append(tab)
      }
    case "closed": tabs.removeAll { $0.id == id }
    case "failed":
      if let index = tabs.firstIndex(where: { $0.id == id }) {
        let old = tabs[index]
        tabs[index] = try BrowserTab(
          .object([
            "tabId": .string(id), "threadId": .string(threadID), "viewport": old.viewport,
            "profileId": old.profileID.map(JSON.string) ?? .null,
            "navStatus": .object([
              "_tag": .string("LoadFailed"), "url": event["url"], "title": event["title"],
              "code": event["code"], "description": event["description"],
            ]),
          ]))
      }
    default: return false
    }
    return true
  }
}

public struct BrowserLocalServer: Sendable, Equatable, Identifiable {
  public let url: URL
  public let process: String
  public let threadID: String?
  public var id: String { url.absoluteString }
  public init?(_ value: JSON) {
    guard let text = value["url"].string, let url = try? BrowserURL.normalize(text) else {
      return nil
    }
    self.url = url
    process = value["processName"].string ?? "Local server"
    threadID = value["terminal"]["threadId"].string
  }
}
