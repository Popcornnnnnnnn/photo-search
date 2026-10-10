import Foundation
import Dispatch

/// Owns the visual-search encoder: resident by default, offloadable on demand.
///
/// The encoder is a separate local process because it holds a 2B vision model
/// that cannot run inside the app. The app starts that process itself, so there
/// is no port, no LaunchAgent, and nothing to uninstall separately.
@Observable
@MainActor
final class PhotoEncoderStore {
    enum State: Equatable {
        case unavailable(String)
        case offloaded
        case loading(progress: Double, stage: String)
        case ready(bytes: Int)
    }

    private(set) var state: State
    private(set) var lastFailure: String?

    /// Release the model when macOS reports memory pressure.
    var offloadsWhenMemoryIsTight: Bool {
        didSet {
            UserDefaults.standard.set(offloadsWhenMemoryIsTight, forKey: Prefs.offloadEncoderWhenTight)
        }
    }

    @ObservationIgnored private let client = PhotoEncoderClient()
    @ObservationIgnored private var pressureSource: DispatchSourceMemoryPressure?
    @ObservationIgnored private var inFlight: Task<Bool, Never>?
    @ObservationIgnored private var inFlightID: UUID?
    @ObservationIgnored private var loadGeneration = 0

    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Prefs.offloadEncoderWhenTight) == nil {
            defaults.set(true, forKey: Prefs.offloadEncoderWhenTight)
        }
        offloadsWhenMemoryIsTight = defaults.bool(forKey: Prefs.offloadEncoderWhenTight)
        state = client.isAvailable
            ? .offloaded
            : .unavailable("The visual search encoder is not installed for this app.")
        observeMemoryPressure()
    }

    var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }

    var isAvailable: Bool {
        if case .unavailable = state { return false }
        return true
    }

    var loadProgress: Double {
        if case .loading(let progress, _) = state { return progress }
        return 0
    }

    var loadStage: String {
        if case .loading(_, let stage) = state { return stage }
        return ""
    }

    var residentBytes: Int {
        if case .ready(let bytes) = state { return bytes }
        return 0
    }

    var residentDescription: String {
        switch state {
        case .ready(let bytes):
            bytes > 0 ? ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory) : "Resident"
        case .loading:
            "Loading"
        case .offloaded:
            "Offloaded"
        case .unavailable:
            "Unavailable"
        }
    }

    // MARK: - Lifecycle

    func refresh() async {
        guard client.isAvailable else {
            state = .unavailable("The visual search encoder is not installed for this app.")
            return
        }
        do {
            let response = try await client.send(.status) { _, _ in }
            state = response.loaded == true
                ? .ready(bytes: response.residentBytes ?? 0)
                : .offloaded
            lastFailure = nil
        } catch {
            state = .offloaded
            lastFailure = error.localizedDescription
        }
    }

    /// Makes sure the model is in memory, reporting progress while it loads.
    func prepare() async -> Bool {
        if case .ready = state { return true }
        if case .unavailable = state { return false }
        let task: Task<Bool, Never>
        let id: UUID
        if let existing = inFlight, !existing.isCancelled, let existingID = inFlightID {
            task = existing
            id = existingID
        } else {
            id = UUID()
            task = Task { await self.load() }
            inFlight = task
            inFlightID = id
        }
        let ready = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if inFlightID == id {
            inFlight = nil
            inFlightID = nil
        }
        return ready && !Task.isCancelled
    }

    func offload() async {
        if let inFlight { _ = await inFlight.value }
        guard client.isAvailable else { return }
        do {
            _ = try await client.send(.offload) { _, _ in }
            state = .offloaded
            lastFailure = nil
        } catch {
            state = .offloaded
            lastFailure = error.localizedDescription
        }
    }

    func embed(_ text: String) async -> [Float]? {
        do {
            let response = try await client.send(.embed(text)) { _, _ in }
            lastFailure = nil
            return response.vector
        } catch {
            lastFailure = error.localizedDescription
            state = .offloaded
            return nil
        }
    }

    func shutdown() {
        inFlight?.cancel()
        pressureSource?.cancel()
        pressureSource = nil
        client.shutdown()
    }

    // MARK: - Internals

    private func load() async -> Bool {
        loadGeneration += 1
        let generation = loadGeneration
        state = .loading(progress: 0, stage: "Starting the visual search encoder")
        do {
            let response = try await client.send(.load) { [weak self] progress, stage in
                Task { @MainActor [weak self] in
                    guard let self, self.loadGeneration == generation, case .loading = self.state else { return }
                    self.state = .loading(progress: progress, stage: stage)
                }
            }
            guard generation == loadGeneration, !Task.isCancelled else { return false }
            state = .ready(bytes: response.residentBytes ?? 0)
            lastFailure = nil
            return true
        } catch {
            guard generation == loadGeneration else { return false }
            state = .offloaded
            lastFailure = error is CancellationError ? nil : error.localizedDescription
            return false
        }
    }

    private func observeMemoryPressure() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: .main
        )
        source.setEventHandler { [weak self] in
            PhotoSearchEngine.clearCache()
            guard let self, self.offloadsWhenMemoryIsTight else { return }
            guard case .ready = self.state else { return }
            Task { await self.offload() }
        }
        source.resume()
        pressureSource = source
    }
}
