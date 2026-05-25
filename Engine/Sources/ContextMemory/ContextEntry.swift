import Foundation

// MARK: - EntryKind

/// Closed set of context memory entry kinds.
///
/// New kinds must be added here (not dynamically registered) so that
/// reducers can be exhaustive and replay-deterministic.
public enum EntryKind: String, Codable, Sendable, Equatable, CaseIterable {
    /// A summarized edit applied to a scene entity.
    case entityEdit       = "entity_edit"
    /// A behavioral preference inferred from UserCorrection signals.
    case userPreference   = "user_preference"
    /// The active workflow context at a point in time.
    case workflowContext  = "workflow_context"
    /// A semantic annotation attached to a scene entity or asset.
    case sceneAnnotation  = "scene_annotation"
    /// A high-level session summary produced at session close.
    case sessionSummary   = "session_summary"
    /// A tracked issue or outstanding question.
    case issueTracked     = "issue_tracked"
}

// MARK: - ContextEntry

/// A single unit of long-term AI context memory.
///
/// All payload values are LLM-safe strings or numbers — no vectors,
/// embeddings, spectral hashes, or raw image bytes. Reducers must
/// enforce this invariant.
public struct ContextEntry: Codable, Sendable, Equatable {
    /// Stable UUID string.
    public var id: String
    public var kind: EntryKind
    /// The primary subject (entity ref like "scene:42", asset URI, or "session").
    public var subject: String
    /// LLM-safe key-value payload. Values are plain strings or numeric literals.
    public var payload: [String: String]
    /// Importance score in [0, 1]. Used for eviction and prompt-budget ranking.
    public var importance: Double
    /// World revision when this entry was last written.
    public var revision: UInt64
    /// Wall-clock timestamp of the last write.
    public var timestamp: Date

    public init(id: String = UUID().uuidString,
                kind: EntryKind,
                subject: String,
                payload: [String: String],
                importance: Double = 0.5,
                revision: UInt64 = 0,
                timestamp: Date = Date()) {
        self.id = id
        self.kind = kind
        self.subject = subject
        self.payload = payload
        self.importance = max(0, min(1, importance))
        self.revision = revision
        self.timestamp = timestamp
    }
}
