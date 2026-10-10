import Foundation
import Testing
@testable import LiquidGlassDemo

@Suite struct PhotoIndexActivityTests {
    private func payload(_ status: String, pending: Int? = nil,
                         error: String? = nil) -> PhotoWorkerStatus.Payload {
        PhotoWorkerStatus.Payload(status: status, lastError: error, pending: pending)
    }

    @Test func runningAndFreshMeansIndexing() {
        let now = Date()
        #expect(PhotoWorkerStatus.activity(payload("running"), modified: now, now: now) == .indexing)
    }

    /// The worker stops writing while the Mac sleeps; that silence must not be
    /// reported as a failure.
    @Test func staleRunningIsExplicitlyOutOfDate() {
        let now = Date()
        let long = now.addingTimeInterval(-PhotoWorkerStatus.staleAfter - 60)
        #expect(PhotoWorkerStatus.activity(payload("running"), modified: long, now: now) == .stale)
    }

    @Test func waitingIsSeparateFromActiveProcessing() {
        let now = Date()
        #expect(PhotoWorkerStatus.activity(payload("waiting", pending: 12), modified: now, now: now) == .waiting)
        #expect(PhotoWorkerStatus.activity(payload("waiting", pending: 0), modified: now, now: now) == .waiting)
    }

    @Test func anErrorOutranksAFreshTimestamp() {
        let now = Date()
        let paused = PhotoWorkerStatus.activity(
            payload("waiting", pending: 12, error: "ModelProviderError: timed out"),
            modified: now, now: now
        )
        #expect(paused == .paused)
    }

    @Test func completionRequiresBothTextAndVisualCoverage() {
        let now = Date()
        var complete = payload("complete", pending: 0)
        #expect(PhotoWorkerStatus.activity(complete, modified: now, now: now) == .waiting)
        complete.embeddingPending = 0
        #expect(PhotoWorkerStatus.activity(complete, modified: now, now: now) == .complete)
        complete.embeddingPending = 12
        #expect(PhotoWorkerStatus.activity(complete, modified: now, now: now) == .waiting)
        complete.embeddingError = "Model failed"
        #expect(PhotoWorkerStatus.activity(complete, modified: now, now: now) == .paused)
        #expect(PhotoWorkerStatus.activity(payload("unknown"), modified: now, now: now) == .idle)
    }

    @Test func skippedCompletionAndUnknownCoverageRemainExplicit() {
        let now = Date()
        var result = payload("complete_with_errors", pending: 0)
        #expect(PhotoWorkerStatus.activity(result, modified: now, now: now) == .waiting)
        result.embeddingPending = 0
        #expect(PhotoWorkerStatus.activity(result, modified: now, now: now) == .completeWithErrors)
        let old = now.addingTimeInterval(-600)
        #expect(PhotoWorkerStatus.activity(result, modified: old, now: now) == .stale)
    }

    @Test func loadReadsTheWorkerFile() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("photo-index-activity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let path = directory.appendingPathComponent("worker-status.json").path
        try #"{"status": "running", "stage": "indexing", "pending": 2267, "last_error": null}"#
            .write(toFile: path, atomically: true, encoding: .utf8)
        #expect(PhotoWorkerStatus.load(at: path) == .indexing)

        try #"{"status": "waiting", "last_error": "ModelProviderError: timed out"}"#
            .write(toFile: path, atomically: true, encoding: .utf8)
        #expect(PhotoWorkerStatus.load(at: path) == .paused)

        #expect(PhotoWorkerStatus.load(at: directory.appendingPathComponent("missing.json").path) == .idle)
    }

    @Test func captionsOnlyNameWorkThatIsHappening() {
        #expect(PhotoIndexActivity.indexing.caption == "Indexing")
        #expect(PhotoIndexActivity.paused.caption == "Paused")
        #expect(PhotoIndexActivity.idle.caption == nil)
    }

    @Test func eachStateNamesItselfForTheSettingsPage() {
        #expect(PhotoIndexActivity.indexing.headline == "Indexing")
        #expect(PhotoIndexActivity.paused.headline == "Paused after an error")
        #expect(PhotoIndexActivity.idle.headline == "No current indexing status")
        #expect(PhotoIndexActivity.complete.headline == "Up to date")
        #expect(PhotoIndexActivity.stale.headline == "Status out of date")
        for state in [PhotoIndexActivity.indexing, .paused, .idle] {
            #expect(!state.statusIcon.isEmpty)
        }
    }

    @Test func stageTokensBecomeReadableText() {
        func detail(_ stage: String?) -> String {
            PhotoWorkerStatus.Payload(status: "running", stage: stage).statusDetail
        }
        #expect(detail("indexing") == "Reading photos and videos")
        #expect(detail("embedding") == "Building the visual index")
        #expect(detail("complete") == "Everything is indexed")
        // An unknown stage degrades to a readable form instead of a raw token.
        #expect(detail("doing_something_new") == "doing something new")
        // With no stage at all, fall back to the status rather than showing blank.
        #expect(detail(nil) == "running")
    }

    @Test func etaRendersOnlyWhenTheWorkerSetOne() {
        var payload = PhotoWorkerStatus.Payload(status: "running")
        #expect(payload.etaText == nil)
        payload.etaAt = "2026-09-26T05:22:17.278677+00:00"
        #expect(payload.etaText != nil)
        payload.etaAt = "not-a-timestamp"
        #expect(payload.etaText == nil)
    }

    @MainActor
    @Test func storeExposesTheWholeSnapshotNotJustTheVerdict() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("photo-index-snapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let path = directory.appendingPathComponent("worker-status.json").path
        try #"""
        {"status": "running", "stage": "indexing", "annotated": 6594, "library_images": 8682,
         "pending": 2096, "rate_per_hour": 58.4, "eta_at": "2026-09-26T05:22:17+00:00",
         "message": "[9] photos-abc.jpg"}
        """#.write(toFile: path, atomically: true, encoding: .utf8)

        let store = PhotoIndexActivityStore(path: path)
        #expect(store.activity == .indexing)
        #expect(store.snapshot?.payload.annotated == 6594)
        #expect(store.snapshot?.payload.libraryImages == 8682)
        #expect(store.snapshot?.payload.ratePerHour == 58.4)
        #expect(store.snapshot?.payload.message == "[9] photos-abc.jpg")
        #expect(store.snapshot?.payload.etaText != nil)
    }
}
