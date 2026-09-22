import AppKit
import ImageIO
import SwiftUI

private struct SendableImage: @unchecked Sendable {
    let value: NSImage
    let cost: Int
}

private final class ThumbnailCache: @unchecked Sendable {
    private let storage = NSCache<NSString, NSImage>()

    init() {
        storage.countLimit = 320
        storage.totalCostLimit = 256 * 1024 * 1024
    }

    func image(for key: String) -> NSImage? {
        storage.object(forKey: key as NSString)
    }

    func insert(_ image: NSImage, key: String, cost: Int) {
        storage.setObject(image, forKey: key as NSString, cost: cost)
    }
}

struct PhotoThumbnailView: View {
    private static let cache = ThumbnailCache()

    let path: String
    let contentMode: ContentMode
    let maxPixelSize: Int

    @State private var image: NSImage?

    init(path: String, contentMode: ContentMode = .fill, maxPixelSize: Int = 720) {
        self.path = path
        self.contentMode = contentMode
        self.maxPixelSize = maxPixelSize
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                ZStack {
                    Color.secondary.opacity(0.08)
                    ProgressView().controlSize(.small)
                }
            }
        }
        .task(id: "\(path)|\(maxPixelSize)") {
            let cacheKey = "\(path)|\(maxPixelSize)"
            if let cached = Self.cache.image(for: cacheKey) {
                image = cached
                return
            }

            image = nil
            let loaded = await Task.detached(priority: .utility) {
                Self.loadThumbnail(path: path, maxPixelSize: maxPixelSize)
            }.value
            if let loaded {
                Self.cache.insert(loaded.value, key: cacheKey, cost: loaded.cost)
            }
            image = loaded?.value
        }
    }

    nonisolated private static func loadThumbnail(path: String, maxPixelSize: Int) -> SendableImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return SendableImage(
            value: NSImage(cgImage: cgImage, size: .zero),
            cost: cgImage.bytesPerRow * cgImage.height
        )
    }
}
