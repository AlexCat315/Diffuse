import Foundation

/// Canonical tool contracts used by embedded agents and MCP. Hosts implement
/// the queries they can supply and report unavailable data explicitly.
public enum UIDiagnosticTools {
    private static func object(_ properties: [String: JSONSchema] = [:], required: [String] = []) -> JSONSchema {
        .object(properties: properties, required: required, additionalProperties: false)
    }
    private static var text: JSONSchema { .string(minLength: 1, maxLength: 256) }
    private static var paging: [String: JSONSchema] {
        ["offset": .integer(minimum: 0, maximum: 1_000_000), "limit": .integer(minimum: 1, maximum: 100)]
    }
    public static let tools: [AgentTool] = [
        AgentTool(name: "get_diagnostics", description: "Read bounded diagnostic issues with evidence and data availability. Recommendations are hypotheses to verify.",
            schema: object(["limit": .integer(minimum: 1, maximum: 100)])),
        AgentTool(name: "query_ui_nodes", description: "Query live UI nodes by accessible label, role or source. Returns flat paged results, clipped visible bounds and inherited input availability. Use visible_only to exclude hidden/offscreen nodes. IDs expire on unmount.",
            schema: object(paging.merging(["node_id": text, "text": text, "role": text, "source": text, "visible_only": .boolean()]) { _, new in new })),
        AgentTool(name: "query_ui_recomposition", description: "Query owning components sorted by total inclusive CPU time, including counts and invalidation causes. Child durations overlap; do not sum them as frame time.",
            schema: object(paging.merging(["text": text, "minimum_count": .integer(minimum: 0, maximum: 1_000_000)]) { _, new in new })),
        AgentTool(name: "query_ui_state", description: "List opted-in state metadata. Read summaries only for explicit ids; private state is never exposed. Unmounted ids are reported as missing.",
            schema: object(paging.merging(["scope_id": text, "ids": .array(of: text, maximumItems: 128)]) { _, new in new })),
        AgentTool(name: "capture_ui_trace", description: "Capture actual UI CPU spans for 50–5000 ms without forcing frames. Returns a session capture id and summary; idle captures may be empty. Does not measure GPU execution.",
            schema: object(["duration_ms": .integer(minimum: 50, maximum: 5000)])),
        AgentTool(name: "get_ui_trace", description: "Read paged events from a retained capture. At most eight bounded captures are retained in this session.",
            schema: object(paging.merging(["capture_id": text]) { _, new in new }, required: ["capture_id"])),
        AgentTool(name: "compare_ui_traces", description: "Compare counts, average and P95 CPU span times by phase for two retained captures. Different workloads and dropped spans limit comparison; changes do not prove causality.",
            schema: object(["baseline_id": text, "candidate_id": text], required: ["baseline_id", "candidate_id"])),
        AgentTool(name: "list_skills", description: "List the host's available task guides without loading their bodies.", schema: object()),
        AgentTool(name: "read_skill", description: "Read a named task guide. Instructions do not grant tools or execute code.",
            schema: object(["name": text], required: ["name"])),
    ]

    public static func skills() throws -> AgentSkillLibrary {
        try AgentSkillLibrary(skills: [AgentSkill(name: "ui-diagnostics", description: "Investigate UI layout, state and performance with runtime evidence.", instructions: """
        Start with get_diagnostics to discover available data. Use query_ui_nodes to locate the affected component and its compiled source location. Query owner recomposition statistics and explicitly exposed state summaries as needed. Capture a bounded CPU trace around the real operation; an idle capture is not evidence of a successful action. Read capture events and compare equivalent workloads before and after a change. Parent spans include child work; do not sum overlapping spans as frame time. CPU draw and present timing do not measure GPU execution. Cite node, scope, sample or capture IDs with observations. Treat recommendations and correlated timings as hypotheses. Report missing, stale, truncated or dropped data. This guide grants no additional tools or write permissions.
        """)])
    }
}
