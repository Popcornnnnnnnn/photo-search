import Foundation
import Testing
@testable import LiquidGlassDemo

@Suite struct ModelProviderRoutingTests {
    @Test func chatGPTProfileRoundTripsWithoutCredentialsAndReportsEffectiveFallback() throws {
        let profile = ModelProviderProfile.chatGPT(accountID: "oaiapp_test", model: "account-model")
        var config = ModelProviderFile.default
        config.providers.append(profile)
        config.fallbackProviderID = profile.id
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ModelProviderFile.self, from: data)
        #expect(decoded.activeProviderID == ModelProviderProfile.qwen4090.id)
        #expect(decoded.providers.last?.chatgptAccountID == "oaiapp_test")
        #expect(!String(decoding: data, as: UTF8.self).contains("access_token"))
        let status = PhotoWorkerStatus.Snapshot(
            payload: .init(status: "running", requestedProviderId: config.activeProviderID, providerId: profile.id),
            activity: .indexing, updated: Date())
        #expect(decoded.effectiveProvider(worker: status)?.kind == .chatgpt)
    }
    @Test func pythonStatusFieldsDecodeIntoTheEffectiveProvider() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let data = Data(#"{"status":"running","requested_provider_id":"qwen-4090","provider_id":"qwen-local-27b","fallback_reason":"connection refused"}"#.utf8)
        let payload = try decoder.decode(PhotoWorkerStatus.Payload.self, from: data)
        #expect(payload.requestedProviderId == "qwen-4090")
        #expect(payload.providerId == "qwen-local-27b")
        #expect(payload.fallbackReason == "connection refused")
        var config = ModelProviderFile.default
        config.providers.append(.localQwen27B)
        config.fallbackProviderID = "qwen-local-27b"
        let snapshot = PhotoWorkerStatus.Snapshot(payload: payload, activity: .indexing, updated: Date())
        #expect(config.effectiveProvider(worker: snapshot)?.model == "qwen3.8-27b-uncensored")
    }

    @Test func oldConfigurationStillDecodesWithoutFallback() throws {
        let data = try JSONEncoder().encode(ModelProviderFile.default)
        let config = try JSONDecoder().decode(ModelProviderFile.self, from: data)
        #expect(config.fallbackProviderID == nil)
        #expect(config.effectiveProvider(worker: nil)?.id == ModelProviderProfile.qwen4090.id)
    }

    @Test func onlyFreshMatchingWorkerMayReportTheFallbackAsActive() {
        var config = ModelProviderFile.default
        config.providers.append(.localQwen27B)
        config.fallbackProviderID = ModelProviderProfile.localQwen27B.id
        var worker = PhotoWorkerStatus.Snapshot(
            payload: .init(status: "running", requestedProviderId: config.activeProviderID,
                           providerId: config.fallbackProviderID),
            activity: .indexing, updated: Date())
        #expect(config.effectiveProvider(worker: worker)?.id == config.fallbackProviderID)
        worker.activity = .stale
        #expect(config.effectiveProvider(worker: worker)?.id == config.activeProviderID)
        worker.activity = .paused
        #expect(config.effectiveProvider(worker: worker)?.id == config.activeProviderID)
        worker.activity = .indexing
        worker.payload.requestedProviderId = "old-selection"
        #expect(config.effectiveProvider(worker: worker)?.id == config.activeProviderID)
    }
}
