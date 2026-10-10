import Foundation
import Darwin

/// Locates the backend command that hosts the visual-search encoder.
///
/// The packaged app lives at `<repository>/dist/Photo Search.app`, so the backend
/// environment is reachable without configuration. `backend.json` overrides that
/// for installations whose backend lives somewhere else.
enum PhotoEncoderCommand {
    static func resolve() -> [String]? {
        configured() ?? bundled()
    }

    private static var configurationURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PhotoSearch/backend.json")
    }

    private static func configured() -> [String]? {
        guard let data = try? Data(contentsOf: configurationURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = object["encoder_command"] as? [String],
              let executable = command.first,
              FileManager.default.isExecutableFile(atPath: executable)
        else { return nil }
        return command
    }

    private static func bundled() -> [String]? {
        let repository = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let executable = repository
            .appendingPathComponent("backend/.venv/bin/photo-search")
            .path
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }
        return [executable, "encoder-serve"]
    }
}

/// Talks to the encoder host over stdin/stdout.
///
/// The app owns the host process: it starts it, asks for query vectors, and can
/// ask it to release the model when memory is tight. One request is in flight at
/// a time, so the blocking pipe reads stay on a private serial queue.
final class PhotoEncoderClient: @unchecked Sendable {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Terminal events the host can answer a request with.
    struct Response {
        let event: String
        let loaded: Bool?
        let residentBytes: Int?
        let dimensions: Int?
        let vector: [Float]?
    }

    enum Request: Sendable {
        case status
        case load
        case offload
        case embed(String)
        case quit

        var payload: [String: Any] {
            switch self {
            case .status: ["command": "status"]
            case .load: ["command": "load"]
            case .offload: ["command": "offload"]
            case .embed(let text): ["command": "embed", "text": text]
            case .quit: ["command": "quit"]
            }
        }

        /// The event that answers this request. Anything else on the stream is
        /// either progress or a side effect of the request (loading an encoder
        /// before answering an embed), so it must not end the read.
        var terminalEvent: String {
            switch self {
            case .status: "status"
            case .load: "loaded"
            case .offload, .quit: "offloaded"
            case .embed: "vector"
            }
        }
    }

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }

    private let lifecycleLock = NSLock()
    private var shuttingDown = false
    private var liveProcess: Process?
    private let requestTimeout: TimeInterval?
    private let queue = DispatchQueue(label: "photo-search.encoder-client")
    private let command: [String]?
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()

    /// `command` is injectable so tests can drive the stdio contract with a stub.
    init(command: [String]? = PhotoEncoderCommand.resolve(), requestTimeout: TimeInterval? = nil) {
        self.command = command
        self.requestTimeout = requestTimeout
    }

    var isAvailable: Bool { command != nil }

    /// Sends one request and returns its terminal event, reporting load stages.
    func send(_ request: Request,
              onProgress: @escaping @Sendable (Double, String) -> Void) async throws -> Response {
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        guard !cancellation.isCancelled else { throw CancellationError() }
                        continuation.resume(returning: try self.perform(request, cancellation: cancellation,
                                                                        onProgress: onProgress))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// Termination must not wait behind a pipe read on the request queue.
    func shutdown() {
        let running = lifecycleLock.withLock {
            shuttingDown = true
            return liveProcess
        }
        if let running, running.isRunning { running.terminate() }
        queue.async { self.stop() }
    }

    // MARK: - Request plumbing

    private func perform(_ request: Request, cancellation: Cancellation,
                         onProgress: @Sendable (Double, String) -> Void) throws -> Response {
        defer {
            if cancellation.isCancelled { stop() }
        }
        try startIfNeeded()
        guard let input else { throw Failure(message: "The visual search helper is not running.") }
        let body = try JSONSerialization.data(withJSONObject: request.payload)
        try input.write(contentsOf: body + Data([0x0A]))

        let defaultTimeout: TimeInterval
        switch request {
        case .load: defaultTimeout = 300
        case .embed: defaultTimeout = 45
        case .offload: defaultTimeout = 30
        case .status, .quit: defaultTimeout = 10
        }
        let timeout = requestTimeout ?? defaultTimeout
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            let line: Data
            do {
                line = try readLine(deadline: deadline, cancellation: cancellation)
            } catch {
                stop()
                throw error
            }
            guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let name = event["event"] as? String else { continue }
            switch name {
            case "progress":
                onProgress(event["progress"] as? Double ?? 0, event["stage"] as? String ?? "")
            case "error":
                stop()
                throw Failure(message: event["error"] as? String ?? "The visual search helper failed.")
            case request.terminalEvent:
                return Response(
                    event: name,
                    loaded: event["loaded"] as? Bool,
                    residentBytes: event["resident_bytes"] as? Int,
                    dimensions: event["dimensions"] as? Int,
                    vector: (event["vector"] as? [Double])?.map(Float.init)
                )
            default:
                continue
            }
        }
    }

    private func startIfNeeded() throws {
        guard !lifecycleLock.withLock({ shuttingDown }) else { throw CancellationError() }
        if let process, process.isRunning { return }
        stop()
        guard let command else {
            throw Failure(message: "The visual search encoder is not installed.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        lifecycleLock.withLock { liveProcess = process }
        self.input = inputPipe.fileHandleForWriting
        self.output = outputPipe.fileHandleForReading
        self.buffer = Data()
    }

    private func readLine(deadline: TimeInterval, cancellation: Cancellation) throws -> Data {
        while true {
            guard !cancellation.isCancelled, !lifecycleLock.withLock({ shuttingDown }) else {
                throw CancellationError()
            }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else {
                throw Failure(message: String(localized: "Visual search timed out. Try searching again.", bundle: .module))
            }
            if let range = buffer.firstRange(of: Data([0x0A])) {
                let line = Data(buffer[buffer.startIndex..<range.lowerBound])
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                return line
            }
            guard let output else { throw Failure(message: "The visual search helper stopped.") }
            var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let result = Darwin.poll(&descriptor, 1, Int32(min(remaining * 1000, 100).rounded(.up)))
            if result < 0 {
                if errno == EINTR { continue }
                throw Failure(message: "The visual search helper could not be read.")
            }
            if result == 0 { continue }
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(output.fileDescriptor, &bytes, bytes.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw Failure(message: "The visual search helper stopped.") }
            buffer.append(contentsOf: bytes.prefix(count))
            guard buffer.count <= 1024 * 1024 else {
                throw Failure(message: "The visual search helper returned an oversized response.")
            }
        }
    }

    private func stop() {
        if let process, process.isRunning {
            process.terminate()
            // Only the app-owned helper is killed; it must not survive a timed-out request.
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
        input?.closeFile()
        output?.closeFile()
        process = nil
        lifecycleLock.withLock { liveProcess = nil }
        input = nil
        output = nil
        buffer = Data()
    }
}
