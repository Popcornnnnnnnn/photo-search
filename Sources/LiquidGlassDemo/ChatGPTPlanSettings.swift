import AppKit
import Foundation

struct ChatGPTAccount: Decodable, Identifiable, Sendable {
    var id: String
    var label: String
    var signedIn: Bool
    var planEnabled: Bool
}

struct ChatGPTModel: Decodable, Identifiable, Sendable {
    var id: String
    var name: String
}

private struct ChatGPTEvent: Decodable, Sendable {
    var event: String?
    var url: String?
    var error: String?
    var accounts: [ChatGPTAccount]?
    var accountId: String?
    var models: [ChatGPTModel]?
    var imageUnderstanding: Bool?
    var revoked: Bool?
}

/// Pipes structured helper events directly to the app. OAuth URLs and credentials
/// never go to the worker logs or the provider configuration file.
private final class ChatGPTCommand: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        if process?.isRunning == true { process?.terminate() }
    }

    private func setProcess(_ value: Process?) {
        lock.lock(); defer { lock.unlock() }
        process = value
    }

    func run(_ arguments: [String], authorize: @escaping @MainActor @Sendable (URL) -> Void) async throws -> ChatGPTEvent {
        guard let encoder = PhotoEncoderCommand.resolve(), encoder.count >= 2 else {
            throw Failure(message: "Photo Search backend is unavailable.")
        }
        let command = Array(encoder.dropLast()) + ["chatgpt"] + arguments
        return try await Task.detached { [self] in
            let child = Process()
            child.executableURL = URL(fileURLWithPath: command[0])
            child.arguments = Array(command.dropFirst())
            let pipe = Pipe()
            child.standardOutput = pipe
            child.standardError = FileHandle.nullDevice
            try child.run()
            setProcess(child)
            defer { setProcess(nil) }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            var buffer = Data()
            var last: ChatGPTEvent?
            while let data = try pipe.fileHandleForReading.read(upToCount: 4096), !data.isEmpty {
                buffer.append(data)
                guard buffer.count <= 1_000_000 else {
                    child.terminate()
                    throw Failure(message: "ChatGPT returned an invalid helper response.")
                }
                while let newline = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    let event = try decoder.decode(ChatGPTEvent.self, from: line)
                    if event.event == "authorize", let value = event.url,
                       let url = URL(string: value), url.scheme == "https", url.host == "auth.openai.com",
                       url.path == "/api/accounts/authorize" {
                        await authorize(url)
                    } else {
                        last = event
                    }
                }
            }
            child.waitUntilExit()
            if let error = last?.error { throw Failure(message: error) }
            guard child.terminationStatus == 0, let last else {
                throw Failure(message: "ChatGPT operation ended. Try again.")
            }
            return last
        }.value
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}

enum ChatGPTModelCatalog {
    /// Keep OAuth credentials and the plan-specific catalog format in the helper.
    static func load(accountID: String) async throws -> [ChatGPTModel] {
        let command = ChatGPTCommand()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let event = try await command.run(["models", "--account", accountID], authorize: { _ in })
            try Task.checkCancellation()
            return event.models ?? []
        } onCancel: {
            command.cancel()
        }
    }
}

@Observable
@MainActor
final class ChatGPTPlanSettings {
    var accounts: [ChatGPTAccount] = []
    var models: [ChatGPTModel] = []
    var selectedAccountID = ""
    var selectedModelID = ""
    var busy = false
    var message = ""
    var imageTestPassed = false
    private let command = ChatGPTCommand()

    var account: ChatGPTAccount? { accounts.first { $0.id == selectedAccountID } }
    var canUsePlan: Bool { account?.planEnabled == true && models.contains { $0.id == selectedModelID } }

    func cancel() { command.cancel() }

    func load(profile: ModelProviderProfile?) async {
        guard !busy else { return }
        if let profile {
            selectedAccountID = profile.chatgptAccountID ?? ""
            selectedModelID = profile.model
        }
        busy = true
        defer { busy = false }
        do {
            let event = try await command.run(["status"], authorize: { _ in })
            accounts = event.accounts ?? []
            if !accounts.contains(where: { $0.id == selectedAccountID }) {
                selectedAccountID = accounts.first?.id ?? ""
            }
            if account?.planEnabled == true { try await fetchModels() }
        } catch { message = error.localizedDescription }
    }

    func signIn(newAccount: Bool = false) async {
        busy = true
        message = ""
        imageTestPassed = false
        defer { busy = false }
        do {
            var arguments = ["login"]
            if !newAccount, !selectedAccountID.isEmpty { arguments += ["--account", selectedAccountID] }
            let event = try await command.run(arguments, authorize: { NSWorkspace.shared.open($0) })
            accounts = event.accounts ?? []
            selectedAccountID = event.accountId ?? selectedAccountID
            models = []
            if account?.planEnabled == true {
                try await fetchModels()
            } else {
                message = String(localized: "Signed in. ChatGPT plan usage was not authorized.", bundle: L10n.bundle)
            }
        } catch { message = error.localizedDescription }
    }

    func changeAccount() async {
        busy = true
        models = []
        selectedModelID = ""
        imageTestPassed = false
        message = ""
        defer { busy = false }
        do { if account?.planEnabled == true { try await fetchModels() } }
        catch { message = error.localizedDescription }
    }

    private func fetchModels() async throws {
        let event = try await command.run(["models", "--account", selectedAccountID], authorize: { _ in })
        models = event.models ?? []
        if !models.contains(where: { $0.id == selectedModelID }) {
            selectedModelID = models.first(where: { $0.id == "gpt-6.1-sol" })?.id ?? models.first?.id ?? ""
        }
    }

    func testImage() async {
        guard canUsePlan else { return }
        busy = true
        imageTestPassed = false
        message = ""
        defer { busy = false }
        do {
            let result = try await command.run(["test", "--account", selectedAccountID, "--model", selectedModelID], authorize: { _ in })
            imageTestPassed = result.imageUnderstanding == true
            message = imageTestPassed ? String(localized: "Test image recognized using your ChatGPT plan.", bundle: L10n.bundle) : String(localized: "Image test did not complete.", bundle: L10n.bundle)
        } catch { message = error.localizedDescription }
    }

    func signOut() async {
        busy = true
        defer { busy = false }
        do {
            let event = try await command.run(["signout", "--account", selectedAccountID], authorize: { _ in })
            accounts = event.accounts ?? []
            models = []
            imageTestPassed = false
            message = event.revoked == true ? String(localized: "Signed out.", bundle: L10n.bundle) : String(localized: "Signed out locally. Disconnect Photo Search in ChatGPT settings to confirm revocation.", bundle: L10n.bundle)
        } catch { message = error.localizedDescription }
    }
}
