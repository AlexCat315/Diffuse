public import Foundation
public import GuavaUIAgentCore

public struct UIDiagnosticOverview: Codable, Sendable {
    public let nodeCount: Int
    public let componentCount: Int
    public let stateObservationAvailable: Bool
    public let timelineAvailable: Bool
    public let hasRoot: Bool
    public let layoutIssues: UIDiagnosticLayoutSummary
}

private struct QueryResponse<Value: Encodable>: Encodable {
    let ok = true
    let data: Value
}

// Typed inputs mirror the schemas in UIDiagnosticTool. They live next to the
// handlers so a renamed field fails decoding instead of silently falling back
// to a default.
private struct GetDiagnosticsInput: Decodable {
    var limit: Int?
}

private struct QueryNodesInput: Decodable {
    var nodeID: String?
    var text: String?
    var role: String?
    var source: String?
    var visibleOnly: Bool?
    var inputEnabledOnly: Bool?
    var offset: Int?
    var limit: Int?

    enum CodingKeys: String, CodingKey {
        case nodeID = "node_id"
        case text, role, source
        case visibleOnly = "visible_only"
        case inputEnabledOnly = "input_enabled_only"
        case offset, limit
    }
}

private struct RecompositionInput: Decodable {
    var text: String?
    var minimumCount: Int?
    var offset: Int?
    var limit: Int?

    enum CodingKeys: String, CodingKey {
        case text
        case minimumCount = "minimum_count"
        case offset, limit
    }
}

private struct StateInput: Decodable {
    var ids: [String]?
    var scopeID: String?
    var offset: Int?
    var limit: Int?

    enum CodingKeys: String, CodingKey {
        case ids
        case scopeID = "scope_id"
        case offset, limit
    }
}

private struct TraceInput: Decodable {
    var captureID: String
    var offset: Int?
    var limit: Int?

    enum CodingKeys: String, CodingKey {
        case captureID = "capture_id"
        case offset, limit
    }
}

private struct CompareTracesInput: Decodable {
    var baselineID: String
    var candidateID: String

    enum CodingKeys: String, CodingKey {
        case baselineID = "baseline_id"
        case candidateID = "candidate_id"
    }
}

private struct CaptureTraceInput: Decodable {
    var durationMS: Int?

    enum CodingKeys: String, CodingKey {
        case durationMS = "duration_ms"
    }
}

private struct EmptyInput: Decodable {}

private struct ReadSkillInput: Decodable {
    var name: String
}

public extension UIDiagnostics {
    /// A complete portable toolbox suitable for AgentSession or MCPServer.
    func toolbox() throws -> AgentToolbox {
        try AgentToolbox(tools: UIDiagnosticTools.tools) { [weak self] name, input in
            guard let self else { throw AgentError.invalidConfiguration("UI diagnostics session ended.") }
            return try await self.execute(name: name, input: input)
        }
    }

    func execute(name: String, input: Data) async throws -> AgentToolResult {
        guard let tool = UIDiagnosticTools.tool(named: name) else { throw AgentError.unknownTool(name) }
        if tool == .captureUITrace {
            try validate(input, for: tool)
            let args = try decode(CaptureTraceInput.self, from: input)
            return try await AgentToolResult.encode(
                QueryResponse(data: captureTrace(durationMilliseconds: args.durationMS ?? 500)))
        }
        return try executeRead(tool: tool, input: input)
    }
}

extension UIDiagnostics {
    /// Immediate reads can run in a native host's synchronous frame inbox.
    /// The asynchronous toolbox and wire adapter share validation and results.
    func executeRead(name: String, input: Data) throws -> AgentToolResult {
        guard let tool = UIDiagnosticTools.tool(named: name) else { throw AgentError.unknownTool(name) }
        return try executeRead(tool: tool, input: input)
    }

    func executeRead(tool: UIDiagnosticTool, input: Data) throws -> AgentToolResult {
        try validate(input, for: tool)
        let result = try readResponse(tool: tool, input: input)
        guard result.json.count <= 524_288 else { throw AgentError.invalidResult }
        return result
    }

    private func validate(_ input: Data, for tool: UIDiagnosticTool) throws {
        guard input.count <= 262_144 else {
            throw AgentError.invalidConfiguration("Query exceeds 256 KiB.")
        }
        try JSONSchemaValidator.validate(data: input, against: tool.definition.schema)
    }

    private func decode<T: Decodable>(_ type: T.Type, from input: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: input)
        } catch {
            throw AgentError.invalidConfiguration("Invalid arguments for this tool: \(error)")
        }
    }

    private func readResponse(tool: UIDiagnosticTool, input: Data) throws -> AgentToolResult {
        switch tool {
        case .getDiagnostics:
            let args = try decode(GetDiagnosticsInput.self, from: input)
            let nodes = try queryNodes(limit: 1)
            return try AgentToolResult.encode(QueryResponse(data: UIDiagnosticOverview(nodeCount: nodes.total,
                componentCount: queryRecomposition(limit: 1).total, stateObservationAvailable: stateObservationAvailable,
                timelineAvailable: true, hasRoot: nodes.total > 0,
                layoutIssues: layoutIssues(limit: args.limit ?? 50))))
        case .queryUINodes:
            let args = try decode(QueryNodesInput.self, from: input)
            let page = try queryNodes(id: args.nodeID,
                text: args.text, role: args.role, source: args.source,
                visibleOnly: args.visibleOnly ?? false,
                inputEnabledOnly: args.inputEnabledOnly ?? false,
                offset: args.offset ?? 0, limit: args.limit ?? 50)
            return try encodeNodes(page)
        case .queryUIRecomposition:
            let args = try decode(RecompositionInput.self, from: input)
            return try encodeNodes(queryRecomposition(text: args.text,
                minimumCount: UInt64(args.minimumCount ?? 0),
                offset: args.offset ?? 0, limit: args.limit ?? 50))
        case .queryUIState:
            let args = try decode(StateInput.self, from: input)
            return try AgentToolResult.encode(QueryResponse(data: queryState(ids: args.ids ?? [],
                scopeID: args.scopeID, offset: args.offset ?? 0, limit: args.limit ?? 50)))
        case .getUITrace:
            let args = try decode(TraceInput.self, from: input)
            return try AgentToolResult.encode(QueryResponse(data: queryTrace(id: args.captureID,
                offset: args.offset ?? 0, limit: args.limit ?? 50)))
        case .compareUITraces:
            let args = try decode(CompareTracesInput.self, from: input)
            return try AgentToolResult.encode(QueryResponse(data: compareTraces(
                baselineID: args.baselineID, candidateID: args.candidateID)))
        case .listSkills:
            _ = try decode(EmptyInput.self, from: input)
            return try AgentToolResult.encode(QueryResponse(data: UIDiagnosticTools.skills().skills.map {
                ["name": $0.name, "description": $0.description]
            }))
        case .readSkill:
            let args = try decode(ReadSkillInput.self, from: input)
            return try AgentToolResult.encode(QueryResponse(data: UIDiagnosticTools.skills().read(name: args.name)))
        case .captureUITrace:
            throw AgentError.invalidConfiguration("capture_ui_trace requires the asynchronous toolbox.")
        }
    }

    private func encodeNodes(_ page: UIDiagnosticPage<UIDiagnosticNode>) throws -> AgentToolResult {
        if let invalid = page.items.compactMap(\.geometryIssue).first {
            throw AgentError.invalidConfiguration("Node \(invalid.nodeID) has invalid layout geometry. Use get_diagnostics.layoutIssues for values and source.")
        }
        return try AgentToolResult.encode(QueryResponse(data: page))
    }
}
