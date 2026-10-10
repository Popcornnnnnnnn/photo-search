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
        let provider = configuration.providers.first { $0.id == configuration.activeProviderID } ?? .qwen4090
        let model = try? ModelProviderSettings.connectionRequest(for: provider)
        return try await check(index: { await PhotoSearchDatabase.isAvailable() }, model: model,
                               providerName: provider.name, session: .shared)
    }

    static func check(index: @Sendable () async -> Bool, model: URLRequest?, providerName: String,
                      session: URLSession) async throws -> PhotoConnectionIssue? {
        async let indexReadable = index()
        async let modelReachable = reachable(model, session: session)
        let (indexOK, modelOK) = try await (indexReadable, modelReachable)
        // Never claim existing photos are searchable when the index cannot be read.
        if !indexOK { return .index }
        if !modelOK { return .model(providerName) }
        return nil
    }

    /// Number of probe attempts before reporting the model as down.
    static let probeAttempts = 3

    private static func reachable(_ request: URLRequest?, session: URLSession) async throws -> Bool {
        guard let request else { return false }
        // A single probe is a coin flip on a relayed path: the same `/models`
        // call measured 0.6s and "no answer at all" minutes apart, with the model
        // service healthy the whole time. One unlucky sample must not raise a
        // banner that claims photo processing is paused, so retry before reporting.
        for attempt in 1...probeAttempts {
            do {
                let (_, response) = try await session.data(for: request)
                try Task.checkCancellation()
                if let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode { return true }
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    throw CancellationError()
                }
            }
        }
        return false
    }
}
