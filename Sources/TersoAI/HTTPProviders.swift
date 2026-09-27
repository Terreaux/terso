// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Security
import TersoCore

/// Secrets live in the macOS Keychain only — never in defaults, files or logs.
public enum KeychainStore {
    static let service = "org.terso.Terso.providers"

    public static func save(_ secret: String, account: String) throws {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard !secret.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(secret.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    public static func read(account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func delete(account: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] as CFDictionary)
    }
}

public struct HTTPProviderConfiguration: Codable, Sendable, Hashable, Identifiable {
    public enum Flavor: String, Codable, Sendable, CaseIterable { case openAICompatible, anthropic }
    public var id: String
    public var displayName: String
    public var flavor: Flavor
    public var baseURL: String
    public var model: String
    public var requiresKey: Bool
    public var timeout: TimeInterval

    public init(id: String, displayName: String, flavor: Flavor, baseURL: String, model: String, requiresKey: Bool, timeout: TimeInterval = 120) {
        self.id = id; self.displayName = displayName; self.flavor = flavor; self.baseURL = baseURL
        self.model = model; self.requiresKey = requiresKey; self.timeout = timeout
    }

    /// Keychain account holding this provider's key.
    public var keychainAccount: String { "apikey.\(id)" }

    /// Loopback endpoints keep text on this machine.
    public var locality: ProviderLocality {
        guard let host = URL(string: baseURL)?.host?.lowercased() else { return .network }
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) || host.hasSuffix(".localhost") ? .local : .network
    }

    public static let openAI = HTTPProviderConfiguration(id: "api.openai", displayName: "OpenAI", flavor: .openAICompatible, baseURL: "https://api.openai.com/v1", model: "gpt-5", requiresKey: true)
    public static let anthropic = HTTPProviderConfiguration(id: "api.anthropic", displayName: "Anthropic", flavor: .anthropic, baseURL: "https://api.anthropic.com/v1", model: "claude-sonnet-5", requiresKey: true)
    public static let ollama = HTTPProviderConfiguration(id: "local.ollama", displayName: "Ollama", flavor: .openAICompatible, baseURL: "http://localhost:11434/v1", model: "llama3.2", requiresKey: false)
    public static let lmStudio = HTTPProviderConfiguration(id: "local.lmstudio", displayName: "LM Studio", flavor: .openAICompatible, baseURL: "http://localhost:1234/v1", model: "local-model", requiresKey: false)
    public static let llamaCpp = HTTPProviderConfiguration(id: "local.llamacpp", displayName: "llama.cpp server", flavor: .openAICompatible, baseURL: "http://localhost:8080/v1", model: "default", requiresKey: false)
}

public struct HTTPProvider: WritingAssistantProvider {
    public let configuration: HTTPProviderConfiguration
    let session: URLSession
    let keyLookup: @Sendable (String) -> String?

    public init(configuration: HTTPProviderConfiguration, session: URLSession = .shared,
                keyLookup: @escaping @Sendable (String) -> String? = { KeychainStore.read(account: $0) }) {
        self.configuration = configuration; self.session = session; self.keyLookup = keyLookup
    }

    public var id: ProviderID { ProviderID(configuration.id) }
    public var displayName: String { configuration.displayName }
    public var locality: ProviderLocality { configuration.locality }
    public let capabilities: Set<ProviderCapability> = Set(ProviderCapability.allCases)

    public func makeURLRequest(_ request: AnalysisRequest) throws -> URLRequest {
        let key = keyLookup(configuration.keychainAccount)
        if configuration.requiresKey && (key ?? "").isEmpty { throw ProviderError.missingCredential(configuration.displayName) }
        let base = configuration.baseURL.hasSuffix("/") ? String(configuration.baseURL.dropLast()) : configuration.baseURL
        var body: [String: Any]
        var req: URLRequest
        switch configuration.flavor {
        case .openAICompatible:
            guard let url = URL(string: base + "/chat/completions") else { throw ProviderError.notConfigured("invalid URL") }
            req = URLRequest(url: url)
            if let key, !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            body = ["model": configuration.model,
                    "messages": [["role": "system", "content": PromptBuilder.system], ["role": "user", "content": PromptBuilder.user(request)]]]
        case .anthropic:
            guard let url = URL(string: base + "/messages") else { throw ProviderError.notConfigured("invalid URL") }
            req = URLRequest(url: url)
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = ["model": configuration.model, "max_tokens": 4096, "system": PromptBuilder.system,
                    "messages": [["role": "user", "content": PromptBuilder.user(request)]]]
        }
        req.httpMethod = "POST"
        req.timeoutInterval = configuration.timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    public func analyze(_ request: AnalysisRequest) async throws -> AnalysisResponse {
        let req = try makeURLRequest(request)
        let (data, response) = try await session.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw ProviderError.http(code, String(decoding: data, as: UTF8.self)) }
        return ResponseParser.parse(try Self.extractText(data, flavor: configuration.flavor))
    }

    static func extractText(_ data: Data, flavor: HTTPProviderConfiguration.Flavor) throws -> String {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ProviderError.invalidResponse("not JSON") }
        switch flavor {
        case .openAICompatible:
            if let choices = obj["choices"] as? [[String: Any]], let msg = choices.first?["message"] as? [String: Any], let text = msg["content"] as? String { return text }
        case .anthropic:
            if let content = obj["content"] as? [[String: Any]] {
                return content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
            }
        }
        throw ProviderError.invalidResponse("no text content")
    }
}

/// A scripted provider for tests and demos. Never touches the network.
public struct ScriptedProvider: WritingAssistantProvider {
    public let id = ProviderID("scripted")
    public let displayName = "Scripted"
    public let locality = ProviderLocality.local
    public let capabilities: Set<ProviderCapability> = Set(ProviderCapability.allCases)
    let reply: @Sendable (AnalysisRequest) -> String

    public init(reply: @escaping @Sendable (AnalysisRequest) -> String) { self.reply = reply }
    public func analyze(_ request: AnalysisRequest) async throws -> AnalysisResponse { ResponseParser.parse(reply(request)) }
}
