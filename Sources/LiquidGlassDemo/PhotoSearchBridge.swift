import Darwin
import Dispatch
import Foundation
import GRDB

enum PhotoSearchBridge {
    static let protocolVersion = 1

    static var defaultSocketPath: String {
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) }
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        return URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/PhotoSearch/search.sock")
            .path
    }
}

struct BridgeRequest: Codable, Sendable {
    var op: String
    var query: String? = nil
    var section: String? = nil
    var time: String? = nil
    var limit: Int? = nil
    var mode: String? = nil
    var loadEncoder: Bool? = nil
    var assetId: String? = nil
}

struct BridgeEncoderStatus: Codable, Sendable, Equatable {
    var available: Bool
    var state: String
    var residentBytes: Int
    var loadProgress: Double
    var loadStage: String
    var lastFailure: String?

    static func unavailable(message: String? = nil) -> Self {
        BridgeEncoderStatus(
            available: false,
            state: "unavailable",
            residentBytes: 0,
            loadProgress: 0,
            loadStage: "",
            lastFailure: message
        )
    }
}

struct BridgePhotoItem: Codable, Sendable, Equatable {
    var id: String
    var filename: String
    var thumbnailPath: String
    var filePath: String
    var capturedAt: String?
    var displayCapturedAt: String?
    var assetType: String
    var displayAssetType: String
    var isVideo: Bool
    var durationSeconds: Double?
    var displayDuration: String?
    var shortCaption: String
    var detailedDescription: String?
    var scene: String?
    var entities: [String]
    var topics: [String]
    var width: Int?
    var height: Int?
    var matchText: Bool
    var matchVisual: Bool
    var matchLabel: String
    var canOpenInPhotos: Bool

    init(photo: IndexedPhoto, canOpenInPhotos: Bool) {
        self.id = photo.id
        self.filename = photo.filename
        self.thumbnailPath = photo.thumbnailPath
        self.filePath = photo.filePath
        self.capturedAt = photo.capturedAt
        self.displayCapturedAt = photo.displayCapturedAt
        self.assetType = photo.assetType
        self.displayAssetType = photo.displayAssetType
        self.isVideo = photo.isVideo
        self.durationSeconds = photo.durationSeconds
        self.displayDuration = photo.displayDuration
        self.shortCaption = photo.shortCaption
        self.detailedDescription = photo.annotation?.detailedDescription
        self.scene = photo.annotation?.scene
        self.entities = photo.annotation?.entities ?? []
        self.topics = photo.annotation?.topics ?? []
        self.width = photo.width
        self.height = photo.height
        self.matchText = photo.matchEvidence?.textMatched ?? false
        self.matchVisual = photo.matchEvidence?.visualMatched ?? false
        self.matchLabel = photo.matchEvidence?.label ?? ""
        self.canOpenInPhotos = canOpenInPhotos
    }
}

struct BridgeResponse: Codable, Sendable {
    var ok: Bool
    var protocolVersion: Int = PhotoSearchBridge.protocolVersion
    var appVersion: String? = AppInfo.versionString
    var error: String? = nil
    var databaseAvailable: Bool? = nil
    var mode: String? = nil
    var visualSearchRan: Bool? = nil
    var matchedCount: Int? = nil
    var elapsedMs: Double? = nil
    var stats: PhotoLibraryStats? = nil
    var encoder: BridgeEncoderStatus? = nil
    var notice: String? = nil
    var noticeTitle: String? = nil
    var items: [BridgePhotoItem]? = nil
}

enum PhotoSearchBridgeHandler {
    private static let photosSourceKinds = [
        "apple-photos",
        "apple-photos-full",
        "apple-photos-benchmark",
    ]

