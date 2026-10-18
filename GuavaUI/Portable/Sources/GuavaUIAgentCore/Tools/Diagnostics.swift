import Foundation

/// The canonical diagnostic tool registry. Name, schema and the immediate-read
/// capability live together so the DevTools wire adapter, the MCP toolbox and
/// the handlers cannot drift into separate string lists.
public enum UIDiagnosticTool: String, CaseIterable, Sendable {
    case getDiagnostics = "get_diagnostics"
    case queryUINodes = "query_ui_nodes"
    case queryUIRecomposition = "query_ui_recomposition"
    case queryUIState = "query_ui_state"
    case captureUITrace = "capture_ui_trace"
    case getUITrace = "get_ui_trace"
    case compareUITraces = "compare_ui_traces"
    case listSkills = "list_skills"
    case readSkill = "read_skill"

    private static func object(_ properties: [String: JSONSchema] = [:], required: [String] = []) -> JSONSchema {
        .object(properties: properties, required: required, additionalProperties: false)
    }

    private static var text: JSONSchema { .string(minLength: 1, maxLength: 256) }

    private static var paging: [String: JSONSchema] {
        ["offset": .integer(minimum: 0, maximum: 1_000_000), "limit": .integer(minimum: 1, maximum: 100)]
    }

    /// The contract exposed to MCP clients, embedded agents and DevTools.
    public var definition: AgentTool {
        switch self {
        case .getDiagnostics:
            AgentTool(name: rawValue, description: "Read bounded diagnostic issues with evidence and data availability. Recommendations are hypotheses to verify.",
                schema: Self.object(["limit": .integer(minimum: 1, maximum: 100)]))
        case .queryUINodes:
            AgentTool(name: rawValue, description: "Query live UI nodes by accessible label, value, help, role or source. Text searches also match debug names and view tags; secure values are redacted before matching. Lazy input values are omitted by default: use node_id with include_value=true to read one field, capped at 4096 characters with valueTruncated reported. Secure providers are never read. Returns flat paged results, clipped visible bounds and effective input availability, including modal scopes. Use visible_only to exclude hidden/offscreen nodes; input_enabled_only also excludes disabled or modal-blocked controls. IDs expire on unmount.",
                schema: Self.object(Self.paging.merging(["node_id": Self.text, "include_value": .boolean(), "text": Self.text, "role": Self.text, "source": Self.text, "visible_only": .boolean(), "input_enabled_only": .boolean()]) { _, new in new }))
        case .queryUIRecomposition:
            AgentTool(name: rawValue, description: "Query owning components sorted by total inclusive CPU time, including counts and invalidation causes. Child durations overlap; do not sum them as frame time.",
                schema: Self.object(Self.paging.merging(["text": Self.text, "minimum_count": .integer(minimum: 0, maximum: 1_000_000)]) { _, new in new }))
        case .queryUIState:
            AgentTool(name: rawValue, description: "List opted-in state metadata. Read summaries only for explicit ids; private state is never exposed. Unmounted ids are reported as missing.",
                schema: Self.object(Self.paging.merging(["scope_id": Self.text, "ids": .array(of: Self.text, maximumItems: 128)]) { _, new in new }))
        case .captureUITrace:
            AgentTool(name: rawValue, description: "Capture actual UI CPU spans for 50–5000 ms without forcing frames. Returns a session capture id and summary; idle captures may be empty. Does not measure GPU execution.",
                schema: Self.object(["duration_ms": .integer(minimum: 50, maximum: 5000)]))
        case .getUITrace:
            AgentTool(name: rawValue, description: "Read paged events from a retained capture. At most eight bounded captures are retained in this session.",
                schema: Self.object(Self.paging.merging(["capture_id": Self.text]) { _, new in new }, required: ["capture_id"]))
        case .compareUITraces:
            AgentTool(name: rawValue, description: "Compare counts, average and P95 CPU span times by phase for two retained captures. Different workloads and dropped spans limit comparison; changes do not prove causality.",
                schema: Self.object(["baseline_id": Self.text, "candidate_id": Self.text], required: ["baseline_id", "candidate_id"]))
        case .listSkills:
            AgentTool(name: rawValue, description: "List the host's available task guides without loading their bodies.", schema: Self.object())
        case .readSkill:
            AgentTool(name: rawValue, description: "Read a named task guide. Instructions do not grant tools or execute code.",
                schema: Self.object(["name": Self.text], required: ["name"]))
        }
    }

    /// Tools the native DevTools wire adapter may execute synchronously in the
    /// host's frame inbox. Trace reads and comparisons stay on the asynchronous
    /// toolbox because they depend on retained capture state.
    public var isImmediateRead: Bool {
        switch self {
        case .captureUITrace, .getUITrace, .compareUITraces: return false
        case .getDiagnostics, .queryUINodes, .queryUIRecomposition, .queryUIState,
             .listSkills, .readSkill: return true
        }
    }

    public static var immediateReadTools: [UIDiagnosticTool] {
        allCases.filter(\.isImmediateRead)
    }
}

/// Canonical tool contracts used by embedded agents and MCP. Hosts implement
/// the queries they can supply and report unavailable data explicitly.
public enum UIDiagnosticTools {
    public static let tools: [AgentTool] = UIDiagnosticTool.allCases.map(\.definition)

    public static func tool(named name: String) -> UIDiagnosticTool? {
        UIDiagnosticTool(rawValue: name)
    }

    public static func skills() throws -> AgentSkillLibrary {
        try AgentSkillLibrary(skills: [AgentSkill(name: "ui-diagnostics", description: "Investigate UI layout, state and performance with runtime evidence.", instructions: """
        Start with get_diagnostics to discover available data. Use query_ui_nodes to locate the affected component and its compiled source location. Query owner recomposition statistics and explicitly exposed state summaries as needed. Capture a bounded CPU trace around the real operation; an idle capture is not evidence of a successful action. Read capture events and compare equivalent workloads before and after a change. Parent spans include child work; do not sum overlapping spans as frame time. CPU draw and present timing do not measure GPU execution. Cite node, scope, sample or capture IDs with observations. Treat recommendations and correlated timings as hypotheses. Report missing, stale, truncated or dropped data. This guide grants no additional tools or write permissions.
        """)])
    }
}
