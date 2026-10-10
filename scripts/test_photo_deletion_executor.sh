#!/usr/bin/env bash
# Runs the actual deletion source against an Objective-C-style callback stub.
# The stub deliberately lacks @Sendable on performChanges, like PhotoKit's API,
# and invokes the callback on a private Dispatch queue. No photo library access.
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_DIR="$(mktemp -d)"
trap 'rm -rf "$CHECK_DIR"' EXIT
cat > "$CHECK_DIR/Photos.swift" <<'SWIFT'
import Foundation

public enum PHAuthorizationStatus: Sendable { case authorized, limited }
public enum PHAccessLevel: Sendable { case readWrite }
public enum PHAssetEditOperation: Sendable { case delete }
public final class PHAsset: Sendable {
    public static func fetchAssets(withLocalIdentifiers ids: [String], options: Any?) -> PHFetchResult {
        precondition(ids == ["executor-regression-fixture-1", "executor-regression-fixture-2"])
        return PHFetchResult()
    }
    public func canPerform(_ operation: PHAssetEditOperation) -> Bool { true }
}
public final class PHFetchResult: Sendable {
    public var count: Int { 2 }
    public func object(at index: Int) -> PHAsset { PHAsset() }
}
public enum PHAssetChangeRequest {
    public static func deleteAssets(_ assets: PHFetchResult) {
        precondition(assets.count == 2)
        dispatchPrecondition(condition: .onQueue(PHPhotoLibrary.transactionQueue))
        print("PASS: production deletion callback ran on the private transaction queue")
    }
}
// The unchecked box is confined to this test stub: it recreates the legacy
// Objective-C API contract that Swift cannot statically verify.
private final class Callback: @unchecked Sendable {
    let body: () -> Void
    init(_ body: @escaping () -> Void) { self.body = body }
}
public final class PHPhotoLibrary: Sendable {
    static let transactionQueue = DispatchQueue(label: "photo-deletion-regression.transaction")
    public static func shared() -> PHPhotoLibrary { PHPhotoLibrary() }
    public static func requestAuthorization(for level: PHAccessLevel) async -> PHAuthorizationStatus { .authorized }
    public func performChanges(_ changes: @escaping () -> Void) async throws {
        let callback = Callback(changes)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Self.transactionQueue.async {
                callback.body()
                continuation.resume()
            }
        }
    }
}
SWIFT
cat > "$CHECK_DIR/Main.swift" <<'SWIFT'
import Foundation
@main struct Check {
    @MainActor static func main() async throws {
        try await PhotoLibraryDeletion.delete(localIdentifiers: ["executor-regression-fixture-1", "executor-regression-fixture-2"])
        MainActor.assertIsolated()
        print("PASS: deletion returned to MainActor")
    }
}
SWIFT
swiftc -swift-version 6 -emit-library -emit-module -module-name Photos \
    "$CHECK_DIR/Photos.swift" -o "$CHECK_DIR/libPhotos.dylib" -emit-module-path "$CHECK_DIR/Photos.swiftmodule"
swiftc -swift-version 6 -parse-as-library -I "$CHECK_DIR" -L "$CHECK_DIR" -lPhotos \
    Sources/LiquidGlassDemo/PhotoLibraryDeletion.swift "$CHECK_DIR/Main.swift" -o "$CHECK_DIR/check"
"$CHECK_DIR/check"
