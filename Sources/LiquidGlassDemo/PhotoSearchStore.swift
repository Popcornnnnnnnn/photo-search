import Foundation
import GRDB
import Darwin

@Observable
@MainActor
final class PhotoSearchStore {
    var query = ""
    private(set) var submittedQuery = ""
    var timeFilter: PhotoTimeFilter = .all
    private(set) var isLoadingMore = false
    nonisolated static let pageSize = 200
    var section: PhotoSection = .all
    var photos: [IndexedPhoto] = []
    var resultCount = 0
    var selectedID: IndexedPhoto.ID?
    var isViewerPresented = false
    var viewerInfoVisible = false
    var stats: PhotoLibraryStats = .empty
    var isLoading = false
    var errorMessage: String?
    var searchNotice: String?
    var searchNoticeTitle: String?

    @ObservationIgnored private var isReloading = false
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var lastRequestedQuery: String?
    @ObservationIgnored private var lastRequestedSection: PhotoSection?
    @ObservationIgnored private var lastRequestedTimeFilter: PhotoTimeFilter?
    @ObservationIgnored private var lastIndexRevision: String?
    @ObservationIgnored private let databasePath: String

    init(databasePath: String = PhotoSearchDatabase.path) {
        self.databasePath = databasePath
    }

    var hasMore: Bool { submittedQuery.isEmpty && photos.count < resultCount }

    func submit(history: SearchHistoryStore? = nil, encoder: PhotoEncoderStore? = nil) {
        submittedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        history?.record(submittedQuery, section: section)
        reload(encoder: encoder)
    }

    func clearSearch() {
        loadTask?.cancel()
        loadGeneration += 1
        isReloading = false
        isLoading = false
        isLoadingMore = false
        lastRequestedQuery = nil
        query = ""
        submittedQuery = ""
    }

