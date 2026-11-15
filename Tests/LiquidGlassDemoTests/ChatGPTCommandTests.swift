import Foundation
import Testing
@testable import LiquidGlassDemo

@Suite struct ChatGPTCommandTests {
    @Test(arguments: [false, true])
    func authorizationArrivesWhileTheHelperIsWaitingForItsCallback(fragmented: Bool) async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chatgpt-pipe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("authorized")
        let script = directory.appendingPathComponent("helper.sh")
        let event = #"{"event":"authorize","url":"https://auth.openai.com/api/accounts/authorize?fixture=1"}"#
        let emit = fragmented
            ? "printf '%s' '\(event.prefix(20))'\nsleep 0.02\nprintf '%s\\n' '\(event.dropFirst(20))'"
            : "printf '%s\\n' '\(event)'"
        let body = """
        \(emit)
        for attempt in {1..200}; do
          if [[ -f '\(marker.path)' ]]; then
            printf '%s\\n' '{"event":"connected","account_id":"fixture"}'
            exit 0
          fi
          sleep 0.01
        done
        printf '%s\\n' '{"event":"error","error":"authorization callback arrived too late"}'
        exit 1
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        let command = ChatGPTCommand(command: ["/bin/zsh", script.path])
        defer { command.cancel() }
        let result = try await command.run([]) { url in
            #expect(url.host == "auth.openai.com")
            do { try Data().write(to: marker) }
            catch { Issue.record("Could not acknowledge the synthetic callback: \(error)") }
        }
        #expect(result.event == "connected")
        #expect(result.accountId == "fixture")
    }

    @Test func authorizationDoesNotOpenAnUntrustedOrigin() async throws {
        let command = ChatGPTCommand(command: ["/bin/zsh", "-c", """
        printf '%s\\n' '{"event":"authorize","url":"https://untrusted.invalid/api/accounts/authorize"}'
        printf '%s\\n' '{"event":"connected","account_id":"fixture"}'
        """])
        let result = try await command.run([]) { _ in Issue.record("Untrusted authorization URL was opened") }
        #expect(result.event == "connected")
    }
}
