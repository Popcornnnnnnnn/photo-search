import AppKit
import CoreGraphics
import Foundation
import GRDB
import Photos
import Testing
@testable import LiquidGlassDemo

@Suite struct NativeLibraryIndexerTests {
    private struct Fixture {
        let directory: URL
        let dbPath: String
        let previewsDir: URL
    }

    private func makeFixture() throws -> Fixture {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("native-indexer-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dbPath = directory.appendingPathComponent("photo-search.sqlite3").path
        let previewsDir = directory.appendingPathComponent("imports/photos-full", isDirectory: true)
        return Fixture(directory: directory, dbPath: dbPath, previewsDir: previewsDir)
    }

    private func cleanUp(_ fixture: Fixture) {
        try? FileManager.default.removeItem(at: fixture.directory)
    }

    private func renderTextJPEG(lines: [String]) throws -> Data {
        let width = 800
        let height = 360
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 44),
            .foregroundColor: NSColor.black
        ]
        for (idx, line) in lines.enumerated() {
            let y = CGFloat(height - 95 - idx * 80)
            NSString(string: line).draw(at: NSPoint(x: 48, y: y), withAttributes: attributes)
        }
        NSGraphicsContext.restoreGraphicsState()

        return try #require(rep.representation(using: .jpeg, properties: [.compressionFactor: 0.95]))
    }

    @Test func ensureSchemaCreatesBackendCompatibleTables() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }

        try PhotoSearchDatabase.ensureSchema(at: fixture.dbPath, previewsDirectory: fixture.previewsDir)

        #expect(FileManager.default.fileExists(atPath: fixture.dbPath))
        #expect(FileManager.default.fileExists(atPath: fixture.previewsDir.path))

        let queue = try DatabaseQueue(path: fixture.dbPath)
        defer { try? queue.close() }
        try queue.read { db in
            let expectedTables = [
                "assets", "artifacts", "embeddings",
                "search_docs", "search_fts",
                "processing_errors", "processing_skips"
            ]
            for name in expectedTables {
                #expect(try db.tableExists(name), "Missing table \(name)")
            }
            let version = try Int.fetchOne(db, sql: "PRAGMA user_version")
            #expect(version == 2)
            let journalMode = try String.fetchOne(db, sql: "PRAGMA journal_mode")?.lowercased()
            #expect(journalMode == "wal")
        }
    }

    @Test func ensureSchemaMigratesLegacyV0DatabaseAndRebuildsStaleFTS() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }

        let seedQueue = try DatabaseQueue(path: fixture.dbPath)
        try seedQueue.write { db in
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
                    imported_at TEXT NOT NULL
                );
                CREATE TABLE embeddings (
                    asset_id TEXT NOT NULL,
                    namespace TEXT NOT NULL,
                    model TEXT NOT NULL,
                    model_revision TEXT NOT NULL DEFAULT '',
                    prompt_version TEXT NOT NULL DEFAULT '',
                    dimensions INTEGER NOT NULL,
                    vector BLOB NOT NULL,
                    created_at TEXT NOT NULL,
                    is_active INTEGER NOT NULL DEFAULT 1,
                    PRIMARY KEY(asset_id, namespace, model, model_revision, prompt_version)
                );
                CREATE TABLE search_docs (
                    asset_id TEXT PRIMARY KEY,
                    asset_type TEXT NOT NULL DEFAULT 'other',
                    short_caption TEXT NOT NULL DEFAULT '',
                    search_text TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );
                CREATE VIRTUAL TABLE search_fts USING fts5(
                    asset_id UNINDEXED,
                    search_text,
                    tokenize='trigram'
                );
                INSERT INTO assets(
                    id, source_kind, source_identifier, file_path, thumbnail_path, sha256,
                    filename, metadata_json, imported_at
                ) VALUES ('legacy-1', 'file', 'src-1', '/tmp/l.jpg', '/tmp/l.jpg', 'legacy-sha',
                          'l.jpg', '{}', '2025-01-01T00:00:00Z');
                INSERT INTO embeddings(
                    asset_id, namespace, model, model_revision, prompt_version, dimensions, vector, created_at
                ) VALUES ('legacy-1', 'image-retrieval-v1', 'm', 'r', 'p', 2, X'0000803f00000000', '2025-01-01T00:00:00Z');
                INSERT INTO search_docs(asset_id, asset_type, short_caption, search_text, updated_at)
                VALUES ('legacy-1', 'photo', 'Migrated glacier peak', 'migrated glacier peak', '2025-01-01T00:00:00Z');
                INSERT INTO search_fts(asset_id, search_text) VALUES ('stale-id', 'stale token');
                PRAGMA user_version = 0;
                """)
        }
        try seedQueue.close()

        try PhotoSearchDatabase.ensureSchema(at: fixture.dbPath, previewsDirectory: fixture.previewsDir)

        let queue = try DatabaseQueue(path: fixture.dbPath)
        defer { try? queue.close() }
        try queue.read { db in
            let version = try Int.fetchOne(db, sql: "PRAGMA user_version")
            #expect(version == 2)

            let assetColumns = try Row.fetchAll(db, sql: "PRAGMA table_info(assets)").map { $0["name"] as String }
            #expect(assetColumns.contains("is_available"))

            let embeddingSHA = try String.fetchOne(
                db,
                sql: "SELECT input_sha256 FROM embeddings WHERE asset_id = 'legacy-1'"
            )
            #expect(embeddingSHA == "legacy-sha")

            let ftsIDs = try String.fetchAll(db, sql: "SELECT asset_id FROM search_fts")
            #expect(ftsIDs == ["legacy-1"])
        }
    }

    @Test func indexesRenderedImageWithVisionOCRAndSearchFindsItViaFTS5() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }

        let jpeg = try renderTextJPEG(lines: ["BOARDING PASS", "TOKYO 2026"])
        let metadata = NativeAssetMetadata(
            assetID: "native-pass-1",
            sourceIdentifier: "LOCAL-UUID-1",
            filename: "IMG_2026.JPG",
            capturedAt: "2026-11-24T01:00:00Z",
            width: 800,
            height: 360,
            isVideo: false,
            isScreenshot: false,
            durationSeconds: nil
        )

        let inserted = try NativeLibraryIndexer.indexImageData(
            jpeg,
            metadata: metadata,
            databasePath: fixture.dbPath,
            previewsDirectory: fixture.previewsDir
        )
        #expect(inserted)

        // Idempotent second call must skip cleanly without overwriting.
        let insertedAgain = try NativeLibraryIndexer.indexImageData(
            jpeg,
            metadata: metadata,
            databasePath: fixture.dbPath,
            previewsDirectory: fixture.previewsDir
        )
        #expect(!insertedAgain)

        let previewFile = fixture.previewsDir.appendingPathComponent("native-pass-1.jpg")
        #expect(FileManager.default.fileExists(atPath: previewFile.path))

        let queue = try DatabaseQueue(path: fixture.dbPath)
        try queue.read { db in
            let storedText = try #require(
                try String.fetchOne(db, sql: "SELECT search_text FROM search_docs WHERE asset_id = 'native-pass-1'")
            )
            #expect(storedText == storedText.lowercased())
        }
        try queue.close()

        let engineOutput = try PhotoSearchEngine.search(
            query: "BOARDING PASS",
            section: .all,
            limit: 10,
            databasePath: fixture.dbPath
        )
        #expect(engineOutput.photos.count == 1)
        #expect(engineOutput.photos.first?.id == "native-pass-1")

        let bridgeResponse = PhotoSearchBridgeHandler.executeSynchronously(
            BridgeRequest(op: "search", query: "TOKYO 2026", section: "all", limit: 10, mode: "lexical"),
            databasePath: fixture.dbPath
        )
        #expect(bridgeResponse.ok)
        #expect(bridgeResponse.items?.count == 1)
        #expect(bridgeResponse.items?.first?.id == "native-pass-1")
    }

    @Test func preservesExistingAssetsAndEmbeddingsWhenSearchDocsMissing() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }

        try PhotoSearchDatabase.ensureSchema(at: fixture.dbPath, previewsDirectory: fixture.previewsDir)
        let assetID = "photos-preembedded"
        let originalPath = "/tmp/python-1600-preview.jpg"
        let originalSHA = "python-full-1600-sha"
        let originalMeta = #"{"media_type":"image","source_modified_at":"2026-10-01T12:00:00Z"}"#

        let queue = try DatabaseQueue(path: fixture.dbPath)
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO assets(
                        id, source_kind, source_identifier, file_path, thumbnail_path,
                        sha256, filename, captured_at, width, height, metadata_json, imported_at, is_available
                    ) VALUES (?, 'apple-photos-full', 'LOCAL-EMB', ?, ?, ?, 'IMG_99.JPG',
                              '2026-10-01T12:00:00Z', 1600, 1200, ?, '2026-10-01T12:00:00Z', 1)
                    """,
                arguments: [assetID, originalPath, originalPath, originalSHA, originalMeta]
            )
            try db.execute(
                sql: """
                    INSERT INTO embeddings(
                        asset_id, namespace, model, model_revision, prompt_version,
                        input_sha256, dimensions, vector, created_at, is_active
                    ) VALUES (?, 'image-retrieval-v1', 'Qwen/Qwen3-VL-Embedding-2B', 'rev1', 'p1', ?, 2,
                              X'0000803f00000000', '2026-10-01T12:00:00Z', 1)
                    """,
                arguments: [assetID, originalSHA]
            )
        }
        try queue.close()

        let jpeg = try renderTextJPEG(lines: ["RECEIPT 8842"])
        let metadata = NativeAssetMetadata(
            assetID: assetID,
            sourceIdentifier: "LOCAL-EMB",
            filename: "IMG_99.JPG",
            capturedAt: "2026-10-01T12:00:00Z",
            width: 1024,
            height: 768,
            isVideo: false,
            isScreenshot: false,
            durationSeconds: nil
        )

        let inserted = try NativeLibraryIndexer.indexImageData(
            jpeg,
            metadata: metadata,
            databasePath: fixture.dbPath,
            previewsDirectory: fixture.previewsDir
        )
        #expect(inserted)

        // Should NOT write a duplicate 1024px preview when Python's assets row already exists.
        let competingPreview = fixture.previewsDir.appendingPathComponent("\(assetID).jpg")
        #expect(!FileManager.default.fileExists(atPath: competingPreview.path))

        let verifyQueue = try DatabaseQueue(path: fixture.dbPath)
        defer { try? verifyQueue.close() }
        try verifyQueue.read { db in
            let row = try #require(
                try Row.fetchOne(db, sql: "SELECT sha256, file_path, metadata_json FROM assets WHERE id = ?", arguments: [assetID])
            )
            #expect((row["sha256"] as String) == originalSHA)
            #expect((row["file_path"] as String) == originalPath)
            #expect((row["metadata_json"] as String) == originalMeta)

            let artifactInputSHA = try String.fetchOne(
                db,
                sql: "SELECT input_sha256 FROM artifacts WHERE asset_id = ? AND is_active = 1",
                arguments: [assetID]
            )
            #expect(artifactInputSHA == originalSHA)

            let activeEmbeddings = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM embeddings e JOIN assets a ON a.id = e.asset_id
                    WHERE e.asset_id = ? AND e.is_active = 1 AND e.input_sha256 = a.sha256
                    """,
                arguments: [assetID]
            )
            #expect(activeEmbeddings == 1)
        }
    }

    @Test func doesNotOverwriteExistingActiveAnnotation() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }

        try PhotoSearchDatabase.ensureSchema(at: fixture.dbPath, previewsDirectory: fixture.previewsDir)

        let existingID = "photos-qwen-existing"
        let pendingDocID = "photos-qwen-annotation-only"
        let originalCaption = "Golden retriever running across a sunset beach"
        let queue = try DatabaseQueue(path: fixture.dbPath)
        try queue.write { db in
            for id in [existingID, pendingDocID] {
                try db.execute(
                    sql: """
                        INSERT INTO assets(
                            id, source_kind, source_identifier, file_path, thumbnail_path,
                            sha256, filename, captured_at, width, height, metadata_json, imported_at, is_available
                        ) VALUES (?, 'apple-photos-full', ?, '/tmp/q.jpg', '/tmp/q.jpg', 'abc123',
                                  'q.jpg', '2026-10-01T12:00:00Z', 100, 100, '{}', '2026-10-01T12:00:00Z', 1)
                        """,
                    arguments: [id, "LOCAL-\(id)"]
                )
                try db.execute(
                    sql: """
                        INSERT INTO artifacts(
                            asset_id, kind, producer, model, input_sha256, data_json, created_at, is_active
                        ) VALUES (?, 'annotation', 'qwen-vlm', 'qwen3.8-27b-fp8', 'abc123', ?, '2026-10-01T12:00:00Z', 1)
                        """,
                    arguments: [id, #"{"asset_type":"photo","short_caption":"Golden retriever running across a sunset beach"}"#]
                )
            }
            try db.execute(
                sql: "INSERT INTO search_docs(asset_id, asset_type, short_caption, search_text, updated_at) VALUES (?, 'photo', ?, ?, '2026-10-01T12:00:00Z')",
                arguments: [existingID, originalCaption, originalCaption.lowercased()]
            )
            try db.execute(
                sql: "INSERT INTO search_fts(asset_id, search_text) VALUES (?, ?)",
                arguments: [existingID, originalCaption.lowercased()]
            )
        }
        try queue.close()

        let jpeg = try renderTextJPEG(lines: ["OVERWRITE ATTEMPT"])
        for id in [existingID, pendingDocID] {
            let metadata = NativeAssetMetadata(
                assetID: id,
                sourceIdentifier: "LOCAL-\(id)",
                filename: "q.jpg",
                capturedAt: "2026-10-01T12:00:00Z",
                width: 800,
                height: 360,
                isVideo: false,
                isScreenshot: false,
                durationSeconds: nil
            )
            let inserted = try NativeLibraryIndexer.indexImageData(
                jpeg,
                metadata: metadata,
                databasePath: fixture.dbPath,
                previewsDirectory: fixture.previewsDir
            )
            #expect(!inserted)
            #expect(!FileManager.default.fileExists(atPath: fixture.previewsDir.appendingPathComponent("\(id).jpg").path))
        }

        let verifyQueue = try DatabaseQueue(path: fixture.dbPath)
        defer { try? verifyQueue.close() }
        try verifyQueue.read { db in
            let storedCaption = try String.fetchOne(
                db,
                sql: "SELECT short_caption FROM search_docs WHERE asset_id = ?",
                arguments: [existingID]
            )
            #expect(storedCaption == originalCaption)

            let producers = try String.fetchAll(
                db,
                sql: "SELECT producer FROM artifacts WHERE asset_id = ? AND is_active = 1",
                arguments: [pendingDocID]
            )
            #expect(producers == ["qwen-vlm"])
        }
    }

    @Test func rejectsInvalidImageDataWithoutCreatingOrphanFiles() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }

        let metadata = NativeAssetMetadata(
            assetID: "corrupt-1",
            sourceIdentifier: "LOCAL-CORRUPT",
            filename: "broken.jpg",
            capturedAt: nil,
            width: 100,
            height: 100,
            isVideo: false,
            isScreenshot: false,
            durationSeconds: nil
        )

        #expect(throws: NativeIndexerError.self) {
            try NativeLibraryIndexer.indexImageData(
                Data("not-an-image".utf8),
                metadata: metadata,
                databasePath: fixture.dbPath,
                previewsDirectory: fixture.previewsDir
            )
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.previewsDir.appendingPathComponent("corrupt-1.jpg").path))
    }

    @Test func assetTypeClassificationHandlesVideosScreenshotsDocumentsAndPhotos() {
        #expect(
            NativeLibraryIndexer.classifyAssetType(
                isVideo: true,
                isScreenshot: false,
                labels: ["outdoor"],
                ocrText: "LONG TEXT THAT SHOULD NOT OVERRIDE VIDEO"
            ) == "video"
        )
        #expect(
            NativeLibraryIndexer.classifyAssetType(
                isVideo: false,
                isScreenshot: true,
                labels: ["document"],
                ocrText: "System Settings"
            ) == "ui_screenshot"
        )
        #expect(
            NativeLibraryIndexer.classifyAssetType(
                isVideo: false,
                isScreenshot: false,
                labels: ["paper", "receipt"],
                ocrText: "Total 42.00"
            ) == "document"
        )
        #expect(
            NativeLibraryIndexer.classifyAssetType(
                isVideo: false,
                isScreenshot: false,
                labels: ["landscape"],
                ocrText: "Invoice #2026-11-24 Total Amount Due Soon"
            ) == "document"
        )
        #expect(
            NativeLibraryIndexer.classifyAssetType(
                isVideo: false,
                isScreenshot: false,
                labels: ["interior design", "furniture"],
                ocrText: ""
            ) == "photo"
        )
        #expect(
            NativeLibraryIndexer.classifyAssetType(
                isVideo: false,
                isScreenshot: false,
                labels: ["dog", "outdoor"],
                ocrText: ""
            ) == "photo"
        )
    }

    @MainActor
    @Test func indexerStoreGuardsAuthorizationAndStopsSafely() {
        let denied = NativeIndexerStore(authorizationStatus: .denied)
        #expect(!denied.isAuthorized)
        #expect(!denied.isBusy)
        denied.stopIndexing()
        #expect(!denied.isIndexing)
    }
}
