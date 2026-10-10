import Foundation
import Testing
@testable import LiquidGlassDemo

@Suite struct SearchHistoryGroupingTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func entry(_ query: String, _ timestamp: String?) -> SearchHistoryEntry {
        SearchHistoryEntry(id: UUID(), query: query, createdAt: timestamp.map(date), section: .all)
    }

    @Test func dateRangesUseLocalCalendarDaysAcrossDaylightSavingTime() {
        let now = date("2026-03-09T16:00:00Z")
        let boundaries: [(SearchHistoryDateRange, String)] = [
            (.today, "2026-03-09T07:00:00Z"),
            (.week, "2026-03-03T08:00:00Z"),
            (.month, "2026-02-08T08:00:00Z")
        ]
        let tomorrow = date("2026-03-10T07:00:00Z")
        for (range, timestamp) in boundaries {
            let start = date(timestamp)
            #expect(range.contains(start, now: now, calendar: calendar))
            #expect(!range.contains(start.addingTimeInterval(-1), now: now, calendar: calendar))
            #expect(range.contains(tomorrow.addingTimeInterval(-1), now: now, calendar: calendar))
            #expect(!range.contains(tomorrow, now: now, calendar: calendar))
            #expect(!range.contains(nil, now: now, calendar: calendar))
        }
        #expect(SearchHistoryDateRange.all.contains(nil, now: now, calendar: calendar))
    }

    @Test func groupsByLocalDayWithNewestFirstAndUndatedLast() {
        let now = date("2026-03-09T16:00:00Z")
        let yesterdayEarly = entry("Morning", "2026-03-08T08:00:00Z")
        let yesterdayLate = entry("Evening", "2026-03-09T06:59:59Z")
        let today = entry("Morning", "2026-03-09T07:00:00Z")
        let legacy = entry("Old search", nil)
        let groups = SearchHistoryDay.groups(for: [legacy, yesterdayEarly, today, yesterdayLate],
                                            range: .all, query: "", now: now, calendar: calendar)
        #expect(groups.count == 3)
        #expect(groups.map(\.entries) == [[today], [yesterdayLate, yesterdayEarly], [legacy]])
        #expect(groups.map { $0.title(now: now, calendar: calendar) } == ["Today", "Yesterday", "Date Unavailable"])
    }

    @Test func combinesKeywordAndDateFiltersWithoutMergingRepeatedSearches() {
        let now = date("2026-03-09T16:00:00Z")
        let first = entry("Cafe ride", "2026-03-09T08:00:00Z")
        let second = entry("Cafe ride", "2026-03-09T09:00:00Z")
        let entries = [first, second,
                       entry("A different search", "2026-03-09T10:00:00Z"),
                       entry("Cafe ride", "2026-03-02T10:00:00Z"),
                       entry("Cafe ride", nil)]
        let groups = SearchHistoryDay.groups(for: entries, range: .week, query: "  CAFÉ  ",
                                            now: now, calendar: calendar)
        #expect(groups.count == 1)
        #expect(groups.first?.entries == [second, first])
        let allDays = SearchHistoryDay.groups(for: entries, range: .all, query: "",
                                             now: now, calendar: calendar)
        #expect(groups.first?.id == allDays.first?.id)
        #expect(SearchHistoryDay.groups(for: entries, range: .today, query: "no match",
                                        now: now, calendar: calendar).isEmpty)
    }
}
