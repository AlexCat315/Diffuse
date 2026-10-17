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

public extension UIDiagnostics {
    /// A complete portable toolbox suitable for AgentSession or MCPServer.
    func toolbox() throws -> AgentToolbox {
        try AgentToolbox(tools: UIDiagnosticTools.tools) { [weak self] name, input in
            guard let self else { throw AgentError.invalidConfiguration("UI diagnostics session ended.") }
            return try await self.execute(name: name, input: input)
        }
    }

    func execute(name: String, input: Data) async throws -> AgentToolResult {
        if name == "capture_ui_trace" {
            let args = try validatedArguments(name: name, input: input)
            return try await AgentToolResult.encode(QueryResponse(data: captureTrace(durationMilliseconds: args["duration_ms"] as? Int ?? 500)))
        }
        return try executeRead(name: name, input: input)
    }
}

extension UIDiagnostics {
    /// Immediate reads can run in a native host's synchronous frame inbox.
    /// The asynchronous toolbox and wire adapter share validation and results.
    func executeRead(name: String, input: Data) throws -> AgentToolResult {
        let args = try validatedArguments(name: name, input: input)
        let result = try readResponse(name: name, args: args)
        guard result.json.count <= 524_288 else { throw AgentError.invalidResult }
        return result
    }

    private func validatedArguments(name: String, input: Data) throws -> [String: Any] {
        guard let tool = UIDiagnosticTools.tools.first(where: { $0.name == name }) else { throw AgentError.unknownTool(name) }
        guard input.count <= 262_144 else { throw AgentError.invalidConfiguration("Query exceeds 256 KiB.") }
        try JSONSchemaValidator.validate(data: input, against: tool.schema)
        return (try JSONSerialization.jsonObject(with: input) as? [String: Any] ?? [:])
            .filter { !($0.value is NSNull) }
    }

    private func readResponse(name: String, args: [String: Any]) throws -> AgentToolResult {
        let offset = args["offset"] as? Int ?? 0, limit = args["limit"] as? Int ?? 50
        switch name {
        case "get_diagnostics":
            let nodes = try queryNodes(limit: 1)
            return try AgentToolResult.encode(QueryResponse(data: UIDiagnosticOverview(nodeCount: nodes.total,
                componentCount: queryRecomposition(limit: 1).total, stateObservationAvailable: stateObservationAvailable,
                timelineAvailable: true, hasRoot: nodes.total > 0, layoutIssues: layoutIssues(limit: limit))))
        case "query_ui_nodes":
            let page = try queryNodes(id: args["node_id"] as? String,
                text: args["text"] as? String, role: args["role"] as? String, source: args["source"] as? String,
                visibleOnly: args["visible_only"] as? Bool ?? false,
                inputEnabledOnly: args["input_enabled_only"] as? Bool ?? false,
                offset: offset, limit: limit)
            return try encodeNodes(page)
        case "query_ui_recomposition":
            return try encodeNodes(queryRecomposition(text: args["text"] as? String,
                minimumCount: UInt64(args["minimum_count"] as? Int ?? 0), offset: offset, limit: limit))
        case "query_ui_state":
            return try AgentToolResult.encode(QueryResponse(data: queryState(ids: args["ids"] as? [String] ?? [],
                scopeID: args["scope_id"] as? String, offset: offset, limit: limit)))
        case "get_ui_trace":
            return try AgentToolResult.encode(QueryResponse(data: queryTrace(id: args["capture_id"] as? String ?? "", offset: offset, limit: limit)))
        case "compare_ui_traces":
            return try AgentToolResult.encode(QueryResponse(data: compareTraces(baselineID: args["baseline_id"] as? String ?? "",
                candidateID: args["candidate_id"] as? String ?? "")))
        case "list_skills":
            return try AgentToolResult.encode(QueryResponse(data: UIDiagnosticTools.skills().skills.map {
                ["name": $0.name, "description": $0.description]
            }))
        case "read_skill":
            return try AgentToolResult.encode(QueryResponse(data: UIDiagnosticTools.skills().read(name: args["name"] as? String ?? "")))
        default: throw AgentError.unknownTool(name)
        }
    }

    private func encodeNodes(_ page: UIDiagnosticPage<UIDiagnosticNode>) throws -> AgentToolResult {
        if let invalid = page.items.compactMap(\.geometryIssue).first {
            throw AgentError.invalidConfiguration("Node \(invalid.nodeID) has invalid layout geometry. Use get_diagnostics.layoutIssues for values and source.")
        }
        return try AgentToolResult.encode(QueryResponse(data: page))
    }
}
