import Foundation

public struct ManagedProvider: Identifiable, Sendable, Equatable {
  public let id: String
  public let driver: String
  public let name: String
  public let status: String
  public let account: String
  public let signedIn: Bool
  public let canLogout: Bool
  public let canAuthenticate: Bool
  public let envelope: JSON
  public let models: [ProviderModel]
  public let explicit: Bool

  public init(snapshot: JSON, settings: JSON) throws {
    id = try snapshot.requiredString("instanceId")
    driver = try snapshot.requiredString("driver")
    name = snapshot["displayName"].string ?? id
    status = snapshot["status"].string ?? "unknown"
    account = snapshot["auth"]["email"].string ?? snapshot["auth"]["label"].string ?? ""
    signedIn = snapshot["auth"]["status"].string == "authenticated"
    canLogout = snapshot["auth"]["canLogout"] != .bool(false)
    canAuthenticate = snapshot["setup"]["canAuthenticate"] != .bool(false)
    models = try snapshot["models"].array.map(ProviderModel.init)
    explicit = settings["providerInstances"][id] != .null
    envelope =
      explicit
      ? settings["providerInstances"][id]
      : .object([
        "driver": .string(driver), "displayName": .string(name),
        "enabled": settings["providers"][driver]["enabled"] == .null
          ? .bool(true) : settings["providers"][driver]["enabled"],
        "config": settings["providers"][driver],
      ])
  }
}

public struct ProviderInstanceDraft: Codable, Sendable {
  public var id: String
  public var driver: String
  public var displayName: String
  public var enabled: Bool
  public var homePath: String
  public var shadowHomePath: String
  public var binaryPath: String
  public var launchArgs: String
  public var customModels: [JSON]
  private let original: JSON

  public init(provider: ManagedProvider? = nil) {
    original = provider?.envelope ?? .object([:])
    id = provider?.id ?? "codex_" + UUID().uuidString.lowercased().prefix(8)
    driver = provider?.driver ?? "codex"
    displayName = provider?.name ?? ""
    enabled = original["enabled"] != .bool(false)
    homePath = original["config"]["homePath"].string ?? ""
    shadowHomePath = original["config"]["shadowHomePath"].string ?? ""
    binaryPath = original["config"]["binaryPath"].string ?? ""
    launchArgs = original["config"]["launchArgs"].string ?? ""
    customModels = original["config"]["customModels"].array
  }

