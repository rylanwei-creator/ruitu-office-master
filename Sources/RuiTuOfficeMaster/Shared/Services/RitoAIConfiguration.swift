import Foundation
import Observation
import CryptoKit

enum RitoAIProviderKind: String, CaseIterable, Identifiable, Codable {
    case deepSeek = "DeepSeek", doubao = "豆包火山方舟", qwen = "通义千问百炼", custom = "自定义兼容接口"
    var id: String { rawValue }
    var endpoint: String {
        switch self {
        case .deepSeek: "https://api.deepseek.com/chat/completions"
        case .doubao: "https://ark.cn-beijing.volces.com/api/v3/chat/completions"
        case .qwen: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
        case .custom: ""
        }
    }
    var model: String { switch self { case .deepSeek: "deepseek-flash"; case .qwen: "qwen-plus"; default: "" } }
}

@MainActor @Observable final class RitoAIConfiguration {
    enum Mode: String, CaseIterable { case local = "本地免费 AI", customAPI = "自定义云端 API" }
    static let shared = RitoAIConfiguration()
    var mode: Mode { didSet { persist() } }
    var provider: RitoAIProviderKind { didSet {
        let nextEndpoint = defaults.string(forKey: "rito.dual.endpoint." + provider.id) ?? provider.endpoint
        let nextModel = defaults.string(forKey: "rito.dual.model." + provider.id) ?? provider.model
        endpoint = nextEndpoint
        modelID = nextModel
        persist()
    } }
    var endpoint: String { didSet { persist() } }
    var modelID: String { didSet { persist() } }
    private(set) var revision = 0
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keychain: any RitoCredentialStore
    init(defaults: UserDefaults = .standard, keychain: any RitoCredentialStore = RitoKeychain()) {
        self.defaults = defaults; self.keychain = keychain
        mode = Mode(rawValue: defaults.string(forKey: "rito.dual.mode") ?? "") ?? .local
        let selected = RitoAIProviderKind(rawValue: defaults.string(forKey: "rito.dual.provider") ?? "") ?? .deepSeek
        provider = selected
        endpoint = defaults.string(forKey: "rito.dual.endpoint." + selected.id) ?? selected.endpoint
        modelID = defaults.string(forKey: "rito.dual.model." + selected.id) ?? selected.model
    }
    private func credentialAccount() throws -> String {
        guard let url = RitoCustomAPIProvider.validEndpoint(endpoint), let host = url.host else { throw RitoCloudError.invalidEndpoint }
        // Changing service or origin never silently forwards an old key to a different host.
        let origin = "https://" + host.lowercased() + ":" + String(url.port ?? 443)
        let hash = SHA256.hash(data: Data(origin.utf8)).map { String(format: "%02x", $0) }.joined()
        return "custom-api." + provider.id + "." + hash
    }
    func saveKey(_ value: String) throws { try keychain.save(value, account: credentialAccount()); revision += 1 }
    func deleteKey() throws { try keychain.delete(credentialAccount()); revision += 1 }
    // Creating a provider never prompts during rendering or editing settings.
    // Credentials are read again for each explicit request, including retries.
    func customProvider() throws -> RitoCredentialAPIProvider {
        guard let url = RitoCustomAPIProvider.validEndpoint(endpoint),
              !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              modelID.count <= 120 else { throw RitoCloudError.notConfigured }
        return .init(endpoint: url, model: modelID, account: try credentialAccount(), credentials: keychain)
    }
    func makeProvider() -> any AIProvider {
        if mode == .local { return RitoOfficeProvider(underlying: RitoLocalProvider()) }
        do { return RitoOfficeProvider(underlying: try customProvider()) }
        catch { return RitoUnavailableProvider(source: .custom, message: error.localizedDescription) }
    }
    private func persist() {
        defaults.set(mode.rawValue, forKey: "rito.dual.mode"); defaults.set(provider.rawValue, forKey: "rito.dual.provider")
        defaults.set(endpoint, forKey: "rito.dual.endpoint." + provider.id); defaults.set(modelID, forKey: "rito.dual.model." + provider.id)
        revision += 1
    }
}

struct RitoUnavailableProvider: AIProvider {
    let source: RitoReplySource
    let message: String
    var capabilities: AIProviderCapabilities { .init(offline: source == .local) }
    func reply(to request: RToolAIRequest) async throws -> RToolAIReply {
        throw NSError(domain: "RitoAI", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// The key lives only in a request-scoped provider, never in UI state or preferences.
struct RitoCredentialAPIProvider: AIProvider {
    let endpoint: URL
    let model: String
    let account: String
    let credentials: any RitoCredentialStore
    var transport: any RitoStreamingTransport = RitoURLSessionTransport()
    var credentialTimeout: TimeInterval = 30
    var source: RitoReplySource { .custom }
    var capabilities: AIProviderCapabilities { .init() }

    func resolve() async throws -> RitoCustomAPIProvider {
        try Task.checkCancellation()
        RitoRequestTrace.event("credential_requested",flush:true)
        // Security.framework can wait for a dialog; leave the main thread responsive.
        let key = try await RitoAsyncDeadline.run(seconds:credentialTimeout,timeout:RitoCloudError.credentialTimeout) {
            let read = Task.detached(priority:.userInitiated) { try credentials.read(account) }
            return try await read.value
        }
        try Task.checkCancellation() // Late authorization cannot send a stopped request.
        guard let key, !key.isEmpty else { throw RitoCloudError.notConfigured }
        RitoRequestTrace.event("credential_available",flush:true)
        return .init(endpoint: endpoint, authorization: key, model: model, transport: transport)
    }
    func reply(to request: RToolAIRequest) async throws -> RToolAIReply {
        await request.progress?(.authorizing)
        let provider = try await resolve()
        return try await provider.reply(to: request)
    }
    func stream(to request: RToolAIRequest, delta: @escaping @MainActor @Sendable (String) -> Void) async throws -> RToolAIReply {
        await request.progress?(.authorizing)
        let provider = try await resolve()
        return try await provider.stream(to: request, delta: delta)
    }
}
