import AppKit
import Foundation
import GRDB
import ImageIO

// A view is recorded only after its decoded image enters the visible viewer.
@MainActor
enum PhotoViewHistory {
    private static let key = "photoSearch.lastViewedAt.v1"
    static let window: TimeInterval = 7 * 24 * 60 * 60

    static func dates(defaults: UserDefaults = .standard) -> [String: Date] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        return (try? PropertyListDecoder().decode([String: Date].self, from: data)) ?? [:]
    }

    static func record(_ id: String, at date: Date = .now, defaults: UserDefaults = .standard) {
        var values = dates(defaults: defaults)
        values[id] = date
        if let data = try? PropertyListEncoder().encode(values) {
            defaults.set(data, forKey: key)
        }
    }

    static func isRecent(_ id: String, at date: Date = .now,
                         defaults: UserDefaults = .standard) -> Bool {
        isRecent(id, in: dates(defaults: defaults), at: date)
    }

    static func isRecent(_ id: String, in dates: [String: Date], at date: Date = .now) -> Bool {
        guard let viewed = dates[id] else { return false }
        return isRecent(viewed: viewed, at: date)
    }

    static func isRecent(viewed: Date, at date: Date) -> Bool {
        viewed <= date && date.timeIntervalSince(viewed) < window
    }
}

struct RandomBrowsePath {
    private(set) var ids: [String] = []
    var count: Int { ids.count }
    var previous: String? { ids.count > 1 ? ids[ids.count - 2] : nil }
    var current: String? { ids.last }

    mutating func append(_ id: String) { ids.append(id) }

    @discardableResult mutating func goBack() -> String? {
        guard ids.count > 1 else { return nil }
        ids.removeLast()
        return ids.last
    }
}

struct RandomBrowsePhoto: Sendable {
    let id: String
    let path: String
    let fallbackPath: String?
    let filename: String
    let capturedAt: String?
    let assetType: String?
    let shortCaption: String?

