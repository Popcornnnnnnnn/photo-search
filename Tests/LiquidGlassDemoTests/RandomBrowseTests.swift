import AppKit
import Foundation
import GRDB
import Testing
@testable import LiquidGlassDemo

@Suite struct RandomBrowseTests {
    @Test func backtrackingDropsTheOldBranch() {
        var path = RandomBrowsePath()
        path.append("A")
        path.append("B")
        path.append("C")
        #expect(path.goBack() == "B")
        path.append("D")
        #expect(path.ids == ["A", "B", "D"])
        #expect(path.goBack() == "B")
        #expect(path.goBack() == "A")
        #expect(path.goBack() == nil)
    }

    @Test @MainActor func sevenDaysAreMeasuredFromEachLastView() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let justInside = now.addingTimeInterval(-PhotoViewHistory.window + 1)
        let boundary = now.addingTimeInterval(-PhotoViewHistory.window)
        #expect(PhotoViewHistory.isRecent(viewed: justInside, at: now))
        #expect(!PhotoViewHistory.isRecent(viewed: boundary, at: now))
        #expect(!PhotoViewHistory.isRecent(viewed: now.addingTimeInterval(1), at: now))
    }

    @Test func libraryLocationUsesExactImageOrItsTimelinePosition() {
        let indexed = [photo("new", "2026-09-02T00:00:00Z"),
                       photo("old", "2026-09-01T00:00:00Z")]
        let exact = PhotoLibraryLocator.find(id: "old", capturedAt: "2020-01-01T00:00:00Z",
                                             in: indexed)
        #expect(exact?.id == "old")
        #expect(exact?.isExact == true)

        let nearby = PhotoLibraryLocator.find(id: "not-indexed",
                                              capturedAt: "2026-09-01T12:00:00Z", in: indexed)
        #expect(nearby?.id == "old")
        #expect(nearby?.isExact == false)
        #expect(PhotoLibraryLocator.find(id: "not-indexed", capturedAt: nil, in: indexed) == nil)
    }

    @Test @MainActor func allRecentlyViewedOffersAnotherRoundButUnreadableImagesDoNot() async throws {
        let fixture = try makeFixture(ids: ["a", "b"])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let suite = "RandomBrowseTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        PhotoViewHistory.record("a", defaults: defaults)
        PhotoViewHistory.record("b", defaults: defaults)

        let store = RandomBrowseStore(databasePath: fixture.databasePath,
                                      defaults: defaults, shufflesQueue: false)
        await store.start()
        #expect(store.status == .exhausted)
        #expect(store.currentID == nil)
        #expect(!store.canGoBack)

        await store.restartRound()
        #expect(store.status == .ready)
        #expect(store.currentID != nil)
        #expect(!store.canGoBack)
        #expect(PhotoViewHistory.isRecent("a", defaults: defaults))
        #expect(PhotoViewHistory.isRecent("b", defaults: defaults))

        let unreadable = try makeFixture(ids: ["broken"], invalidImageIDs: ["broken"])
        defer { try? FileManager.default.removeItem(at: unreadable.directory) }
        let unavailable = RandomBrowseStore(databasePath: unreadable.databasePath,
                                            defaults: defaults, shufflesQueue: false)
        await unavailable.start()
        #expect(unavailable.status == .unavailable)
        #expect(unavailable.currentID == nil)

        let empty = try makeFixture(ids: [])
        defer { try? FileManager.default.removeItem(at: empty.directory) }
        let emptyStore = RandomBrowseStore(databasePath: empty.databasePath,
                                           defaults: defaults, shufflesQueue: false)
        await emptyStore.start()
        #expect(emptyStore.status == .empty)
    }

    @Test @MainActor func preparedWindowSurvivesManySkippedIDsAndBacktrackingBranches() async throws {
        let skipped = (0..<12).map { String(format: "b%02d", $0) }
        let candidates = (0..<4).map { "c\($0)" }
        let fixture = try makeFixture(ids: ["a0"] + skipped + candidates)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let suite = "RandomBrowseTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for id in skipped { PhotoViewHistory.record(id, defaults: defaults) }

        let store = RandomBrowseStore(databasePath: fixture.databasePath,
                                      defaults: defaults, shufflesQueue: false)
        await store.start()
        #expect(store.currentID == "a0")
        #expect(!store.canGoBack)
        await store.preloadingTask?.value
        #expect(store.preparedNextID == "c0")

        // Only images already decoded into the bounded window can survive this.
        for id in candidates.dropFirst() {
            try FileManager.default.removeItem(at: fixture.imagePath(for: id))
        }
        await store.next() // B
        #expect(store.currentID == "c0")
        await store.next() // C
        #expect(store.currentID == "c1")
        await store.next()
        #expect(store.currentID == "c2")
        await store.goBack()
        #expect(store.currentID == "c1")
        await store.next() // D, never replays c2
        #expect(store.currentID == "c3")
        await store.goBack()
        #expect(store.currentID == "c1")
        await store.goBack()
        #expect(store.currentID == "c0")
        await store.goBack()
        #expect(store.currentID == "a0")
        #expect(!store.canGoBack)
    }

    private struct Fixture {
        let directory: URL
        var databasePath: String { directory.appendingPathComponent("photos.sqlite3").path }
        func imagePath(for id: String) -> URL { directory.appendingPathComponent("\(id).png") }
    }

    @MainActor
    private func makeFixture(ids: [String], invalidImageIDs: Set<String> = []) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("random-browse-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = Fixture(directory: directory)

        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))

        let db = try DatabaseQueue(path: fixture.databasePath)
        try db.write { database in
            try database.execute(sql: """
                CREATE TABLE assets (
                    id TEXT PRIMARY KEY, file_path TEXT NOT NULL,
                    thumbnail_path TEXT NOT NULL, filename TEXT NOT NULL,
                    captured_at TEXT, is_available INTEGER NOT NULL
                );
                CREATE TABLE search_docs (
                    asset_id TEXT PRIMARY KEY, asset_type TEXT, short_caption TEXT
                );
                """)
            for id in ids {
                let path = fixture.imagePath(for: id)
                try (invalidImageIDs.contains(id) ? Data("not an image".utf8) : png).write(to: path)
                try database.execute(
                    sql: "INSERT INTO assets VALUES (?, ?, ?, ?, NULL, 1)",
                    arguments: [id, path.path, path.path, id]
                )
            }
        }
        try db.close()
        return fixture
    }

    private func photo(_ id: String, _ capturedAt: String) -> IndexedPhoto {
        IndexedPhoto(id: id, thumbnailPath: "", filePath: "", filename: id,
                     capturedAt: capturedAt, width: nil, height: nil, assetType: "photo",
                     shortCaption: "", model: nil, annotation: nil)
    }
}
