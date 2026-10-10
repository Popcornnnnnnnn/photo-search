import Foundation
import GRDB
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import LiquidGlassDemo

@Suite struct PhotoReviewTests {
    @Test func captionHintsDistinguishWholeSceneProblemsFromBackgroundsAndDocuments() {
        let hints: [(String, String, PhotoReviewReason?)] = [
            ("一张极度模糊的夜间照片，画面中充满了垂直方向的动态光轨和深色阴影。", "photo", .blur),
            ("一张模糊的俯拍照片，显示穿着白色运动鞋的双脚，裤腿为红黄配色。", "photo", .accidental),
            ("一张模糊的室内地面照片，显示灰色水泥地、墙角和一只运动鞋。", "photo", .accidental),
            ("一张几乎全白的空白图像，尺寸极小。", "other", .blank),
            ("一只手拿着背面玻璃严重碎裂的手机，背景是模糊的笔记本电脑键盘。", "photo", nil),
            ("一张夜间手持浅蓝色雪糕的模糊照片，背景可见地面和拍摄者的影子。", "photo", nil),
            ("一名骑行者，背景严重模糊。", "photo", nil),
            ("一张白色背景的证件照。", "photo", nil),
            ("一份包含两个空白甲方签署栏的合同截图。", "document", nil)
        ]
        for (caption, type, expected) in hints {
            #expect(PhotoReviewClassifier.hint(caption: caption, assetType: type) == expected)
        }
    }

    @Test func blankCheckRequiresNeutralUniformPixels() throws {
        #expect(PhotoReviewClassifier.previewIsBlank(try image(color: [1, 1, 1])))
        #expect(PhotoReviewClassifier.previewIsBlank(try image(color: [0.04, 0.04, 0.04])))
        #expect(!PhotoReviewClassifier.previewIsBlank(try image(color: [1, 0, 0])))
        #expect(!PhotoReviewClassifier.previewIsBlank(try image(color: [1, 1, 1], hasText: true)))
    }

    @Test @MainActor func scanAndDecisionsAreReadOnlyPersistentReversibleAndContentScoped() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("photo-review-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("blank.png")
        let destination = try #require(CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try image(color: [1, 1, 1]), nil)
        #expect(CGImageDestinationFinalize(destination))
        let originalBytes = try Data(contentsOf: file)
        let database = directory.appendingPathComponent("index.sqlite3").path
        let writer = try DatabaseQueue(path: database)
        try await writer.write { db in
            try db.execute(sql: """
                CREATE TABLE assets(id TEXT PRIMARY KEY, sha256 TEXT, file_path TEXT, thumbnail_path TEXT,
                    filename TEXT, captured_at TEXT, width INTEGER, height INTEGER, is_available INTEGER,
                    source_kind TEXT DEFAULT 'apple-photos-full', source_identifier TEXT DEFAULT 'test-local-id');
                CREATE TABLE artifacts(asset_id TEXT, kind TEXT, is_active INTEGER, input_sha256 TEXT,
                    model TEXT, data_json TEXT, raw_text TEXT);
                """)
            for id in ["blank", "ocr", "stale", "missing", "hidden"] {
                let path = id == "missing" ? file.path + ".absent" : file.path
                try db.execute(sql: "INSERT INTO assets(id, sha256, file_path, thumbnail_path, filename, captured_at, width, height, is_available) VALUES (?, 'v1', ?, ?, 'sample.png', '2026-09-28T00:00:00Z', 96, 96, ?)",
                               arguments: [id, path, path, id == "hidden" ? 0 : 1])
                let hash = id == "stale" ? "v0" : "v1"
                try db.execute(sql: "INSERT INTO artifacts VALUES (?, 'annotation', 1, ?, 'test', ?, '')",
                               arguments: [id, hash, "{\"asset_type\":\"other\",\"short_caption\":\"一张纯白色的空白图像。\"}"])
            }
            try db.execute(sql: "INSERT INTO artifacts VALUES ('ocr', 'ocr', 1, 'v1', 'test', '{}', 'Invoice 123')")
        }
        let suite = "PhotoReviewTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PhotoReviewStore(databasePath: database, defaults: defaults)
        await store.load()
        #expect(store.error == nil)
        #expect(store.candidates.map(\.id) == ["blank"])
        #expect(store.unavailableCount == 1)
        let candidate = try #require(store.selected)
        store.mark(candidate, as: .marked)
        #expect(store.visibleCandidates.isEmpty)
        #expect(store.count(.marked) == 1)
        let reopened = PhotoReviewStore(databasePath: database, defaults: defaults)
        await reopened.load(selectInitialFilter: true)
        #expect(reopened.filter == .marked)
        #expect(reopened.decision(for: candidate) == .marked)
        reopened.filter = .marked
        reopened.selectFirstIfNeeded()
        #expect(reopened.selected?.id == "blank")
        reopened.mark(candidate, as: .pending)
        reopened.filter = .pending
        reopened.selectFirstIfNeeded()
        #expect(reopened.selected?.id == "blank")
        reopened.mark(candidate, as: .keep)
        try await writer.write { db in
            try db.execute(sql: "UPDATE assets SET sha256 = 'v2' WHERE id = 'blank'")
            try db.execute(sql: "UPDATE artifacts SET input_sha256 = 'v2' WHERE asset_id = 'blank'")
        }
        await reopened.load()
        #expect(reopened.count(.pending) == 1)
        #expect(reopened.count(.keep) == 0)
        #expect(try Data(contentsOf: file) == originalBytes)
        let remainingCount = try await writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM assets") }
        #expect(remainingCount == 5)
    }


