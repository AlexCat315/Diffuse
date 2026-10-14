import Foundation

/// Provider wire formats supported by the shared tool contract.
public enum SessionAPIFormat: Sendable {
    case anthropic, openAIResponses, openAICompatible
}

/// Plain tool metadata. Execution stays with the application that owns the data.
public struct AgentTool: Sendable {
    public let name: String
    public let description: String
    public let schema: JSONSchema
    public let readOnly: Bool

    public init(name: String, description: String, schema: JSONSchema, readOnly: Bool = true) {
        self.name = name
        self.description = description
        self.schema = schema
        self.readOnly = readOnly
    }

    public var mcpDefinition: [String: Any] {
        ["name": name, "description": description, "inputSchema": schema.jsonObject(),
         "annotations": ["readOnlyHint": readOnly, "openWorldHint": false]]
    }

    public func providerDefinition(format: SessionAPIFormat) -> [String: Any] {
        switch format {
        case .anthropic:
            ["name": name, "description": description, "input_schema": schema.jsonObject()]
        case .openAICompatible:
            ["type": "function", "function": ["name": name, "description": description,
                                              "parameters": schema.jsonObject()]]
        case .openAIResponses:
            ["type": "function", "name": name, "description": description,
             "parameters": schema.jsonObject(), "strict": false]
        }
    }
}

public struct AgentToolResult: Sendable {
    public let json: Data
    public let isError: Bool
    public init(json: Data, isError: Bool = false) {
        self.json = json
        self.isError = isError
    }
    public static func encode<T: Encodable>(_ value: T, isError: Bool = false) throws -> Self {
        Self(json: try JSONEncoder().encode(value), isError: isError)
    }
}
