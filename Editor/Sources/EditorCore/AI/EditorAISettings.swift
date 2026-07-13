import AIRuntime
import CapabilityRuntime
import Foundation
#if canImport(Security)
import Security
#endif

// MARK: - Provider

public enum EditorAIProvider: String, Codable, Sendable, Equatable, CaseIterable {
    case none
    case anthropic
    case openai
    case deepseek

    public var displayName: String {
        switch self {
        case .none:      return "None"
        case .anthropic: return "Anthropic"
        case .openai:    return "OpenAI"
        case .deepseek:  return "DeepSeek"
        }
    }

    public var defaultModel: String {
        switch self {
        case .none:      return ""
        case .anthropic: return SessionConfig.defaultAnthropicModel
        case .openai:    return SessionConfig.defaultOpenAIModel
        case .deepseek:  return SessionConfig.defaultDeepSeekModel
        }
    }
}

// MARK: - Settings

public struct EditorAISettings: Codable, Sendable, Equatable {
    public var provider: EditorAIProvider
    public var model: String
    /// Compatibility preference for read-only/legacy flows. Capability-backed
    /// AI writes always escalate to the required preview confirmation policy.
    public var autoApprove: Bool

    public static let `default` = EditorAISettings(
        provider: .none,
        model: SessionConfig.defaultAnthropicModel
    )

    public init(provider: EditorAIProvider = .none,
                model: String = SessionConfig.defaultAnthropicModel,
                autoApprove: Bool = false) {
        self.provider = provider
        self.model = model
        self.autoApprove = autoApprove
    }

    private enum CodingKeys: String, CodingKey { case provider, model, autoApprove }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decodeIfPresent(EditorAIProvider.self, forKey: .provider) ?? .none
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? SessionConfig.defaultAnthropicModel
        autoApprove = try c.decodeIfPresent(Bool.self, forKey: .autoApprove) ?? false
    }
}

// MARK: - Capability Settings

public enum EditorCapabilityReleasePhase: String, Codable, Sendable, Equatable, CaseIterable {
    case stable
    case beta
    case experimental

    public var displayName: String {
        switch self {
        case .stable:       return "Stable"
        case .beta:         return "Beta"
        case .experimental: return "Experimental"
        }
    }

    var runtimePhase: CapabilityReleasePhase {
        switch self {
        case .stable:       return .stable
        case .beta:         return .beta
        case .experimental: return .experimental
        }
    }
}

public struct EditorCapabilitySettings: Codable, Sendable, Equatable {
    public var releasePhase: EditorCapabilityReleasePhase

    public static let `default` = EditorCapabilitySettings(releasePhase: .stable)

    public init(releasePhase: EditorCapabilityReleasePhase = .stable) {
        self.releasePhase = releasePhase
    }

    private enum CodingKeys: String, CodingKey {
        case releasePhase
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        releasePhase = try values.decodeIfPresent(EditorCapabilityReleasePhase.self,
                                                  forKey: .releasePhase) ?? .stable
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(releasePhase, forKey: .releasePhase)
    }
}

// MARK: - Key store

/// Stores provider API keys in the operating-system credential store. Keys are
/// never written to project files, settings JSON, prompts, logs, or plugins.
public enum AIKeychain {
    private static let service = "com.guava.editor.ai-provider"

    private static var legacyKeysFileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Guava", isDirectory: true)
            .appendingPathComponent("ai_keys.json")
    }

    /// One-time migration from older development builds. The plaintext file is
    /// removed only after every non-empty value is present in Keychain; a
    /// Keychain failure must not silently destroy the user's credentials.
    private static func migrateLegacyPlaintextStoreIfNeeded() {
#if canImport(Security)
        guard let url = legacyKeysFileURL,
              let data = try? Data(contentsOf: url),
              let keys = try? JSONDecoder().decode([String: String].self, from: data)
        else { return }

        var migrationSucceeded = true
        for (account, key) in keys where !key.isEmpty {
            let itemIdentity: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            var lookup = itemIdentity
            lookup[kSecMatchLimit as String] = kSecMatchLimitOne
            if SecItemCopyMatching(lookup as CFDictionary, nil) == errSecSuccess {
                continue
            }
            var insert = itemIdentity
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            insert[kSecValueData as String] = Data(key.utf8)
            let status = SecItemAdd(insert as CFDictionary, nil)
            migrationSucceeded = migrationSucceeded && status == errSecSuccess
        }
        if migrationSucceeded {
            try? FileManager.default.removeItem(at: url)
        }
#endif
    }

    public static func save(key: String, provider: EditorAIProvider) {
        migrateLegacyPlaintextStoreIfNeeded()
        guard !key.isEmpty else {
            delete(provider: provider)
            return
        }
#if canImport(Security)
        delete(provider: provider)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(key.utf8),
        ]
        _ = SecItemAdd(query as CFDictionary, nil)
#endif
    }

    public static func load(provider: EditorAIProvider) -> String? {
        migrateLegacyPlaintextStoreIfNeeded()
#if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty else { return nil }
        return key
#else
        return nil
#endif
    }

    public static func delete(provider: EditorAIProvider) {
        migrateLegacyPlaintextStoreIfNeeded()
#if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
        ]
        _ = SecItemDelete(query as CFDictionary)
#endif
    }

    public static func hasKey(for provider: EditorAIProvider) -> Bool {
        load(provider: provider) != nil
    }
}
