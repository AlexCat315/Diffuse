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
    public func resetPreviewScene() {
        removeEditorAutosave()
        scene.resetToPreviewScene()
        reloadScriptsAfterSceneReplacement()
        if let selection = scene.defaultSelectionID {
            store.dispatch(.setSelectedEntity(selection))
        } else {
            store.dispatch(.setSelectedEntity(nil))
        }
        logConsole("Created new preview scene")
    }

    /// New documents begin empty; preview fixtures are only created explicitly.
    public func createEmptyScene() {
        removeEditorAutosave()
        _ = scene.load(manifest: EditorSceneManifest(revision: 0, entityCount: 0, roots: []))
        reloadScriptsAfterSceneReplacement()
        store.dispatch(.setSelectedEntity(nil))
        store.dispatch(.markSceneUnsaved)
        logConsole("Created new empty scene")
    }

    public func setCloseProjectHandler(_ handler: (() -> Void)?) {
        closeProjectHandler = handler
    }

    public func requestCloseProject() {
        if store.state.playbackState != .stopped { applyPlaybackState(.stopped) }
        guard !hasUnsavedSceneChanges && !scriptWorkspace.snapshot.documents.contains(where: \.isDirty) else {
            store.dispatch(.requestClose(EditorPendingCloseRequest(action: .closeProject)))
            return
        }
        closeProject()
    }

    public func closeProject() { closeProjectHandler?() }

    public func requestNewScene() {
        guard store.state.playbackState == .stopped else {
            reportSceneAuthoringUnavailable("Stop simulation before creating a new scene.")
            return
        }
        guard hasUnsavedSceneChanges else {
            createEmptyScene()
            return
        }
        store.dispatch(.requestClose(EditorPendingCloseRequest(action: .newScene)))
    }

    public func requestOpenSceneManifest() {
        guard store.state.playbackState == .stopped else {
            reportSceneAuthoringUnavailable("Stop simulation before opening another scene.")
            return
        }
        guard hasUnsavedSceneChanges else {
            _ = openSceneManifest()
            return
        }
        store.dispatch(.requestClose(EditorPendingCloseRequest(action: .openScene)))
    }

    /// Opens a scene chosen by the user, deferring the actual load behind the
    /// unsaved-changes confirmation when necessary.
    public func requestOpenSceneManifest(at url: URL) {
        guard store.state.playbackState == .stopped else {
            reportSceneAuthoringUnavailable("Stop simulation before opening another scene.")
            return
        }
        guard hasUnsavedSceneChanges else {
            _ = openSceneManifest(at: url)
            return
        }
        store.dispatch(.requestClose(EditorPendingCloseRequest(action: .openScene,
                                                               documentPath: url.path)))
    }
}
