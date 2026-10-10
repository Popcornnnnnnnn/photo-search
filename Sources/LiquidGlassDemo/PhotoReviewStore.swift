import Foundation
import GRDB
import ImageIO

enum PhotoReviewReason: String, Sendable {
    case blank, blur, accidental

    var title: String {
        switch self {
        case .blank: "Nearly blank"
        case .blur: "Possible heavy blur"
        case .accidental: "Possible accidental shot"
        }
    }

    var explanation: String {
        switch self {
        case .blank: "The description suggests a blank image, and the local preview has almost no tonal variation."
        case .blur: "The existing description flags severe blur across the scene, rather than just a blurred background."
        case .accidental: "The description suggests an obstructed lens or a blurred close-up of the ground or feet. This may still be intentional."
        }
    }
}

struct PhotoReviewCandidate: Identifiable, Sendable {
    let photo: IndexedPhoto
    let fingerprint: String
    let reason: PhotoReviewReason
    let previewPath: String
    let sourceKind: String
    let sourceIdentifier: String
    var id: String { photo.id }

    var canDeleteFromPhotos: Bool {
        ["apple-photos", "apple-photos-benchmark", "apple-photos-full"].contains(sourceKind)
            && !sourceIdentifier.isEmpty
    }
}

/// Conservative hints from the existing caption, not a new quality model.
/// A generic mention of blur, a white background or a blank form is insufficient.
enum PhotoReviewClassifier {
    static func hint(caption: String, assetType: String) -> PhotoReviewReason? {
        let text = caption.lowercased()
        func matches(_ pattern: String) -> Bool {
            text.range(of: pattern, options: .regularExpression) != nil
        }
        if matches("(全白|全黑|纯白色|纯黑色|空白).{0,10}(图像|图片)|^(a |an )?(nearly |almost |completely |entirely )?(blank|solid white|solid black) (image|photo)") {
            return .blank
        }
        guard assetType == "photo" || assetType == "other" else { return nil }
        if matches("(背景|background).{0,12}(极度|严重|severely|heavily).{0,6}(模糊|blur)") { return nil }
        if matches("(极度|严重|整体|完全).{0,6}模糊|^(a |an )?(severely|extremely|heavily) (blurred|blurry)") {
            return .blur
        }
        if matches("(镜头.{0,5}(被遮挡|被覆盖)|疑似误拍|意外拍摄|accidentally captured|lens is (covered|obstructed))") {
            return .accidental
        }
        if text.contains("模糊"),
           matches("(地面|俯拍|近距离|特写)"),
           matches("(地面|双脚|袜子|一只.{0,6}脚)"),
           !matches("(人像|人物|运动员|骑行者|雪糕|手机|背景.{0,8}模糊)") {
            return .accidental
        }
        return nil
    }

    /// Inspect a downsampled local preview. A white document with text, a
    /// uniform colored illustration, or an unreadable file must not pass.
    static func previewIsBlank(_ image: CGImage) -> Bool {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return false }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return false }
        var low = 255.0, high = 0.0, sum = 0.0, sumSquares = 0.0, colorSpread = 0.0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[offset]), g = Double(pixels[offset + 1]), b = Double(pixels[offset + 2])
            let value = (r + g + b) / 3
            low = min(low, value); high = max(high, value)
            sum += value; sumSquares += value * value
            colorSpread += max(r, g, b) - min(r, g, b)
        }
        let count = Double(width * height), mean = sum / count
        let deviation = sqrt(max(0, sumSquares / count - mean * mean))
        return (mean < 25 || mean > 235) && deviation < 2 && high - low < 18 && colorSpread / count < 5
    }

    static func preview(at path: String) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 192,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }
}

enum PhotoReviewDecision: String, Codable, CaseIterable, Identifiable {
    case pending, keep, marked
    var id: String { rawValue }
    var title: String {
        switch self {
        case .pending: "To review"
        case .keep: "Kept"
        case .marked: "To delete"
        }
    }
}

