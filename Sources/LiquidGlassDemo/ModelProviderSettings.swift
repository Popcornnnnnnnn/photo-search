import Foundation
import Security
import Darwin

enum ModelProviderKind: String, Codable, CaseIterable, Identifiable {
    case local
    case cloud

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct ModelProviderProfile: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var kind: ModelProviderKind
    var baseURL: String
    var model: String
    var producer: String
    var requiresTailscale: Bool
    var jsonMode: Bool
    var qwenThinkingControl: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, kind, model, producer
        case baseURL = "base_url"
        case requiresTailscale = "requires_tailscale"
        case jsonMode = "json_mode"
        case qwenThinkingControl = "qwen_thinking_control"
    }

    static let qwen4090 = ModelProviderProfile(
        id: "qwen-4090",
        name: "Qwen 4090",
        kind: .local,
        baseURL: "http://127.0.0.1:18000/v1",
        model: "qwen3.8-27b-fp8",
        producer: "qwen-vlm",
        requiresTailscale: true,
        jsonMode: true,
        qwenThinkingControl: true
    )

    static func custom() -> ModelProviderProfile {
        let id = "provider-\(UUID().uuidString.lowercased())"
        return ModelProviderProfile(
            id: id,
            name: "New Provider",
            kind: .local,
            baseURL: "http://127.0.0.1:8000/v1",
            model: "",
            producer: "openai-compatible:\(id)",
            requiresTailscale: false,
            jsonMode: true,
            qwenThinkingControl: false
        )
    }
}

struct ModelProviderFile: Codable, Equatable {
    var version = 1
    var activeProviderID: String
    var reprocessExisting: Bool
    var providers: [ModelProviderProfile]

    enum CodingKeys: String, CodingKey {
        case version, providers
        case activeProviderID = "active_provider_id"
        case reprocessExisting = "reprocess_existing"
    }

    static let `default` = ModelProviderFile(
        activeProviderID: ModelProviderProfile.qwen4090.id,
        reprocessExisting: false,
        providers: [.qwen4090]
    )
}

enum ProviderConnectionState: Equatable {
    case idle
    case testing
    case success(String)
    case failure(String)

    var message: String {
        switch self {
        case .idle: "Not tested"
        case .testing: "Testing connection…"
        case .success(let message), .failure(let message): message
        }
    }
}

@Observable
@MainActor
final class ModelProviderSettings {
    static let keychainService = "com.popcornnn.photo-search.model-api-key"

    var configuration: ModelProviderFile
    var draftProvider: ModelProviderProfile?
    var draftAPIKey = ""
    var draftReprocessExisting = false
    var isAddingProvider = false
    var connectionState: ProviderConnectionState = .idle
    var savedMessage = ""

    init(configuration: ModelProviderFile? = nil) {
        self.configuration = configuration ?? Self.loadConfiguration()
    }

    var activeProvider: ModelProviderProfile? {
        configuration.providers.first { $0.id == configuration.activeProviderID }
    }

    var draftHasStoredAPIKey: Bool {
        guard let draftProvider else { return false }
        return Self.readAPIKey(providerID: draftProvider.id) != nil
    }

    func beginAddingProvider() {
        draftProvider = .custom()
        draftAPIKey = ""
        draftReprocessExisting = configuration.reprocessExisting
        isAddingProvider = true
        connectionState = .idle
        savedMessage = ""
    }

    func beginEditingProvider(_ provider: ModelProviderProfile) {
        draftProvider = provider
        draftAPIKey = ""
        draftReprocessExisting = configuration.reprocessExisting
        isAddingProvider = false
        connectionState = .idle
        savedMessage = ""
    }

    func cancelEditing() {
        draftProvider = nil
        draftAPIKey = ""
        draftReprocessExisting = configuration.reprocessExisting
        isAddingProvider = false
        connectionState = .idle
    }

    func saveDraft() throws {
        guard var provider = draftProvider else { throw ProviderSettingsError.noProvider }
        try Self.validate(&provider)
        let wasActive = provider.id == configuration.activeProviderID
        if let index = configuration.providers.firstIndex(where: { $0.id == provider.id }) {
            configuration.providers[index] = provider
        } else {
            configuration.providers.append(provider)
        }
        if !draftAPIKey.isEmpty {
            try Self.storeAPIKey(draftAPIKey, providerID: provider.id)
        }
        configuration.reprocessExisting = draftReprocessExisting
        try persist(restartWorker: wasActive)
        savedMessage = isAddingProvider
            ? "Added \(provider.name). Choose Use when you are ready to switch."
            : "Saved \(provider.name)."
        cancelEditing()
    }

