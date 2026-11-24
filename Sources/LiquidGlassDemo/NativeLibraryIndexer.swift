import AppKit
import CoreML
import CryptoKit
import Darwin
import Foundation
import GRDB
import ImageIO
import Photos
import Vision

extension PhotoSearchDatabase {
    /// Creates or migrates the local SQLite index so a clean Mac can start indexing
    /// immediately without running Python setup scripts. Schema and migrations match
    /// `backend/photo_search/db.py` (`PRAGMA user_version = 2`).
    static func ensureSchema(
        at path: String = PhotoSearchDatabase.path,
        previewsDirectory: URL? = nil
    ) throws {
        let dbURL = URL(fileURLWithPath: path)
        let dbDir = dbURL.deletingLastPathComponent()
        let previewsDir = previewsDirectory ?? NativeLibraryIndexer.defaultPreviewsDirectory(databasePath: path)

        let fm = FileManager.default
        try fm.createDirectory(
            at: dbDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fm.createDirectory(
            at: previewsDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        var config = Configuration()
        config.busyMode = .timeout(5.0)
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let queue = try DatabaseQueue(path: path, configuration: config)
        defer { try? queue.close() }

        // WAL mode cannot be changed inside an explicit transaction.
        try queue.inDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }

        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS assets (
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

                CREATE INDEX IF NOT EXISTS assets_sha256_idx ON assets(sha256);
                CREATE INDEX IF NOT EXISTS assets_captured_at_idx ON assets(captured_at);

                CREATE TABLE IF NOT EXISTS artifacts (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
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
                    is_active INTEGER NOT NULL DEFAULT 1,
                    UNIQUE(asset_id, kind, producer, model, prompt_version, schema_version, preprocess_version, input_sha256)
                );

                CREATE INDEX IF NOT EXISTS artifacts_active_idx ON artifacts(asset_id, kind, is_active);

                CREATE TABLE IF NOT EXISTS embeddings (
                    asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
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

                CREATE TABLE IF NOT EXISTS search_docs (
                    asset_id TEXT PRIMARY KEY REFERENCES assets(id) ON DELETE CASCADE,
                    asset_type TEXT NOT NULL DEFAULT 'other',
                    short_caption TEXT NOT NULL DEFAULT '',
                    search_text TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );

                CREATE VIRTUAL TABLE IF NOT EXISTS search_fts USING fts5(
                    asset_id UNINDEXED,
                    search_text,
                    tokenize='trigram'
                );

                CREATE TABLE IF NOT EXISTS processing_errors (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    asset_id TEXT REFERENCES assets(id) ON DELETE CASCADE,
                    stage TEXT NOT NULL,
                    error TEXT NOT NULL,
                    created_at TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS processing_skips (
                    asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
                    stage TEXT NOT NULL,
                    reason TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    PRIMARY KEY(asset_id, stage)
                );
                """)

            let version = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
            if version < 2 {
                if version < 1 {
                    let assetColumns = Set(
                        try Row.fetchAll(db, sql: "PRAGMA table_info(assets)")
                            .map { ($0["name"] as String) }
                    )
                    if !assetColumns.contains("is_available") {
                        try db.execute(
                            sql: "ALTER TABLE assets ADD COLUMN is_available INTEGER NOT NULL DEFAULT 1"
                        )
                    }

                    let embeddingColumns = Set(
                        try Row.fetchAll(db, sql: "PRAGMA table_info(embeddings)")
                            .map { ($0["name"] as String) }
                    )
                    if !embeddingColumns.contains("input_sha256") {
                        try db.execute(sql: "ALTER TABLE embeddings RENAME TO embeddings_legacy")
                        try db.execute(sql: """
                            CREATE TABLE embeddings (
                                asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
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
                            )
                            """)
                        try db.execute(sql: """
                            INSERT INTO embeddings
                            SELECT e.asset_id, e.namespace, e.model, e.model_revision, e.prompt_version,
                                   a.sha256, e.dimensions, e.vector, e.created_at, e.is_active
                            FROM embeddings_legacy e JOIN assets a ON a.id = e.asset_id
                            """)
                        try db.execute(sql: "DROP TABLE embeddings_legacy")
                    }
                }

                try db.execute(sql: "DELETE FROM search_fts")
                try db.execute(sql: """
                    INSERT INTO search_fts(asset_id, search_text)
                    SELECT asset_id, search_text FROM search_docs
                    """)
                try db.execute(sql: "PRAGMA user_version = 2")
            }
        }

        _ = Darwin.chmod(path, 0o600)
    }
}

struct NativeAssetMetadata: Sendable {
    let assetID: String
    let sourceIdentifier: String
    let filename: String
    let capturedAt: String?
    let width: Int
    let height: Int
    let isVideo: Bool
    let isScreenshot: Bool
    let durationSeconds: Double?
}

struct NativeVisionResult: Sendable {
    let ocrText: String
    let labels: [String]
}

enum NativeIndexerError: LocalizedError {
    case invalidImage
    case photosUnauthorized(PHAuthorizationStatus)

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            "Unable to decode image preview data."
        case .photosUnauthorized:
            "Photos access has not been granted yet."
        }
    }
}

enum NativeVisionAnalyzer {
    static func analyze(imageData: Data) throws -> NativeVisionResult {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NativeIndexerError.invalidImage
        }

        let orientation = cgImageOrientation(from: source)
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        let textRequest = makeTextRequest(level: .accurate, cpuOnly: false)
        do {
            try handler.perform([textRequest])
        } catch {
            // Virtualized or headless runners without Metal/ANE can fail on GPU/ANE
            // text recognition; retry on CPU before reporting failure.
            let cpuFallback = makeTextRequest(level: .fast, cpuOnly: true)
            try handler.perform([cpuFallback])
            return NativeVisionResult(
                ocrText: extractOCRText(from: cpuFallback),
                labels: classifyBestEffort(handler: handler)
            )
        }

        return NativeVisionResult(
            ocrText: extractOCRText(from: textRequest),
            labels: classifyBestEffort(handler: handler)
        )
    }

    private static func cgImageOrientation(from source: CGImageSource) -> CGImagePropertyOrientation {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let rawValue = properties[kCGImagePropertyOrientation] as? UInt32,
              let orientation = CGImagePropertyOrientation(rawValue: rawValue) else {
            return .up
        }
        return orientation
    }

    private static func makeTextRequest(
        level: VNRequestTextRecognitionLevel,
        cpuOnly: Bool
    ) -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = level == .accurate
        if cpuOnly,
           let cpuDevice = MLComputeDevice.allComputeDevices.first(where: {
               if case .cpu = $0 { return true }
               return false
           }) {
            request.setComputeDevice(cpuDevice, for: .main)
        }
        let supportedLanguages = (try? request.supportedRecognitionLanguages()) ?? []
        let preferredLanguages = ["zh-Hans", "zh-Hant", "en-US"].filter { supportedLanguages.contains($0) }
        if !preferredLanguages.isEmpty {
            request.recognitionLanguages = preferredLanguages
        }
        return request
    }

    private static func extractOCRText(from request: VNRecognizeTextRequest) -> String {
        let lines = (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return lines.joined(separator: "\n")
    }

    private static func classifyBestEffort(handler: VNImageRequestHandler) -> [String] {
        let classifyRequest = VNClassifyImageRequest()
        try? handler.perform([classifyRequest])
        var seenLabels = Set<String>()
        let labels = (classifyRequest.results ?? [])
            .filter { $0.confidence >= 0.25 }
            .sorted { $0.confidence > $1.confidence }
            .compactMap { observation -> String? in
                let cleaned = observation.identifier
                    .replacingOccurrences(of: "_", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty, seenLabels.insert(cleaned.lowercased()).inserted else {
                    return nil
                }
                return cleaned
            }
            .prefix(10)
        return Array(labels)
    }
}

enum NativeLibraryIndexer {
    static let producer = "apple-vision-native"
    static let model = "apple-vision"
    static let promptVersion = "native-v1"
    static let schemaVersion = "v1"
    static let preprocessVersion = "native-jpeg-1024"

    private static let documentTokens: Set<String> = [
        "document", "documents", "receipt", "receipts", "screenshot", "screenshots",
        "text", "page", "pages", "form", "forms", "invoice", "invoices",
        "paper", "signage", "whiteboard"
    ]

    static func defaultPreviewsDirectory(databasePath: String = PhotoSearchDatabase.path) -> URL {
        URL(fileURLWithPath: databasePath)
            .deletingLastPathComponent()
            .appendingPathComponent("imports/photos-full", isDirectory: true)
    }

    static func stableAssetID(for localIdentifier: String) -> String {
        let digest = SHA256.hash(data: Data(localIdentifier.utf8))
        return "photos-" + digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    static func classifyAssetType(
        isVideo: Bool,
        isScreenshot: Bool,
        labels: [String],
        ocrText: String
    ) -> String {
        if isVideo { return "video" }
        if isScreenshot { return "ui_screenshot" }

        let documentHint = labels.contains { label in
            let tokens = label.lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
            return tokens.contains { documentTokens.contains($0) }
        }
        let trimmedOCR = ocrText.trimmingCharacters(in: .whitespacesAndNewlines)
        if documentHint || trimmedOCR.count >= 24 {
            return "document"
        }
        return "photo"
    }

    static func buildShortCaption(
        assetType: String,
        labels: [String],
        ocrText: String,
        filename: String
    ) -> String {
        let ocrSnippet = ocrText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        let labelSummary = labels.prefix(3).joined(separator: ", ")

        let raw: String
        if assetType == "video" {
            if !ocrSnippet.isEmpty {
                raw = "Video · \(ocrSnippet)"
            } else if !labelSummary.isEmpty {
                raw = "Video · \(labelSummary)"
            } else {
                raw = "Video · \(filename)"
            }
        } else if !labelSummary.isEmpty && !ocrSnippet.isEmpty {
            raw = "\(labelSummary) · \(ocrSnippet)"
        } else if !ocrSnippet.isEmpty {
            raw = ocrSnippet
        } else if !labelSummary.isEmpty {
            raw = labelSummary
        } else {
            raw = filename
        }

        if raw.count <= 160 { return raw }
        return String(raw.prefix(159)) + "…"
    }

    static func buildSearchText(
        filename: String,
        shortCaption: String,
        labels: [String],
        ocrText: String,
        capturedAt: String?,
        assetType: String
    ) -> String {
        var parts: [String] = []
        var seen = Set<String>()
        func append(_ value: String?) {
            guard let value else { return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return }
            parts.append(trimmed)
        }

        append(shortCaption)
        append(ocrText)
        for label in labels { append(label) }
        append(filename)
        append(assetType.replacingOccurrences(of: "_", with: " "))
        if let capturedAt, capturedAt.count >= 10 {
            append(String(capturedAt.prefix(10)))
        }
        return parts.joined(separator: "\n")
    }

    /// Indexes one JPEG preview into `photo-search.sqlite3` using Apple Vision OCR +
    /// classification.
    ///
    /// - Strictly skips any asset that already exists in `search_docs` or owns an
    ///   active non-native `annotation` artifact.
    /// - If an `assets` row already exists (e.g. Python imported the asset and computed
    ///   embeddings/checkpoints prior to VLM annotation), preserves the existing
    ///   `assets` row (`sha256`, preview path, and `metadata_json`) and binds the native
    ///   artifact to `existingAsset.sha256` without writing a duplicate preview file.
    /// - Returns `true` if newly indexed, `false` if skipped.
    @discardableResult
    static func indexImageData(
        _ jpegData: Data,
        metadata: NativeAssetMetadata,
        databasePath: String = PhotoSearchDatabase.path,
        previewsDirectory: URL? = nil,
        existingQueue: DatabaseQueue? = nil
    ) throws -> Bool {
        let resolvedPreviewsDir = previewsDirectory ?? defaultPreviewsDirectory(databasePath: databasePath)
        let queue: DatabaseQueue
        let ownsQueue: Bool
        if let existingQueue {
            queue = existingQueue
            ownsQueue = false
        } else {
            try PhotoSearchDatabase.ensureSchema(at: databasePath, previewsDirectory: resolvedPreviewsDir)
            queue = try openWritableQueue(at: databasePath)
            ownsQueue = true
        }
        defer {
            if ownsQueue { try? queue.close() }
        }

        // Fast pre-check before running Vision OCR/classification.
        let alreadyHandled = try queue.read { db in
            try assetShouldSkip(db, assetID: metadata.assetID)
        }
        if alreadyHandled {
            return false
        }

        let vision = try NativeVisionAnalyzer.analyze(imageData: jpegData)
        let digest = SHA256.hash(data: jpegData)
        let previewSHA256 = digest.map { String(format: "%02x", $0) }.joined()

        let assetType = classifyAssetType(
            isVideo: metadata.isVideo,
            isScreenshot: metadata.isScreenshot,
            labels: vision.labels,
            ocrText: vision.ocrText
        )
        let shortCaption = buildShortCaption(
            assetType: assetType,
            labels: vision.labels,
            ocrText: vision.ocrText,
            filename: metadata.filename
        )
        let searchText = buildSearchText(
            filename: metadata.filename,
            shortCaption: shortCaption,
            labels: vision.labels,
            ocrText: vision.ocrText,
            capturedAt: metadata.capturedAt,
            assetType: assetType
        )
        let now = ISO8601DateFormatter.string(
            from: Date(),
            timeZone: .gmt,
            formatOptions: [.withInternetDateTime, .withFractionalSeconds]
        )

        var assetMeta: [String: Any] = [
            "media_type": metadata.isVideo ? "video" : "photo",
            "is_screenshot": metadata.isScreenshot,
            "source": producer,
            "preprocess_version": preprocessVersion
        ]
        if let duration = metadata.durationSeconds, duration.isFinite, duration >= 0 {
            assetMeta["duration_seconds"] = duration
        }
        let metadataJSONData = try JSONSerialization.data(withJSONObject: assetMeta, options: [.sortedKeys])
        let metadataJSON = String(decoding: metadataJSONData, as: UTF8.self)

        let ocrLines = vision.ocrText
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var annotationPayload: [String: Any] = [
            "asset_type": assetType,
            "short_caption": shortCaption,
            "detailed_description": vision.ocrText.isEmpty ? shortCaption : vision.ocrText,
            "entities": vision.labels,
            "topics": vision.labels,
            "search_terms": vision.labels,
            "observed_facts": Array(ocrLines.prefix(6)),
            "ocr_text": vision.ocrText
        ]
        if metadata.isVideo {
            annotationPayload["scene"] = "Video cover frame"
        }
        let annotationJSONData = try JSONSerialization.data(
            withJSONObject: annotationPayload,
            options: [.sortedKeys]
        )
        let annotationJSON = String(decoding: annotationJSONData, as: UTF8.self)

        var writtenPreviewURL: URL?
        do {
            var didInsert = false
            try queue.write { db in
                // Re-check both guards inside the serialized write transaction (zero TOCTOU).
                if try assetShouldSkip(db, assetID: metadata.assetID) {
                    return
                }

                let existingAssetSHA = try String.fetchOne(
                    db,
                    sql: "SELECT sha256 FROM assets WHERE id = ? LIMIT 1",
                    arguments: [metadata.assetID]
                )

                let inputSHA256: String
                if let existingAssetSHA {
                    // Preserve existing Python-imported preview, sha256, and video metadata
                    // so embeddings and checkpoints stay valid.
                    inputSHA256 = existingAssetSHA
                } else {
                    inputSHA256 = previewSHA256
                    let fm = FileManager.default
                    try fm.createDirectory(
                        at: resolvedPreviewsDir,
                        withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700]
                    )
                    let safeFileBase = sanitizedFilenameComponent(metadata.assetID)
                    let previewURL = resolvedPreviewsDir.appendingPathComponent("\(safeFileBase).jpg")
                    try jpegData.write(to: previewURL, options: .atomic)
                    _ = Darwin.chmod(previewURL.path, 0o600)
                    writtenPreviewURL = previewURL

                    try db.execute(
                        sql: """
                            INSERT INTO assets(
                                id, source_kind, source_identifier, file_path, thumbnail_path,
                                sha256, filename, captured_at, width, height, metadata_json, imported_at, is_available
                            ) VALUES (?, 'apple-photos-full', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
                            """,
                        arguments: [
                            metadata.assetID,
                            metadata.sourceIdentifier,
                            previewURL.path,
                            previewURL.path,
                            inputSHA256,
                            metadata.filename,
                            metadata.capturedAt,
                            metadata.width,
                            metadata.height,
                            metadataJSON,
                            now
                        ]
                    )
                }

                try db.execute(
                    sql: "UPDATE artifacts SET is_active = 0 WHERE asset_id = ? AND kind = 'annotation' AND producer = ?",
                    arguments: [metadata.assetID, producer]
                )
                try db.execute(
                    sql: """
                        INSERT INTO artifacts(
                            asset_id, kind, producer, model, prompt_version, schema_version,
                            preprocess_version, input_sha256, data_json, raw_text, created_at, is_active
                        ) VALUES (?, 'annotation', ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
                        ON CONFLICT(asset_id, kind, producer, model, prompt_version, schema_version, preprocess_version, input_sha256)
                        DO UPDATE SET
                            data_json = excluded.data_json,
                            raw_text = excluded.raw_text,
                            created_at = excluded.created_at,
                            is_active = 1
                        """,
                    arguments: [
                        metadata.assetID,
                        producer,
                        model,
                        promptVersion,
                        schemaVersion,
                        preprocessVersion,
                        inputSHA256,
                        annotationJSON,
                        vision.ocrText,
                        now
                    ]
                )

                try db.execute(
                    sql: """
                        INSERT INTO search_docs(asset_id, asset_type, short_caption, search_text, updated_at)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [metadata.assetID, assetType, shortCaption, searchText, now]
                )

                try db.execute(sql: "DELETE FROM search_fts WHERE asset_id = ?", arguments: [metadata.assetID])
                try db.execute(
                    sql: "INSERT INTO search_fts(asset_id, search_text) VALUES (?, ?)",
                    arguments: [metadata.assetID, searchText]
                )
                didInsert = true
            }
            return didInsert
        } catch {
            if let writtenPreviewURL {
                try? FileManager.default.removeItem(at: writtenPreviewURL)
            }
            throw error
        }
    }

    static func assetShouldSkip(_ db: Database, assetID: String) throws -> Bool {
        if try Int.fetchOne(
            db,
            sql: "SELECT 1 FROM search_docs WHERE asset_id = ? LIMIT 1",
            arguments: [assetID]
        ) != nil {
            return true
        }
        return try Int.fetchOne(
            db,
            sql: """
                SELECT 1 FROM artifacts
                WHERE asset_id = ? AND kind = 'annotation' AND is_active = 1
                  AND producer != ?
                LIMIT 1
                """,
            arguments: [assetID, producer]
        ) != nil
    }

    static func openWritableQueue(at path: String) throws -> DatabaseQueue {
        var config = Configuration()
        config.busyMode = .timeout(5.0)
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        return try DatabaseQueue(path: path, configuration: config)
    }

    private static func sanitizedFilenameComponent(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let cleaned = String(mapped)
        return cleaned.isEmpty ? "asset" : cleaned
    }
}

private final class NativeIndexingCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.withLock { cancelled = true }
    }

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }
}

