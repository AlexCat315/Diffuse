/// A model provider the editor can select. Transport remains in the host:
/// the contribution names a supported API format, base URL and models, and
/// the host owns credentials, HTTP, streaming and auditing.
public struct AIProviderContribution: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    /// `anthropic`, `openai-responses` or `openai-compatible`.
    public var apiFormat: String
    public var baseURL: String?
    public var defaultModel: String?
    public var models: [AIModelContribution]
    public var auth: AIAuthContribution?

    public init(id: String, title: String, apiFormat: String, baseURL: String? = nil,
                defaultModel: String? = nil, models: [AIModelContribution],
                auth: AIAuthContribution? = nil) {
        self.id = id
        self.title = title
        self.apiFormat = apiFormat
        self.baseURL = baseURL
        self.defaultModel = defaultModel
        self.models = models
        self.auth = auth
    }
}

public struct AIModelContribution: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var contextWindow: Int?
    public var maxOutputTokens: Int?
    public var supportsTools: Bool?

    public init(id: String, title: String, contextWindow: Int? = nil,
                maxOutputTokens: Int? = nil, supportsTools: Bool? = nil) {
        self.id = id
        self.title = title
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.supportsTools = supportsTools
    }
}

public struct AIAuthContribution: Codable, Sendable, Equatable {
    /// Only `apiKey` is supported for host-mediated providers.
    public var type: String
    public var fields: [AIAuthFieldContribution]

    public init(type: String = "apiKey", fields: [AIAuthFieldContribution]) {
        self.type = type
        self.fields = fields
    }
}

public struct AIAuthFieldContribution: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var secret: Bool?
    /// Host-only fallback when the credential file has no value.
    public var environmentVariable: String?

    public init(id: String, title: String, secret: Bool? = nil,
                environmentVariable: String? = nil) {
        self.id = id
        self.title = title
        self.secret = secret
        self.environmentVariable = environmentVariable
    }
}

