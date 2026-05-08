import Foundation

/// Appends NL intent resolution records to `.guava/intent_training.jsonl`.
///
/// Two record shapes exist depending on which path resolved the intent:
///
/// **Cascade path** (`layer` ∈ `"local"` `"ai_tool"` `"keyword"` `"fallback"`):
/// ```json
/// {
///   "ts": "2026-05-08T09:12:34Z",
///   "text": "把这个灯变成点光源",
///   "locale": "zh-Hans",
///   "layer": "local",
///   "verb": "scene.set_light_type",
///   "confidence": 0.87,
///   "arguments": {"light_type": "point"},
///   "candidates": [
///     {"verb": "scene.set_light_type", "confidence": 0.87, "reason": "token_overlap"},
///     {"verb": "scene.set_light_intensity", "confidence": 0.31, "reason": "token_overlap"}
///   ],
///   "workspace": "level",
///   "scene_entity_count": 8,
///   "selected_entity_kind": "Point Light",
///   "latency_ms": 3,
///   "outcome": "applied"
/// }
/// ```
///
/// **AI planner path** (`layer == "ai_planner"`):
/// ```json
/// {
///   "ts": "2026-05-08T09:15:02Z",
///   "text": "把所有点光源的强度调低一半",
///   "locale": "zh-Hans",
///   "layer": "ai_planner",
///   "model": "claude-sonnet-4-6",
///   "plan_summary": "Reduce all point light intensities by 50%",
///   "plan_reasoning": "User wants dimmer lighting overall",
///   "plan_step_count": 3,
///   "plan_steps": [
///     {"op": "set_light_intensity", "entity_id": "scene:1", "intensity": 500},
///     {"op": "set_light_intensity", "entity_id": "scene:4", "intensity": 250},
///     {"op": "set_light_intensity", "entity_id": "scene:7", "intensity": 125}
///   ],
///   "workspace": "level",
///   "scene_entity_count": 12,
///   "selected_entity_kind": "Point Light",
///   "latency_ms": 2340,
///   "outcome": "applied"
/// }
/// ```
///
/// **Unresolved record** (`layer == "unresolved"`):
/// ```json
/// {
///   "ts": "2026-05-08T09:16:11Z",
///   "text": "make it glow",
///   "locale": "en",
///   "layer": "unresolved",
///   "candidates": [
///     {"verb": "scene.set_light_intensity", "confidence": 0.12, "reason": "token_overlap"}
///   ],
///   "unresolved_reason": "missing_target",
///   "workspace": "level",
///   "scene_entity_count": 12,
///   "latency_ms": 4,
///   "outcome": "unresolved"
/// }
/// ```
///
/// `layer` values:
/// - `"local"` — Layer 1 local classifier (token_overlap)
/// - `"ai_tool"` — Layer 2 Anthropic tool-use backend
/// - `"keyword"` — fallback keyword matcher
/// - `"fallback"` — other fallback path
/// - `"ai_planner"` — main AI scene-planner path
/// - `"unresolved"` — no layer could produce a verb
///
/// `outcome` values: `"applied"` `"discarded"` `"unresolved"` `"error"`
///
/// This file is append-only and never read back at runtime.
/// Offline usage:
/// ```sh
/// # All applied ai_planner records for analysis
/// jq 'select(.outcome == "applied" and .layer == "ai_planner")' intent_training.jsonl
/// # Unresolved intents with near-miss candidates
/// jq 'select(.layer == "unresolved" and (.candidates | length) > 0)' intent_training.jsonl
/// # Average AI planner latency
/// jq '[select(.layer == "ai_planner") | .latency_ms] | add / length' intent_training.jsonl
/// ```
public enum IntentTrainingLogger {

    // MARK: - Supporting types

    public struct CandidateRecord {
        public var verb: String
        public var confidence: Double
        public var reason: String

        public init(verb: String, confidence: Double, reason: String) {
            self.verb = verb
            self.confidence = confidence
            self.reason = reason
        }
    }

    public struct Entry {
        // Core
        public var text: String
        public var locale: String?

        /// Routing layer that produced the result.
        /// `"local"` | `"ai_tool"` | `"keyword"` | `"fallback"` | `"ai_planner"` | `"unresolved"`
        public var layer: String

        // Cascade path (nil for ai_planner layer)
        public var verb: String?
        public var confidence: Double?
        /// Resolved argument key→primitive pairs. `vec3` values are serialised as `[x, y, z]`.
        public var arguments: [String: Any]?
        /// Top alternative candidates considered, including the winner as the first element.
        public var candidates: [CandidateRecord]

        /// Set when `layer == "unresolved"`.
        /// Values: `"empty_input"` `"unsupported_verb"` `"missing_target"` `"missing_argument"`
        public var unresolvedReason: String?

        // AI planner path (nil for cascade layers)
        public var planSummary: String?
        public var planReasoning: String?
        public var planStepCount: Int?
        /// Pre-serialised plan steps as flat JSON objects, keyed by `SceneEditStep.CodingKeys`.
        public var planSteps: [[String: Any]]?
        /// Anthropic model ID that generated the plan (e.g. `"claude-sonnet-4-6"`).
        public var modelID: String?

