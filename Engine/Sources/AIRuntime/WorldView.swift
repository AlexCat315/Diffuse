import Foundation

/// A brief record of one applied Edit, as tracked by Session's WorldView.
public struct WorldViewEdit: Sendable {
    public var summary: String
    public var revision: UInt64
    public var timestamp: Date

    public init(summary: String, revision: UInt64, timestamp: Date = Date()) {
        self.summary = summary
        self.revision = revision
        self.timestamp = timestamp
    }
}

/// Session's incrementally-maintained understanding of the World.
///
/// In Phase 2 it is snapshot-based; Phase 5 migrates it to delta-driven.
/// All mutation goes through the `apply(…)` family so update semantics stay localized.
public struct WorldView: Sendable {
    public var sceneSnapshot: SceneSemanticSnapshot?
    public var sceneRevision: UInt64?
    public var selectedEntityRefs: [String]
    public var recentEdits: [WorldViewEdit]
    public var workflowMode: String?

    private static let maxRecentEdits = 20

    public init() {
        selectedEntityRefs = []
        recentEdits = []
    }

    /// Replaces the snapshot and derives revision + selection from it.
    public mutating func apply(snapshot: SceneSemanticSnapshot) {
        sceneSnapshot = snapshot
        sceneRevision = snapshot.sceneRevision
        workflowMode = snapshot.workspaceMode
        selectedEntityRefs = snapshot.entities
            .filter(\.isSelected)
            .map(\.id)
    }

    /// Records an applied Edit to the recent-edit ring.
    public mutating func apply(editSummary: String, revision: UInt64) {
        recentEdits.append(WorldViewEdit(summary: editSummary, revision: revision))
        if recentEdits.count > Self.maxRecentEdits {
            recentEdits.removeFirst(recentEdits.count - Self.maxRecentEdits)
        }
        sceneRevision = revision
    }

    /// Updates the active selection without a full snapshot refresh.
    public mutating func apply(selectionChanged entityRefs: [String]) {
        selectedEntityRefs = entityRefs
    }
}