@Observable
@MainActor
final class NativeIndexerStore {
    private(set) var authorizationStatus: PHAuthorizationStatus
    private(set) var isAuthorizing = false
    private(set) var isIndexing = false
    private(set) var processedCount = 0
    private(set) var totalCount = 0
    private(set) var newlyIndexedCount = 0
    private(set) var skippedCount = 0
    private(set) var failedCount = 0
    private(set) var statusMessage = ""
    private(set) var lastError: String?

    @ObservationIgnored private let workerQueue = DispatchQueue(
        label: "com.popcornnn.photo-search.native-indexer",
        qos: .utility
    )
    @ObservationIgnored private var activeCancellation: NativeIndexingCancellation?

    init(authorizationStatus: PHAuthorizationStatus = .notDetermined) {
        self.authorizationStatus = authorizationStatus
    }

    var isBusy: Bool {
        isIndexing || isAuthorizing
    }

    var isAuthorized: Bool {
        authorizationStatus == .authorized || authorizationStatus == .limited
    }

    var authorizationLabel: String {
        switch authorizationStatus {
        case .authorized: "Full Access"
        case .limited: "Selected Photos"
        case .denied: "Denied in System Settings"
        case .restricted: "Restricted"
        case .notDetermined: "Not Granted"
        @unknown default: "Unknown"
        }
    }

