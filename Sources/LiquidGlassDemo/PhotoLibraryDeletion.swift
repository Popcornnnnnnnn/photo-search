import Foundation
import Photos

enum PhotoLibraryDeletion {
    enum Failure: LocalizedError {
        case unsupportedSource, changedSource, permissionDenied, missingAsset, cannotDelete

        var errorDescription: String? {
            switch self {
            case .unsupportedSource:
                "This image has no verified link to an Apple Photos original. Delete it in its source app."
            case .changedSource:
                "This photo's source has changed. Refresh the review before deleting."
            case .permissionDenied:
                "Photos access is required to delete the original. Allow access in System Settings → Privacy & Security → Photos."
            case .missingAsset:
                "One or more originals are not accessible in the current Photos library. Nothing was deleted."
            case .cannotDelete:
                "Photos does not allow one or more selected items to be deleted. Nothing was deleted."
            }
        }
    }

    @MainActor
    static func delete(localIdentifiers: [String]) async throws {
        let identifiers = Array(Set(localIdentifiers)).sorted()
        guard !identifiers.isEmpty else { return }
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { throw Failure.permissionDenied }
        try Task.checkCancellation()
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        guard assets.count == identifiers.count else { throw Failure.missingAsset }
        guard (0..<assets.count).allSatisfy({ assets.object(at: $0).canPerform(.delete) }) else {
            throw Failure.cannotDelete
        }
        // PhotoKit invokes this block on its transaction queue, not MainActor.
        try await PHPhotoLibrary.shared().performChanges { @Sendable in
            PHAssetChangeRequest.deleteAssets(assets)
        }
    }
}
