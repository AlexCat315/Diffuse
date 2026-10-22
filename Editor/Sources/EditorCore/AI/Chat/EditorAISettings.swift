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

public enum AICredentialStoreError: Error, Sendable, Equatable, LocalizedError {
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .writeFailed(reason): "The API key could not be saved: \(reason)"
        }
    }
}

public enum AICredentialSource: Sendable, Equatable {
    case credentialFile
    case environment(variable: String)
}

/// Provider API keys in one file only the user can read
/// (`~/Library/Application Support/GuavaStudio/Credentials/ai-providers.json`,
/// mode 0600 inside a 0700 folder). Keys are never written to project files,
/// settings JSON, prompts, logs, or plugins; environment variables fill in
/// providers without a stored key.
public enum AICredentialStore {
    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share")
        return base.appendingPathComponent("GuavaStudio/Credentials/ai-providers.json")
    }

    public static func save(key: String, provider: EditorAIProvider) throws {
        try save(key: key, provider: provider, at: fileURL)
    }

    static func save(key: String, provider: EditorAIProvider, at url: URL) throws {
        var keys = stored(at: url)
        keys[provider.rawValue] = key.isEmpty ? nil : key
        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let data = try JSONEncoder().encode(keys)
            // Created owner-only before the key is written, then swapped in whole.
            let staging = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
            guard FileManager.default.createFile(atPath: staging.path, contents: nil,
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteNoPermission)
            }
            let handle = try FileHandle(forWritingTo: staging)
            try handle.write(contentsOf: data)
            try handle.close()
            _ = try FileManager.default.replaceItemAt(url, withItemAt: staging)
        } catch {
            throw AICredentialStoreError.writeFailed(error.localizedDescription)
        }
    }

    public static func load(provider: EditorAIProvider) -> String? {
        stored(at: fileURL)[provider.rawValue]
            ?? environmentCredential(provider: provider, environment: ProcessInfo.processInfo.environment)?.key
    }

    public static func credentialSource(for provider: EditorAIProvider) -> AICredentialSource? {
        if stored(at: fileURL)[provider.rawValue] != nil { return .credentialFile }
        return environmentCredential(provider: provider, environment: ProcessInfo.processInfo.environment)
            .map { .environment(variable: $0.variable) }
    }

    public static func delete(provider: EditorAIProvider) throws {
        try save(key: "", provider: provider)
    }

    public static func hasKey(for provider: EditorAIProvider) -> Bool {
        credentialSource(for: provider) != nil
    }

    static func stored(at url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let keys = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return keys.filter { !$0.value.isEmpty }
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
}
