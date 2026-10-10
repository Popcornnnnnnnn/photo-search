import SwiftUI

/// Whether the background worker is indexing right now. The worker rewrites
/// `worker-status.json` on every batch and between batches, so the sidebar can
/// report real activity instead of a permanently green dot.
///
/// A stale status is separate from both an error and a completed index; silence
/// while the Mac sleeps does not establish whether the pipeline is up to date.
enum PhotoIndexActivity: Equatable, Sendable {
    case indexing, waiting, paused, idle, complete, completeWithErrors, stale

    var caption: String? {
        switch self {
        case .indexing: "Indexing"
        case .waiting: "Waiting"
        case .paused: "Paused"
        case .stale: "Status out of date"
        case .completeWithErrors: "Some items skipped"
        case .idle, .complete: nil
        }
    }

    var headline: String {
        switch self {
        case .indexing: String(localized: "Indexing", bundle: .module)
        case .waiting: String(localized: "Waiting for the next batch", bundle: .module)
        case .paused: String(localized: "Paused after an error", bundle: .module)
        case .idle: String(localized: "No current indexing status", bundle: .module)
        case .complete: String(localized: "Up to date", bundle: .module)
        case .completeWithErrors: String(localized: "Finished with skipped items", bundle: .module)
        case .stale: String(localized: "Status out of date", bundle: .module)
        }
    }

    var statusIcon: String {
        switch self {
        case .indexing: "arrow.triangle.2.circlepath"
        case .waiting: "clock"
        case .paused, .completeWithErrors: "exclamationmark.triangle.fill"
        case .idle: "questionmark.circle"
        case .complete: "checkmark.circle.fill"
        case .stale: "clock.badge.exclamationmark"
        }
    }
}

/// The worker's own status file, read read-only. It describes the pipeline
/// rather than the photos, so it stays out of the search index queries.
enum PhotoWorkerStatus {
    /// A `running` status the worker has not refreshed in this long counts as
    /// stopped. The worker rewrites the file at least once a minute while awake.
    static let staleAfter: TimeInterval = 300

    struct Payload: Decodable, Equatable {
        var status: String
        var lastError: String?
        var pending: Int?
        var stage: String?
        var message: String?
        var annotated: Int?
        var libraryImages: Int?
        var ratePerHour: Double?
        var etaAt: String?
        var updatedAt: String?
        var embedded: Int?
        var embeddingPending: Int?
        var embeddingError: String?
        var libraryVideos: Int?
        var videosAnnotated: Int?

        var needsPhotosAccess: Bool {
            lastError?.contains("Photos access was not granted") == true
        }

        /// Plain-language version of the worker's `stage` token.
        var statusDetail: String {
            switch stage {
            case "syncing": "Checking Photos for changes"
            case "importing": "Updating changed previews"
            case "checking_model": "Checking the model connection"
            case "indexing": "Reading photos and videos"
            case "embedding": "Building the visual index"
            case "complete": "Everything is indexed"
            case .some(let other): other.replacingOccurrences(of: "_", with: " ")
            case nil: status
            }
        }

        /// The worker's ETA as a readable date, or nil when it has not set one.
        var etaText: String? {
            guard let etaAt, let date = PhotoWorkerStatus.parseTimestamp(etaAt) else { return nil }
            return date.formatted(date: .abbreviated, time: .shortened)
        }
    }

    /// The worker writes Python's `datetime.isoformat()`, which carries fractional
    /// seconds and a `+00:00` offset. `ISO8601DateFormatter`'s default options
    /// reject the fraction, so try with it and fall back without.
    static func parseTimestamp(_ value: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }

    static var path: String {
        URL(fileURLWithPath: PhotoSearchDatabase.path)
            .deletingLastPathComponent()
            .appendingPathComponent("worker-status.json")
            .path
    }

    /// Reads the status file. A missing or unreadable file means "nothing is
    /// running as far as we can tell", which is what an idle footer should show.
    static func load(at path: String = path, now: Date = Date()) -> PhotoIndexActivity {
        snapshot(at: path, now: now)?.activity ?? .idle
    }

    /// The decoded status file plus the pipeline's own activity verdict, so the
    /// sidebar footer and the settings page read one file through one path.
    struct Snapshot: Equatable, Sendable {
        var payload: Payload
        var activity: PhotoIndexActivity
        /// When the worker last wrote the file. The page shows this so a
        /// "nothing moved" number can be told apart from a stopped worker.
        var updated: Date

        var statusDetail: String {
            if activity == .stale {
                return String(format: String(localized: "Last reported: %@", bundle: .module), payload.statusDetail)
            }
            if activity == .waiting, payload.pending == 0 {
                return payload.embeddingPending == nil
                    ? String(localized: "Visual coverage is unknown", bundle: .module)
                    : String(localized: "Waiting for visual indexing", bundle: .module)
            }
            if activity == .completeWithErrors {
                return String(localized: "Some items could not be indexed", bundle: .module)
            }
            return payload.statusDetail
        }
    }

    static func snapshot(at path: String = path, now: Date = Date()) -> Snapshot? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attributes[.modificationDate] as? Date else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let payload = try? decoder.decode(Payload.self, from: data) else { return nil }
        return Snapshot(payload: payload, activity: activity(payload, modified: modified, now: now),
                        updated: modified)
    }

    static func activity(_ payload: Payload, modified: Date, now: Date = Date()) -> PhotoIndexActivity {
        if let error = payload.lastError, !error.isEmpty { return .paused }
        if let error = payload.embeddingError, !error.isEmpty { return .paused }
        guard now.timeIntervalSince(modified) <= staleAfter else { return .stale }
        switch payload.status {
        case "running": return .indexing
        case "waiting": return .waiting
        case "complete":
            // A completed annotation pass does not establish visual coverage.
            guard payload.pending == 0, payload.embeddingPending == 0 else { return .waiting }
            return .complete
        case "complete_with_errors":
            return payload.pending == 0 && payload.embeddingPending == 0 ? .completeWithErrors : .waiting
        default: return .idle
        }
    }
}

@Observable
@MainActor
final class PhotoIndexActivityStore {
    private(set) var activity: PhotoIndexActivity = .idle
    private(set) var snapshot: PhotoWorkerStatus.Snapshot?

    @ObservationIgnored private let path: String

    init(path: String = PhotoWorkerStatus.path) {
        self.path = path
        // Read once up front so the footer reports the real state on first paint
        // instead of flashing "nothing running" until the first poll lands.
        let initial = PhotoWorkerStatus.snapshot(at: path)
        self.snapshot = initial
        self.activity = initial?.activity ?? .idle
    }

    func requestPhotosAccess() async throws {
        guard let command = PhotoEncoderCommand.resolve(), command.last == "encoder-serve" else {
            throw PhotoEncoderClient.Failure(message: "The Photo Search backend could not be found.")
        }
        let arguments = Array(command.dropFirst().dropLast()) + ["authorize-photos"]
        let executable = command[0]
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let errorPipe = Pipe()
            process.standardError = errorPipe
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
                throw PhotoEncoderClient.Failure(message: String(data: data, encoding: .utf8) ?? "Photos access was not granted.")
            }
        }.value
        await refresh()
    }

    func refresh() async {
        let path = path
        let next = await Task.detached(priority: .utility) {
            PhotoWorkerStatus.snapshot(at: path)
        }.value
        snapshot = next
        activity = next?.activity ?? .idle
    }
}
