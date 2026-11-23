import AppKit
import CoreGraphics
import Foundation
import GRDB
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

        let previewFile = fixture.previewsDir.appendingPathComponent("native-pass-1.jpg")
        #expect(FileManager.default.fileExists(atPath: previewFile.path))

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

    @Test func doesNotOverwriteExistingActiveAnnotation() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }

        try PhotoSearchDatabase.ensureSchema(at: fixture.dbPath, previewsDirectory: fixture.previewsDir)

        let existingID = "photos-qwen-existing"
        let originalCaption = "Golden retriever running across a sunset beach"
        let queue = try DatabaseQueue(path: fixture.dbPath)
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO assets(
                        id, source_kind, source_identifier, file_path, thumbnail_path,
                        sha256, filename, captured_at, width, height, metadata_json, imported_at, is_available
                    ) VALUES (?, 'apple-photos-full', 'LOCAL-QWEN', '/tmp/q.jpg', '/tmp/q.jpg', 'abc123',
                              'q.jpg', '2026-10-01T12:00:00Z', 100, 100, '{}', '2026-10-01T12:00:00Z', 1)
                    """,
                arguments: [existingID]
            )
            try db.execute(
                sql: """
                    INSERT INTO artifacts(
                        asset_id, kind, producer, model, input_sha256, data_json, created_at, is_active
                    ) VALUES (?, 'annotation', 'qwen-vlm', 'qwen3.8-27b-fp8', 'abc123', ?, '2026-10-01T12:00:00Z', 1)
                    """,
                arguments: [existingID, #"{"asset_type":"photo","short_caption":"Golden retriever running across a sunset beach"}"#]
            )
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
        let metadata = NativeAssetMetadata(
            assetID: existingID,
            sourceIdentifier: "LOCAL-QWEN",
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
                arguments: [existingID]
            )
            #expect(producers == ["qwen-vlm"])
        }
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
                labels: ["dog", "outdoor"],
                ocrText: ""
            ) == "photo"
        )
    }
}
