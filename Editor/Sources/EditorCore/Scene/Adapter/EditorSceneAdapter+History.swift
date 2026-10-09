import IntentRuntime
import SceneRuntime

extension EditorSceneAdapter {
    func notifyRevisionChanged(recordHistory: Bool = true, componentKeys: Set<SceneComponentKey>? = nil) {
        editHistory.recordRevisionChange(to: scene, recordHistory: recordHistory, componentKeys: componentKeys)
        invalidateParticleFeedback()
        onRevisionChanged?(scene.snapshot.revision)
    }

    func withEditHistoryGroup<Result>(_ body: () -> Result) -> Result {
        editHistory.beginGroup(in: scene)
        defer { editHistory.endGroup(in: scene) }
        return body()
    }

    /// Coalesces the live mutations produced by one pointer drag into a single
    /// undo entry. Calls are idempotent so focus loss and an eventual mouse-up
    /// can both terminate the same interaction safely.
    public func beginInteractiveEditHistoryGroup() {
        editHistory.beginInteractiveGroup(in: scene)
    }

    public func endInteractiveEditHistoryGroup() {
        editHistory.endInteractiveGroup(in: scene)
    }

    /// Restores the pre-drag scene without consuming an undo entry. A late
    /// mouse-up or focus-loss event after cancellation is harmless.
    public func cancelInteractiveEditHistoryGroup() {
        guard let previous = editHistory.cancelInteractiveGroup() else { return }
        restoreHistoryScene(previous)
    }

    public var canUndoEdit: Bool { editHistory.canUndo }
    public var canRedoEdit: Bool { editHistory.canRedo }

    @discardableResult
    public func undoEdit() -> Bool {
        guard let previous = editHistory.undo(replacing: scene) else { return false }
        restoreHistoryScene(previous)
        return true
    }

    @discardableResult
    public func redoEdit() -> Bool {
        guard let next = editHistory.redo(replacing: scene) else { return false }
        restoreHistoryScene(next)
        return true
    }

    func resetEditHistory() {
        editHistory.reset(to: scene)
    }

    private func restoreHistoryScene(_ restoredScene: SceneRuntime) {
        scene = restoredScene
        invalidateParticleFeedback()
        onRevisionChanged?(scene.snapshot.revision)
    }
}
