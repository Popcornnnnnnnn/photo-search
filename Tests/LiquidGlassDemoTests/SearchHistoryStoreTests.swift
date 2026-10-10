import Foundation
import Testing
@testable import LiquidGlassDemo

@Suite struct SearchHistoryStoreTests {
    @MainActor
    @Test func preservesRepeatedSearchesWithTimeAndScopeAcrossReloads() {
        let suiteName = "SearchHistoryStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SearchHistoryStore(defaults: defaults, storageKey: "history")
        let firstTime = Date(timeIntervalSince1970: 1_700_000_000)
        let secondTime = firstTime.addingTimeInterval(60)
        store.record("  Purple   jersey\n", section: .photo, at: firstTime)
        store.record("Purple jersey", section: .all, at: secondTime)
        store.record(" \n\t ")

        #expect(store.entries.map(\.query) == ["Purple jersey", "Purple jersey"])
        #expect(store.entries.map(\.createdAt) == [secondTime, firstTime])
        #expect(store.entries.map(\.section) == [.all, .photo])
        #expect(Set(store.entries.map(\.id)).count == 2)
        #expect(SearchHistoryStore(defaults: defaults, storageKey: "history").entries == store.entries)

        let earlier = store.entries[1]
        store.remove(id: store.entries[0].id)
        #expect(SearchHistoryStore(defaults: defaults, storageKey: "history").entries == [earlier])

        store.clear()
        #expect(store.entries.isEmpty)
        #expect(SearchHistoryStore(defaults: defaults, storageKey: "history").entries.isEmpty)
    }

    @MainActor
    @Test func keepsAllSearchesBeyondTheOldLimit() {
        let suiteName = "SearchHistoryStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SearchHistoryStore(defaults: defaults, storageKey: "history")
        for index in 0..<100 {
            store.record("query \(index)")
        }

        let reloaded = SearchHistoryStore(defaults: defaults, storageKey: "history")
        #expect(reloaded.entries.count == 100)
        #expect(reloaded.entries.first?.query == "query 99")
        #expect(reloaded.entries.last?.query == "query 0")
    }

    @MainActor
    @Test func migratesLegacyQueriesOnceWithoutInventingDates() {
        let suiteName = "SearchHistoryStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(["  跑步 比赛  ", "Purple jersey", "Purple jersey", "  "], forKey: "history")

        let migrated = SearchHistoryStore(defaults: defaults, storageKey: "history")
        #expect(migrated.entries.map(\.query) == ["跑步 比赛", "Purple jersey", "Purple jersey"])
        #expect(migrated.entries.allSatisfy { $0.createdAt == nil && $0.section == .all })
        #expect(SearchHistoryStore(defaults: defaults, storageKey: "history").entries == migrated.entries)

        migrated.clear()
        #expect(SearchHistoryStore(defaults: defaults, storageKey: "history").entries.isEmpty)
        #expect(defaults.object(forKey: "history") == nil)
    }
}
