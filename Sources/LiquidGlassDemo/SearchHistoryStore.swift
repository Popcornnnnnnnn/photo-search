import Foundation

@Observable
@MainActor
final class SearchHistoryStore {
    private static let maximumEntryCount = 20

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey: String

    private(set) var entries: [String]

    var recentEntries: [String] {
        Array(entries.prefix(5))
    }

    init(defaults: UserDefaults = .standard,
         storageKey: String = Prefs.searchHistory) {
        self.defaults = defaults
        self.storageKey = storageKey
        entries = Self.cleaned(defaults.stringArray(forKey: storageKey) ?? [])
    }

    func record(_ query: String) {
        let normalized = Self.normalize(query)
        guard !normalized.isEmpty else { return }

        let key = Self.comparisonKey(normalized)
        entries.removeAll { Self.comparisonKey($0) == key }
        entries.insert(normalized, at: 0)
        entries = Array(entries.prefix(Self.maximumEntryCount))
        defaults.set(entries, forKey: storageKey)
    }

    func remove(_ query: String) {
        let key = Self.comparisonKey(query)
        entries.removeAll { Self.comparisonKey($0) == key }
        defaults.set(entries, forKey: storageKey)
    }

    func clear() {
        entries = []
        defaults.removeObject(forKey: storageKey)
    }

    private static func cleaned(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let normalized = normalize(value)
            let key = comparisonKey(normalized)
            guard !normalized.isEmpty, seen.insert(key).inserted else { return nil }
            return normalized
        }
        .prefix(maximumEntryCount)
        .map { $0 }
    }

    private static func normalize(_ query: String) -> String {
        query.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
    }

    private static func comparisonKey(_ query: String) -> String {
        query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