    static func handle(
        _ request: BridgeRequest,
        databasePath: String = PhotoSearchDatabase.path,
        encoder: PhotoEncoderStore? = nil
    ) async -> BridgeResponse {
        let op = request.op.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        switch op {
        case "load":
            guard let encoder else {
                return BridgeResponse(
                    ok: false,
                    error: "The visual search encoder is unavailable in this mode.",
                    encoder: .unavailable()
                )
            }
            let available = await MainActor.run { encoder.isAvailable }
            guard available else {
                let status = await encoderSnapshot(encoder)
                return BridgeResponse(
                    ok: false,
                    error: status.lastFailure ?? "The visual search encoder is not installed.",
                    encoder: status
                )
            }
            // Keep loading detached from request lifetime so an aborted client does
            // not tear down a 4 GB model warm-up mid-flight.
            let ready = await Task { @MainActor in
                await encoder.prepare()
            }.value
            let status = await encoderSnapshot(encoder)
            return BridgeResponse(
                ok: ready,
                error: ready ? nil : (status.lastFailure ?? "Failed to load the visual search encoder."),
                encoder: status
            )

        case "offload":
            guard let encoder else {
                return BridgeResponse(ok: true, encoder: .unavailable())
            }
            await Task { @MainActor in
                await encoder.offload()
            }.value
            let status = await encoderSnapshot(encoder)
            return BridgeResponse(ok: true, encoder: status)

        case "open-in-photos":
            let assetID = (request.assetId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !assetID.isEmpty, assetID.rangeOfCharacter(from: .controlCharacters) == nil else {
                return BridgeResponse(ok: false, error: "Missing or invalid assetId.")
            }
            do {
                try await MainActor.run {
                    try PhotoOriginal.openSynchronously(assetID: assetID, databasePath: databasePath)
                }
                return BridgeResponse(ok: true)
            } catch {
                return BridgeResponse(ok: false, error: error.localizedDescription)
            }

        case "ping", "search":
            let trimmedQuery = (request.query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let requestedMode = (request.mode ?? "hybrid").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let resolvedVector: [Float]?
            if op == "search", !trimmedQuery.isEmpty, requestedMode != "lexical" {
                let loadIfNeeded = request.loadEncoder ?? true
                resolvedVector = await obtainQueryVector(
                    for: trimmedQuery,
                    encoder: encoder,
                    loadIfNeeded: loadIfNeeded
                )
            } else {
                resolvedVector = nil
            }
            let encoderStatus = await encoderSnapshot(encoder)
            do {
                return try await photoSearchBackground {
                    executeSynchronously(
                        request,
                        databasePath: databasePath,
                        queryVector: resolvedVector,
                        encoderStatus: encoderStatus
                    )
                }
            } catch {
                return BridgeResponse(
                    ok: false,
                    error: error.localizedDescription,
                    encoder: encoderStatus
                )
            }

        default:
            let encoderStatus = await encoderSnapshot(encoder)
            return BridgeResponse(
                ok: false,
                error: "Unsupported bridge op: \(request.op)",
                encoder: encoderStatus
            )
        }
    }

    /// Synchronous path used both by `--search-json` CLI (without MainActor hops)
    /// and by `handle` after resolving any query vector on `@MainActor`.
    static func executeSynchronously(
        _ request: BridgeRequest,
        databasePath: String = PhotoSearchDatabase.path,
        queryVector: [Float]? = nil,
        encoderStatus: BridgeEncoderStatus = .unavailable()
    ) -> BridgeResponse {
        let started = DispatchTime.now().uptimeNanoseconds
        let op = request.op.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let dbAvailable = databaseExistsAndReady(at: databasePath)

        switch op {
        case "ping":
            guard dbAvailable else {
                return BridgeResponse(
                    ok: true,
                    databaseAvailable: false,
                    elapsedMs: elapsedMilliseconds(since: started),
                    encoder: encoderStatus
                )
            }
            let stats = try? PhotoSearchDatabase.read(at: databasePath) { db in
                try PhotoSearchEngine.loadStats(db)
            }
            return BridgeResponse(
                ok: true,
                databaseAvailable: true,
                elapsedMs: elapsedMilliseconds(since: started),
                stats: stats,
                encoder: encoderStatus
            )

        case "search":
            guard dbAvailable else {
                return BridgeResponse(
                    ok: false,
                    error: "Photo Search index database not found at \(databasePath).",
                    databaseAvailable: false,
                    elapsedMs: elapsedMilliseconds(since: started),
                    encoder: encoderStatus
                )
            }

            let section = PhotoSection.fromBridgeKey(request.section)
            let timeFilter = PhotoTimeFilter.fromBridgeKey(request.time)
            let interval = timeFilter.interval()
            let limit = min(max(request.limit ?? 40, 1), 200)
            let trimmedQuery = (request.query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

            do {
                let output: PhotoSearchDatabase.Output
                let mode: String
                let visualSearchRan: Bool

                if trimmedQuery.isEmpty {
                    output = try PhotoSearchDatabase.fetch(
                        section: section,
                        databasePath: databasePath,
                        limit: limit,
                        interval: interval
                    )
                    mode = "browse"
                    visualSearchRan = false
                } else {
                    let effectiveVector = (request.mode ?? "hybrid")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased() == "lexical" ? nil : queryVector
                    output = try PhotoSearchEngine.search(
                        query: trimmedQuery,
                        section: section,
                        limit: limit,
                        databasePath: databasePath,
                        queryVector: effectiveVector,
                        interval: interval
                    )
                    visualSearchRan = output.visualSearchRan
                    mode = visualSearchRan ? "hybrid" : "lexical"
                }

                let openableIDs = try photosOpenableIDs(
                    for: output.photos.map(\.id),
                    databasePath: databasePath
                )
                let items = output.photos.map { photo in
                    BridgePhotoItem(
                        photo: photo,
                        canOpenInPhotos: openableIDs.contains(photo.id)
                    )
                }

                return BridgeResponse(
                    ok: true,
                    databaseAvailable: true,
                    mode: mode,
                    visualSearchRan: visualSearchRan,
                    matchedCount: output.matchedCount,
                    elapsedMs: elapsedMilliseconds(since: started),
                    stats: output.stats,
                    encoder: encoderStatus,
                    notice: output.notice,
                    noticeTitle: output.noticeTitle,
                    items: items
                )
            } catch {
                return BridgeResponse(
                    ok: false,
                    error: error.localizedDescription,
                    databaseAvailable: dbAvailable,
                    elapsedMs: elapsedMilliseconds(since: started),
                    encoder: encoderStatus
                )
            }

        default:
            return BridgeResponse(
                ok: false,
                error: "Unsupported synchronous op: \(request.op)",
                databaseAvailable: dbAvailable,
                elapsedMs: elapsedMilliseconds(since: started),
                encoder: encoderStatus
            )
        }
    }

    static func runCLI(args: [String]) -> Int32 {
        let dbPath = value(of: "--db", in: args) ?? PhotoSearchDatabase.path
        let op = args.contains("--ping") ? "ping" : "search"
        let request = BridgeRequest(
            op: op,
            query: value(of: "--query", in: args),
            section: value(of: "--section", in: args),
            time: value(of: "--time", in: args),
            limit: value(of: "--limit", in: args).flatMap(Int.init),
            mode: "lexical"
        )
        let response = executeSynchronously(request, databasePath: dbPath)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(response) else {
            FileHandle.standardOutput.write(Data("{\"ok\":false,\"error\":\"Failed to encode JSON\"}\n".utf8))
            return 1
        }
        FileHandle.standardOutput.write(data + Data([0x0A]))
        return response.ok ? 0 : 1
    }

    // MARK: - Helpers

    private static func databaseExistsAndReady(at path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        return (try? PhotoSearchDatabase.read(at: path) { db in
            try db.tableExists("assets")
        }) ?? false
    }

    private static func photosOpenableIDs(
        for assetIDs: [String],
        databasePath: String
    ) throws -> Set<String> {
        guard !assetIDs.isEmpty else { return [] }
        return try PhotoSearchDatabase.read(at: databasePath) { db in
            let assetPlaceholders = Array(repeating: "?", count: assetIDs.count).joined(separator: ", ")
            let sourcePlaceholders = Array(repeating: "?", count: photosSourceKinds.count).joined(separator: ", ")
            let sql = """
                SELECT id FROM assets
                WHERE id IN (\(assetPlaceholders))
                  AND is_available = 1
                  AND source_kind IN (\(sourcePlaceholders))
                  AND source_identifier != ''
                """
            let args: [DatabaseValueConvertible?] = assetIDs.map { $0 } + photosSourceKinds.map { $0 }
            let rows = try String.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return Set(rows)
        }
    }

    @MainActor
    private static func obtainQueryVector(
        for query: String,
        encoder: PhotoEncoderStore?,
        loadIfNeeded: Bool
    ) async -> [Float]? {
        guard let encoder, encoder.isAvailable else { return nil }
        let ready: Bool
        if encoder.isReady {
            ready = true
        } else if loadIfNeeded {
            ready = await Task { @MainActor in
                await encoder.prepare()
            }.value
        } else {
            ready = false
        }
        guard ready else { return nil }
        return await Task { @MainActor in
            await encoder.embed(query)
        }.value
    }

    @MainActor
    private static func encoderSnapshot(_ encoder: PhotoEncoderStore?) -> BridgeEncoderStatus {
        guard let encoder else { return .unavailable() }
        switch encoder.state {
        case .unavailable(let message):
            return BridgeEncoderStatus(
                available: false,
                state: "unavailable",
                residentBytes: 0,
                loadProgress: 0,
                loadStage: "",
                lastFailure: encoder.lastFailure ?? message
            )
        case .offloaded:
            return BridgeEncoderStatus(
                available: true,
                state: "offloaded",
                residentBytes: 0,
                loadProgress: 0,
                loadStage: "",
                lastFailure: encoder.lastFailure
            )
        case .loading(let progress, let stage):
            return BridgeEncoderStatus(
                available: true,
                state: "loading",
                residentBytes: 0,
                loadProgress: progress,
                loadStage: stage,
                lastFailure: encoder.lastFailure
            )
        case .ready(let bytes):
            return BridgeEncoderStatus(
                available: true,
                state: "ready",
                residentBytes: bytes,
                loadProgress: 1.0,
                loadStage: "Visual search is ready",
                lastFailure: encoder.lastFailure
            )
        }
    }

    private static func elapsedMilliseconds(since startNs: UInt64) -> Double {
        let elapsed = DispatchTime.now().uptimeNanoseconds &- startNs
        return Double(Int((Double(elapsed) / 100_000.0).rounded())) / 10.0
    }

    private static func value(of flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
}

/// Local Unix-domain socket server exposing hybrid search and encoder lifecycle
/// controls to companion tools such as the Raycast extension without duplicating
/// the 4 GB embedding model in memory.
final class PhotoSearchBridgeServer: @unchecked Sendable {
    private static let maxRequestBytes = 64 * 1024

    let socketPath: String
    private let databasePath: String
    private let encoder: PhotoEncoderStore?
    private let idleOffloadInterval: TimeInterval?
    private let shouldIdleOffload: (@Sendable () async -> Bool)?
    private let idleOffloadHandler: (@Sendable () async -> Void)?
    private let acceptQueue = DispatchQueue(label: "photo-search.bridge.accept")
    private let clientQueue = DispatchQueue(label: "photo-search.bridge.client", attributes: .concurrent)
    private let lock = NSLock()
    private var acceptSource: DispatchSourceRead?
    private var idleWorkItem: DispatchWorkItem?
    private var idleGeneration: UInt64 = 0
    private var started = false

    init(
        socketPath: String = PhotoSearchBridge.defaultSocketPath,
        databasePath: String = PhotoSearchDatabase.path,
        encoder: PhotoEncoderStore? = nil,
        idleOffloadInterval: TimeInterval? = nil,
        shouldIdleOffload: (@Sendable () async -> Bool)? = nil,
        idleOffloadHandler: (@Sendable () async -> Void)? = nil
    ) {
        self.socketPath = socketPath
        self.databasePath = databasePath
        self.encoder = encoder
        self.idleOffloadInterval = idleOffloadInterval
        self.shouldIdleOffload = shouldIdleOffload
        self.idleOffloadHandler = idleOffloadHandler
    }

    deinit {
        stop()
    }

    func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }

        let parent = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let maxPathLen = MemoryLayout.size(ofValue: address.sun_path)
        let utf8 = Array(socketPath.utf8)
        guard utf8.count < maxPathLen else {
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            rawBuffer.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in utf8.enumerated() {
                rawBuffer[index] = byte
            }
        }

        let listenFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var closedByCancelHandler = false
        defer {
            if !closedByCancelHandler { Darwin.close(listenFD) }
        }

        _ = Darwin.fcntl(listenFD, F_SETFD, FD_CLOEXEC)
        let flags = Darwin.fcntl(listenFD, F_GETFL, 0)
        if flags >= 0 {
            _ = Darwin.fcntl(listenFD, F_SETFL, flags | O_NONBLOCK)
        }

        Darwin.unlink(socketPath)
        let bindResult = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(listenFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EADDRINUSE)
        }
        _ = Darwin.chmod(socketPath, 0o600)

        guard Darwin.listen(listenFD, 16) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            Darwin.unlink(socketPath)
            throw POSIXError(code)
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: acceptQueue)
        closedByCancelHandler = true
        source.setEventHandler { [weak self] in
            guard let self else { return }
            while true {
                var clientAddr = sockaddr_un()
                var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)
                let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                        Darwin.accept(listenFD, sockaddrPtr, &clientLen)
                    }
                }
                if clientFD < 0 {
                    if errno == EWOULDBLOCK || errno == EAGAIN || errno == EINTR { break }
                    break
                }
                self.configureAndHandleClient(clientFD)
            }
        }
        source.setCancelHandler {
            Darwin.close(listenFD)
        }
        acceptSource = source
        started = true
        source.resume()
    }

    func stop() {
        cancelIdleOffload()
        let sourceToCancel: DispatchSourceRead? = lock.withLock {
            guard started else { return nil }
            started = false
            let src = acceptSource
            acceptSource = nil
            return src
        }
        sourceToCancel?.cancel()
        Darwin.unlink(socketPath)
    }

    func recordEncoderActivity() {
        scheduleIdleOffload()
    }

    private func scheduleIdleOffload() {
        guard let interval = idleOffloadInterval, interval > 0 else { return }
        let workItem: DispatchWorkItem = lock.withLock {
            idleWorkItem?.cancel()
            idleGeneration &+= 1
            let generation = idleGeneration
            var item: DispatchWorkItem!
            item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let isCurrent = self.lock.withLock { () -> Bool in
                    guard self.idleGeneration == generation else { return false }
                    self.idleWorkItem = nil
                    return true
                }
                guard isCurrent else { return }
                let shouldOffload = self.shouldIdleOffload
                let customHandler = self.idleOffloadHandler
                let encoder = self.encoder
                Task.detached(priority: .utility) { [weak self] in
                    if let shouldOffload, !(await shouldOffload()) { return }
                    guard let self else { return }
                    let stillCurrent = self.lock.withLock { self.idleGeneration == generation }
                    guard stillCurrent else { return }
                    if let customHandler {
                        await customHandler()
                    } else if let encoder {
                        let isReady = await MainActor.run { encoder.isReady }
                        if isReady {
                            await encoder.offload()
                            AppLog.app.notice("Auto-offloaded idle visual search encoder")
                        }
                    }
                }
            }
            idleWorkItem = item
            return item
        }
        acceptQueue.asyncAfter(deadline: .now() + interval, execute: workItem)
    }

    private func cancelIdleOffload() {
        let workItem: DispatchWorkItem? = lock.withLock {
            idleGeneration &+= 1
            let work = idleWorkItem
            idleWorkItem = nil
            return work
        }
        workItem?.cancel()
    }

    private func configureAndHandleClient(_ clientFD: Int32) {
        _ = Darwin.fcntl(clientFD, F_SETFD, FD_CLOEXEC)
        // Accepted sockets can inherit O_NONBLOCK from the listening socket on
        // macOS; switch back to blocking mode so large responses do not stop at
        // the 8 KB AF_UNIX send buffer boundary with EAGAIN.
        let clientFlags = Darwin.fcntl(clientFD, F_GETFL, 0)
        if clientFlags >= 0 && (clientFlags & O_NONBLOCK) != 0 {
            _ = Darwin.fcntl(clientFD, F_SETFL, clientFlags & ~O_NONBLOCK)
        }
        var noSigPipe: Int32 = 1
        _ = Darwin.setsockopt(
            clientFD,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = Darwin.setsockopt(
            clientFD,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
        var sendTimeout = timeval(tv_sec: 15, tv_usec: 0)
        _ = Darwin.setsockopt(
            clientFD,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &sendTimeout,
            socklen_t(MemoryLayout<timeval>.size)
        )

        let databasePath = databasePath
        let encoder = encoder
        clientQueue.async { [weak self] in
            let requestResult = Self.readRequest(from: clientFD)
            switch requestResult {
            case .empty:
                Darwin.close(clientFD)
            case .failure(let message):
                Self.writeResponse(BridgeResponse(ok: false, error: message), to: clientFD)
                Darwin.close(clientFD)
            case .request(let request):
                Task.detached(priority: .userInitiated) { [weak self] in
                    let response = await PhotoSearchBridgeHandler.handle(
                        request,
                        databasePath: databasePath,
                        encoder: encoder
                    )
                    if let self {
                        let op = request.op.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        if op == "offload" {
                            self.cancelIdleOffload()
                        } else if (op == "load" && response.ok) || (op == "search" && response.visualSearchRan == true) {
                            self.scheduleIdleOffload()
                        }
                    }
                    Self.writeResponse(response, to: clientFD)
                    Darwin.close(clientFD)
                }
            }
        }
    }

    private enum ReadResult {
        case empty
        case failure(String)
        case request(BridgeRequest)
    }

    private static func readRequest(from fd: Int32) -> ReadResult {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while buffer.count < maxRequestBytes {
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count > 0 {
                if let newline = chunk[..<count].firstIndex(of: 0x0A) {
                    buffer.append(contentsOf: chunk[..<newline])
                    break
                }
                buffer.append(contentsOf: chunk[..<count])
            } else if count == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                return .failure("Failed to read request from socket.")
            }
        }
        if buffer.count >= maxRequestBytes {
            return .failure("Request exceeds maximum size.")
        }
        guard !buffer.isEmpty else { return .empty }
        do {
            let request = try JSONDecoder().decode(BridgeRequest.self, from: buffer)
            return .request(request)
        } catch {
            return .failure("Invalid JSON request: \(error.localizedDescription)")
        }
    }

    private static func writeResponse(_ response: BridgeResponse, to fd: Int32) {
        let jsonEncoder = JSONEncoder()
        jsonEncoder.outputFormatting = [.withoutEscapingSlashes]
        guard var payload = try? jsonEncoder.encode(response) else { return }
        payload.append(0x0A)
        payload.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(fd, base.advanced(by: offset), rawBuffer.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
    }
}
