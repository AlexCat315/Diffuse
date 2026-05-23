import AIRuntime
import CapabilityRuntime
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
    /// When `true`, AI edit plans are applied immediately without a confirmation step.
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