  public func mutation(create: Bool, mergingLatest latest: JSON? = nil) throws -> JSON {
    let slug = id.trimmingCharacters(in: .whitespacesAndNewlines)
    guard slug.count <= 64,
      slug.range(of: "^[a-zA-Z][a-zA-Z0-9_-]*$", options: .regularExpression) != nil
    else {
      throw T3Error(
        "Account ID must start with a letter and use up to 64 letters, numbers, dashes or underscores."
      )
    }
    guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw T3Error("Enter an account name.")
    }
    guard driver == "codex" || driver == "claudeAgent" else {
      throw T3Error("Configuration editing is available for Claude and Codex.")
    }
    var seen: Set<String> = []
    for model in customModels {
      let slug = (model.string ?? model["slug"].string ?? "").trimmingCharacters(
        in: .whitespacesAndNewlines)
      guard !slug.isEmpty, seen.insert(slug).inserted else {
        throw T3Error("Custom model IDs must be nonempty and unique.")
      }
    }
    let base = latest ?? original
    var config: [String: JSON] = [:]
    if case .object(let fields) = base["config"] { config = fields }
    config["homePath"] = .string(homePath.trimmingCharacters(in: .whitespacesAndNewlines))
    config["binaryPath"] = .string(binaryPath.trimmingCharacters(in: .whitespacesAndNewlines))
    config["launchArgs"] = .string(launchArgs)
    config["customModels"] = .array(customModels)
    if driver == "codex" {
      config["shadowHomePath"] = .string(
        shadowHomePath.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    var envelope: [String: JSON] = [:]
    if case .object(let fields) = base { envelope = fields }
    envelope["driver"] = .string(driver)
    envelope["displayName"] = .string(displayName.trimmingCharacters(in: .whitespacesAndNewlines))
    envelope["enabled"] = .bool(enabled)
    envelope["config"] = .object(config)
    return .object([
      "patch": .object([:]),
      "providerInstanceMutation": .object([
        "operation": .string(create ? "create" : "upsert"),
        "instanceId": .string(slug), "instance": .object(envelope),
      ]),
    ])
  }
}

public struct ProviderLoginState: Sendable, Equatable {
  public let instanceID: String
  public let phase: String
  public let flowID: String?
  public let interaction: JSON
  public let methods: [JSON]
  public let url: URL?
  public var active: Bool { ["starting", "waiting", "verifying"].contains(phase) }
  public init(_ value: JSON) throws {
    instanceID = try value.requiredString("instanceId")
    phase = try value.requiredString("phase")
    flowID = value["flowId"].string
    interaction = value["interaction"]
    methods = value["methods"].array
    let candidate = interaction["url"].string ?? value["authorizationUrl"].string
    url = candidate.flatMap(URL.init(string:)).flatMap {
      ["https", "http"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil
    }
  }
  public func response(_ response: JSON) throws -> JSON {
    guard active, let flowID, let interactionID = interaction["id"].string else {
      throw T3Error("This sign-in interaction is no longer active.")
    }
    switch response["type"].string {
    case "browser":
      guard interaction["type"].string == "browser",
        ["accept", "decline"].contains(response["action"].string ?? "")
      else {
        throw T3Error("This sign-in does not accept browser consent.")
      }
    case "terminal":
      guard interaction["type"].string == "terminal", let text = response["data"].string,
        text.utf16.count <= 4_096
      else {
        throw T3Error("Terminal input must be at most 4096 characters.")
      }
    case "credentials":
      guard interaction["type"].string == "credentials",
        case .object(let values) = response["values"],
        values.count <= 16,
        values.values.allSatisfy({ $0.string != nil && ($0.string?.utf16.count ?? 0) <= 16_384 })
      else {
        throw T3Error("Invalid credential response.")
      }
    default: throw T3Error("Unsupported sign-in interaction.")
    }
    return .object([
      "instanceId": .string(instanceID), "flowId": .string(flowID),
      "interactionId": .string(interactionID), "response": response,
    ])
  }
}

/// Local client preferences, scoped by server endpoint and compatible with the native picker's favorites.
public struct ModelPickerPreferences: Sendable, Equatable {
  public var favorites: Set<ModelIdentity> = []
  public var hidden: Set<ModelIdentity> = []
  public var order: [String: [String]] = [:]
  public init() {}
  public init(environment: String, defaults: UserDefaults = .standard) {
    func identities(_ key: String) -> Set<ModelIdentity> {
      guard let data = defaults.data(forKey: key + environment) else { return [] }
      return (try? JSONDecoder().decode(Set<ModelIdentity>.self, from: data)) ?? []
    }
    favorites = identities("modelFavorites:")
    hidden = identities("modelHidden:")
    if let data = defaults.data(forKey: "modelOrder:" + environment) {
      order = (try? JSONDecoder().decode([String: [String]].self, from: data)) ?? [:]
    }
  }
  public func save(environment: String, defaults: UserDefaults = .standard) throws {
    defaults.set(try JSONEncoder().encode(favorites), forKey: "modelFavorites:" + environment)
    defaults.set(try JSONEncoder().encode(hidden), forKey: "modelHidden:" + environment)
    defaults.set(try JSONEncoder().encode(order), forKey: "modelOrder:" + environment)
  }
  public func models(_ models: [ProviderModel], instanceID: String, includingHidden: Bool = false)
    -> [ProviderModel]
  {
    var positions: [String: Int] = [:]
    for (index, id) in (order[instanceID] ?? []).enumerated() where positions[id] == nil {
      positions[id] = index
    }
    return models.enumerated().filter { _, model in
      includingHidden || model.custom
        || !hidden.contains(ModelIdentity(instanceID: instanceID, modelID: model.id))
    }.sorted { lhs, rhs in
      let left = ModelIdentity(instanceID: instanceID, modelID: lhs.element.id)
      let right = ModelIdentity(instanceID: instanceID, modelID: rhs.element.id)
      if favorites.contains(left) != favorites.contains(right) { return favorites.contains(left) }
      let a = positions[lhs.element.id] ?? Int.max
      let b = positions[rhs.element.id] ?? Int.max
      return a == b ? lhs.offset < rhs.offset : a < b
    }.map(\.element)
  }
}
