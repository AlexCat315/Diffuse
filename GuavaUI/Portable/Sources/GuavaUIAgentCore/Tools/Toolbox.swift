import Foundation

public enum AgentError: Error, LocalizedError, Sendable {
    case invalidConfiguration(String), unknownTool(String), invalidResult, stepLimit
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message): message
        case .unknownTool(let name): "Unknown tool: \(name)"
        case .invalidResult: "Tool returned invalid JSON or exceeded 512 KiB."
        case .stepLimit: "Agent reached its tool round limit."
        }
    }
}

/// One validated boundary shared by model sessions and MCP clients.
public struct AgentToolbox: Sendable {
    public typealias Executor = @Sendable (String, Data) async throws -> AgentToolResult
    public let tools: [AgentTool]
    private let executor: Executor

    public init(tools: [AgentTool], execute: @escaping Executor) throws {
        guard tools.count <= 256, Set(tools.map(\.name)).count == tools.count,
              tools.allSatisfy({ !$0.name.isEmpty && $0.name.utf8.count <= 128
                  && $0.description.utf8.count <= 16_384 }) else {
            throw AgentError.invalidConfiguration("Tool names must be unique and bounded; at most 256 tools are supported.")
        }
        self.tools = tools
        self.executor = execute
    }

    public func execute(name: String, input: Data) async throws -> AgentToolResult {
        guard let tool = tools.first(where: { $0.name == name }) else { throw AgentError.unknownTool(name) }
        guard input.count <= 262_144 else { throw AgentError.invalidConfiguration("Tool input exceeds 256 KiB.") }
        try JSONSchemaValidator.validate(data: input, against: tool.schema)
        try Task.checkCancellation()
        let result = try await executor(name, input)
        try Task.checkCancellation()
        guard result.json.count <= 524_288,
              (try? JSONSerialization.jsonObject(with: result.json, options: [.fragmentsAllowed])) != nil else {
            throw AgentError.invalidResult
        }
        return result
    }
}
