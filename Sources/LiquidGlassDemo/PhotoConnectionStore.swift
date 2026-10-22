import Foundation

enum PhotoConnectionIssue: Equatable, Sendable {
    case index
    case model(String)

    var title: String {
        switch self {
        case .index: "Search index unavailable"
        case .model: "Photo processing paused"
        }
    }

    var message: String {
        switch self {
        case .index:
            "The local photo index can't be read right now. We'll check again automatically."
        case .model(let name):
            "\(name) is unavailable. Existing photos are still searchable; new photos will wait."
        }
    }
}

@Observable
@MainActor
final class PhotoConnectionStore {
    private(set) var issue: PhotoConnectionIssue?
    private(set) var isChecking = false

    @ObservationIgnored private let check: @MainActor () async throws -> PhotoConnectionIssue?

    init(check: @escaping @MainActor () async throws -> PhotoConnectionIssue? = {
        try await PhotoConnectionService.check()
    }) {
        self.check = check
    }

    func refresh() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        do {
            let nextIssue = try await check()
            try Task.checkCancellation()
            issue = nextIssue
        } catch {
            // Closing the window or cancelling a request is not a disconnection.
            guard !Task.isCancelled, !(error is CancellationError),
                  (error as? URLError)?.code != .cancelled else { return }
            issue = .index
        }
    }
}

enum PhotoConnectionService {
    @MainActor
    static func check() async throws -> PhotoConnectionIssue? {
        let configuration = ModelProviderSettings.loadConfiguration()
        let provider = configuration.effectiveProvider(worker: PhotoWorkerStatus.snapshot()) ?? .qwen4090
        return try await check(index: { await PhotoSearchDatabase.isAvailable() }, provider: provider,
                               session: .shared)
    }

    static func check(index: @Sendable () async -> Bool, provider: ModelProviderProfile,
                      session: URLSession,
                      chatGPTModels: @Sendable (String) async throws -> [ChatGPTModel] = {
                          try await ChatGPTModelCatalog.load(accountID: $0)
                      }) async throws -> PhotoConnectionIssue? {
        guard provider.kind == .chatgpt else {
            let model = try? await ModelProviderSettings.connectionRequest(for: provider)
            return try await check(index: index, model: model, providerName: provider.name,
                                   session: session, modelID: provider.model)
        }

        // Plan accounts use app-owned OAuth, not a generic API-key /models probe.
        async let indexReadable = index()
        let modelOK: Bool
        do {
            if let accountID = provider.chatgptAccountID, !accountID.isEmpty {
                let models = try await chatGPTModels(accountID)
                modelOK = models.contains { $0.id == provider.model }
            } else {
                modelOK = false
            }
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            modelOK = false
        }
        try Task.checkCancellation()
        if !(await indexReadable) { return .index }
        return modelOK ? nil : .model(provider.name)
    }

    static func check(index: @Sendable () async -> Bool, model: URLRequest?, providerName: String,
                      session: URLSession, modelID: String? = nil) async throws -> PhotoConnectionIssue? {
        async let indexReadable = index()
        async let modelReachable = reachable(model, session: session, modelID: modelID)
        let (indexOK, modelOK) = try await (indexReadable, modelReachable)
        // Never claim existing photos are searchable when the index cannot be read.
        if !indexOK { return .index }
        if !modelOK { return .model(providerName) }
        return nil
    }

    /// Number of probe attempts before reporting the model as down.
    static let probeAttempts = 3

    private static func reachable(_ request: URLRequest?, session: URLSession, modelID: String?) async throws -> Bool {
        guard let request else { return false }
        // A single probe is a coin flip on a relayed path: the same `/models`
        // call measured 0.6s and "no answer at all" minutes apart, with the model
        // service healthy the whole time. One unlucky sample must not raise a
        // banner that claims photo processing is paused, so retry before reporting.
        for _ in 1...probeAttempts {
            do {
                let (data, response) = try await session.data(for: request)
                try Task.checkCancellation()
                if let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode {
                    guard let modelID else { return true }
                    let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    let models = payload?["data"] as? [[String: Any]] ?? []
                    return models.contains { $0["id"] as? String == modelID }
                }
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    throw CancellationError()
                }
            }
        }
        return false
    }
}
