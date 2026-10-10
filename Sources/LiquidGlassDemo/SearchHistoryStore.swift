import Foundation

struct SearchHistoryEntry: Codable, Equatable, Identifiable {
    let id: UUID
    let query: String
    let createdAt: Date?
    let section: PhotoSection
}

@Observable
@MainActor
final class SearchHistoryStore {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey: String

    private(set) var entries: [SearchHistoryEntry]

    init(defaults: UserDefaults = .standard,
         storageKey: String = Prefs.searchHistory) {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey) {
            entries = (try? JSONDecoder().decode([SearchHistoryEntry].self, from: data)) ?? []
        } else {
            // The old list stored only queries. Preserve its order without
            // inventing timestamps for searches made before this format.
            entries = (defaults.stringArray(forKey: storageKey) ?? []).compactMap { value in
                let query = Self.normalize(value)
                guard !query.isEmpty else { return nil }
                return SearchHistoryEntry(id: UUID(), query: query, createdAt: nil, section: .all)
            }
            if !entries.isEmpty { persist() }
        }
    }

    func record(_ query: String, section: PhotoSection = .all, at date: Date = Date()) {
        let normalized = Self.normalize(query)
        guard !normalized.isEmpty else { return }

        entries.insert(SearchHistoryEntry(id: UUID(), query: normalized, createdAt: date, section: section), at: 0)
        persist()
    }

    func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        persist()
    }

    func clear() {
        entries = []
        defaults.removeObject(forKey: storageKey)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private static func normalize(_ query: String) -> String {
        query.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
    }

}