    func refreshIfChanged() async {
        guard submittedQuery.isEmpty, !isReloading, !isLoadingMore else { return }
        let path = databasePath
        let generation = loadGeneration
        do {
            let revision = try await photoSearchBackground { try PhotoSearchDatabase.revision(at: path) }
            guard generation == loadGeneration, revision != lastIndexRevision else { return }
            reload(showLoading: false)
        } catch {
            guard generation == loadGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    func loadMore() async {
        guard hasMore, !isReloading, !isLoadingMore else { return }
        isLoadingMore = true
        let generation = loadGeneration
        let path = databasePath
        let section = section
        let interval = timeFilter.interval()
        let offset = photos.count
        defer { if generation == loadGeneration { isLoadingMore = false } }
        do {
            var output = try await photoSearchBackground {
                try PhotoSearchDatabase.fetch(section: section, databasePath: path,
                                              limit: Self.pageSize, offset: offset, interval: interval)
            }
            guard !Task.isCancelled, generation == loadGeneration else { return }
            if output.indexRevision != lastIndexRevision {
                // A writer commit (or a replaced read connection) requires one
                // consistent prefix, rather than appending offsets to an old page.
                output = try await photoSearchBackground {
                    try PhotoSearchDatabase.fetch(section: section, databasePath: path,
                                                  limit: offset + Self.pageSize, interval: interval)
                }
                guard !Task.isCancelled, generation == loadGeneration else { return }
                photos = output.photos
                if !photos.contains(where: { $0.id == selectedID }) { selectedID = photos.first?.id }
            } else {
                photos.append(contentsOf: output.photos)
            }
            lastIndexRevision = output.indexRevision
            stats = output.stats
            resultCount = output.matchedCount
            errorMessage = nil
        } catch {
            guard generation == loadGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Load older pages only when a deliberate timeline jump needs them.
    func loadForLocation(id: String, capturedAt: String?) async {
        let generation = loadGeneration
        while hasMore, generation == loadGeneration, !Task.isCancelled,
              !photos.contains(where: { $0.id == id }) {
            if let capturedAt, let oldest = photos.last?.capturedAt, oldest < capturedAt { break }
            let count = photos.count
            await loadMore()
            if photos.count == count { break }
        }
    }

    var selectedPhoto: IndexedPhoto? {
        guard let selectedID else { return nil }
        return photos.first { $0.id == selectedID }
    }

    var canSelectPrevious: Bool {
        guard let selectedID, let index = photos.firstIndex(where: { $0.id == selectedID }) else { return false }
        return index > photos.startIndex
    }

    var canSelectNext: Bool {
        guard let selectedID, let index = photos.firstIndex(where: { $0.id == selectedID }) else { return false }
        return index < photos.index(before: photos.endIndex) || hasMore
    }

    var previousPhoto: IndexedPhoto? {
        adjacentPhoto(offset: -1)
    }

    var nextPhoto: IndexedPhoto? {
        adjacentPhoto(offset: 1)
    }

    var selectedPositionLabel: String? {
        guard let selectedID, let index = photos.firstIndex(where: { $0.id == selectedID }) else { return nil }
        return "\(index + 1) of \(submittedQuery.isEmpty ? resultCount : photos.count)"
    }

    func openViewer(for photo: IndexedPhoto? = nil) {
        if let photo { selectedID = photo.id }
        guard selectedPhoto != nil else { return }
        viewerInfoVisible = false
        isViewerPresented = true
    }

    func closeViewer() {
        isViewerPresented = false
        viewerInfoVisible = false
    }

    func moveSelection(by offset: Int) {
        guard !photos.isEmpty else { return }
        let current = selectedID.flatMap { selected in
            photos.firstIndex(where: { $0.id == selected })
        } ?? photos.startIndex
        if offset > 0, current + offset >= photos.count, hasMore {
            let selected = selectedID
            let count = photos.count
            Task {
                await loadMore()
                guard selectedID == selected, photos.count > count else { return }
                moveSelection(by: offset)
            }
            return
        }
        let target = min(max(current + offset, photos.startIndex), photos.index(before: photos.endIndex))
        selectedID = photos[target].id
    }

    private func adjacentPhoto(offset: Int) -> IndexedPhoto? {
        guard let selectedID,
              let current = photos.firstIndex(where: { $0.id == selectedID }) else { return nil }
        let target = current + offset
        guard photos.indices.contains(target) else { return nil }
        return photos[target]
    }

    func reload(showLoading: Bool = true,
                onlyIfChanged: Bool = false, encoder: PhotoEncoderStore? = nil) {
        let requestedQuery = submittedQuery
        let requestedSection = section
        let requestedTimeFilter = timeFilter
        let interval = requestedTimeFilter.interval()
        let path = databasePath
        let browseLimit = onlyIfChanged || showLoading ? Self.pageSize : max(Self.pageSize, photos.count)
        // Explicit submission and a simultaneous filter update reuse one request.
        if onlyIfChanged, requestedQuery == lastRequestedQuery,
           requestedSection == lastRequestedSection, requestedTimeFilter == lastRequestedTimeFilter { return }
        lastRequestedQuery = requestedQuery
        lastRequestedSection = requestedSection
        lastRequestedTimeFilter = requestedTimeFilter
        isLoadingMore = false
        loadTask?.cancel()
        isReloading = true
        loadGeneration += 1
        let generation = loadGeneration
        if showLoading {
            isLoading = true
            searchNotice = nil
            searchNoticeTitle = nil
        }

        loadTask = Task {
            do {
                try Task.checkCancellation()
                let output: PhotoSearchDatabase.Output
                if requestedQuery.isEmpty {
                    output = try await photoSearchBackground {
                        try PhotoSearchDatabase.fetch(section: requestedSection, databasePath: path,
                                                      limit: browseLimit, interval: interval)
                    }
                } else {
                    let queryVector = await visualVector(for: requestedQuery, encoder: encoder)
                    try Task.checkCancellation()
                    output = try await photoSearchBackground {
                        try PhotoSearchEngine.search(query: requestedQuery, section: requestedSection,
                                                     databasePath: path, queryVector: queryVector,
                                                     interval: interval)
                    }
                }
                try Task.checkCancellation()
                guard generation == loadGeneration else { return }
                lastIndexRevision = output.indexRevision
                photos = output.photos
                resultCount = output.matchedCount
                stats = output.stats
                searchNotice = output.notice
                searchNoticeTitle = output.noticeTitle
                if selectedID == nil || !photos.contains(where: { $0.id == selectedID }) {
                    selectedID = photos.first?.id
                }
                errorMessage = nil
                isReloading = false
                isLoading = false
            } catch is CancellationError {
                return
            } catch {
                guard generation == loadGeneration else { return }
                isReloading = false
                errorMessage = error.localizedDescription
                searchNotice = nil
                searchNoticeTitle = nil
                isLoading = false
            }
        }
    }

    /// Query vectors come from the app's own encoder process. When it is not
    /// installed, or the model cannot load, search still runs on text matches.
    private func visualVector(for query: String, encoder: PhotoEncoderStore?) async -> [Float]? {
        guard let encoder, encoder.isAvailable else { return nil }
        guard await encoder.prepare() else { return nil }
        guard !Task.isCancelled else { return nil }
        return await encoder.embed(query)
    }
}

enum PhotoSearchDatabase {
    struct Output: Sendable {
        let photos: [IndexedPhoto]
        let matchedCount: Int
        let stats: PhotoLibraryStats
        var notice: String? = nil
        var noticeTitle: String? = nil
        var indexRevision: String? = nil
    }

    static var path: String {
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) }
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        return URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/PhotoSearch/photo-search.sqlite3")
            .path
    }

    /// Open the live index read-only. The worker keeps the database in WAL mode,
    /// and SQLite needs a read-write file descriptor to coordinate the shared-memory
    /// file, so an OS-level read-only open fails even for SELECT statements. Keep the
    /// connection logically read-only instead: query_only rejects every write while
    /// still allowing it to join the live WAL.
    static func read<T>(at path: String = PhotoSearchDatabase.path, _ body: (Database) throws -> T) throws -> T {
        try readVersioned(at: path) { db, _ in try body(db) }
    }

    static func readVersioned<T>(at path: String = PhotoSearchDatabase.path,
                                 _ body: (Database, String) throws -> T) throws -> T {
        let reader = try PhotoSearchIndex.reader(at: path)
        return try reader.database.read { db in
            let version = try Int.fetchOne(db, sql: "PRAGMA data_version") ?? 0
            return try body(db, "\(reader.identity)|\(version)")
        }
    }

    static func revision(at path: String = PhotoSearchDatabase.path) throws -> String {
        try readVersioned(at: path) { _, revision in revision }
    }

    static func fetch(section: PhotoSection, databasePath: String = PhotoSearchDatabase.path,
                      limit: Int = PhotoSearchStore.pageSize, offset: Int = 0,
                      interval: DateInterval? = nil) throws -> Output {
        try readVersioned(at: databasePath) { db, revision in
            try Task.checkCancellation()
            var conditions: [String] = ["d.asset_id IS NOT NULL", "a.is_available = 1"]
            var arguments: [DatabaseValueConvertible?] = []
            if let assetType = section.assetType {
                conditions.append("d.asset_type = ?")
                arguments.append(assetType)
            }
            if let interval {
                conditions.append("julianday(a.captured_at) >= julianday(?) AND julianday(a.captured_at) < julianday(?)")
                let formatter = ISO8601DateFormatter()
                arguments += [formatter.string(from: interval.start), formatter.string(from: interval.end)]
            }
            let sql = """
                SELECT a.id, a.thumbnail_path, a.file_path, a.filename, a.captured_at,
                       a.width, a.height, a.metadata_json, d.asset_type, d.short_caption,
                       j.model, j.data_json
                FROM assets AS a
                JOIN search_docs AS d ON d.asset_id = a.id
                LEFT JOIN artifacts AS j ON j.asset_id = a.id AND j.kind = 'annotation'
                    AND j.is_active = 1 AND j.input_sha256 = a.sha256
                WHERE \(conditions.joined(separator: " AND "))
                ORDER BY COALESCE(a.captured_at, a.imported_at) DESC, a.id DESC
                LIMIT ? OFFSET ?
                """
            let rows = try Row.fetchAll(db, sql: sql,
                                       arguments: StatementArguments(arguments + [max(1, limit), max(0, offset)]))
            let photos = rows.map { row in
                let annotationJSON: String? = row["data_json"]
                return IndexedPhoto(
                    id: row["id"], thumbnailPath: row["thumbnail_path"], filePath: row["file_path"],
                    filename: row["filename"], capturedAt: row["captured_at"], width: row["width"],
                    height: row["height"], assetType: row["asset_type"], shortCaption: row["short_caption"],
                    model: row["model"], annotation: PhotoAnnotation.decode(annotationJSON),
                    durationSeconds: IndexedPhoto.videoDuration(from: row["metadata_json"])
                )
            }
            let count = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM assets a JOIN search_docs d ON d.asset_id = a.id
                WHERE \(conditions.joined(separator: " AND "))
                """, arguments: StatementArguments(arguments)) ?? 0
            return Output(photos: photos, matchedCount: count, stats: try PhotoSearchEngine.loadStats(db),
                          indexRevision: revision)
        }
    }

    /// Cheap probe for the connection check: is there an index we can actually read?
    /// Opening a missing file would create an empty database, so check first.
    static func isAvailable(at path: String = PhotoSearchDatabase.path) async -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        return await Task.detached(priority: .utility) {
            (try? read(at: path) { db in try db.tableExists("assets") }) ?? false
        }.value
    }
}
