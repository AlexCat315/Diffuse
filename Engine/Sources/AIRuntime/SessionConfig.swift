import Foundation

/// Which wire format the inference endpoint speaks.
public enum SessionAPIFormat: Sendable {
    case anthropic
    case openAICompatible
}

/// Configuration for Session's built-in inference capability.
public struct SessionConfig: Sendable {
    public var apiKey: String
    public var model: String
    public var maxTokens: Int
    public var timeoutInterval: TimeInterval
    public var baseURL: URL
    public var apiFormat: SessionAPIFormat

    public static let defaultModel          = "claude-sonnet-4-6"
    public static let defaultAnthropicModel = "claude-sonnet-4-6"
    public static let defaultOpenAIModel    = "gpt-4o"
    public static let defaultDeepSeekModel  = "deepseek-chat"

    public init(apiKey: String,
                model: String,
                maxTokens: Int = 2048,
                timeoutInterval: TimeInterval = 90,
                baseURL: URL,
                apiFormat: SessionAPIFormat) {
        self.apiKey = apiKey
        self.model = model
        self.maxTokens = maxTokens
        self.timeoutInterval = timeoutInterval
        self.baseURL = baseURL
        self.apiFormat = apiFormat
    }

    public static func anthropic(apiKey: String,
                                  model: String = defaultAnthropicModel,
                                  maxTokens: Int = 2048,
                                  timeoutInterval: TimeInterval = 90) -> SessionConfig {
        SessionConfig(apiKey: apiKey,
                      model: model,
                      maxTokens: maxTokens,
                      timeoutInterval: timeoutInterval,
                      baseURL: URL(string: "https://api.anthropic.com")!,
                      apiFormat: .anthropic)
    }

    public static func openAI(apiKey: String,
                               model: String = defaultOpenAIModel,
                               maxTokens: Int = 2048,
                               timeoutInterval: TimeInterval = 90) -> SessionConfig {
        SessionConfig(apiKey: apiKey,
                      model: model,
                      maxTokens: maxTokens,
                      timeoutInterval: timeoutInterval,
                      baseURL: URL(string: "https://api.openai.com")!,
                      apiFormat: .openAICompatible)
    }

    public static func deepSeek(apiKey: String,
                                 model: String = defaultDeepSeekModel,
                                 maxTokens: Int = 2048,
                                 timeoutInterval: TimeInterval = 90) -> SessionConfig {
        SessionConfig(apiKey: apiKey,
                      model: model,
                      maxTokens: maxTokens,
                      timeoutInterval: timeoutInterval,
                      baseURL: URL(string: "https://api.deepseek.com")!,
                      apiFormat: .openAICompatible)
    }
}