@Observable
@MainActor
final class PhotoReviewStore {
    private struct SavedDecision: Codable {
        let fingerprint: String
        let decision: PhotoReviewDecision
    }
    private static let defaultsKey = "photoSearch.reviewDecisions.v1"
    private(set) var candidates: [PhotoReviewCandidate] = []
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var checkedCount = 0
    private(set) var unavailableCount = 0
    private(set) var isDeleting = false
    var deletionMessage: String?
    var filter: PhotoReviewDecision = .pending
    var selectedID: String?
    private var decisions: [String: SavedDecision] = [:]
    @ObservationIgnored private let databasePath: String
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let deleteAssets: @MainActor ([String]) async throws -> Void

    init(databasePath: String = PhotoSearchDatabase.path, defaults: UserDefaults = .standard,
         deleteAssets: @escaping @MainActor ([String]) async throws -> Void = PhotoLibraryDeletion.delete) {
        self.databasePath = databasePath
        self.defaults = defaults
        self.deleteAssets = deleteAssets
        decisions = Self.readDecisions(defaults)
    }

    var visibleCandidates: [PhotoReviewCandidate] { candidates.filter { decision(for: $0) == filter } }
    var markedCandidates: [PhotoReviewCandidate] { candidates.filter { decision(for: $0) == .marked } }
    var selected: PhotoReviewCandidate? { visibleCandidates.first { $0.id == selectedID } }

    func count(_ decision: PhotoReviewDecision) -> Int { candidates.filter { self.decision(for: $0) == decision }.count }

    func decision(for candidate: PhotoReviewCandidate) -> PhotoReviewDecision {
        guard let saved = decisions[candidate.id], saved.fingerprint == candidate.fingerprint else { return .pending }
        return saved.decision
    }

    func selectFirstIfNeeded() {
        if !visibleCandidates.contains(where: { $0.id == selectedID }) { selectedID = visibleCandidates.first?.id }
    }

    func mark(_ candidate: PhotoReviewCandidate, as decision: PhotoReviewDecision) {
        let oldIndex = visibleCandidates.firstIndex { $0.id == candidate.id } ?? 0
        // Read before writing so another window's decisions are not overwritten.
        decisions = Self.readDecisions(defaults)
        if decision == .pending { decisions.removeValue(forKey: candidate.id) }
        else { decisions[candidate.id] = SavedDecision(fingerprint: candidate.fingerprint, decision: decision) }
        if let data = try? PropertyListEncoder().encode(decisions) { defaults.set(data, forKey: Self.defaultsKey) }
        let remaining = visibleCandidates
        selectedID = remaining.isEmpty ? nil : remaining[min(oldIndex, remaining.count - 1)].id
    }

