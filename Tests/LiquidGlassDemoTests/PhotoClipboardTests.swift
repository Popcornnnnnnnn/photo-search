import AppKit
import Foundation
import Testing
@testable import LiquidGlassDemo

@Suite struct PhotoClipboardTests {
    @MainActor
    @Test func copiesTheOriginalImageAsPasteboardImage() throws {
        let imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("photo-clipboard-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: imageURL) }

        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()

        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: imageURL)

        let photo = IndexedPhoto(
            id: "clipboard-test",
            thumbnailPath: "",
            filePath: imageURL.path,
            filename: imageURL.lastPathComponent,
            capturedAt: nil,
            width: 8,
            height: 8,
            assetType: "photo",
            shortCaption: "",
            model: nil,
            annotation: nil
        )
        let pasteboard = NSPasteboard(name: .init("PhotoClipboardTests.\(UUID().uuidString)"))

        #expect(PhotoClipboard.copy(photo, to: pasteboard))
        #expect(pasteboard.readObjects(forClasses: [NSImage.self])?.isEmpty == false)
    }
}
