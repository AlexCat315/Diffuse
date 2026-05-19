import SceneRuntime

/// Ring-buffer snapshot store for undo/redo. Holds up to `capacity` `SceneRuntime` value
/// copies (~50 MB at 64 entries). Pushing a new snapshot clears the redo stack.
public final class UndoStack: @unchecked Sendable {
    public let capacity: Int

    private var undoEntries: [SceneRuntime] = []
    private var redoEntries: [SceneRuntime] = []

    public init(capacity: Int = 64) {
        self.capacity = max(1, capacity)
    }

    public var canUndo: Bool { !undoEntries.isEmpty }
    public var canRedo: Bool { !redoEntries.isEmpty }
    public var undoDepth: Int { undoEntries.count }
    public var redoDepth: Int { redoEntries.count }

    /// Call before every `TransactionExecutor.apply`. Clears the redo stack.
    public func push(_ scene: SceneRuntime) {
        if undoEntries.count >= capacity {
            undoEntries.removeFirst()
        }
        undoEntries.append(scene)
        redoEntries.removeAll(keepingCapacity: true)
    }

    /// Restore the previous scene state. Returns the snapshot to restore, or nil if empty.
    /// Pass `current` to save it onto the redo stack before returning the older snapshot.
    public func undo(current: SceneRuntime) -> SceneRuntime? {
        guard let snapshot = undoEntries.popLast() else { return nil }
        if redoEntries.count >= capacity {
            redoEntries.removeFirst()
        }
        redoEntries.append(current)
        return snapshot
    }

    /// Re-apply the most recently undone state. Returns the snapshot to restore, or nil if empty.
    /// Pass `current` to save it back onto the undo stack.
    public func redo(current: SceneRuntime) -> SceneRuntime? {
        guard let snapshot = redoEntries.popLast() else { return nil }
        if undoEntries.count >= capacity {
            undoEntries.removeFirst()
        }
        undoEntries.append(current)
        return snapshot
    }

    public func clear() {
        undoEntries.removeAll(keepingCapacity: true)
        redoEntries.removeAll(keepingCapacity: true)
    }
}
