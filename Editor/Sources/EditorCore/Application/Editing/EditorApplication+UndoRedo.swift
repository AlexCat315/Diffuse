import AIRuntime
import ContextMemory
import AssetPipeline
import AudioRuntime
import CapabilityRuntime
import EngineCore
import EngineKernel
import IntentRuntime
import ObservationBus
import PerceptionRuntime
import PluginRuntime
import SemanticPipeline
import RenderBackend
import RHIWGPU
import SceneRuntime
import GuavaUICompose
import GuavaUIRuntime
import Foundation
import SIMDCompat

extension EditorApplication {
    // MARK: - Undo / Redo

    public var canUndo: Bool { scene.canUndoEdit }
    public var canRedo: Bool { scene.canRedoEdit }

    public func undo() {
        guard store.state.playbackState == .stopped else {
            reportSceneAuthoringUnavailable("Stop simulation before undoing scene edits.")
            return
        }
        guard scene.undoEdit() else { return }
        validateSelectionAfterHistoryNavigation()
        store.dispatch(.setAIStatusMessage("Undone"))
        logConsole("Undo applied", severity: .info)
    }

    public func redo() {
        guard store.state.playbackState == .stopped else {
            reportSceneAuthoringUnavailable("Stop simulation before redoing scene edits.")
            return
        }
        guard scene.redoEdit() else { return }
        validateSelectionAfterHistoryNavigation()
        store.dispatch(.setAIStatusMessage("Redone"))
        logConsole("Redo applied", severity: .info)
    }

    func reportSceneAuthoringUnavailable(_ message: String) {
        store.dispatch(.setAIStatusMessage(message))
        logConsole(message, severity: .warning)
    }

    private func validateSelectionAfterHistoryNavigation() {
        let selectedID = store.state.selectedEntityID
        if scene.entitySummary(id: selectedID) == nil {
            store.dispatch(.setSelectedEntity(scene.roots.first?.id))
        }
        displayInvalidationHandler?()
    }
}
