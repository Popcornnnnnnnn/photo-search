import AVFoundation
import AppKit
import CryptoKit
import Foundation
import Photos

struct ExportRecord: Codable {
    let id: String
    let localIdentifier: String
    let path: String
    let filename: String
    let capturedAt: String?
    let width: Int
    let height: Int
    let favorite: Bool
    let mediaSubtypes: UInt
    let modifiedAt: String?
    let thumbnailPath: String?
    let mediaType: String?
    let duration: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case localIdentifier = "local_identifier"
        case path
        case filename
        case capturedAt = "captured_at"
        case width
        case height
        case favorite
        case mediaSubtypes = "media_subtypes"
        case modifiedAt = "modified_at"
        case thumbnailPath = "thumbnail_path"
        case mediaType = "media_type"
        case duration
    }
}

enum ExportError: Error, CustomStringConvertible {
    case usage
    case unauthorized(PHAuthorizationStatus)
    case imageUnavailable(String)
    case encodingFailed(String)

    var description: String {
        switch self {
        case .usage:
            return "usage: photo-export --output DIR [--limit N] [--strategy recent|benchmark|all]"
        case .unauthorized(let status):
            return "Photos access was not granted (status: \(status.rawValue))"
        case .imageUnavailable(let identifier):
            return "Unable to load image for \(identifier)"
        case .encodingFailed(let identifier):
            return "Unable to encode image for \(identifier)"
        }
    }
}

func evenlySpacedIndices(count: Int, limit: Int) -> [Int] {
    guard count > 0, limit > 0 else { return [] }
    if limit >= count { return Array(0..<count) }
    if limit == 1 { return [0] }
    return (0..<limit).map { Int((Double($0) * Double(count - 1) / Double(limit - 1)).rounded()) }
}

func argument(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else {
        return nil
    }
    return CommandLine.arguments[index + 1]
}

func stableID(_ value: String) -> String {
    let digest = SHA256.hash(data: Data(value.utf8))
    return "photos-" + digest.prefix(12).map { String(format: "%02x", $0) }.joined()
}

func jpegData(_ image: NSImage, identifier: String) throws -> Data {
    guard
        let tiff = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff),
        let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.88])
    else {
        throw ExportError.encodingFailed(identifier)
    }
    return data
}

func requestPreview(asset: PHAsset, manager: PHImageManager) throws -> NSImage {
    let options = PHImageRequestOptions()
    options.deliveryMode = .highQualityFormat
    options.resizeMode = .exact
    options.isNetworkAccessAllowed = true
    options.isSynchronous = true
    options.version = .current
    var result: NSImage?
    manager.requestImage(
        for: asset,
        targetSize: CGSize(width: 1600, height: 1600),
        contentMode: .aspectFit,
        options: options
    ) { image, _ in
        result = image
    }
    guard let result else {
        throw ExportError.imageUnavailable(asset.localIdentifier)
    }
    return result
}

func exportVideo(asset: PHAsset, manager: PHImageManager, destination: URL) async throws {
    let options = PHVideoRequestOptions()
    options.version = .current
    options.deliveryMode = .highQualityFormat
    options.isNetworkAccessAllowed = true
    let session: AVAssetExportSession? = await withCheckedContinuation { continuation in
        manager.requestExportSession(forVideo: asset, options: options,
                                     exportPreset: AVAssetExportPresetPassthrough) { session, _ in
            continuation.resume(returning: session)
        }
    }
    guard let session, session.supportedFileTypes.contains(.mov) else {
        throw ExportError.imageUnavailable(asset.localIdentifier)
    }
    let temporary = destination.deletingPathExtension().appendingPathExtension("tmp.mov")
    defer { try? FileManager.default.removeItem(at: temporary) }
    try? FileManager.default.removeItem(at: temporary)
    try await session.export(to: temporary, as: .mov)
    if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
    }
    try FileManager.default.moveItem(at: temporary, to: destination)
}

