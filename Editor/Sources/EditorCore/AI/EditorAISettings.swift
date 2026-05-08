import AIRuntime
import Foundation
import Security

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

    public static let `default` = EditorAISettings(
        provider: .none,
        model: SessionConfig.defaultAnthropicModel
    )

    public init(provider: EditorAIProvider = .none,
                model: String = SessionConfig.defaultAnthropicModel) {
        self.provider = provider
        self.model = model
    }
}

// MARK: - Keychain

/// Stores provider API keys in the system Keychain under the Guava service name.
/// Keys are indexed by provider raw value so each provider has an independent slot.
public enum AIKeychain {
    private static let service = "dev.guava.editor.ai"

    public static func save(key: String, provider: EditorAIProvider) {
        guard !key.isEmpty else {
            delete(provider: provider)
            return
        }
        let data = Data(key.utf8)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: provider.rawValue,
            kSecValueData: data,
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    public static func load(provider: EditorAIProvider) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: provider.rawValue,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty else {
            return nil
        }
        return key
    }

    public static func delete(provider: EditorAIProvider) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: provider.rawValue,
        ]
        SecItemDelete(query as CFDictionary)
    }

    public static func hasKey(for provider: EditorAIProvider) -> Bool {
        load(provider: provider) != nil
    }
}
