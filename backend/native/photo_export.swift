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

            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            guard status == .authorized || status == .limited else {
                throw ExportError.unauthorized(status)
            }

            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            if strategy == "recent" { options.fetchLimit = limit }
            let assets = PHAsset.fetchAssets(with: .image, options: options)
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
            var lines: [String] = []
            var failures = 0

            for asset in selected {
                do {
                    let id = stableID(asset.localIdentifier)
                    let filename = id + ".jpg"
                    let destination = output.appendingPathComponent(filename)
                    if !FileManager.default.fileExists(atPath: destination.path) {
                        let image = try requestPreview(asset: asset, manager: manager)
                        let data = try jpegData(image, identifier: asset.localIdentifier)
                        try data.write(to: destination, options: .atomic)
                    }
                    let record = ExportRecord(
                        id: id,
                        localIdentifier: asset.localIdentifier,
                        path: destination.path,
                        filename: filename,
                        capturedAt: asset.creationDate.map { iso.string(from: $0) },
                        width: asset.pixelWidth,
                        height: asset.pixelHeight,
                        favorite: asset.isFavorite,
                        mediaSubtypes: asset.mediaSubtypes.rawValue
                    )
                    let encoded = try encoder.encode(record)
                    lines.append(String(decoding: encoded, as: UTF8.self))
                } catch {
                    failures += 1
                    FileHandle.standardError.write(Data("export error: \(error)\n".utf8))
                }
            }

            let manifest = output.appendingPathComponent("manifest.jsonl")
            try (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n"))
                .write(to: manifest, atomically: true, encoding: .utf8)
            let result = output.appendingPathComponent("result.json")
            let resultJSON = "{\"exported\":\(lines.count),\"failed\":\(failures),\"strategy\":\"\(strategy)\",\"library_images\":\(assets.count),\"manifest\":\"\(manifest.path)\"}"
            try resultJSON.write(to: result, atomically: true, encoding: .utf8)
            print(resultJSON)
        } catch {
            FileHandle.standardError.write(Data("photo-export: \(error)\n".utf8))
            Foundation.exit(1)
        }
    }
}
