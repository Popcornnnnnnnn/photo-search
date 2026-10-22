import Foundation
import Testing
@testable import LiquidGlassDemo

@Suite struct PhotoConnectionTests {
    private func request(_ path: String) -> URLRequest {
        URLRequest(url: URL(string: "https://connection-test.invalid/\(path)")!)
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConnectionTestProtocol.self]
        return URLSession(configuration: configuration)
    }

    @Test func distinguishesModelFailureFromIndexFailure() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let cases: [(Bool, String, PhotoConnectionIssue?)] = [
            (true, "ok", nil),
            (true, "offline", .model("Qwen test")),
            (true, "unauthorized", .model("Qwen test")),
            (true, "timeout", .model("Qwen test")),
            (false, "ok", .index),
            (false, "offline", .index)
        ]
        for (index, model, expected) in cases {
            let issue = try await PhotoConnectionService.check(index: { index }, model: request(model),
                                                               providerName: "Qwen test", session: session)
            #expect(issue == expected)
        }
    }

    @Test func invalidModelConfigurationDoesNotHideAnUnreadableIndex() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let issue = try await PhotoConnectionService.check(index: { false }, model: nil,
                                                           providerName: "Qwen test", session: session)
        #expect(issue == .index)
    }

    @Test func aHealthyServerMustOfferTheSelectedModel() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        for (path, expected): (String, PhotoConnectionIssue?) in [
            ("models", nil), ("ok", .model("Local test"))
        ] {
            let issue = try await PhotoConnectionService.check(index: { true }, model: request(path),
                providerName: "Local test", session: session, modelID: "selected-model")
            #expect(issue == expected)
        }
    }

    @MainActor
    @Test func recoveryClearsTheNoticeAndCancellationDoesNotInventAnOutage() async {
        var calls = 0
        let store = PhotoConnectionStore {
            calls += 1
            switch calls {
            case 1: return .model("Qwen test")
            case 2: throw CancellationError()
            default: return nil
            }
        }
        await store.refresh()
        #expect(store.issue == .model("Qwen test"))
        await store.refresh()
        #expect(store.issue == .model("Qwen test"))
        #expect(!store.isChecking)
        await store.refresh()
        #expect(store.issue == nil)
        #expect(!store.isChecking)
    }

    @MainActor
    @Test func concurrentRefreshesDoNotStartOverlappingChecks() async {
        var calls = 0
        var release: CheckedContinuation<PhotoConnectionIssue?, Never>?
        let store = PhotoConnectionStore {
            calls += 1
            return await withCheckedContinuation { release = $0 }
        }
        let first = Task { await store.refresh() }
        while release == nil { await Task.yield() }
        await store.refresh()
        #expect(calls == 1)
        #expect(store.isChecking)
        release?.resume(returning: nil)
        await first.value
        #expect(!store.isChecking)
    }

    @MainActor
    @Test func connectionProbeUsesProviderEndpointAndAuthentication() throws {
        var provider = ModelProviderProfile.qwen4090
        provider.baseURL = "https://connection-test.invalid/v1/"
        let request = try ModelProviderSettings.connectionRequest(for: provider, apiKey: "unit-test-key")
        #expect(request.url?.absoluteString == "https://connection-test.invalid/v1/models")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer unit-test-key")
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(request.timeoutInterval == ModelProviderSettings.connectionTimeout)
    }

    @Test func chatGPTProbeUsesTheSelectedAccountsAuthorizedCatalog() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let provider = ModelProviderProfile.chatGPT(accountID: "test-account", model: "selected-model")
        let issue = try await PhotoConnectionService.check(index: { true }, provider: provider,
            session: session, chatGPTModels: { accountID in
                #expect(accountID == "test-account")
                return [ChatGPTModel(id: "selected-model", name: "Selected model")]
            })
        #expect(issue == nil)
    }

    @Test func chatGPTProbeRequiresTheSelectedModelAndReportsAuthorizationFailure() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let provider = ModelProviderProfile.chatGPT(accountID: "test-account", model: "selected-model")
        let missingModel = try await PhotoConnectionService.check(index: { true }, provider: provider,
            session: session, chatGPTModels: { _ in [ChatGPTModel(id: "other-model", name: "Other")] })
        #expect(missingModel == .model("ChatGPT"))
        let unauthorized = try await PhotoConnectionService.check(index: { true }, provider: provider,
            session: session, chatGPTModels: { _ in throw URLError(.userAuthenticationRequired) })
        #expect(unauthorized == .model("ChatGPT"))
    }

    @Test func chatGPTProbeRequiresAnAccountAndPreservesIndexErrorPriority() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let provider = ModelProviderProfile.chatGPT(accountID: "", model: "selected-model")
        for indexReadable in [true, false] {
            let issue = try await PhotoConnectionService.check(index: { indexReadable }, provider: provider,
                session: session, chatGPTModels: { _ in
                    Issue.record("A missing account must not start a catalog request")
                    return []
                })
            #expect(issue == (indexReadable ? .model("ChatGPT") : .index))
        }
        let signedIn = ModelProviderProfile.chatGPT(accountID: "test-account", model: "selected-model")
        let issue = try await PhotoConnectionService.check(index: { false }, provider: signedIn,
            session: session, chatGPTModels: { _ in throw URLError(.notConnectedToInternet) })
        #expect(issue == .index)
    }

    @Test func cancelledChatGPTProbeDoesNotBecomeAnOutage() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let provider = ModelProviderProfile.chatGPT(accountID: "test-account", model: "selected-model")
        await #expect(throws: CancellationError.self) {
            _ = try await PhotoConnectionService.check(index: { true }, provider: provider,
                session: session, chatGPTModels: { _ in throw CancellationError() })
        }
    }

    @Test func localProbeKeepsItsExistingEndpointAndNeverUsesChatGPT() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        var provider = ModelProviderProfile.localQwen27B
        provider.baseURL = "https://connection-test.invalid"
        provider.model = "selected-model"
        let issue = try await PhotoConnectionService.check(index: { true }, provider: provider,
            session: session, chatGPTModels: { _ in
                Issue.record("Local providers must not use ChatGPT authorization")
                return []
            })
        #expect(issue == nil)
    }
}

private final class ConnectionTestProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        if url.path == "/offline" || url.path == "/timeout" {
            client?.urlProtocol(self, didFailWithError: URLError(url.path == "/timeout" ? .timedOut : .cannotConnectToHost))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: url.path == "/unauthorized" ? 401 : 200,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = url.path == "/models" ? "{\"data\":[{\"id\":\"selected-model\"}]}" : "{}"
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
