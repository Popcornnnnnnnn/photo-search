import Foundation

enum SearchHistoryDateRange: String, CaseIterable, Identifiable {
    case all = "All Time"
    case today = "Today"
    case week = "Last 7 Days"
    case month = "Last 30 Days"

    var id: Self { self }

    func contains(_ date: Date?, now: Date, calendar: Calendar) -> Bool {
        guard self != .all else { return true }
        guard let date else { return false }
        let days = switch self {
        case .all, .today: 1
        case .week: 7
        case .month: 30
        }
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: 1 - days, to: today),
              let end = calendar.date(byAdding: .day, value: 1, to: today) else { return false }
        return date >= start && date < end
    }
}

struct SearchHistoryDay: Identifiable {
    enum ID: Hashable {
        case dated(Date)
        case undated
    }

    let id: ID
    let entries: [SearchHistoryEntry]

    var date: Date? {
        if case .dated(let date) = id { return date }
        return nil
    }

    func title(now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date else { return "Date Unavailable" }
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    static func groups(for entries: [SearchHistoryEntry], range: SearchHistoryDateRange,
                       query: String, now: Date = Date(), calendar: Calendar = .current) -> [Self] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = entries.filter {
            range.contains($0.createdAt, now: now, calendar: calendar)
                && (query.isEmpty || $0.query.localizedStandardContains(query))
        }
        let grouped = Dictionary(grouping: matches) { entry in
            entry.createdAt.map { ID.dated(calendar.startOfDay(for: $0)) } ?? .undated
        }
        return grouped.map { id, entries in
            Self(id: id, entries: entries.sorted {
                ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast)
            })
        }.sorted {
            ($0.date ?? .distantPast) > ($1.date ?? .distantPast)
        }
    }
}