    func activateProvider(_ provider: ModelProviderProfile) throws {
        configuration.activeProviderID = provider.id
        try persist(restartWorker: true)
        savedMessage = "Using \(provider.name)."
    }

    func deleteDraftProvider() throws {
        guard let provider = draftProvider else { throw ProviderSettingsError.noProvider }
        guard provider.id != configuration.activeProviderID else {
            throw ProviderSettingsError.cannotDeleteActive
        }
        configuration.providers.removeAll { $0.id == provider.id }
        Self.deleteAPIKey(providerID: provider.id)
        try persist(restartWorker: false)
        savedMessage = "Removed \(provider.name)."
        cancelEditing()
    }

    func testDraftConnection() async {
        guard let provider = draftProvider else { return }
        connectionState = .testing
        do {
            let baseURL = provider.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let url = URL(string: "\(baseURL)/models") else {
                throw ProviderSettingsError.invalidURL
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            let key = draftAPIKey.isEmpty ? Self.readAPIKey(providerID: provider.id) : draftAPIKey
            if let key, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                throw ProviderSettingsError.connectionRejected
            }
            connectionState = .success("Connected to \(provider.name)")
        } catch {
            connectionState = .failure(error.localizedDescription)
        }
    }

    private static func validate(_ provider: inout ModelProviderProfile) throws {
        provider.name = provider.name.trimmingCharacters(in: .whitespacesAndNewlines)
        provider.baseURL = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        provider.model = provider.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !provider.name.isEmpty else { throw ProviderSettingsError.missingName }
        guard URL(string: provider.baseURL).map({ ["http", "https"].contains($0.scheme ?? "") }) == true else {
            throw ProviderSettingsError.invalidURL
        }
        guard !provider.model.isEmpty else { throw ProviderSettingsError.missingModel }
    }

    private func persist(restartWorker: Bool) throws {
        let url = Self.configurationURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(configuration)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        if restartWorker { Self.restartWorker() }
    }

    static var configurationURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PhotoSearch/model-providers.json")
    }

    static func loadConfiguration() -> ModelProviderFile {
        guard let data = try? Data(contentsOf: configurationURL) else { return .default }
        let decoder = JSONDecoder()
        guard let configuration = try? decoder.decode(ModelProviderFile.self, from: data),
              !configuration.providers.isEmpty,
              configuration.providers.contains(where: { $0.id == configuration.activeProviderID }) else {
            return .default
        }
        return configuration
    }

    private static func keychainQuery(providerID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: providerID,
        ]
    }

    private static func readAPIKey(providerID: String) -> String? {
        var query = keychainQuery(providerID: providerID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func storeAPIKey(_ key: String, providerID: String) throws {
        let query = keychainQuery(providerID: providerID)
        let data = Data(key.utf8)
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        let result: OSStatus
        if status == errSecSuccess {
            result = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        } else {
            var insert = query
            insert[kSecValueData as String] = data
            result = SecItemAdd(insert as CFDictionary, nil)
        }
        guard result == errSecSuccess else { throw ProviderSettingsError.keychain(result) }
    }

    private static func deleteAPIKey(providerID: String) {
        SecItemDelete(keychainQuery(providerID: providerID) as CFDictionary)
    }

    private static func restartWorker() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["kickstart", "-k", "gui/\(getuid())/com.popcornnn.photo-search.worker"]
        try? process.run()
    }
}

enum ProviderSettingsError: LocalizedError {
    case noProvider
    case missingName
    case invalidURL
    case missingModel
    case connectionRejected
    case cannotDeleteActive
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .noProvider: "Select a model provider."
        case .missingName: "Enter a provider name."
        case .invalidURL: "Enter a valid HTTP or HTTPS API base URL."
        case .missingModel: "Enter a model identifier."
        case .connectionRejected: "The provider rejected the connection test."
        case .cannotDeleteActive: "Switch to another provider before removing this one."
        case .keychain(let status): "Keychain could not save the API key (\(status))."
        }
    }
}
