import AppKit
import GRDB
import SwiftUI

enum PhotoOriginal {
    enum Failure: LocalizedError {
        case unavailable, photosError(String)

        var errorDescription: String? {
            switch self {
            case .unavailable:
                "This item has no available link to an original in Photos."
            case .photosError(let message):
                "Photos could not open this item: \(message)"
            }
        }
    }

    static func identifier(for assetID: String, databasePath: String = PhotoSearchDatabase.path) throws -> String {
        try PhotoSearchDatabase.read(at: databasePath) { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT source_kind, source_identifier FROM assets WHERE id = ? AND is_available = 1
                """, arguments: [assetID]) else { throw Failure.unavailable }
            let kind: String = row["source_kind"]
            let identifier: String = row["source_identifier"]
            guard ["apple-photos", "apple-photos-full", "apple-photos-benchmark"].contains(kind),
                  !identifier.isEmpty,
                  identifier.rangeOfCharacter(from: .controlCharacters) == nil else { throw Failure.unavailable }
            return identifier
        }
    }

    // PhotoKit identifiers are passed as a string, not interpolated as code.
    static func scriptString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    @MainActor
    static func open(assetID: String, errors: ErrorStore) {
        do {
            let identifier = try identifier(for: assetID)
            let script = """
                tell application id "com.apple.Photos"
                    spotlight (media item id \(scriptString(identifier)))
                    activate
                end tell
                """
            guard let appleScript = NSAppleScript(source: script) else { throw Failure.unavailable }
            var details: NSDictionary?
            appleScript.executeAndReturnError(&details)
            if let details {
                let message = details[NSAppleScript.errorMessage] as? String ?? "Check Photos access and try again."
                throw Failure.photosError(message)
            }
        } catch {
            errors.present(title: "Unable to Open in Photos", message: error.localizedDescription)
        }
    }
}