    var displayDate: String {
        guard let capturedAt else { return filename }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: capturedAt) ?? ISO8601DateFormatter().date(from: capturedAt) else {
            return capturedAt
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct PreparedImage: @unchecked Sendable {
    let image: NSImage
}

@Observable
@MainActor
final class RandomBrowseStore {
    enum Status { case loading, empty, unavailable, exhausted, ready }

    private(set) var status: Status = .loading
    private(set) var currentID: String?
    private(set) var currentImage: NSImage?
    private(set) var currentDisplayDate = ""
    private(set) var previousImage: NSImage?
    private(set) var preparedNextID: String?
    private(set) var canGoBack = false

    @ObservationIgnored private var photos: [String: RandomBrowsePhoto] = [:]
    @ObservationIgnored private var queue: [String] = []
    @ObservationIgnored private var cursor = 0
    @ObservationIgnored private var path = RandomBrowsePath()
    @ObservationIgnored private var cache: [String: NSImage] = [:]
    @ObservationIgnored private var seenThisRound: Set<String> = []
    @ObservationIgnored private var unavailableIDs: Set<String> = []
    @ObservationIgnored private var ignoresRecentForRound = false
    @ObservationIgnored private var preparing = false
    @ObservationIgnored private var advancing = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let databasePath: String
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let shufflesQueue: Bool
    @ObservationIgnored var preloadingTask: Task<Void, Never>?

    init(databasePath: String = PhotoSearchDatabase.path,
         defaults: UserDefaults = .standard,
         shufflesQueue: Bool = true) {
        self.databasePath = databasePath
        self.defaults = defaults
        self.shufflesQueue = shufflesQueue
    }

    var currentPhoto: RandomBrowsePhoto? { currentID.flatMap { photos[$0] } }
    var nextImage: NSImage? {
        guard let id = preparedNextID else { return nil }
        return cache[id]
    }

    func refreshPreparedCandidate() {
        guard let id = preparedNextID else { return }
        if cursor >= queue.count || !queue[cursor...].contains(id) || seenThisRound.contains(id)
            || (!ignoresRecentForRound && PhotoViewHistory.isRecent(id, defaults: defaults)) {
            preparedNextID = nil
        }
    }

    func start() async {
        generation += 1
        let request = generation
        status = .loading
        currentID = nil
        currentImage = nil
        currentDisplayDate = ""
        previousImage = nil
        preparedNextID = nil
        canGoBack = false
        preparing = false
        advancing = false
        preloadingTask = nil
        let databasePath = databasePath
        let fetched = try? await Task.detached(priority: .userInitiated) {
            try PhotoSearchDatabase.read(at: databasePath) { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT a.id, a.file_path, a.thumbnail_path, a.filename, a.captured_at,
                           d.asset_type, d.short_caption
                    FROM assets AS a
                    LEFT JOIN search_docs AS d ON d.asset_id = a.id
                    WHERE a.is_available = 1 AND COALESCE(d.asset_type, 'other') != 'video' AND LOWER(a.file_path) NOT LIKE '%.mov'
                    """)
                let photos = rows.compactMap { row -> RandomBrowsePhoto? in
                        let original: String = row["file_path"]
                        let preview: String = row["thumbnail_path"]
                        let path = [original, preview].first {
                            !$0.isEmpty && FileManager.default.isReadableFile(atPath: $0)
                        }
                        guard let path else { return nil }
                        let fallback = preview != path && FileManager.default.isReadableFile(atPath: preview)
                            ? preview : nil
                        return RandomBrowsePhoto(id: row["id"], path: path,
                                                 fallbackPath: fallback,
                                                 filename: row["filename"], capturedAt: row["captured_at"],
                                                 assetType: row["asset_type"], shortCaption: row["short_caption"])
                    }
                return (rows.count, photos)
            }
        }.value
        guard request == generation else { return }
        let candidates = fetched?.1 ?? []
        photos = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        let ids = candidates.map(\.id)
        queue = shufflesQueue ? ids.shuffled() : ids.sorted()
        cursor = 0
        path = RandomBrowsePath()
        cache = [:]
        seenThisRound = []
        unavailableIDs = []
        ignoresRecentForRound = false
        status = candidates.isEmpty ? (fetched == nil || fetched?.0 != 0 ? .unavailable : .empty) : .loading
        if !candidates.isEmpty { await next() }
    }

    func goBack() async {
        guard path.count > 1 else { return }
        let request = generation
        guard let id = path.previous else { return }
        guard await image(for: id) != nil else { return }
        guard request == generation, path.previous == id else { return }
        path.goBack()
        show(id)
        status = .ready
        replenish()
        Task { await preparePrevious() }
    }

    func commitPreparedBack() -> Bool {
        guard let id = path.previous, cache[id] != nil else { return false }
        path.goBack()
        show(id)
        status = .ready
        replenish()
        Task { await preparePrevious() }
        return true
    }

    func preparePrevious() async -> Bool {
        guard let id = path.previous else { return false }
        let request = generation
        let loaded = await image(for: id)
        guard request == generation, path.previous == id, let loaded else { return false }
        previousImage = loaded
        return true
    }

    func next() async {
        guard !advancing else { return }
        let request = generation
        advancing = true
        defer { if request == generation { advancing = false } }
        let recentViews = PhotoViewHistory.dates(defaults: defaults)
        var skippedRecent = false
        while cursor < queue.count {
            let id = queue[cursor]
            cursor += 1
            if !ignoresRecentForRound && PhotoViewHistory.isRecent(id, in: recentViews) {
                skippedRecent = true
                continue
            }
            if unavailableIDs.contains(id) || seenThisRound.contains(id) {
                continue
            }
            let loaded = await image(for: id)
            guard request == generation else { return }
            guard let image = loaded else {
                unavailableIDs.insert(id)
                continue
            }
            // Another viewer may have shown an image while it was preparing.
            if !ignoresRecentForRound && PhotoViewHistory.isRecent(id, defaults: defaults) {
                skippedRecent = true
                continue
            }
            path.append(id)
            seenThisRound.insert(id)
            cache[id] = image
            show(id)
            status = .ready
            replenish()
            return
        }
        status = currentID == nil && !skippedRecent ? .unavailable : .exhausted
        preparedNextID = nil
    }

    /// Decode the next eligible image before moving the canvas. This keeps a
    /// quick swipe from exposing an empty neighbor while preloading catches up.
    func prepareNext() async -> Bool {
        refreshPreparedCandidate()
        if nextImage != nil { return true }
        let request = generation
        let recentViews = PhotoViewHistory.dates(defaults: defaults)
        for id in queue[cursor...] {
            if unavailableIDs.contains(id) || seenThisRound.contains(id)
                || (!ignoresRecentForRound && PhotoViewHistory.isRecent(id, in: recentViews)) {
                continue
            }
            let loaded = await image(for: id)
            guard request == generation else { return false }
            guard loaded != nil else {
                unavailableIDs.insert(id)
                continue
            }
            if !ignoresRecentForRound && PhotoViewHistory.isRecent(id, defaults: defaults) { continue }
            preparedNextID = id
            return true
        }
        return false
    }

    func commitPreparedNext() -> Bool {
        guard let id = preparedNextID,
              let index = queue[cursor...].firstIndex(of: id),
              let image = cache[id],
              !seenThisRound.contains(id),
              (ignoresRecentForRound || !PhotoViewHistory.isRecent(id, defaults: defaults)) else { return false }
        cursor = index + 1
        path.append(id)
        seenThisRound.insert(id)
        cache[id] = image
        show(id)
        status = .ready
        replenish()
        return true
    }

    func restartRound() async {
        ignoresRecentForRound = true
        seenThisRound = []
        queue = Array(photos.keys).shuffled()
        cursor = 0
        status = .ready
        await next()
    }

    func didDisplayCurrent(_ id: String) {
        guard currentID == id, currentImage != nil else { return }
        PhotoViewHistory.record(id, defaults: defaults)
    }

    private func show(_ id: String) {
        guard let image = cache[id] else { return }
        currentID = id
        currentImage = image
        currentDisplayDate = photos[id]?.displayDate ?? ""
        canGoBack = path.count > 1
        previousImage = path.previous.flatMap { cache[$0] }
        preparedNextID = nil
    }

    private func image(for id: String) async -> NSImage? {
        if let cached = cache[id] { return cached }
        guard let photo = photos[id] else { return nil }
        let request = generation
        let paths = [photo.path, photo.fallbackPath].compactMap { $0 }
        let result = await Task.detached(priority: .utility) { () -> PreparedImage? in
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 3200,
                kCGImageSourceShouldCacheImmediately: true
            ]
            for path in paths {
                guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                      let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                    continue
                }
                return PreparedImage(image: NSImage(cgImage: cgImage, size: .zero))
            }
            return nil
        }.value
        guard request == generation else { return nil }
        if let result { cache[id] = result.image }
        return result?.image
    }

    private func replenish() {
        guard !preparing else { return }
        let request = generation
        preparing = true
        preloadingTask = Task { @MainActor in
            var lookahead = cursor
            var prepared = 0
            let startingID = currentID
            let recentViews = PhotoViewHistory.dates(defaults: defaults)
            var preparedIDs: [String] = []
            while lookahead < queue.count && prepared < 4 {
                if currentID != startingID { break }
                let id = queue[lookahead]
                lookahead += 1
                if unavailableIDs.contains(id) || seenThisRound.contains(id)
                    || (!ignoresRecentForRound && PhotoViewHistory.isRecent(id, in: recentViews)) {
                    continue
                }
                let loaded = await image(for: id) != nil
                guard request == generation else { return }
                if currentID != startingID { break }
                if loaded {
                    prepared += 1
                    preparedIDs.append(id)
                    if preparedNextID == nil && currentID == startingID
                        && (ignoresRecentForRound || !PhotoViewHistory.isRecent(id, defaults: defaults)) {
                        preparedNextID = id
                    }
                } else {
                    unavailableIDs.insert(id)
                }
            }
            if currentID != startingID {
                preparing = false
                replenish()
                return
            }
            // Keep only the prepared window and nearby backtracking images.
            var retained = Set(path.ids.suffix(3)).union(preparedIDs)
            if let currentID { retained.insert(currentID) }
            if let preparedNextID { retained.insert(preparedNextID) }
            cache = cache.filter { retained.contains($0.key) }
            preparing = false
        }
    }
}
