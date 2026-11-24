import Foundation
import Testing
@testable import LiquidGlassDemo

/// Guards the stdio contract with the encoder host. `read(upToCount:)` blocks
/// until it fills the requested count, so a short reply must be read with
/// `availableData`; that regression is what this test pins down.
@Suite struct PhotoEncoderClientTests {
    @Test func statusRoundTripsOverThePipe() async throws {
        let client = PhotoEncoderClient()
        guard client.isAvailable else { return }  // no backend checkout to talk to
        defer { client.shutdown() }

        let response = try await client.send(.status) { _, _ in }

        #expect(response.event == "status")
        #expect(response.loaded == false)
        #expect(response.dimensions == 2048)
    }

    /// The host loads the encoder before answering an embed, so a `loaded` line
    /// can arrive first. Reading it as the answer leaves the real vector in the
    /// pipe and the *next* query then receives this one's vector.
    @Test func embedSkipsALoadedLineAndReturnsItsOwnVector() async throws {
        let script = try StubHost.make(
            replies: [
                #"{"event":"loaded","dimensions":2048,"resident_bytes":123}"#,
                #"{"event":"vector","dimensions":2048,"vector":[1.5,2.5]}"#,
            ]
        )
        defer { StubHost.remove(script) }
        let client = PhotoEncoderClient(command: ["/bin/zsh", script.path])
        defer { client.shutdown() }

        let response = try await client.send(.embed("约会")) { _, _ in }

        #expect(response.event == "vector")
        #expect(response.vector == [1.5, 2.5])
    }
    @Test func aSilentHostTimesOutAndTheNextSearchRestartsIt() async throws {
        let script = try StubHost.make(replies: [#"{"event":"status","loaded":false}"#], firstRequestHangs: true)
        defer { StubHost.remove(script) }
        let client = PhotoEncoderClient(command: ["/bin/zsh", script.path], requestTimeout: 0.2)
        defer { client.shutdown() }
        do {
            _ = try await client.send(.status) { _, _ in }
            Issue.record("A silent host must time out")
        } catch {
            #expect(error.localizedDescription.contains("timed out"))
        }
        let response = try await client.send(.status) { _, _ in }
        #expect(response.event == "status")
    }

    @Test func cancellationStopsTheOldReadWithoutConsumingTheNextReply() async throws {
        let script = try StubHost.make(replies: [#"{"event":"status","loaded":false}"#], firstRequestHangs: true)
        defer { StubHost.remove(script) }
        let client = PhotoEncoderClient(command: ["/bin/zsh", script.path], requestTimeout: 5)
        defer { client.shutdown() }
        let request = Task { try await client.send(.status) { _, _ in } }
        try await StubHost.waitUntilStarted(script)
        request.cancel()
        do {
            _ = try await request.value
            Issue.record("The cancelled request must finish with cancellation")
        } catch { #expect(error is CancellationError) }
        let response = try await client.send(.status) { _, _ in }
        #expect(response.event == "status")
    }

    @Test func quittingDoesNotWaitForASilentHost() async throws {
        let script = try StubHost.make(replies: [], firstRequestHangs: true)
        defer { StubHost.remove(script) }
        let client = PhotoEncoderClient(command: ["/bin/zsh", script.path], requestTimeout: 5)
        let request = Task { try await client.send(.status) { _, _ in } }
        try await StubHost.waitUntilStarted(script)
        let start = Date()
        client.shutdown()
        #expect(Date().timeIntervalSince(start) < 1)
        do {
            _ = try await request.value
            Issue.record("Shutdown must release an active request")
        } catch { }
    }

}

/// A tiny stand-in for the encoder host: echoes canned replies to each request.
enum StubHost {
    struct Script {
        let directory: URL
        let path: String
    }

    static func make(replies: [String], firstRequestHangs: Bool = false) throws -> Script {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("photo-search-stub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("stub-host.sh")
        let marker = directory.appendingPathComponent("started").path
        let hang = firstRequestHangs
            ? ["if [[ ! -f '\(marker)' ]]; then", "  : > '\(marker)'", "  read -r ignored", "fi"] : []
        let body = (["#!/bin/zsh", "while read -r line; do"] + hang +
                    replies.flatMap { ["  print -r -- '\($0)'"] } +
                    ["done", ""]).joined(separator: "\n")
        try body.write(to: URL(fileURLWithPath: path.path), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: path.path)
        return Script(directory: directory, path: path.path)
    }

    static func waitUntilStarted(_ script: Script) async throws {
        let marker = script.directory.appendingPathComponent("started").path
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: marker) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw PhotoEncoderClient.Failure(message: "Stub host did not start")
    }

    static func remove(_ script: Script) {
        try? FileManager.default.removeItem(at: script.directory)
    }
}
