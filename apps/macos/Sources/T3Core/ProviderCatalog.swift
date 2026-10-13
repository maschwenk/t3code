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
  public let accentColor: String?
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
    accentColor = value["accentColor"].string
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
  public private(set) var fileOpen = FileOpenCapabilities()
  public private(set) var newProjectsRoot: String?
  public private(set) var scratchWorkspaceRoot: String?
  private var defaultMode = "approval-required"
  private var projectModes: [String: String] = [:]
  private var settings: JSON = .null
  public init(planModeEnabled: Bool = false) { self.planModeEnabled = planModeEnabled }
  public mutating func setPlanModeEnabled(_ enabled: Bool) { planModeEnabled = enabled }

  public mutating func apply(_ event: JSON) throws {
    switch event["type"].string {
    case "snapshot":
      providers = try event["config"]["providers"].array.map(ProviderEntry.init)
      applySettings(event["config"]["settings"])
      attachmentPolicy = AttachmentPolicy(event["config"]["environment"]["capabilities"])
      fileOpen = FileOpenCapabilities(event["config"])
      newProjectsRoot = event["config"]["newProjectsRoot"].string
      scratchWorkspaceRoot = event["config"]["scratchWorkspaceRoot"].string
    case "providerStatuses":
      providers = try event["payload"]["providers"].array.map(ProviderEntry.init)
    case "settingsUpdated":
      applySettings(event["payload"]["settings"])
    default: break
    }
  }

  public func provider(for selection: JSON) -> ProviderEntry? {
    providers.first { $0.id == selection["instanceId"].string }
  }

  public func configuredWorkspaceMode(project: JSON) -> String? {
    WorkspaceDefaults.configuredMode(settings: settings, project: project)
  }

  public func defaultRuntimeMode(projectID: String) -> String {
    projectModes[projectID] ?? defaultMode
  }
  private mutating func applySettings(_ settings: JSON) {
    self.settings = settings
    defaultMode = settings["defaultRuntimeMode"].string ?? "approval-required"
    if case .object(let overrides) = settings["projectSettingsOverrides"] {
      projectModes = overrides.compactMapValues { $0["defaultRuntimeMode"].string }
    } else {
      projectModes = [:]
    }
  }

  public func newThreadConfiguration(project: JSON, carrying thread: ThreadSummary?) throws
    -> NewThreadConfiguration
  {
    let projectID = try project.requiredString("id")
    let overrides = settings["projectSettingsOverrides"][projectID]
    var configured = settings["defaultModelSelection"]
    if !settings["projectSettingsFolded"].bool, project["defaultModelSelection"] != .null {
      configured = project["defaultModelSelection"]
    }
    if case .object(let fields) = overrides, let value = fields["defaultModelSelection"] {
      configured = value
    }
    if configured != .null, provider(for: configured)?.available != true {
      configured = settings["defaultModelSelection"]
    }
    let candidates = [configured, thread?.model ?? .null]
    for candidate in candidates {
      if let provider = provider(for: candidate), provider.available,
        let model = model(for: candidate)
      {
        return NewThreadConfiguration(
          projectID: projectID,
          model: model.selection(
            instanceID: provider.id, preserving: candidate, planModeEnabled: planModeEnabled),
          runtimeMode: defaultRuntimeMode(projectID: projectID),
          interactionMode: planModeEnabled ? thread?.interactionMode ?? "default" : "default")
      }
    }
    guard let provider = providers.first(where: { $0.available && !$0.models.isEmpty }),
      let model = provider.models.first(where: { !$0.legacy }) ?? provider.models.first
    else { throw T3Error("Connect an available provider before starting a new thread.") }
    return NewThreadConfiguration(
      projectID: projectID,
      model: model.selection(instanceID: provider.id, planModeEnabled: planModeEnabled),
      runtimeMode: defaultRuntimeMode(projectID: projectID), interactionMode: "default")
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
