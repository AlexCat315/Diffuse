import Foundation
import IntentRuntime

// MARK: - Mutation type

/// A mutation that a reducer can produce: either upsert an entry or delete one by id.
public enum ContextMemoryMutation: Sendable {
    case upsert(ContextEntry)
    case delete(id: String)
}

// MARK: - Reducer type

/// A pure function that derives zero or more `ContextMemoryMutation`s from a `WorldEvent`.
///
/// - Parameters:
///   - existing: The current entry list (keyed by id). Read-only.
///   - event: The incoming WorldEvent.
/// - Returns: Mutations to apply. Returning `[]` means the event produces no memory change.
///
/// Reducers **must** be deterministic pure functions with no side effects. The identity of
/// entries they create must be derived solely from the event and `existing` — so that
/// replaying the same event sequence always yields a bit-equal result.
public typealias ContextMemoryReducer = @Sendable (
    _ existing: [String: ContextEntry],
    _ event: WorldEvent
) -> [ContextMemoryMutation]

// MARK: - Built-in reducers

/// Produces an `entityEdit` entry whenever an edit is applied.
///
/// The entry is keyed by edit ID, so repeated replays of the same edit produce
/// the same entry (idempotent by construction).
public let editAppliedReducer: ContextMemoryReducer = { _, event in
    guard case let .editApplied(editID, summary, revision) = event,
          !editID.isEmpty, !summary.isEmpty else { return [] }
    return [.upsert(
        ContextEntry(
            id: "edit:\(editID)",
            kind: .entityEdit,
            subject: "session",
            payload: ["summary": summary, "edit_id": editID],
            importance: 0.4,
            revision: revision
        )
    )]
}

/// Produces a `sceneAnnotation` entry whenever a new entity is added.
///
/// Uses "entity_added:\(ref)" as stable id so repeated replay is idempotent.
public let entityAddedReducer: ContextMemoryReducer = { _, event in
    guard case let .entityAdded(ref, name, kind) = event else { return [] }
    var payload: [String: String] = ["name": name, "ref": ref]
    if let k = kind { payload["kind"] = k }
    return [.upsert(
        ContextEntry(
            id: "entity_added:\(ref)",
            kind: .sceneAnnotation,
            subject: ref,
            payload: payload,
            importance: 0.3
        )
    )]
}

/// Deletes the `entity_added` entry and all `inferred` entries for the removed entity.
///
/// Returns `.delete` mutations for every matching entry in `existing`, so the
/// store stays clean without leaving tombstones.
public let entityRemovedReducer: ContextMemoryReducer = { existing, event in
    guard case let .entityRemoved(ref) = event else { return [] }
    let addedID = "entity_added:\(ref)"
    let inferredPrefix = "inferred:\(ref):"
    var mutations: [ContextMemoryMutation] = []
    if existing[addedID] != nil { mutations.append(.delete(id: addedID)) }
    for key in existing.keys where key.hasPrefix(inferredPrefix) {
        mutations.append(.delete(id: key))
    }
    return mutations
}

/// Produces a `sceneAnnotation` update whenever an AI-inferred property arrives
/// with high confidence (≥ 0.8).
public let highConfidenceInferredReducer: ContextMemoryReducer = { existing, event in
    guard case let .entityInferredUpdated(ref, property, value, confidence, source) = event,
          confidence >= 0.8 else { return [] }
    let entryID = "inferred:\(ref):\(property)"
    var payload: [String: String] = [
        "ref": ref,
        "property": property,
        "confidence": String(format: "%.2f", confidence),
    ]
    if let src = source { payload["source"] = src }
    switch value {
    case let .string(s): payload["value"] = s
    case let .float(f):  payload["value"] = String(format: "%.4g", f)
    case let .bool(b):   payload["value"] = b ? "true" : "false"
    case let .vec3(x, y, z): payload["value"] = "(\(x), \(y), \(z))"
    case let .vec4(x, y, z, w): payload["value"] = "(\(x), \(y), \(z), \(w))"
    }
    let prev = existing[entryID]
    return [.upsert(
        ContextEntry(
            id: entryID,
            kind: .sceneAnnotation,
            subject: ref,
            payload: payload,
            importance: min(1.0, 0.5 + confidence * 0.5),
            revision: prev?.revision ?? 0
        )
    )]
}

// MARK: - Reducer registry

/// Immutable ordered list of `ContextMemoryReducer` functions.
///
/// Apply reducers in registration order for determinism.
public struct ReducerRegistry: Sendable {
    private let reducers: [ContextMemoryReducer]

    public init(reducers: [ContextMemoryReducer] = []) {
        self.reducers = reducers
    }

    /// Returns a new registry with `reducer` appended at the end.
    public func adding(_ reducer: @escaping ContextMemoryReducer) -> ReducerRegistry {
        ReducerRegistry(reducers: reducers + [reducer])
    }

    /// Runs all reducers against `existing` for `event` and returns the combined mutations.
    public func apply(existing: [String: ContextEntry], event: WorldEvent) -> [ContextMemoryMutation] {
        reducers.flatMap { $0(existing, event) }
    }

    /// Default registry with the four built-in reducers.
    public static let `default` = ReducerRegistry(reducers: [
        editAppliedReducer,
        entityAddedReducer,
        entityRemovedReducer,
        highConfidenceInferredReducer,
    ])
}
