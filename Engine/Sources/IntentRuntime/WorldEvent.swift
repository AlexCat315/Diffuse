import Foundation

/// Scalar property value carried by a WorldEvent authored-state change.
public enum WorldPropertyValue: Sendable, Equatable {
    case vec3(Float, Float, Float)
    case float(Float)
    case string(String)
    case bool(Bool)
}

/// A fine-grained World state change emitted by TransactionExecutor on every apply().
///
/// Session feeds these into WorldView.apply(event:) to maintain an incremental entity index
/// without full-snapshot refreshes — the Phase 5 migration of the snapshot path to delta-driven.
public enum WorldEvent: Sendable, Equatable {
    /// An entity was created (spawned or duplicated).
    case entityAdded(ref: String, name: String, kind: String?)
    /// An entity was permanently removed from the World.
    case entityRemoved(ref: String)
    /// An authored property on an entity was changed by a user or AI action.
    case entityAuthoredChanged(ref: String, property: String, value: WorldPropertyValue)
    /// An Edit was applied to the World — carries the revision bump.
    case editApplied(editID: String, summary: String, revision: UInt64)
    /// The active selection set changed.
    case selectionChanged(refs: [String])
}
