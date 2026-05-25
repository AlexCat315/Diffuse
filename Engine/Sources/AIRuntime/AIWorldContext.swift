import Foundation
import IntentRuntime
import ObservationBus

/// Local semantic state shared by AI providers and local perception workers.
///
/// This keeps Guava's AI-visible world available even when no remote text
/// provider is configured. Remote `Session` instances can be seeded from it.
public actor AIWorldContext {
    private var worldView: WorldView
    private var worldRevision: UInt64 = 0
    private var storedSnapshots: [String: WorldView] = [:]
    private var snapshotInsertionOrder: [String] = []
    private static let maxStoredSnapshots = 8

    public init(worldView: WorldView = WorldView()) {
        self.worldView = worldView
    }

    public func observe(snapshot: SceneSemanticSnapshot) {
        worldView.apply(snapshot: snapshot)
        worldRevision += 1
    }

    public func observe(event: WorldEvent) {
        worldView.apply(event: event)
        worldRevision += 1
    }

    public func observe(events: [WorldEvent]) {
        for event in events {
            worldView.apply(event: event)
        }
        if !events.isEmpty {
            worldRevision += UInt64(events.count)
        }
    }

    public func replaceWorldView(_ worldView: WorldView) {
        self.worldView = worldView
        worldRevision += 1
    }

    public func snapshot() -> WorldView {
        worldView
    }

    public func entityRecord(ref: String) -> WorldEntityRecord? {
        worldView.entityIndex[ref]
    }

    /// Returns the WorldView captured for `snapshotID`, or nil if it was never
    /// materialized or has been evicted.
    public func worldViewForSnapshot(snapshotID: String) -> WorldView? {
        storedSnapshots[snapshotID]
    }

    public func discardSnapshot(snapshotID: String) {
        storedSnapshots.removeValue(forKey: snapshotID)
        snapshotInsertionOrder.removeAll { $0 == snapshotID }
    }
}

// MARK: - SnapshotProvider

extension AIWorldContext: SnapshotProvider {
    /// Captures the current WorldView under a fresh UUID, returning that ID and
    /// a cursor pointing to the current world revision on the "world" stream.
    ///
    /// Callers can retrieve the captured WorldView with `worldViewForSnapshot(snapshotID:)`.
    /// Subscribers using `.fromSnapshot(snapshotID:)` will receive any ObservationBus
    /// events on the "world" stream published after this point.
    public func materializeSnapshot(scope: String) async throws -> (snapshotID: String, cursor: StreamCursor) {
        let snapshotID = UUID().uuidString
        // Evict oldest entries to cap memory usage (FIFO by insertion order).
        while storedSnapshots.count >= Self.maxStoredSnapshots,
              let oldest = snapshotInsertionOrder.first {
            snapshotInsertionOrder.removeFirst()
            storedSnapshots.removeValue(forKey: oldest)
        }
        storedSnapshots[snapshotID] = worldView
        snapshotInsertionOrder.append(snapshotID)
        return (snapshotID, StreamCursor(streamID: "world", seq: worldRevision))
    }
}
