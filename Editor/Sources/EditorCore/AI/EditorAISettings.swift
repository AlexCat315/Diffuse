import AIRuntime
import Foundation

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

// MARK: - Key store

/// Stores provider API keys as a JSON file in Application Support.
/// Avoids Keychain permission dialogs that occur when the binary identity
/// changes on every `swift build` during development.
public enum AIKeychain {
    private static var keysFileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Guava", isDirectory: true)
            .appendingPathComponent("ai_keys.json")
    }

    private static func loadAll() -> [String: String] {
        guard let url = keysFileURL,
              let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return dict
    }

    private static func saveAll(_ dict: [String: String]) {
        guard let url = keysFileURL else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(dict) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    public static func save(key: String, provider: EditorAIProvider) {
        guard !key.isEmpty else {
            delete(provider: provider)
            return
        }
        var all = loadAll()
        all[provider.rawValue] = key
        saveAll(all)
    }

    public static func load(provider: EditorAIProvider) -> String? {
        guard let key = loadAll()[provider.rawValue], !key.isEmpty else { return nil }
        return key
    }

    public static func delete(provider: EditorAIProvider) {
        var all = loadAll()
        all.removeValue(forKey: provider.rawValue)
        saveAll(all)
    }

    public static func hasKey(for provider: EditorAIProvider) -> Bool {
        load(provider: provider) != nil
    }
}