    func refreshAuthorization() {
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    @discardableResult
    func requestAuthorization() async -> PHAuthorizationStatus {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        authorizationStatus = status
        return status
    }

    func stopIndexing() {
        activeCancellation?.cancel()
        if isIndexing {
            statusMessage = "Stopping after current item…"
        }
    }

    func startIndexing(
        limit: Int? = 200,
        databasePath: String = PhotoSearchDatabase.path,
        onProgressBatch: (@MainActor @Sendable () -> Void)? = nil
    ) {
        guard !isBusy else { return }
        lastError = nil

        let currentStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        authorizationStatus = currentStatus
        if currentStatus == .notDetermined {
            isAuthorizing = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.isAuthorizing = false }
                let resolved = await self.requestAuthorization()
                guard resolved == .authorized || resolved == .limited else {
                    self.lastError = "Allow Photos access to index your library locally."
                    return
                }
                self.beginWorkerRun(limit: limit, databasePath: databasePath, onProgressBatch: onProgressBatch)
            }
            return
        }

        guard currentStatus == .authorized || currentStatus == .limited else {
            lastError = "Allow Photos access in Privacy & Security → Photos."
            return
        }

        beginWorkerRun(limit: limit, databasePath: databasePath, onProgressBatch: onProgressBatch)
    }

    private func beginWorkerRun(
        limit: Int?,
        databasePath: String,
        onProgressBatch: (@MainActor @Sendable () -> Void)?
    ) {
        let cancellation = NativeIndexingCancellation()
        activeCancellation = cancellation
        isIndexing = true
        processedCount = 0
        totalCount = 0
        newlyIndexedCount = 0
        skippedCount = 0
        failedCount = 0
        statusMessage = "Scanning Apple Photos…"

        let batchCallback = onProgressBatch
        let publishProgress: @Sendable (Int, Int, Int, Int, Int, String, Bool) -> Void = {
            [weak self] processed, total, newlyIndexed, skipped, failed, message, shouldRefreshGrid in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.processedCount = processed
                self.totalCount = total
                self.newlyIndexedCount = newlyIndexed
                self.skippedCount = skipped
                self.failedCount = failed
                self.statusMessage = message
                if shouldRefreshGrid {
                    batchCallback?()
                }
            }
        }
        let finishRun: @Sendable (Int, Int, Int, Int, Int, String, String?) -> Void = {
            [weak self] processed, total, newlyIndexed, skipped, failed, message, errorMessage in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.processedCount = processed
                self.totalCount = total
                self.newlyIndexedCount = newlyIndexed
                self.skippedCount = skipped
                self.failedCount = failed
                self.statusMessage = message
                self.lastError = errorMessage
                self.isIndexing = false
                self.activeCancellation = nil
                batchCallback?()
            }
        }

        workerQueue.async {
            do {
                let previewsDir = NativeLibraryIndexer.defaultPreviewsDirectory(databasePath: databasePath)
                try PhotoSearchDatabase.ensureSchema(at: databasePath, previewsDirectory: previewsDir)
                let queue = try NativeLibraryIndexer.openWritableQueue(at: databasePath)
                defer { try? queue.close() }

                let fetchOptions = PHFetchOptions()
                fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                fetchOptions.predicate = NSPredicate(
                    format: "mediaType == %d || mediaType == %d",
                    PHAssetMediaType.image.rawValue,
                    PHAssetMediaType.video.rawValue
                )
                let fetched = PHAsset.fetchAssets(with: fetchOptions)
                let targetCount = limit.map { min($0, fetched.count) } ?? fetched.count

                if targetCount == 0 {
                    finishRun(0, 0, 0, 0, 0, "No photos or videos found in Photos.", nil)
                    return
                }

                publishProgress(0, targetCount, 0, 0, 0, "Indexing on-device with Apple Vision…", false)

                let manager = PHImageManager.default()
                let isoFormatter = ISO8601DateFormatter()
                isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

                var processed = 0
                var newlyIndexed = 0
                var skipped = 0
                var failed = 0
                var lastNotifiedNewlyIndexed = 0

                for index in 0..<targetCount {
                    if cancellation.isCancelled { break }
                    autoreleasepool {
                        let asset = fetched.object(at: index)
                        let assetID = NativeLibraryIndexer.stableAssetID(for: asset.localIdentifier)
                        let isVideo = asset.mediaType == .video
                        let isScreenshot = asset.mediaSubtypes.contains(.photoScreenshot)
                        let ext = isVideo ? "mov" : "jpg"
                        let capturedAt = asset.creationDate.map { isoFormatter.string(from: $0) }
                        let metadata = NativeAssetMetadata(
                            assetID: assetID,
                            sourceIdentifier: asset.localIdentifier,
                            filename: Self.preferredFilename(for: asset, fallbackExtension: ext),
                            capturedAt: capturedAt,
                            width: asset.pixelWidth,
                            height: asset.pixelHeight,
                            isVideo: isVideo,
                            isScreenshot: isScreenshot,
                            durationSeconds: isVideo ? asset.duration : nil
                        )

                        do {
                            let alreadyPresent = try queue.read { db in
                                try NativeLibraryIndexer.assetShouldSkip(db, assetID: assetID)
                            }
                            if alreadyPresent {
                                skipped += 1
                            } else if let jpegData = Self.exportPreviewJPEG(asset: asset, manager: manager) {
                                let inserted = try NativeLibraryIndexer.indexImageData(
                                    jpegData,
                                    metadata: metadata,
                                    databasePath: databasePath,
                                    previewsDirectory: previewsDir,
                                    existingQueue: queue
                                )
                                if inserted {
                                    newlyIndexed += 1
                                } else {
                                    skipped += 1
                                }
                            } else {
                                failed += 1
                            }
                        } catch {
                            failed += 1
                        }
                    }

                    processed += 1
                    var notifyGrid = false
                    if newlyIndexed - lastNotifiedNewlyIndexed >= 10 {
                        lastNotifiedNewlyIndexed = newlyIndexed
                        notifyGrid = true
                    }
                    if processed == 1 || processed.isMultiple(of: 5) || processed == targetCount {
                        publishProgress(
                            processed,
                            targetCount,
                            newlyIndexed,
                            skipped,
                            failed,
                            "Indexed \(newlyIndexed.formatted()) new (\(processed.formatted())/\(targetCount.formatted()))",
                            notifyGrid
                        )
                    }
                }

                let failedSuffix = failed > 0 ? ", \(failed.formatted()) failed" : ""
                let summary = cancellation.isCancelled
                    ? "Stopped — \(newlyIndexed.formatted()) indexed, \(skipped.formatted()) skipped\(failedSuffix)."
                    : "Done — \(newlyIndexed.formatted()) indexed, \(skipped.formatted()) already in index\(failedSuffix)."
                finishRun(processed, targetCount, newlyIndexed, skipped, failed, summary, nil)
            } catch {
                finishRun(0, 0, 0, 0, 0, "Indexing failed.", error.localizedDescription)
            }
        }
    }

    nonisolated private static func preferredFilename(for asset: PHAsset, fallbackExtension: String) -> String {
        if let resource = PHAssetResource.assetResources(for: asset).first,
           !resource.originalFilename.isEmpty {
            return resource.originalFilename
        }
        return NativeLibraryIndexer.stableAssetID(for: asset.localIdentifier) + "." + fallbackExtension
    }

    nonisolated private static func exportPreviewJPEG(asset: PHAsset, manager: PHImageManager) -> Data? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        options.isSynchronous = true
        options.version = .current

        var exportedImage: NSImage?
        manager.requestImage(
            for: asset,
            targetSize: CGSize(width: 1024, height: 1024),
            contentMode: .aspectFit,
            options: options
        ) { image, _ in
            exportedImage = image
        }
        guard let exportedImage,
              let tiff = exportedImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
    }
}