    @Test(arguments: ["success", "cancel", "denied", "missing", "stale", "file", "selection", "index-failure"], [false, true])
    @MainActor func deletionUsesExactOriginalAndOnlyHidesAfterSuccess(scenario: String, batch: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("photo-delete-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("preview.png")
        let destination = try #require(CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try image(color: [1, 1, 1]), nil)
        #expect(CGImageDestinationFinalize(destination))
        let originalBytes = try Data(contentsOf: file)
        let database = directory.appendingPathComponent("index.sqlite3").path
        let writer = try DatabaseQueue(path: database)
        let kind = scenario == "file" ? "file" : scenario == "selection" ? "apple-photos-selection" : "apple-photos-full"
        try await writer.write { db in
            try db.execute(sql: """
                CREATE TABLE assets(id TEXT PRIMARY KEY, sha256 TEXT, file_path TEXT, thumbnail_path TEXT,
                    filename TEXT, captured_at TEXT, width INTEGER, height INTEGER, is_available INTEGER,
                    source_kind TEXT, source_identifier TEXT);
                CREATE TABLE artifacts(asset_id TEXT, kind TEXT, is_active INTEGER, input_sha256 TEXT,
                    model TEXT, data_json TEXT, raw_text TEXT);
                """)
            for id in ["first", "second", "third"] {
                try db.execute(sql: "INSERT INTO assets VALUES (?, 'v1', ?, ?, 'preview.png', NULL, 96, 96, 1, ?, ?)",
                               arguments: [id, file.path, file.path, kind, "exact-\(id)/L0/001"])
                try db.execute(sql: "INSERT INTO artifacts VALUES (?, 'annotation', 1, 'v1', 'test', ?, '')",
                               arguments: [id, "{\"asset_type\":\"photo\",\"short_caption\":\"A severely blurred photo\"}"])
            }
            if scenario == "index-failure" {
                try db.execute(sql: "CREATE TRIGGER fail_update BEFORE UPDATE ON assets WHEN OLD.id = '\(batch ? "second" : "first")' BEGIN SELECT RAISE(FAIL, 'test write failure'); END")
            }
        }
        let suite = "PhotoDeletionTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var deleteCalls: [[String]] = []
        let store = PhotoReviewStore(databasePath: database, defaults: defaults) { identifiers in
            deleteCalls.append(identifiers)
            switch scenario {
            case "cancel": throw CancellationError()
            case "denied": throw PhotoLibraryDeletion.Failure.permissionDenied
            case "missing": throw PhotoLibraryDeletion.Failure.missingAsset
            default: break
            }
        }
        await store.load()
        let candidate = try #require(store.selected)
        let second = try #require(store.candidates.first { $0.id == "second" })
        let kept = try #require(store.candidates.first { $0.id == "third" })
        store.mark(kept, as: .keep)
        store.mark(candidate, as: .marked)
        if batch { store.mark(second, as: .marked) }
        await store.load(selectInitialFilter: true)
        #expect(deleteCalls.isEmpty) // Marks never trigger deletion automatically.
        #expect(store.filter == (batch ? .marked : .pending))
        if !batch { store.mark(candidate, as: .pending) }
        store.selectedID = candidate.id
        if scenario == "stale" {
            try await writer.write { db in
                try db.execute(sql: "UPDATE assets SET sha256 = 'v2' WHERE id = ?", arguments: [batch ? "second" : "first"])
            }
        }
        let requested = batch ? store.markedCandidates : [candidate]
        #expect(requested.map(\.id) == (batch ? ["first", "second"] : ["first"]))
        let succeeded = await store.delete(requested)
        let expectedSuccess = scenario == "success" || scenario == "index-failure"
        #expect(succeeded == expectedSuccess)
        #expect(!store.isDeleting)
        let rejectedBeforePhotos = ["file", "selection", "stale"].contains(scenario)
        let expectedIdentifiers = batch ? ["exact-first/L0/001", "exact-second/L0/001"] : ["exact-first/L0/001"]
        #expect(deleteCalls == (rejectedBeforePhotos ? [] : [expectedIdentifiers])) // One batch call, no per-photo loop.
        let available = try await writer.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM assets WHERE is_available = 1 ORDER BY id")
        }
        let remaining = batch ? ["third"] : ["second", "third"]
        #expect(available == (scenario == "success" ? remaining : ["first", "second", "third"]))
        #expect(store.candidates.map(\.id) == (expectedSuccess ? remaining : ["first", "second", "third"]))
        #expect(store.count(.keep) == 1)
        #expect(store.selectedID == (expectedSuccess ? (batch ? nil : "second") : "first"))
        if scenario == "index-failure" {
            #expect(store.deletionMessage?.hasPrefix("Deleted from Photos.") == true)
        } else if scenario == "success" || scenario == "cancel" {
            #expect(store.deletionMessage == nil)
        } else {
            #expect(store.deletionMessage != nil)
        }
        #expect(try Data(contentsOf: file) == originalBytes)
    }

    private func image(color: [CGFloat], hasText: Bool = false) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 96, height: 96, bitsPerComponent: 8,
                                            bytesPerRow: 96 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: color[0], green: color[1], blue: color[2], alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 96, height: 96))
        if hasText {
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(CGRect(x: 10, y: 30, width: 60, height: 3))
        }
        return try #require(context.makeImage())
    }
}
