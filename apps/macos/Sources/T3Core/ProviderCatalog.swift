import Foundation

public struct ProviderModel: Sendable, Equatable, Identifiable {
  public let id: String
  public let name: String
  public let descriptors: [JSON]
  public let legacy: Bool
  public let shortName: String?
  public let subProvider: String?
  public let custom: Bool
  public let badge: String?

  public init(_ value: JSON) throws {
    id = try value.requiredString("slug")
    name = value["name"].string ?? id
    descriptors = value["capabilities"]["optionDescriptors"].array
    legacy = value["isLegacy"].bool
    shortName = value["shortName"].string
    subProvider = value["subProvider"].string
    custom = value["isCustom"].bool
    badge = value["badge"].string
  }

  public func selection(
    instanceID: String, preserving previous: JSON? = nil, planModeEnabled: Bool = true
  ) -> JSON {
    let previousOptions = previous?["options"].array ?? []
    let options = descriptors.compactMap { descriptor -> JSON? in
      guard let id = descriptor["id"].string else { return nil }
      let old = previousOptions.first { $0["id"].string == id }?["value"] ?? .null
      let value: JSON
      if descriptor["type"].string == "boolean" {
        if case .bool = old { value = old } else { value = .bool(descriptor["currentValue"].bool) }
      } else {
        let choices = descriptor["options"].array.filter {
          planModeEnabled || id != "agent" || $0["id"].string != "plan"
        }
        value =
          choices.contains { $0["id"] == old }
          ? old
          : choices.first { $0["id"] == descriptor["currentValue"] }?["id"]
            ?? choices.first { $0["isDefault"].bool }?["id"]
            ?? (id == "agent" ? choices.first?["id"] : nil) ?? .null
      }
      return value == .null ? nil : .object(["id": .string(id), "value": value])
    }
    return .object([
      "instanceId": .string(instanceID), "model": .string(id), "options": .array(options),
    ])
  }
}

public struct ProviderEntry: Sendable, Equatable, Identifiable {
  public let id: String
  public let name: String
  public let driver: String
  public let models: [ProviderModel]
  public let available: Bool
  public let unavailableReason: String?
  public let runtimeModes: [String]
  public let showInteractionMode: Bool
  public let requiresNewThreadForModelChange: Bool

  public init(_ value: JSON) throws {
    id = try value.requiredString("instanceId")
    name = value["displayName"].string ?? id
    driver = value["driver"].string ?? id
    models = try value["models"].array.map(ProviderModel.init)
    available =
      value["enabled"].bool && value["installed"].bool
      && value["status"].string != "disabled" && value["availability"].string != "unavailable"
    unavailableReason = value["unavailableReason"].string ?? value["message"].string
    runtimeModes = value["supportedRuntimeModes"].array.compactMap(\.string)
    showInteractionMode = value["showInteractionModeToggle"].bool
    requiresNewThreadForModelChange = value["requiresNewThreadForModelChange"].bool
  }
}

public struct ProviderCatalog: Sendable, Equatable {
  public private(set) var providers: [ProviderEntry] = []
  public private(set) var planModeEnabled = false
  public private(set) var attachmentPolicy = AttachmentPolicy()
  public init() {}

  public mutating func apply(_ event: JSON) throws {
    switch event["type"].string {
    case "snapshot":
      providers = try event["config"]["providers"].array.map(ProviderEntry.init)
      planModeEnabled = event["config"]["settings"]["planModeEnabled"].bool
      attachmentPolicy = AttachmentPolicy(event["config"]["environment"]["capabilities"])
    case "providerStatuses":
      providers = try event["payload"]["providers"].array.map(ProviderEntry.init)
    case "settingsUpdated":
      planModeEnabled = event["payload"]["settings"]["planModeEnabled"].bool
    default: break
    }
  }

  public func provider(for selection: JSON) -> ProviderEntry? {
    providers.first { $0.id == selection["instanceId"].string }
  }

  public func model(for selection: JSON) -> ProviderModel? {
    provider(for: selection)?.models.first { $0.id == selection["model"].string }
  }

  public func descriptors(for selection: JSON) -> [JSON] {
    (model(for: selection)?.descriptors ?? []).compactMap { descriptor in
      guard !planModeEnabled, descriptor["id"].string == "agent",
        descriptor["type"].string == "select", case .object(var fields) = descriptor
      else { return descriptor }
      let options = descriptor["options"].array.filter { $0["id"].string != "plan" }
      guard !options.isEmpty else { return nil }
      fields["options"] = .array(options)
      return .object(fields)
    }
  }
}
