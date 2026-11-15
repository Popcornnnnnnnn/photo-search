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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let path: String
    let contentMode: ContentMode
    let maxPixelSize: Int
    let animatesContentMode: Bool
    let rotationDegrees: Double?
    let onDisplayed: (() -> Void)?

    @State private var image: NSImage?
    @State private var failed = false

    init(path: String, contentMode: ContentMode = .fill, maxPixelSize: Int = 720,
         animatesContentMode: Bool = false, rotationDegrees: Double? = nil,
         onDisplayed: (() -> Void)? = nil) {
        self.path = path
        self.contentMode = contentMode
        self.maxPixelSize = maxPixelSize
        self.animatesContentMode = animatesContentMode
        self.rotationDegrees = rotationDegrees
        self.onDisplayed = onDisplayed
    }

    var body: some View {
        Group {
            if let image {
                if animatesContentMode {
                    GeometryReader { proxy in
                        let widthRatio = proxy.size.width / max(image.size.width, 1)
                        let heightRatio = proxy.size.height / max(image.size.height, 1)
                        let fillScale = max(widthRatio, heightRatio) / max(min(widthRatio, heightRatio), 0.0001)

                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .scaleEffect(contentMode == .fill ? fillScale : 1)
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: contentMode)
                    }
                    .clipped()
                } else if let rotationDegrees {
                    FittedRotatingImage(image: image, rotationDegrees: rotationDegrees)
                        .onAppear { onDisplayed?() }
                } else {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .onAppear { onDisplayed?() }
                }
            } else if failed {
                Image(systemName: "photo.badge.exclamationmark")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel(String(localized: "Preview unavailable", bundle: .module))
            } else {
                ZStack {
                    Color.secondary.opacity(0.08)
                    ProgressView().controlSize(.small)
                }
            }
        }
        .task(id: "\(path)|\(maxPixelSize)") {
            failed = false
            let cacheKey = "\(path)|\(maxPixelSize)"
            if let cached = Self.cache.image(for: cacheKey) {
                image = cached
                return
            }

            image = nil
            do {
                let loaded = try await photoSearchBackground(priority: .utility) {
                    Self.loadThumbnail(path: path, maxPixelSize: maxPixelSize)
                }
                guard !Task.isCancelled else { return }
                failed = loaded == nil
                if let loaded {
                    Self.cache.insert(loaded.value, key: cacheKey, cost: loaded.cost)
                }
                image = loaded?.value
            } catch { }
        }
    }

    nonisolated private static func loadThumbnail(path: String, maxPixelSize: Int) -> SendableImage? {
        guard !Task.isCancelled else { return nil }
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

struct FittedRotatingImage: View {
    let image: NSImage
    let rotationDegrees: Double

    var body: some View {
        GeometryReader { proxy in
            let imageWidth = max(image.size.width, 1)
            let imageHeight = max(image.size.height, 1)
            let fit = min(proxy.size.width / imageWidth, proxy.size.height / imageHeight)
            let fittedSize = CGSize(width: imageWidth * fit, height: imageHeight * fit)

            Image(nsImage: image)
                .resizable()
                .frame(width: fittedSize.width, height: fittedSize.height)
                .modifier(RotatingFitEffect(
                    degrees: rotationDegrees,
                    imageSize: fittedSize,
                    canvasSize: proxy.size
                ))
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

private struct RotatingFitEffect: AnimatableModifier {
    var degrees: Double
    let imageSize: CGSize
    let canvasSize: CGSize

    nonisolated var animatableData: Double {
        get { degrees }
        set { degrees = newValue }
    }

    func body(content: Content) -> some View {
        let radians: Double = degrees * .pi / 180
        let cosine: Double = cos(radians)
        let sine: Double = sin(radians)
        let width = abs(imageSize.width * CGFloat(cosine)) + abs(imageSize.height * CGFloat(sine))
        let height = abs(imageSize.width * CGFloat(sine)) + abs(imageSize.height * CGFloat(cosine))
        let fit = min(canvasSize.width / max(width, 1), canvasSize.height / max(height, 1))

        content
            .rotationEffect(.degrees(degrees))
            .scaleEffect(fit)
    }
}
