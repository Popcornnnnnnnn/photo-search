import AppKit

enum PhotoClipboard {
    @MainActor
    static func copy(_ photo: IndexedPhoto,
                     to pasteboard: NSPasteboard = .general) -> Bool {
        let paths = [photo.filePath, photo.thumbnailPath]
        guard let path = paths.first(where: {
            !$0.isEmpty && FileManager.default.fileExists(atPath: $0)
        }), let image = NSImage(contentsOfFile: path) else {
            return false
        }

        pasteboard.clearContents()
        return pasteboard.writeObjects([image])
    }
}