    func load(selectInitialFilter: Bool = false) async {
        guard !isLoading, !isDeleting else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        let databasePath = databasePath
        let task = Task.detached(priority: .utility) { try Self.scan(databasePath: databasePath) }
        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            try Task.checkCancellation()
            candidates = result.candidates
            checkedCount = result.checked
            unavailableCount = result.unavailable
            decisions = Self.readDecisions(defaults)
            if selectInitialFilter, count(.pending) == 0, count(.marked) > 0 { filter = .marked }
            selectFirstIfNeeded()
        } catch is CancellationError {
            return
        } catch {
            self.error = "Could not read the photo index. Try again when the library is available."
        }
    }

    /// A snapshot of the explicitly confirmed items, submitted in one Photos transaction.
    @discardableResult
    func delete(_ requested: [PhotoReviewCandidate]) async -> Bool {
        guard !requested.isEmpty, !isDeleting, !isLoading else { return false }
        isDeleting = true
        deletionMessage = nil
        defer { isDeleting = false }
        do {
            guard requested.allSatisfy(\.canDeleteFromPhotos) else { throw PhotoLibraryDeletion.Failure.unsupportedSource }
            try PhotoSearchDatabase.read(at: databasePath) { db in
                for candidate in requested {
                    let matches = try Bool.fetchOne(db, sql: """
                        SELECT EXISTS(SELECT 1 FROM assets WHERE id = ? AND sha256 = ?
                            AND source_kind = ? AND source_identifier = ? AND is_available = 1)
                        """, arguments: [candidate.id, candidate.fingerprint, candidate.sourceKind, candidate.sourceIdentifier])
                    guard matches == true else { throw PhotoLibraryDeletion.Failure.changedSource }
                }
            }
            try await deleteAssets(requested.map(\.sourceIdentifier))
        } catch is CancellationError {
            return false
        } catch {
            deletionMessage = error.localizedDescription
            return false
        }

        // A local index error after a committed Photos change is not a failed deletion.
        do {
            let writer = try DatabaseQueue(path: databasePath)
            try await writer.write { db in
                for candidate in requested {
                    try db.execute(sql: """
                        UPDATE assets SET is_available = 0
                        WHERE id = ? AND source_kind = ? AND source_identifier = ?
                        """, arguments: [candidate.id, candidate.sourceKind, candidate.sourceIdentifier])
                }
            }
        } catch {
            deletionMessage = "Deleted from Photos. The local index could not refresh; deleted photos may remain in search until the next library sync."
        }
        let deletedIDs = Set(requested.map(\.id))
        let oldIndex = visibleCandidates.firstIndex { $0.id == selectedID } ?? 0
        candidates.removeAll { deletedIDs.contains($0.id) }
        let remaining = visibleCandidates
        selectedID = remaining.isEmpty ? nil : remaining[min(oldIndex, remaining.count - 1)].id
        return true
    }

    private static func readDecisions(_ defaults: UserDefaults) -> [String: SavedDecision] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [:] }
        return (try? PropertyListDecoder().decode([String: SavedDecision].self, from: data)) ?? [:]
    }

    nonisolated static func scan(databasePath: String) throws -> (candidates: [PhotoReviewCandidate], checked: Int, unavailable: Int) {
        try PhotoSearchDatabase.read(at: databasePath) { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT a.id, a.sha256, a.file_path, a.thumbnail_path, a.filename, a.source_kind, a.source_identifier,
                       a.captured_at, a.width, a.height, j.model, j.data_json,
                       o.raw_text AS ocr_text
                FROM assets a
                JOIN artifacts j ON j.asset_id = a.id AND j.kind = 'annotation'
                    AND j.is_active = 1 AND j.input_sha256 = a.sha256
                LEFT JOIN artifacts o ON o.asset_id = a.id AND o.kind = 'ocr'
                    AND o.is_active = 1 AND o.input_sha256 = a.sha256
                WHERE a.is_available = 1 AND COALESCE(json_extract(j.data_json, '$.asset_type'), 'other') != 'video'
                ORDER BY a.captured_at DESC, a.id
                """)
            var candidates: [PhotoReviewCandidate] = []
            var unavailable = 0
            for row in rows {
                try Task.checkCancellation()
                let annotation = PhotoAnnotation.decode(row["data_json"])
                let caption = annotation?.shortCaption ?? ""
                let type = annotation?.assetType ?? "other"
                guard let reason = PhotoReviewClassifier.hint(caption: caption, assetType: type) else { continue }
                let original: String = row["file_path"], thumbnail: String = row["thumbnail_path"]
                let paths = [original, thumbnail].filter { !$0.isEmpty }
                let validPath: String? = autoreleasepool {
                    for path in paths {
                        guard let image = PhotoReviewClassifier.preview(at: path) else { continue }
                        if reason == .blank {
                            let ocr: String = row["ocr_text"] ?? ""
                            guard ocr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                  PhotoReviewClassifier.previewIsBlank(image) else { return nil }
                        }
                        return path
                    }
                    unavailable += 1
                    return nil
                }
                guard let validPath else { continue }
                let photo = IndexedPhoto(id: row["id"], thumbnailPath: thumbnail, filePath: original,
                                         filename: row["filename"], capturedAt: row["captured_at"],
                                         width: row["width"], height: row["height"], assetType: type,
                                         shortCaption: caption, model: row["model"], annotation: annotation)
                candidates.append(PhotoReviewCandidate(photo: photo, fingerprint: row["sha256"],
                                                       reason: reason, previewPath: validPath,
                                                       sourceKind: row["source_kind"], sourceIdentifier: row["source_identifier"]))
            }
            return (candidates, rows.count, unavailable)
        }
    }
}