        // Scene context at submission time
        public var workspaceMode: String?
        public var sceneEntityCount: Int?
        /// Kind label of the selected entity: `"Point Light"` `"Camera"` `"Static Mesh"` etc.
        public var selectedEntityKind: String?

        // Performance
        public var latencyMs: Int?

        /// `"applied"` | `"discarded"` | `"unresolved"` | `"error"`
        public var outcome: String

        public init(text: String,
                    locale: String? = nil,
                    layer: String,
                    verb: String? = nil,
                    confidence: Double? = nil,
                    arguments: [String: Any]? = nil,
                    candidates: [CandidateRecord] = [],
                    unresolvedReason: String? = nil,
                    planSummary: String? = nil,
                    planReasoning: String? = nil,
                    planStepCount: Int? = nil,
                    planSteps: [[String: Any]]? = nil,
                    modelID: String? = nil,
                    workspaceMode: String? = nil,
                    sceneEntityCount: Int? = nil,
                    selectedEntityKind: String? = nil,
                    latencyMs: Int? = nil,
                    outcome: String) {
            self.text = text
            self.locale = locale
            self.layer = layer
            self.verb = verb
            self.confidence = confidence
            self.arguments = arguments
            self.candidates = candidates
            self.unresolvedReason = unresolvedReason
            self.planSummary = planSummary
            self.planReasoning = planReasoning
            self.planStepCount = planStepCount
            self.planSteps = planSteps
            self.modelID = modelID
            self.workspaceMode = workspaceMode
            self.sceneEntityCount = sceneEntityCount
            self.selectedEntityKind = selectedEntityKind
            self.latencyMs = latencyMs
            self.outcome = outcome
        }
    }

    // MARK: - Public API

    /// Appends `entry` as a JSON line to `<projectDirectory>/.guava/intent_training.jsonl`.
    /// Silently drops the record on any I/O or serialization failure —
    /// logging must never interrupt the editor flow.
    public static func log(_ entry: Entry, projectDirectory: String) {
        guard let line = serialize(entry) else { return }
        append(line, to: projectDirectory)
    }

    // MARK: - Serialization

    private static func serialize(_ entry: Entry) -> String? {
        var obj: [String: Any] = [
            "ts":      iso8601Now(),
            "text":    entry.text,
            "layer":   entry.layer,
            "outcome": entry.outcome,
        ]

        if let v = entry.locale              { obj["locale"]               = v }
        if let v = entry.verb                { obj["verb"]                 = v }
        if let v = entry.confidence          { obj["confidence"]           = v }
        if let v = entry.arguments, !v.isEmpty { obj["arguments"]         = v }
        if !entry.candidates.isEmpty {
            obj["candidates"] = entry.candidates.map {
                ["verb": $0.verb, "confidence": $0.confidence, "reason": $0.reason] as [String: Any]
            }
        }
        if let v = entry.unresolvedReason    { obj["unresolved_reason"]   = v }
        if let v = entry.planSummary         { obj["plan_summary"]        = v }
        if let v = entry.planReasoning       { obj["plan_reasoning"]      = v }
        if let v = entry.planStepCount       { obj["plan_step_count"]     = v }
        if let v = entry.planSteps, !v.isEmpty { obj["plan_steps"]        = v }
        if let v = entry.modelID             { obj["model"]               = v }
        if let v = entry.workspaceMode       { obj["workspace"]           = v }
        if let v = entry.sceneEntityCount    { obj["scene_entity_count"]  = v }
        if let v = entry.selectedEntityKind  { obj["selected_entity_kind"] = v }
        if let v = entry.latencyMs           { obj["latency_ms"]          = v }

        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let str  = String(data: data, encoding: .utf8)
        else { return nil }
        return str + "\n"
    }

    // MARK: - I/O

    private static func append(_ line: String, to projectDirectory: String) {
        let dir  = URL(fileURLWithPath: projectDirectory, isDirectory: true)
            .appendingPathComponent(".guava", isDirectory: true)
        let file = dir.appendingPathComponent("intent_training.jsonl")

        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: file.path) {
            guard let handle = try? FileHandle(forWritingTo: file) else { return }
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            handle.closeFile()
        } else {
            try? Data(line.utf8).write(to: file, options: .atomic)
        }
    }

    private static func iso8601Now() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }
}

// MARK: - IntentArgumentValue → JSON primitive

import IntentRuntime

extension IntentArgumentValue {
    /// Returns a JSON-serialisable primitive for training log serialization.
    /// `vec3` values are represented as `[x, y, z]`; `stableID` as its raw `UInt64`.
    var trainingLogPrimitive: Any {
        switch self {
        case .bool(let v):     return v
        case .integer(let v):  return v
        case .number(let v):   return v
        case .string(let v):   return v
        case .stableID(let v): return v
        case .vec3(let v):     return [v.x, v.y, v.z]
        }
    }
}
