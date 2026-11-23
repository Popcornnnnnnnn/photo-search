import Darwin
import Foundation
import GRDB
import Testing
@testable import LiquidGlassDemo

@Suite(.serialized) struct PhotoSearchBridgeTests {
    private struct Fixture {
        let directory: URL
        let dbPath: String
        let socketPath: String
    }

    private func makeFixture() throws -> Fixture {
        let shortID = String(UUID().uuidString.prefix(8))
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("psb-\(shortID)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dbPath = directory.appendingPathComponent("photo-search.sqlite3").path
        let socketPath = "/tmp/psb-\(shortID).sock"

        let queue = try DatabaseQueue(path: dbPath)
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
                INSERT INTO assets(
                    id, source_kind, source_identifier, file_path, thumbnail_path, sha256,
                    filename, captured_at, width, height, metadata_json, imported_at, is_available
                ) VALUES
                    ('p1', 'apple-photos-full', 'PH-123/L0/001', '/tmp/p1.jpg', '/tmp/p1-thumb.jpg',
                     's1', 'p1.jpg', '2026-10-01T12:00:00Z', 1600, 1200, '{}', '2026-10-01T12:00:00Z', 1),
                    ('v1', 'file', 'v1', '/tmp/v1.mp4', '/tmp/v1-thumb.jpg',
                     's2', 'v1.mp4', '2026-10-02T12:00:00Z', 1920, 1080, '{"duration_seconds":42.5}', '2026-10-02T12:00:00Z', 1);
                INSERT INTO artifacts(
                    asset_id, kind, producer, model, input_sha256, data_json, created_at, is_active
                ) VALUES
                    ('p1', 'annotation', 'test', 'qwen', 's1',
                     '{"asset_type":"photo","short_caption":"Golden retriever sleeping on a rug","scene":"living room","entities":["dog"]}',
                     '2026-10-01T12:00:00Z', 1),
                    ('v1', 'annotation', 'test', 'qwen', 's2',
                     '{"asset_type":"video","short_caption":"Waves crashing on the rocky beach","topics":["ocean"]}',
                     '2026-10-02T12:00:00Z', 1);
                INSERT INTO search_docs(asset_id, asset_type, short_caption, search_text, updated_at) VALUES
                    ('p1', 'photo', 'Golden retriever sleeping on a rug', 'golden retriever sleeping on a rug dog living room', '2026-10-01T12:00:00Z'),
                    ('v1', 'video', 'Waves crashing on the rocky beach', 'waves crashing on the rocky beach ocean', '2026-10-02T12:00:00Z');
                """)
        }
        try queue.close()
        return Fixture(directory: directory, dbPath: dbPath, socketPath: socketPath)
    }

    private func cleanUp(_ fixture: Fixture) {
        Darwin.unlink(fixture.socketPath)
        try? FileManager.default.removeItem(at: fixture.directory)
    }

    private func sendSocketJSON(_ socketPath: String, json: String) async throws -> BridgeResponse {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
                    guard fd >= 0 else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    defer { Darwin.close(fd) }

                    var recvTimeout = timeval(tv_sec: 10, tv_usec: 0)
                    _ = Darwin.setsockopt(
                        fd, SOL_SOCKET, SO_RCVTIMEO, &recvTimeout,
                        socklen_t(MemoryLayout<timeval>.size)
                    )

                    var addr = sockaddr_un()
                    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
                    addr.sun_family = sa_family_t(AF_UNIX)
                    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                        raw.initializeMemory(as: UInt8.self, repeating: 0)
                        for (idx, byte) in socketPath.utf8.enumerated() {
                            raw[idx] = byte
                        }
                    }
                    let connected = withUnsafePointer(to: &addr) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                            Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                        }
                    }
                    guard connected == 0 else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED)
                    }

                    let payload = Array((json + "\n").utf8)
                    let written = payload.withUnsafeBytes { ptr in
                        Darwin.write(fd, ptr.baseAddress, payload.count)
                    }
                    guard written == payload.count else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }

                    var responseData = Data()
                    var chunk = [UInt8](repeating: 0, count: 4096)
                    while true {
                        let count = Darwin.read(fd, &chunk, chunk.count)
                        if count > 0 {
                            if let nl = chunk[..<count].firstIndex(of: 0x0A) {
                                responseData.append(contentsOf: chunk[..<nl])
                                break
                            }
                            responseData.append(contentsOf: chunk[..<count])
                        } else if count == 0 {
                            break
                        } else if errno == EINTR {
                            continue
                        } else {
                            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ETIMEDOUT)
                        }
                    }
                    continuation.resume(returning: try JSONDecoder().decode(BridgeResponse.self, from: responseData))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    @Test func fetchAssetReturnsSingleAvailableItem() throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }

        let video = try PhotoSearchDatabase.fetchAsset(id: "v1", databasePath: fixture.dbPath)
        #expect(video?.id == "v1")
        #expect(video?.isVideo == true)
        #expect(video?.displayDuration == "0:43")
        #expect(try PhotoSearchDatabase.fetchAsset(id: "missing", databasePath: fixture.dbPath) == nil)
    }

    @Test func handlerHandlesPingBrowseLexicalHybridFallbackAndErrors() async throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }

        let ping = await PhotoSearchBridgeHandler.handle(BridgeRequest(op: "ping"), databasePath: fixture.dbPath)
        #expect(ping.ok)
        #expect(ping.databaseAvailable == true)
        #expect(ping.stats?.total == 2)
        #expect(ping.stats?.indexed == 2)

        let browse = await PhotoSearchBridgeHandler.handle(
            BridgeRequest(op: "search", query: "", section: "video", limit: 10),
            databasePath: fixture.dbPath
        )
        #expect(browse.ok)
        #expect(browse.mode == "browse")
        #expect(browse.items?.count == 1)
        #expect(browse.items?.first?.id == "v1")
        #expect(browse.items?.first?.canOpenInPhotos == false)

        let lexical = await PhotoSearchBridgeHandler.handle(
            BridgeRequest(op: "search", query: "golden retriever", limit: 10, mode: "lexical"),
            databasePath: fixture.dbPath
        )
        #expect(lexical.ok)
        #expect(lexical.mode == "lexical")
        #expect(lexical.visualSearchRan == false)
        #expect(lexical.items?.first?.id == "p1")
        #expect(lexical.items?.first?.canOpenInPhotos == true)
        #expect(lexical.items?.first?.entities == ["dog"])

        // Without an encoder, hybrid falls back cleanly to lexical search.
        let hybridFallback = await PhotoSearchBridgeHandler.handle(
            BridgeRequest(op: "search", query: "rocky beach", limit: 10, mode: "hybrid"),
            databasePath: fixture.dbPath
        )
        #expect(hybridFallback.ok)
        #expect(hybridFallback.mode == "lexical")
        #expect(hybridFallback.visualSearchRan == false)
        #expect(hybridFallback.items?.first?.id == "v1")

        let unsupported = await PhotoSearchBridgeHandler.handle(
            BridgeRequest(op: "unknown"),
            databasePath: fixture.dbPath
        )
        #expect(!unsupported.ok)
    }

    @Test func unixSocketServerRoundTripsAndUnlinksOnStop() async throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }

        let server = PhotoSearchBridgeServer(socketPath: fixture.socketPath, databasePath: fixture.dbPath)
        try server.start()
        #expect(FileManager.default.fileExists(atPath: fixture.socketPath))

        let pong = try await sendSocketJSON(fixture.socketPath, json: #"{"op":"ping"}"#)
        #expect(pong.ok)
        #expect(pong.databaseAvailable == true)
        #expect(pong.stats?.total == 2)

        let search = try await sendSocketJSON(
            fixture.socketPath,
            json: #"{"op":"search","query":"retriever","mode":"lexical","limit":5}"#
        )
        #expect(search.ok)
        #expect(search.items?.count == 1)
        #expect(search.items?.first?.id == "p1")

        server.stop()
        #expect(!FileManager.default.fileExists(atPath: fixture.socketPath))
    }

    @Test func unixSocketServerStreamsResponsesLargerThan8KBBuffer() async throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }

        let longCaption = String(repeating: "sunset over alpine lake ", count: 600)
        let queue = try DatabaseQueue(path: fixture.dbPath)
        try await queue.write { db in
            try db.execute(
                sql: "UPDATE search_docs SET short_caption = ?, search_text = ? WHERE asset_id = 'p1'",
                arguments: [longCaption, "sunset over alpine lake " + longCaption]
            )
        }
        try queue.close()

        let server = PhotoSearchBridgeServer(socketPath: fixture.socketPath, databasePath: fixture.dbPath)
        try server.start()
        defer { server.stop() }

        let large = try await sendSocketJSON(
            fixture.socketPath,
            json: #"{"op":"search","query":"alpine lake","mode":"lexical","limit":5}"#
        )
        #expect(large.ok)
        #expect(large.items?.first?.shortCaption.count == longCaption.count)
    }

    @Test func unixSocketServerIdleOffloadFiresAndCancelsCleanly() async throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }

        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func increment() { lock.withLock { value += 1 } }
            var current: Int { lock.withLock { value } }
        }

        let counter = Counter()
        let server = PhotoSearchBridgeServer(
            socketPath: fixture.socketPath,
            databasePath: fixture.dbPath,
            idleOffloadInterval: 0.2,
            shouldIdleOffload: { true },
            idleOffloadHandler: { counter.increment() }
        )
        try server.start()

        server.recordEncoderActivity()
        try await Task.sleep(for: .milliseconds(100))
        // Resetting activity before 0.2s pushes out the deadline.
        server.recordEncoderActivity()
        try await Task.sleep(for: .milliseconds(120))
        #expect(counter.current == 0)

        try await Task.sleep(for: .milliseconds(250))
        #expect(counter.current == 1)

        // Calling stop() cancels any armed timer cleanly.
        server.recordEncoderActivity()
        server.stop()
        try await Task.sleep(for: .milliseconds(300))
        #expect(counter.current == 1)
    }

    @Test func unstartedServerStopDoesNotUnlinkActiveSocket() async throws {
        let fixture = try makeFixture()
        defer { cleanUp(fixture) }

        let active = PhotoSearchBridgeServer(socketPath: fixture.socketPath, databasePath: fixture.dbPath)
        try active.start()
        defer { active.stop() }
        #expect(FileManager.default.fileExists(atPath: fixture.socketPath))

        let bystander = PhotoSearchBridgeServer(socketPath: fixture.socketPath, databasePath: fixture.dbPath)
        bystander.stop()
        #expect(FileManager.default.fileExists(atPath: fixture.socketPath))

        let pong = try await sendSocketJSON(fixture.socketPath, json: #"{"op":"ping"}"#)
        #expect(pong.ok)
    }
}
