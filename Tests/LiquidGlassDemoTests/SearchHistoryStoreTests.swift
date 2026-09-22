import Foundation
import Testing
@testable import LiquidGlassDemo

@Suite struct SearchHistoryStoreTests {
    @MainActor
    @Test func normalizesDeduplicatesPersistsAndClears() {
        let suiteName = "SearchHistoryStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SearchHistoryStore(defaults: defaults, storageKey: "history")
        store.record("  Purple   jersey  ")
        store.record("purple jersey")
        store.record("273.7 km")

        #expect(store.entries == ["273.7 km", "purple jersey"])
        #expect(SearchHistoryStore(defaults: defaults, storageKey: "history").entries == store.entries)

        store.remove("PURPLE JERSEY")
        #expect(store.entries == ["273.7 km"])

        store.clear()
        #expect(store.entries.isEmpty)
        #expect(defaults.stringArray(forKey: "history") == nil)
    }

    @MainActor
    @Test func keepsOnlyTheTwentyMostRecentSearches() {
        let suiteName = "SearchHistoryStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SearchHistoryStore(defaults: defaults, storageKey: "history")
        for index in 0..<24 {
            store.record("query \(index)")
        }

        #expect(store.entries.count == 20)
        #expect(store.entries.first == "query 23")
        #expect(store.entries.last == "query 4")
        #expect(store.recentEntries.count == 5)
    }
}
