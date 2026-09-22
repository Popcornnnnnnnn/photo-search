import Foundation
import GRDB
import Darwin

@Observable
@MainActor
final class PhotoSearchStore {
    var query = ""
    var section: PhotoSection = .all
    var photos: [IndexedPhoto] = []
    var resultCount = 0
    var selectedID: IndexedPhoto.ID?
    var isViewerPresented = false
    var viewerInfoVisible = false
    var stats: PhotoLibraryStats = .empty
    var isLoading = false
    var errorMessage: String?

    @ObservationIgnored private var loadGeneration = 0

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
        return index < photos.index(before: photos.endIndex)
    }

    var previousPhoto: IndexedPhoto? {
        adjacentPhoto(offset: -1)
    }

    var nextPhoto: IndexedPhoto? {
        adjacentPhoto(offset: 1)
    }

    var selectedPositionLabel: String? {
        guard let selectedID, let index = photos.firstIndex(where: { $0.id == selectedID }) else { return nil }
        return "\(index + 1) of \(photos.count)"
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

    func reload(showLoading: Bool = true) {
        loadGeneration += 1
        let generation = loadGeneration
        let requestedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedSection = section
        if showLoading {
            isLoading = true
        }

        Task {
            do {
                let output = try await Task.detached(priority: .userInitiated) {
                    try PhotoSearchDatabase.fetch(query: requestedQuery, section: requestedSection)
                }.value
                guard generation == loadGeneration else { return }
                photos = output.photos
                resultCount = output.matchedCount
                stats = output.stats
                if selectedID == nil || !photos.contains(where: { $0.id == selectedID }) {
                    selectedID = photos.first?.id
                }
                errorMessage = nil
                isLoading = false
            } catch {
                guard generation == loadGeneration else { return }
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }
}

private enum PhotoSearchDatabase {
    struct Output: Sendable {
        let photos: [IndexedPhoto]
        let matchedCount: Int
        let stats: PhotoLibraryStats
    }

    static var path: String {
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) }
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        return URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/PhotoSearch/photo-search.sqlite3")
            .path
    }

    static func fetch(query: String, section: PhotoSection) throws -> Output {
        var configuration = Configuration()
        // The live worker keeps this database in WAL mode. SQLite needs a
        // read-write file descriptor to coordinate the WAL shared-memory file,
        // so an OS-level read-only open fails even for SELECT statements. Keep
        // the connection logically read-only instead: query_only makes SQLite
        // reject every write while still allowing it to join the live WAL.
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA query_only = ON")
        }
        let database = try DatabaseQueue(path: path, configuration: configuration)

        return try database.read { db in
            var conditions: [String] = ["d.asset_id IS NOT NULL"]
            var arguments: [DatabaseValueConvertible?] = []

            if let assetType = section.assetType {
                conditions.append("d.asset_type = ?")
                arguments.append(assetType)
            }
            let queryTerms = query
                .split(whereSeparator: \Character.isWhitespace)
                .map(String.init)
            for term in queryTerms {
                conditions.append("d.search_text LIKE '%' || ? || '%' COLLATE NOCASE")
                arguments.append(term)
            }

            let sql = """
                SELECT
                    a.id,
                    a.thumbnail_path,
                    a.file_path,
                    a.filename,
                    a.captured_at,
                    a.width,
                    a.height,
                    d.asset_type,
                    d.short_caption,
                    j.model,
                    j.data_json
                FROM assets AS a
                JOIN search_docs AS d ON d.asset_id = a.id
                LEFT JOIN artifacts AS j
                    ON j.asset_id = a.id
                    AND j.kind = 'annotation'
                    AND j.is_active = 1
                WHERE \(conditions.joined(separator: " AND "))
                ORDER BY COALESCE(a.captured_at, a.imported_at) DESC
                """

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
            let photos = rows.map { row in
                let annotationJSON: String? = row["data_json"]
                return IndexedPhoto(
                    id: row["id"],
                    thumbnailPath: row["thumbnail_path"],
                    filePath: row["file_path"],
                    filename: row["filename"],
                    capturedAt: row["captured_at"],
                    width: row["width"],
                    height: row["height"],
                    assetType: row["asset_type"],
                    shortCaption: row["short_caption"],
                    model: row["model"],
                    annotation: PhotoAnnotation.decode(annotationJSON)
                )
            }

            let countSQL = """
                SELECT COUNT(*)
                FROM assets AS a
                JOIN search_docs AS d ON d.asset_id = a.id
                WHERE \(conditions.joined(separator: " AND "))
                """
            let matchedCount = try Int.fetchOne(
                db,
                sql: countSQL,
                arguments: StatementArguments(arguments)
            ) ?? 0

            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM assets") ?? 0
            let indexed = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_docs") ?? 0
            let failed = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM processing_skips") ?? 0
            return Output(
                photos: photos,
                matchedCount: matchedCount,
                stats: .init(total: total, indexed: indexed, failed: failed)
            )
        }
    }
}
