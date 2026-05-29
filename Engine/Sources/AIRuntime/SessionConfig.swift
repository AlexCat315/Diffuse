import Foundation

/// Which wire format the inference endpoint speaks.
public enum SessionAPIFormat: Sendable {
    case anthropic
    case openAICompatible
}

/// Named assets available in the project, surfaced in the system prompt so Claude
/// can use correct clip/mesh names rather than guessing.
public struct AssetCatalog: Sendable {
    /// Audio clip names (no file extension). Used by set_audio_source.
    public var audioClips: [String]
    /// Animation clip names. Used by set_animation_player.
    public var animationClips: [String]
    /// Mesh/model names available for spawning or reference. Optional context only.
    public var meshNames: [String]

    public init(audioClips: [String] = [],
                animationClips: [String] = [],
                meshNames: [String] = []) {
        self.audioClips = audioClips
        self.animationClips = animationClips
        self.meshNames = meshNames
    }

    public var isEmpty: Bool {
        audioClips.isEmpty && animationClips.isEmpty && meshNames.isEmpty
    }

    /// Compact system-prompt section listing available assets.
    var systemPromptSection: String {
        var lines: [String] = []
        if !audioClips.isEmpty {
            lines.append("Available audio clips (use exact names for set_audio_source): \(audioClips.joined(separator: ", "))")
        }
        if !animationClips.isEmpty {
            lines.append("Available animation clips (use exact names for set_animation_player): \(animationClips.joined(separator: ", "))")
        }
        if !meshNames.isEmpty {
            lines.append("Available meshes: \(meshNames.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }
}

/// Configuration for Session's built-in inference capability.
public struct SessionConfig: Sendable {
    public var apiKey: String
    public var model: String
    public var maxTokens: Int
    public var timeoutInterval: TimeInterval
    public var baseURL: URL
    public var apiFormat: SessionAPIFormat
    /// When `true`, produced Proposals use `.automatic` approval — changes apply
    /// immediately without a confirmation step. Default `false` (requires approval).
    public var autoApprove: Bool
    /// Project asset catalog surfaced in the system prompt. Set this to the asset
    /// names available in the project so Claude uses correct clip/mesh identifiers.
    public var assetCatalog: AssetCatalog
    /// Backoff policy for transient inference failures (rate limits, 5xx, dropped connections).
    public var retryPolicy: RetryPolicy

    public static let defaultModel          = "claude-sonnet-4-6"
    public static let defaultAnthropicModel = "claude-sonnet-4-6"
    public static let defaultOpenAIModel    = "gpt-4o"
    public static let defaultDeepSeekModel  = "deepseek-chat"

    public init(apiKey: String,
                model: String,
                maxTokens: Int = 2048,
                timeoutInterval: TimeInterval = 90,
                baseURL: URL,
                apiFormat: SessionAPIFormat,
                autoApprove: Bool = false,
                assetCatalog: AssetCatalog = AssetCatalog(),
                retryPolicy: RetryPolicy = .default) {
        self.apiKey = apiKey
        self.model = model
        self.maxTokens = maxTokens
        self.timeoutInterval = timeoutInterval
        self.baseURL = baseURL
        self.apiFormat = apiFormat
        self.autoApprove = autoApprove
        self.assetCatalog = assetCatalog
        self.retryPolicy = retryPolicy
    }

    public static func anthropic(apiKey: String,
                                  model: String = defaultAnthropicModel,
                                  maxTokens: Int = 2048,
                                  timeoutInterval: TimeInterval = 90,
                                  autoApprove: Bool = false,
                                  assetCatalog: AssetCatalog = AssetCatalog(),
                                  retryPolicy: RetryPolicy = .default) -> SessionConfig {
        SessionConfig(apiKey: apiKey,
                      model: model,
                      maxTokens: maxTokens,
                      timeoutInterval: timeoutInterval,
                      baseURL: URL(string: "https://api.anthropic.com")!,
                      apiFormat: .anthropic,
                      autoApprove: autoApprove,
                      assetCatalog: assetCatalog,
                      retryPolicy: retryPolicy)
    }

    public static func openAI(apiKey: String,
                               model: String = defaultOpenAIModel,
                               maxTokens: Int = 2048,
                               timeoutInterval: TimeInterval = 90,
                               autoApprove: Bool = false,
                               assetCatalog: AssetCatalog = AssetCatalog(),
                               retryPolicy: RetryPolicy = .default) -> SessionConfig {
        SessionConfig(apiKey: apiKey,
                      model: model,
                      maxTokens: maxTokens,
                      timeoutInterval: timeoutInterval,
                      baseURL: URL(string: "https://api.openai.com")!,
                      apiFormat: .openAICompatible,
                      autoApprove: autoApprove,
                      assetCatalog: assetCatalog,
                      retryPolicy: retryPolicy)
    }

    public static func deepSeek(apiKey: String,
                                 model: String = defaultDeepSeekModel,
                                 maxTokens: Int = 2048,
                                 timeoutInterval: TimeInterval = 90,
                                 autoApprove: Bool = false,
                                 assetCatalog: AssetCatalog = AssetCatalog(),
                                 retryPolicy: RetryPolicy = .default) -> SessionConfig {
        SessionConfig(apiKey: apiKey,
                      model: model,
                      maxTokens: maxTokens,
                      timeoutInterval: timeoutInterval,
                      baseURL: URL(string: "https://api.deepseek.com")!,
                      apiFormat: .openAICompatible,
                      autoApprove: autoApprove,
                      assetCatalog: assetCatalog,
                      retryPolicy: retryPolicy)
    }
}