@main
struct PhotoExporter {
    static func main() async {
        do {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            guard let outputValue = argument("--output") else { throw ExportError.usage }
            let limit = max(1, Int(argument("--limit") ?? "12") ?? 12)
            let strategy = argument("--strategy") ?? "recent"
            let output = URL(fileURLWithPath: outputValue, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

            let existingStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            let noPrompt = CommandLine.arguments.contains("--no-prompt")
            let authorize = CommandLine.arguments.contains("--authorize")
            let status = authorize || (existingStatus == .notDetermined && !noPrompt)
                ? await PHPhotoLibrary.requestAuthorization(for: .readWrite) : existingStatus
            guard status == .authorized || status == .limited else {
                throw ExportError.unauthorized(status)
            }

            if authorize {
                let payload = ["authorized": true, "limited": status == .limited]
                let data = try JSONSerialization.data(withJSONObject: payload)
                try data.write(to: output.appendingPathComponent("result.json"), options: .atomic)
                return
            }

            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            if strategy == "recent" { options.fetchLimit = limit }
            options.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d",
                                            PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
            if argument("--media-type") == "video" {
                options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
            }
            let assets = PHAsset.fetchAssets(with: options)
            var selected: [PHAsset] = []
            var selectedIDs = Set<String>()

            func appendAsset(_ asset: PHAsset) {
                if selected.count < limit && selectedIDs.insert(asset.localIdentifier).inserted {
                    selected.append(asset)
                }
            }

            if strategy == "benchmark" {
                let screenshotTarget = min(25, max(1, limit / 4))
                let generalTarget = max(0, limit - screenshotTarget)
                for index in evenlySpacedIndices(count: assets.count, limit: generalTarget) {
                    appendAsset(assets.object(at: index))
                }

                let screenshotOptions = PHFetchOptions()
                screenshotOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                screenshotOptions.predicate = NSPredicate(
                    format: "(mediaSubtype & %d) != 0",
                    PHAssetMediaSubtype.photoScreenshot.rawValue
                )
                let screenshots = PHAsset.fetchAssets(with: .image, options: screenshotOptions)
                for index in evenlySpacedIndices(count: screenshots.count, limit: screenshotTarget) {
                    appendAsset(screenshots.object(at: index))
                }
                var fillIndex = 0
                while selected.count < limit && fillIndex < assets.count {
                    appendAsset(assets.object(at: fillIndex))
                    fillIndex += 1
                }
            } else if strategy == "all" {
                assets.enumerateObjects { asset, _, _ in appendAsset(asset) }
            } else {
                assets.enumerateObjects { asset, _, stop in
                    appendAsset(asset)
                    if selected.count >= limit { stop.pointee = true }
                }
            }

            let manager = PHImageManager.default()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let manifest = output.appendingPathComponent("manifest.jsonl")
            var previous: [String: ExportRecord] = [:]
            if let old = try? String(contentsOf: manifest, encoding: .utf8) {
                for line in old.split(separator: "\n") {
                    if let record = try? JSONDecoder().decode(ExportRecord.self, from: Data(line.utf8)) {
                        previous[record.id] = record
                    }
                }
            }
            var lines: [String] = []
            var failures = 0
            var failedIDs: [String] = []
            var regenerated = 0

            for asset in selected {
                do {
                    let id = stableID(asset.localIdentifier)
                    let modifiedAt = asset.modificationDate.map { iso.string(from: $0) }
                    let old = previous[id]
                    let oldURL = old.map { URL(fileURLWithPath: $0.path) }
                    let oldDate = oldURL.flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
                    let legacyUnchanged = old?.modifiedAt == nil
                        && (asset.modificationDate.map { $0 <= (oldDate ?? .distantPast) } ?? true)
                    let isVideo = asset.mediaType == .video
                    let reusable = (old?.mediaType ?? "image") == (isVideo ? "video" : "image")
                        && old != nil && (old?.modifiedAt == modifiedAt || legacyUnchanged)
                        && old?.width == asset.pixelWidth && old?.height == asset.pixelHeight
                        && FileManager.default.fileExists(atPath: old?.path ?? "")
                        && (!isVideo || FileManager.default.fileExists(atPath: old?.thumbnailPath ?? ""))
                    let version = stableID(modifiedAt ?? asset.creationDate.map { iso.string(from: $0) } ?? "original")
                    let filename = id + "-" + version.suffix(12) + (isVideo ? ".mov" : ".jpg")
                    let destination = reusable ? oldURL! : output.appendingPathComponent(filename)
                    let thumbnail = isVideo
                        ? (reusable ? URL(fileURLWithPath: old!.thumbnailPath!)
                           : destination.deletingPathExtension().appendingPathExtension("jpg"))
                        : destination
                    if !reusable {
                        if isVideo { try await exportVideo(asset: asset, manager: manager, destination: destination) }
                        let image = try requestPreview(asset: asset, manager: manager)
                        let data = try jpegData(image, identifier: asset.localIdentifier)
                        try data.write(to: thumbnail, options: .atomic)
                        regenerated += 1
                    }
                    let record = ExportRecord(
                        id: id,
                        localIdentifier: asset.localIdentifier,
                        path: destination.path,
                        filename: id + (isVideo ? ".mov" : ".jpg"),
                        capturedAt: asset.creationDate.map { iso.string(from: $0) },
                        width: asset.pixelWidth,
                        height: asset.pixelHeight,
                        favorite: asset.isFavorite,
                        mediaSubtypes: asset.mediaSubtypes.rawValue,
                        modifiedAt: modifiedAt,
                        thumbnailPath: thumbnail.path,
                        mediaType: isVideo ? "video" : "image",
                        duration: isVideo ? asset.duration : nil
                    )
                    let encoded = try encoder.encode(record)
                    lines.append(String(decoding: encoded, as: UTF8.self))
                } catch {
                    failures += 1
                    failedIDs.append(stableID(asset.localIdentifier))
                    FileHandle.standardError.write(Data("export error: \(error)\n".utf8))
                }
            }

            try (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n"))
                .write(to: manifest, atomically: true, encoding: .utf8)
            let result = output.appendingPathComponent("result.json")
            let payload: [String: Any] = [
                "exported": lines.count, "failed": failures, "regenerated": regenerated,
                "strategy": strategy, "library_assets": assets.count,
                "library_images": selected.filter { $0.mediaType == .image }.count,
                "library_videos": selected.filter { $0.mediaType == .video }.count,
                "manifest": manifest.path,
                "full_snapshot": strategy == "all" && argument("--media-type") == nil && status == .authorized && selected.count == assets.count,
                "present_ids": selected.map { stableID($0.localIdentifier) }, "failed_ids": failedIDs
            ]
            let resultJSON = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
            try resultJSON.write(to: result, atomically: true, encoding: .utf8)
            print(resultJSON)
        } catch {
            if let output = argument("--output"),
               let data = try? JSONSerialization.data(withJSONObject: ["error": String(describing: error)]) {
                try? data.write(to: URL(fileURLWithPath: output).appendingPathComponent("result.json"), options: .atomic)
            }
            FileHandle.standardError.write(Data("photo-export: \(error)\n".utf8))
            Foundation.exit(1)
        }
    }
}
