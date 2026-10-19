import Foundation

public struct ModelIdentity: Codable, Hashable, Sendable {
  public let instanceID: String
  public let modelID: String
  public init(instanceID: String, modelID: String) {
    self.instanceID = instanceID
    self.modelID = modelID
  }
  public init(_ selection: JSON) {
    self.init(
      instanceID: selection["instanceId"].string ?? "", modelID: selection["model"].string ?? "")
  }
}

public struct ModelChoice: Sendable, Equatable, Identifiable {
  public let provider: ProviderEntry
  public let model: ProviderModel
  public var id: ModelIdentity { ModelIdentity(instanceID: provider.id, modelID: model.id) }
  fileprivate let fields: [String]
}

public struct ModelSearch: Sendable {
  private let choices: [ModelChoice]

  public init(catalog: ProviderCatalog) {
    choices = catalog.providers.flatMap { provider in
      provider.models.map { model in
        let names = [
          model.name, model.shortName, model.subProvider, provider.driver, provider.name,
        ]
        .compactMap { $0 }
        return ModelChoice(
          provider: provider, model: model,
          fields: (names + [names.joined(separator: " ")]).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
          })
      }
    }
  }

  public func results(
    query: String, instanceID: String?, favoritesOnly: Bool = false,
    favorites: Set<ModelIdentity> = []
  ) -> [ModelChoice] {
    let tokens = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    if tokens.isEmpty {
      return choices.enumerated().filter { _, choice in
        (instanceID == nil || choice.provider.id == instanceID)
          && (!favoritesOnly || favorites.contains(choice.id))
      }.sorted { a, b in
        let aFavorite = favorites.contains(a.element.id)
        let bFavorite = favorites.contains(b.element.id)
        if aFavorite != bFavorite { return aFavorite }
        return a.offset < b.offset
      }.map(\.element)
    }
    // Searching spans accounts even while a provider or Favorites tab is selected.
    let normalizedQuery = tokens.joined(separator: " ")
    func isExactModel(_ choice: ModelChoice) -> Bool {
      choice.model.name.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        == normalizedQuery
    }
    return choices.enumerated().compactMap { offset, choice -> (ModelChoice, Int, Int, Bool)? in
      var total = 0
      for token in tokens {
        let matches = choice.fields.enumerated().compactMap { fieldIndex, field in
          Self.score(field: field, token: token, base: fieldIndex * 10)
        }
        guard let best = matches.min() else { return nil }
        total += best
      }
      if favorites.contains(choice.id) { total -= 24 }
      return (choice, total, offset, isExactModel(choice))
    }.sorted { a, b in
      if a.3 != b.3 { return a.3 }
      if a.1 != b.1 { return a.1 < b.1 }
      let aFavorite = favorites.contains(a.0.id)
      let bFavorite = favorites.contains(b.0.id)
      if aFavorite != bFavorite { return aFavorite }
      // Keep precise matches and favorites ahead; prefer current models only on a relevance tie.
      if a.0.model.legacy != b.0.model.legacy { return !a.0.model.legacy }
      let order = (a.0.fields.last ?? "").localizedCompare(b.0.fields.last ?? "")
      return order == .orderedSame ? a.2 < b.2 : order == .orderedAscending
    }.map { $0.0 }
  }

  private static func score(field: String, token: String, base: Int) -> Int? {
    guard !field.isEmpty else { return nil }
    if field == token { return base }
    let lengthPenalty = min(64, max(0, field.count - token.count))
    if field.hasPrefix(token) { return base + 2 + lengthPenalty }
    let boundary = [" ", "-", "_", "/"].compactMap { marker -> Int? in
      guard let range = field.range(of: marker + token) else { return nil }
      return field.distance(from: field.startIndex, to: range.lowerBound) + 1
    }.min()
    if let boundary { return base + 4 + boundary * 2 + lengthPenalty }
    if let range = field.range(of: token) {
      return base + 6 + field.distance(from: field.startIndex, to: range.lowerBound) * 2
        + lengthPenalty
    }
    guard token.count >= 3 else { return nil }
    let query = Array(token)
    var queryIndex = 0
    var first = 0
    var previous = 0
    var gaps = 0
    for (index, character) in field.enumerated() where character == query[queryIndex] {
      if queryIndex == 0 { first = index } else { gaps += index - previous - 1 }
      previous = index
      queryIndex += 1
      if queryIndex == query.count {
        return base + 100 + first * 2 + gaps * 3 + index - first + 1 - query.count + lengthPenalty
      }
    }
    return nil
  }
}
