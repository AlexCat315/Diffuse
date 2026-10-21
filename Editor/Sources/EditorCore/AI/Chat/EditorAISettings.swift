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

public enum AIKeychainError: Error, Sendable, Equatable, LocalizedError {
    case unavailable
    case operationFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "The operating-system credential store is unavailable."
        case let .operationFailed(status):
            switch status {
            case -25293, -25308:
                return "The credential store refused access. Allow GuavaStudio in the Keychain prompt, or remove the old \"com.guava.editor.ai-provider\" item in Keychain Access and enter the key again."
            case -128:
                return "Access to the credential store was cancelled."
            case -25291, -25307:
                return "The login keychain is locked or unavailable."
            default:
                return "The credential store operation failed with status \(status)."
            }
        }
    }
}

public enum AICredentialSource: Sendable, Equatable {
    case operatingSystemStore
    case environment(variable: String)
}

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

    /// Runs the legacy migration at most once per process.
    private static let legacyMigration: Void = migrateLegacyPlaintextStoreIfNeeded()

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

    public static func save(key: String, provider: EditorAIProvider) throws {
        _ = legacyMigration
        guard !key.isEmpty else {
            try delete(provider: provider)
            return
        }
#if canImport(Security)
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
        ]
        // Replace rather than update. An item only trusts the build that wrote
        // it, so on development-signed builds an in-place update fails (or
        // prompts) after every rebuild; a fresh item trusts the running app.
        try delete(provider: provider)
        var insertion = identity
        insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        insertion[kSecValueData as String] = Data(key.utf8)
        let addStatus = SecItemAdd(insertion as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw AIKeychainError.operationFailed(addStatus)
        }
#else
        throw AIKeychainError.unavailable
#endif
    }

    public static func load(provider: EditorAIProvider) -> String? {
        _ = legacyMigration
        if let stored = loadFromOperatingSystemStore(provider: provider) {
            return stored
        }
        return environmentCredential(
            provider: provider,
            environment: ProcessInfo.processInfo.environment
        )?.key
    }

    /// Answers from item attributes alone, so status checks never read the
    /// secret and never trigger a Keychain access prompt.
    public static func credentialSource(for provider: EditorAIProvider) -> AICredentialSource? {
        _ = legacyMigration
        if storedItemExists(provider: provider) {
            return .operatingSystemStore
        }
        guard let environment = environmentCredential(
            provider: provider,
            environment: ProcessInfo.processInfo.environment
        ) else { return nil }
        return .environment(variable: environment.variable)
    }

    static func environmentCredential(
        provider: EditorAIProvider,
        environment: [String: String]
    ) -> (variable: String, key: String)? {
        let candidates: [String]
        switch provider {
        case .none:
            return nil
        case .anthropic:
            candidates = ["GUAVA_ANTHROPIC_API_KEY", "ANTHROPIC_API_KEY"]
        case .openai:
            candidates = ["GUAVA_OPENAI_API_KEY", "OPENAI_API_KEY"]
        case .deepseek:
            candidates = ["GUAVA_DEEPSEEK_API_KEY", "DEEPSEEK_API_KEY"]
        }
        for variable in candidates {
            guard let value = environment[variable]?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ), !value.isEmpty else { continue }
            return (variable, value)
        }
        return nil
    }

    private static func storedItemExists(provider: EditorAIProvider) -> Bool {
#if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
#else
        return false
#endif
    }

    private static func loadFromOperatingSystemStore(provider: EditorAIProvider) -> String? {
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

    public static func delete(provider: EditorAIProvider) throws {
        _ = legacyMigration
#if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AIKeychainError.operationFailed(status)
        }
#else
        throw AIKeychainError.unavailable
#endif
    }

    public static func hasKey(for provider: EditorAIProvider) -> Bool {
        credentialSource(for: provider) != nil
    }
}
