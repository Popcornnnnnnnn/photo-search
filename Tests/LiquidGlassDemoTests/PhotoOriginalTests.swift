import Foundation
import GRDB
import Testing
@testable import LiquidGlassDemo

@Suite struct PhotoOriginalTests {
    @Test func resolvesOnlyAvailablePhotosIdentifiers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("index.sqlite3").path
        let database = try DatabaseQueue(path: path)
        try database.write { db in
            try db.execute(sql: "CREATE TABLE assets (id TEXT, source_kind TEXT, source_identifier TEXT, is_available INTEGER)")
            try db.execute(sql: "INSERT INTO assets VALUES ('photo', 'apple-photos-full', 'A-B/L0/001', 1)")
            try db.execute(sql: "INSERT INTO assets VALUES ('file', 'file', '/tmp/file.jpg', 1)")
            try db.execute(sql: "INSERT INTO assets VALUES ('gone', 'apple-photos-full', 'C/L0/001', 0)")
            try db.execute(sql: "INSERT INTO assets VALUES ('bad', 'apple-photos-full', ?, 1)", arguments: ["x\nend tell"])
        }
        #expect(try PhotoOriginal.identifier(for: "photo", databasePath: path) == "A-B/L0/001")
        for id in ["file", "gone", "bad", "missing"] {
            #expect(throws: PhotoOriginal.Failure.self) { try PhotoOriginal.identifier(for: id, databasePath: path) }
        }
        #expect(PhotoOriginal.scriptString("a\"b\\c") == "\"a\\\"b\\\\c\"")
    }
}
