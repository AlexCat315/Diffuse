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
    /// Transitions to a new playback state.
    /// - On `.playing`: snapshots the current scene, enables Jolt physics simulation.
    /// - On `.paused`: freezes physics (mode → off) without restoring the scene.
    /// - On `.stopped`: restores the pre-play scene snapshot and disables physics.
    public func applyPlaybackState(_ next: PlaybackState) {
        let current = store.state.playbackState
        guard current.canTransition(to: next) else { return }
        guard next == .stopped || store.workspaceMode.isGameWorkspace else { return }
        EditorViewportInputController.shared.reset()
        enqueueViewportInput(.windowFocusLost)

        switch next {
        case .playing:
            store.dispatch(.setViewportMode(.game))
            if physicsPlaySnapshot == nil {
                scene.scriptRuntime.reset()
                physicsPlaySnapshot = scene.scene
                physicsPlayAuthoringRevision = store.state.sceneRevision
                persistPhysicsPlaySnapshot()
            }
            scene.setAuthoringEnabled(false)
            scene.setEditorViewportCameraEnabled(false)
            scene.scriptRuntime.isGameplayExecutionEnabled = true
            var settings = scene.scene.physicsSettings
            settings.simulationMode = .play
            settings.backendKind = .jolt
            scene.scene.setPhysicsSettings(settings)
            store.dispatch(.setPlaybackState(.playing))
            logConsole("Physics simulation started")

        case .paused:
            scene.setAuthoringEnabled(false)
            scene.setEditorViewportCameraEnabled(false)
            scene.scriptRuntime.isGameplayExecutionEnabled = false
            var settings = scene.scene.physicsSettings
            settings.simulationMode = .off
            scene.scene.setPhysicsSettings(settings)
            store.dispatch(.setPlaybackState(.paused))
            logConsole("Physics simulation paused")

        case .stopped:
            store.dispatch(.setViewportMode(.scene))
            scene.scriptRuntime.isGameplayExecutionEnabled = false
            scene.scriptRuntime.stop(in: &scene.scene)
            AudioEngine.shared.resetPlaybackState()
            // Fallback: restore from disk if the in-memory snapshot was lost (e.g. after a crash).
            if physicsPlaySnapshot == nil {
                physicsPlaySnapshot = loadPersistedPhysicsPlaySnapshot()
            }
            let restoredPlaySnapshot: Bool
            if let snapshot = physicsPlaySnapshot {
                scene.scene = snapshot
                physicsPlaySnapshot = nil
                restoredPlaySnapshot = true
            } else {
                restoredPlaySnapshot = false
            }
            deletePersistedPhysicsPlaySnapshot()
            if !restoredPlaySnapshot {
                var settings = scene.scene.physicsSettings
                settings.simulationMode = .off
                settings.backendKind = .none
                scene.scene.setPhysicsSettings(settings)
            }
            scene.setAuthoringEnabled(true)
            scene.setEditorViewportCameraEnabled(true)
            scene.notifyRevisionChanged(recordHistory: false)
            // Runtime preparation can advance the scene's internal revision
            // without authored edits. Restore the document's pre-play baseline.
            store.dispatch(.setSceneRevision(physicsPlayAuthoringRevision ?? scene.revision))
            physicsPlayAuthoringRevision = nil
            store.dispatch(.setPlaybackState(.stopped))
            logConsole("Physics simulation stopped")
        }
        queueTrackedRenderSettings(makeViewportRenderSettings(shadowsEnabled: store.viewportShadowsEnabled,
                                                               shadingMode: store.viewportShadingMode))
    }
}
