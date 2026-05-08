import Foundation

/// Configuration for Session's built-in inference capability.
public struct SessionConfig: Sendable {
    public var apiKey: String
    public var model: String
    public var maxTokens: Int
    public var timeoutInterval: TimeInterval

    public static let defaultModel = "claude-sonnet-4-6"

    public init(apiKey: String,
                model: String = defaultModel,
                maxTokens: Int = 2048,
                timeoutInterval: TimeInterval = 30) {
        self.apiKey = apiKey
        self.model = model
        self.maxTokens = maxTokens
        self.timeoutInterval = timeoutInterval
    }
}
