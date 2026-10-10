import Foundation
import GRDB
import Testing
@testable import LiquidGlassDemo

@Suite struct PhotoSearchEngineTests {
    /// Temporary index shaped like the worker's schema, so search runs on the same
    /// tables and columns the Python backend writes.
    struct Fixture {
        let directory: URL
        let path: String
    }

    private func makeFixture() throws -> Fixture {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("photo-search-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("photo-search.sqlite3").path
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE assets (
                    id TEXT PRIMARY KEY,
                    source_kind TEXT NOT NULL,
                    source_identifier TEXT NOT NULL,
                    file_path TEXT NOT NULL,
                    thumbnail_path TEXT NOT NULL,
                    sha256 TEXT NOT NULL,
                    filename TEXT NOT NULL,
                    captured_at TEXT,
                    width INTEGER,
                    height INTEGER,
                    metadata_json TEXT NOT NULL,
                    imported_at TEXT NOT NULL,
                    is_available INTEGER NOT NULL DEFAULT 1
                );
                CREATE TABLE artifacts (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    asset_id TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    producer TEXT NOT NULL,
                    model TEXT NOT NULL DEFAULT '',
                    prompt_version TEXT NOT NULL DEFAULT '',
                    schema_version TEXT NOT NULL DEFAULT '',
                    preprocess_version TEXT NOT NULL DEFAULT '',
                    input_sha256 TEXT NOT NULL,
                    data_json TEXT NOT NULL,
                    raw_text TEXT NOT NULL DEFAULT '',
                    created_at TEXT NOT NULL,
                    is_active INTEGER NOT NULL DEFAULT 1
                );
                CREATE TABLE search_docs (
                    asset_id TEXT PRIMARY KEY,
                    asset_type TEXT NOT NULL DEFAULT 'other',
                    short_caption TEXT NOT NULL DEFAULT '',
                    search_text TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );
                CREATE TABLE processing_skips (
                    asset_id TEXT NOT NULL,
                    stage TEXT NOT NULL,
                    reason TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    PRIMARY KEY(asset_id, stage)
                );
                CREATE TABLE embeddings (
                    asset_id TEXT NOT NULL,
                    namespace TEXT NOT NULL,
                    model TEXT NOT NULL,
                    model_revision TEXT NOT NULL DEFAULT '',
                    prompt_version TEXT NOT NULL DEFAULT '',
                    input_sha256 TEXT NOT NULL,
                    dimensions INTEGER NOT NULL,
                    vector BLOB NOT NULL,
                    created_at TEXT NOT NULL,
                    is_active INTEGER NOT NULL DEFAULT 1,
                    PRIMARY KEY(asset_id, namespace, model, model_revision, prompt_version, input_sha256)
                );
                """)
        }
        try queue.close()
        return Fixture(directory: directory, path: path)
    }

    private func addPhoto(
        _ path: String,
        id: String,
        caption: String,
        assetType: String = "photo",
        capturedAt: String? = nil
    ) throws {
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO assets(
                        id, source_kind, source_identifier, file_path, thumbnail_path, sha256,
                        filename, captured_at, width, height, metadata_json, imported_at, is_available
                    ) VALUES (?, 'file', ?, ?, ?, ?, ?, ?, 100, 100, '{}', ?, 1)
                    """,
                arguments: [id, id, "/unused-\(id).jpg", "/unused-\(id).jpg", id,
                            "\(id).jpg", capturedAt, "2026-01-01T00:00:00Z"]
            )
            try db.execute(
                sql: """
                    INSERT INTO artifacts(
                        asset_id, kind, producer, model, input_sha256, data_json, created_at, is_active
                    ) VALUES (?, 'annotation', 'test', 'test-model', ?, ?, ?, 1)
                    """,
                arguments: [id, id, #"{"asset_type":"\#(assetType)","short_caption":"\#(caption)"}"#,
                            "2026-01-01T00:00:00Z"]
            )
            try db.execute(
                sql: "INSERT INTO search_docs(asset_id, asset_type, short_caption, search_text, updated_at) VALUES (?, ?, ?, ?, ?)",
                arguments: [id, assetType, caption, caption.lowercased(), "2026-01-01T00:00:00Z"]
            )
        }
        try queue.close()
    }

    private func cleanUp(_ fixture: Fixture) {
        try? FileManager.default.removeItem(at: fixture.directory)
    }

    /// Stores one active vector under the pinned contract the engine accepts.
    private func addEmbedding(_ path: String, id: String, vector: [Float], video: Bool = false) throws {
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO embeddings(
                        asset_id, namespace, model, model_revision, prompt_version,
                        input_sha256, dimensions, vector, created_at, is_active
                    ) VALUES (?, ?, 'Qwen/Qwen3-VL-Embedding-2B',
                              '9f2f7e710d6d81056aa5c0a4f04764fec6bb7bda',
                              ?, ?, 2048, ?, ?, 1)
                    """,
                arguments: [id, video ? "video-retrieval-v1" : "image-retrieval-v1",
                            video ? "official-wrapper-393e2978:video-summary-v1"
                                : "official-wrapper-393e2978:document-default-v1",
                            id, vector.withUnsafeBufferPointer { Data(buffer: $0) },
                            "2026-01-01T00:00:00Z"]
            )
        }
        try queue.close()
    }

    /// A query vector close to one axis, matching the shape the encoder returns.
    private func axisVector(_ axis: Int) -> [Float] {
        var vector = [Float](repeating: 0, count: 2048)
        vector[axis] = 1
        return vector
    }

    @Test func passwordSearchRejectsWeakVideoRecallButKeepsTextAndSemanticMatches() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        func vector(_ similarity: Float) -> [Float] {
            var result = axisVector(0)
            result[0] = similarity
            result[1] = sqrt(1 - similarity * similarity)
            return result
        }
        try addPhoto(fixture.path, id: "password-photo", caption: "密码输入框")
        try addEmbedding(fixture.path, id: "password-photo", vector: vector(0.47))
        // Reproduce the measured 0.46 false positive from a cycling video.
        try addPhoto(fixture.path, id: "cycling", caption: "夜间公路自行车骑行", assetType: "video")
        try addEmbedding(fixture.path, id: "cycling", vector: vector(0.46), video: true)
        try addPhoto(fixture.path, id: "weak-video", caption: "户外运动", assetType: "video")
        try addEmbedding(fixture.path, id: "weak-video", vector: vector(0.54), video: true)
        // Preserve video recall without shared words above the separate gate.
        try addPhoto(fixture.path, id: "semantic-video", caption: "登录认证界面", assetType: "video")
        try addEmbedding(fixture.path, id: "semantic-video", vector: vector(0.56), video: true)
        // An exact transcript/OCR hit must survive even with a weak vector.
        try addPhoto(fixture.path, id: "spoken-password", caption: "讲解密码设置步骤", assetType: "video")
        try addEmbedding(fixture.path, id: "spoken-password", vector: vector(0.20), video: true)
        // Image-vector recall has a lower gate than video summaries.
        try addPhoto(fixture.path, id: "semantic-photo", caption: "账号安全窗口")
        try addEmbedding(fixture.path, id: "semantic-photo", vector: vector(0.47))
        try addPhoto(fixture.path, id: "weak-photo", caption: "工伤保险咨询聊天")
        try addEmbedding(fixture.path, id: "weak-photo", vector: vector(0.41))

        let output = try PhotoSearchEngine.search(query: "密码", section: .all,
                                                  databasePath: fixture.path, queryVector: axisVector(0))
        #expect(Set(output.photos.map(\.id)) ==
                Set(["password-photo", "semantic-video", "spoken-password", "semantic-photo"]))
        let videos = try PhotoSearchEngine.search(query: "密码", section: .video,
                                                  databasePath: fixture.path, queryVector: axisVector(0))
        #expect(Set(videos.photos.map(\.id)) == Set(["semantic-video", "spoken-password"]))
    }

    @Test func partialTextEvidencePreservesLowerConfidenceImageRecall() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        let query = "从副驾驶看别人开宝马走在林荫路上"
        let caption = "宝马林荫路"
        let coverage = PhotoSearchEngine.textCoverage(query: query, text: caption)
        #expect(coverage >= 0.25 && coverage < 0.50)
        try addPhoto(fixture.path, id: "car", caption: caption)
        var vector = axisVector(0)
        vector[0] = 0.42
        vector[1] = sqrt(1 - 0.42 * 0.42)
        try addEmbedding(fixture.path, id: "car", vector: vector)
        let output = try PhotoSearchEngine.search(query: query, section: .all,
                                                  databasePath: fixture.path, queryVector: axisVector(0))
        #expect(output.photos.map(\.id) == ["car"])
    }

    @Test func wholeVideoVectorAndTranscriptReturnOneVideoWithDuration() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        try addPhoto(fixture.path, id: "video", caption: "海边骑行", assetType: "video")
        try addPhoto(fixture.path, id: "photo", caption: "海边骑行")
        try addEmbedding(fixture.path, id: "video", vector: axisVector(0))
        let queue = try DatabaseQueue(path: fixture.path)
        try queue.write { db in
            try db.execute(sql: "UPDATE assets SET metadata_json = ? WHERE id='video'",
                           arguments: ["{\"media_type\":\"video\",\"duration_seconds\":65}"])
            try db.execute(sql: "UPDATE search_docs SET search_text = search_text || ' 明天去蓝色灯塔' WHERE asset_id='video'")
            try db.execute(sql: "UPDATE embeddings SET namespace='video-retrieval-v1', prompt_version='official-wrapper-393e2978:video-summary-v1' WHERE asset_id='video'")
        }
        try queue.close()
        let semantic = try PhotoSearchEngine.search(query: "沙滩自行车", section: .video,
                                                    databasePath: fixture.path, queryVector: axisVector(0))
        #expect(semantic.photos.map(\.id) == ["video"])
        #expect(semantic.photos.first?.isVideo == true)
        #expect(semantic.photos.first?.displayDuration == "1:05")
        let spoken = try PhotoSearchEngine.search(query: "蓝色灯塔", section: .all, databasePath: fixture.path)
        #expect(spoken.photos.map(\.id) == ["video"])
        let photos = try PhotoSearchDatabase.fetch(section: .photo, databasePath: fixture.path)
        #expect(photos.photos.map(\.id) == ["photo"])
        let videos = try PhotoSearchDatabase.fetch(section: .video, databasePath: fixture.path)
        #expect(videos.photos.map(\.id) == ["video"])
        #expect(videos.photos.first?.displayDuration == "1:05")
    }

    @Test func queryVectorFindsPhotosWithoutSharedWords() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        try addPhoto(fixture.path, id: "lookalike", caption: "高架水泥柱旁的骑行者")
        try addPhoto(fixture.path, id: "other", caption: "室内桌面")
        try addEmbedding(fixture.path, id: "lookalike", vector: axisVector(0))
        try addEmbedding(fixture.path, id: "other", vector: axisVector(1))

        let output = try PhotoSearchEngine.search(
            query: "桥下休息", section: .all, databasePath: fixture.path,
            queryVector: axisVector(0)
        )

        #expect(output.photos.map(\.id) == ["lookalike"])
        #expect(output.notice == nil)
    }

    @Test func lexicalSearchStillRunsWithoutAQueryVector() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        try addPhoto(fixture.path, id: "lookalike", caption: "高架水泥柱旁的骑行者")
        try addEmbedding(fixture.path, id: "lookalike", vector: axisVector(0))

        let output = try PhotoSearchEngine.search(query: "桥下休息", section: .all,
                                                  databasePath: fixture.path)

        #expect(output.photos.isEmpty)
        #expect(output.notice?.contains("Visual search is unavailable") == true)
    }

    @Test func exactErrorCodeOutranksIncidentalWords() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        try addPhoto(fixture.path, id: "lookalike", caption: "OpenCode editor")
        try addPhoto(fixture.path, id: "correct", caption: "OpenCode ECONNREFUSED")

        let output = try PhotoSearchEngine.search(query: "ECONNREFUSED", section: .all,
                                                  databasePath: fixture.path)

        #expect(output.photos.first?.id == "correct")
    }

    @Test func unknownIdentifierCannotBeSatisfiedByAnIncidentalWord() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        try addPhoto(fixture.path, id: "scene", caption: "An ERROR in an editor")

        let output = try PhotoSearchEngine.search(query: "ZXQ_UNSEEN_942761_ERROR", section: .all,
                                                  databasePath: fixture.path)

        #expect(output.photos.isEmpty)
        #expect(output.noticeTitle == "No sufficiently relevant matches")
    }

    @Test func categoryFilterAppliesBeforeRankingAndLimit() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        try addPhoto(fixture.path, id: "scene", caption: "headphones", assetType: "photo")
        try addPhoto(fixture.path, id: "chat", caption: "headphones discussion",
                     assetType: "chat_screenshot")

        let output = try PhotoSearchEngine.search(query: "headphones", section: .chatScreenshot,
                                                  limit: 1, databasePath: fixture.path)

        #expect(output.photos.map(\.id) == ["chat"])
        #expect(output.photos.first?.annotation != nil)
    }

    @Test func unrelatedQueryReturnsNothingAndSaysSo() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        try addPhoto(fixture.path, id: "scene", caption: "一张普通的照片，骑车的男子")

        let output = try PhotoSearchEngine.search(query: "月球表面弹钢琴的章鱼照片", section: .all,
                                                  databasePath: fixture.path)

        #expect(output.photos.isEmpty)
        #expect(output.noticeTitle == "No sufficiently relevant matches")
        #expect(output.notice?.contains("Visual search is unavailable") == true)
    }

    @Test func rankingPrefersTheNewestCaptureOnTiedScores() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        try addPhoto(fixture.path, id: "older", caption: "桥下骑行",
                     capturedAt: "2020-01-01T00:00:00Z")
        try addPhoto(fixture.path, id: "newer", caption: "桥下骑行",
                     capturedAt: "2026-01-01T00:00:00Z")

        let output = try PhotoSearchEngine.search(query: "桥下骑行", section: .all,
                                                  databasePath: fixture.path)

        #expect(output.photos.map(\.id) == ["newer", "older"])
        #expect(output.stats.indexed == 2)
    }

    @Test func coverageIgnoresSentencePadding() {
        #expect(PhotoSearchEngine.strippedFillers("帮我找那张照片") == "")
        #expect(PhotoSearchEngine.strippedFillers("桥下骑车") == "桥下骑车")
        #expect(PhotoSearchEngine.textCoverage(query: "帮我找那张桥下骑车的照片", text: "桥下骑车") == 1.0)
    }

    @Test func queryTermsKeepWholeChunksAndChineseNgrams() {
        let terms = PhotoSearchEngine.fallbackTerms("桥下骑车")
        #expect(terms.first == "桥下骑车")
        #expect(terms.contains("桥下"))
        #expect(terms.contains("骑车"))
        #expect(Set(terms).count == terms.count)
    }
    private struct RankingFixture: Decodable {
        struct Asset: Decodable {
            let id: String
            let caption: String
            var type: String?
            var capturedAt: String?
            var similarity: Float?
        }
        struct Case: Decodable {
            let id: String
            let query: String
            var hybrid: Bool?
            var section: PhotoSection?
            let assets: [Asset]
            let expected: [String]
        }
        let cases: [Case]
    }

    @Test func sharedRankingCasesMatchTheBackendContract() throws {
        let url = try #require(Bundle.module.url(forResource: "search-ranking", withExtension: "json",
                                                 subdirectory: "Fixtures"))
        let cases = try JSONDecoder().decode(RankingFixture.self, from: Data(contentsOf: url)).cases
        for sample in cases {
            let fixture = try makeFixture()
            defer { cleanUp(fixture) }
            for asset in sample.assets {
                try addPhoto(fixture.path, id: asset.id, caption: asset.caption, assetType: asset.type ?? "photo",
                             capturedAt: asset.capturedAt ?? "2025-01-01T00:00:00Z")
                if let similarity = asset.similarity {
                    var vector = [Float](repeating: 0, count: 2048)
                    vector[0] = similarity
                    vector[1] = sqrt(1 - similarity * similarity)
                    let video = asset.type == "video"
                    try addEmbedding(fixture.path, id: asset.id, vector: vector, video: video)
                }
            }
            let output = try PhotoSearchEngine.search(query: sample.query, section: sample.section ?? .all,
                                                      databasePath: fixture.path,
                                                      queryVector: sample.hybrid == true ? axisVector(0) : nil)
            #expect(output.photos.map(\.id) == sample.expected, "Ranking case: \(sample.id)")
        }
    }

    @Test func yearFiltersUseLocalCalendarBoundaries() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let now = try #require(PhotoWorkerStatus.parseTimestamp("2026-10-08T00:00:00Z"))
        let lastYear = try #require(PhotoTimeFilter.lastYear.interval(now: now, calendar: calendar))
        #expect(lastYear.start == PhotoWorkerStatus.parseTimestamp("2024-12-31T16:00:00Z"))
        #expect(lastYear.end == PhotoWorkerStatus.parseTimestamp("2025-12-31T16:00:00Z"))
        #expect(PhotoTimeFilter.all.interval(now: now, calendar: calendar) == nil)
    }

    @Test func dateFilteringPrecedesRankingAndPagination() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        try addPhoto(fixture.path, id: "older", caption: "headphones", capturedAt: "2024-12-31T23:00:00Z")
        try addPhoto(fixture.path, id: "selected", caption: "headphones", capturedAt: "2025-03-01T00:00:00Z")
        try addPhoto(fixture.path, id: "newer", caption: "headphones", capturedAt: "2026-01-01T00:00:00Z")
        let interval = DateInterval(start: try #require(PhotoWorkerStatus.parseTimestamp("2025-01-01T00:00:00Z")),
                                    end: try #require(PhotoWorkerStatus.parseTimestamp("2026-01-01T00:00:00Z")))
        let result = try PhotoSearchEngine.search(query: "headphones", section: .all, limit: 1,
                                                  databasePath: fixture.path, interval: interval)
        #expect(result.photos.map(\.id) == ["selected"])
        let browse = try PhotoSearchDatabase.fetch(section: .all, databasePath: fixture.path, limit: 1, interval: interval)
        #expect(browse.photos.map(\.id) == ["selected"])
        #expect(browse.matchedCount == 1)
    }

    @Test func customDatesIncludeBothEntireDaysInSearchAndBrowse() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let start = try #require(PhotoWorkerStatus.parseTimestamp("2025-10-07T12:00:00Z"))
        let end = try #require(PhotoWorkerStatus.parseTimestamp("2025-10-08T12:00:00Z"))
        let interval = try #require(PhotoTimeFilter.custom(start: start, end: end).interval(calendar: calendar))
        #expect(interval == PhotoTimeFilter.custom(start: end, end: start).interval(calendar: calendar))
        for (id, date) in [("first", "2025-10-07T00:00:00Z"), ("last", "2025-10-08T23:59:59Z"),
                           ("before", "2025-10-06T23:59:59Z"), ("after", "2025-10-09T00:00:00Z")] {
            try addPhoto(fixture.path, id: id, caption: "calendar", capturedAt: date)
        }
        let result = try PhotoSearchEngine.search(query: "calendar", section: .all, databasePath: fixture.path, interval: interval)
        let browse = try PhotoSearchDatabase.fetch(section: .all, databasePath: fixture.path, interval: interval)
        #expect(Set(result.photos.map(\.id)) == ["first", "last"])
        #expect(Set(browse.photos.map(\.id)) == ["first", "last"])
        #expect(browse.matchedCount == 2)
    }

    @Test func customSingleDayRespectsDaylightSavingChanges() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        for (stamp, hours) in [("2025-03-09T16:00:00Z", 23.0), ("2025-11-02T17:00:00Z", 25.0)] {
            let day = try #require(PhotoWorkerStatus.parseTimestamp(stamp))
            let interval = try #require(PhotoTimeFilter.custom(start: day, end: day).interval(calendar: calendar))
            #expect(interval.duration == hours * 3600)
            #expect(calendar.component(.hour, from: interval.start) == 0)
            #expect(calendar.component(.hour, from: interval.end) == 0)
        }
    }

    @Test func invalidVectorsDoNotBlockCompatibleCandidates() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        try addPhoto(fixture.path, id: "invalid", caption: "desk")
        try addPhoto(fixture.path, id: "valid", caption: "高架水泥柱旁的骑行者")
        try addEmbedding(fixture.path, id: "invalid", vector: [Float](repeating: .nan, count: 2048))
        try addEmbedding(fixture.path, id: "valid", vector: axisVector(0))
        let result = try PhotoSearchEngine.search(query: "桥下休息", section: .all,
                                                  databasePath: fixture.path, queryVector: axisVector(0))
        #expect(result.photos.map(\.id) == ["valid"])
    }

    @Test func pagesAreStableAndReportTheFullFilteredCount() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        for id in ["a", "b", "c", "d", "e"] { try addPhoto(fixture.path, id: id, caption: "headphones") }
        let first = try PhotoSearchDatabase.fetch(section: .all, databasePath: fixture.path, limit: 3)
        let second = try PhotoSearchDatabase.fetch(section: .all, databasePath: fixture.path, limit: 3, offset: 3)
        #expect(first.matchedCount == 5)
        #expect(first.photos.map(\.id) + second.photos.map(\.id) == ["e", "d", "c", "b", "a"])
    }

    @Test func aWriterCommitInvalidatesCachedTextAndVectors() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        try addPhoto(fixture.path, id: "old", caption: "desk")
        try addEmbedding(fixture.path, id: "old", vector: axisVector(1))
        let first = try PhotoSearchEngine.search(query: "headphones", section: .all,
                                                databasePath: fixture.path, queryVector: axisVector(0))
        #expect(first.photos.isEmpty)
        try addPhoto(fixture.path, id: "new", caption: "headphones")
        try addEmbedding(fixture.path, id: "new", vector: axisVector(0))
        let second = try PhotoSearchEngine.search(query: "headphones", section: .all,
                                                 databasePath: fixture.path, queryVector: axisVector(0))
        #expect(second.photos.map(\.id) == ["new"])
        #expect(second.indexRevision != first.indexRevision)
        #expect(second.photos[0].matchEvidence?.textMatched == true)
        #expect(second.photos[0].matchEvidence?.visualMatched == true)
    }

    @MainActor @Test func editingADraftDoesNotChangeTheSubmittedSearch() async throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        try addPhoto(fixture.path, id: "headphones", caption: "headphones", assetType: "photo")
        try addPhoto(fixture.path, id: "desk", caption: "desk", assetType: "photo")
        let store = PhotoSearchStore(databasePath: fixture.path)
        store.query = "headphones"
        store.submit()
        try await waitForSearch(store)
        store.query = "desk"
        store.section = .photo
        store.reload()
        try await waitForSearch(store)
        #expect(store.submittedQuery == "headphones")
        #expect(store.photos.map(\.id) == ["headphones"])
        store.submit()
        try await waitForSearch(store)
        #expect(store.photos.map(\.id) == ["desk"])
    }

    @MainActor @Test func loadingMorePreservesSelectionAndRefreshKeepsLoadedPages() async throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }
        for index in 0..<205 { try addPhoto(fixture.path, id: "id-\(index)", caption: "headphones") }
        let store = PhotoSearchStore(databasePath: fixture.path)
        store.reload()
        try await waitForSearch(store)
        #expect(store.photos.count == 200)
        #expect(store.resultCount == 205)
        let selected = store.selectedID
        await store.loadMore()
        #expect(store.photos.count == 205)
        #expect(store.selectedID == selected)
        #expect(!store.hasMore)
        try addPhoto(fixture.path, id: "new", caption: "headphones", capturedAt: "2026-10-08T00:00:00Z")
        await store.refreshIfChanged()
        // Background refresh does not show a blocking loading state.
        for _ in 0..<200 where store.photos.first?.id != "new" {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.photos.first?.id == "new")
        #expect(store.photos.count == 205)
        #expect(store.resultCount == 206)
        #expect(store.selectedID == selected)
    }

    @MainActor private func waitForSearch(_ store: PhotoSearchStore) async throws {
        for _ in 0..<300 {
            if !store.isLoading { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Search did not finish")
    }

}
