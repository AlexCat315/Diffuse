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
    /// Revision equality covers ordinary edits/undo. A recovered autosave is
    /// explicitly dirty because rebuilding two structurally similar manifests
    /// can legitimately produce the same runtime revision.
    public var hasUnsavedSceneChanges: Bool {
        store.state.sceneDirty
    }

    @discardableResult
    public func saveSceneManifest() -> URL? {
        do {
            let guavaDirectory = sceneManifestURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: guavaDirectory,
                                                    withIntermediateDirectories: true)
            let authoredOutput = authoredSceneManifest()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(authoredOutput.manifest)
            try data.write(to: sceneManifestURL, options: [.atomic])
            store.dispatch(.setSceneRevision(authoredOutput.revision))
            if authoredOutput.usedPlaySnapshot {
                physicsPlayAuthoringRevision = authoredOutput.revision
            }
            store.dispatch(.markSceneSaved(authoredOutput.revision))
            removeEditorAutosave()
            logConsole(authoredOutput.usedPlaySnapshot
                           ? "Saved authored scene snapshot during playback"
                           : "Saved scene manifest",
                       detail: sceneManifestURL.path)
            return sceneManifestURL
        } catch {
            logConsole("Failed to save scene manifest",
                       severity: .error,
                       detail: String(describing: error))
            return nil
        }
    }

    /// Returns the edit-time scene used by durable authoring outputs. Gameplay
    /// saves deliberately use the live runtime state, while scene saves and
    /// packaged builds must not capture transient physics results.
    func authoredSceneManifest() -> (
        manifest: EditorSceneManifest,
        revision: UInt64,
        usedPlaySnapshot: Bool
    ) {
        if store.state.timing.playbackState != .stopped,
           let physicsPlaySnapshot {
            let snapshotAdapter = EditorSceneAdapter()
            snapshotAdapter.scene = physicsPlaySnapshot
            return (
                snapshotAdapter.manifest(selectedEntityID: store.state.selection.selectedEntityID),
                snapshotAdapter.revision,
                true
            )
        }
        return (
            scene.manifest(selectedEntityID: store.state.selection.selectedEntityID),
            scene.revision,
            false
        )
    }

    public func openSceneManifest() -> EditorSceneManifest? {
        openSceneManifest(clearRecoveryOnSuccess: true, logMissing: true)
    }

    /// Loads an Editor scene manifest from an explicit location. Subsequent
    /// saves still target this project's canonical `.guava` manifest.
    public func openSceneManifest(at url: URL) -> EditorSceneManifest? {
        openSceneManifest(from: url, clearRecoveryOnSuccess: true, logMissing: true)
    }

    /// Restores the normal scene and then overlays a newer autosave when the
    /// previous Editor process did not complete a save/discard workflow.
    @discardableResult
    public func restoreProjectSceneAtLaunch() -> EditorSceneManifest? {
        let saved = openSceneManifest(clearRecoveryOnSuccess: false, logMissing: false)
        let savedDate = fileModificationDate(sceneManifestURL) ?? .distantPast
        let autosaveDate = fileModificationDate(editorAutosaveURL) ?? .distantPast
        let interruptedPlayDate = fileModificationDate(physicsPlaySnapshotURL) ?? .distantPast

        if interruptedPlayDate > max(savedDate, autosaveDate) {
            if let recovered = restoreInterruptedPlaySnapshotAtLaunch() {
                return recovered
            }
        } else if interruptedPlayDate != .distantPast {
            // A newer durable save/autosave already supersedes this snapshot.
            deletePersistedPhysicsPlaySnapshot()
        }

        guard FileManager.default.fileExists(atPath: editorAutosaveURL.path) else {
            return saved
        }

        let recoveryDate = fileModificationDate(editorAutosaveURL) ?? .distantPast
        guard saved == nil || recoveryDate > savedDate else {
            removeEditorAutosave()
            return saved
        }

        do {
            guard let document = try GameSaveDocument.read(from: editorAutosaveURL) else {
                return saved
            }
            let result = scene.load(manifest: document.manifest)
            guard result.error == nil else {
                throw result.error!
            }
            reloadScriptsAfterSceneReplacement()
            store.dispatch(.setSelectedEntity(result.selectedEntityID))
            store.dispatch(.setSceneRecoveryPending(true))
            recoverySuppressedRevision = nil
            lastEditorAutosavedRevision = store.state.document.sceneRevision
            editorAutosaveElapsed = 0
            logConsole("Recovered autosaved scene",
                       severity: .warning,
                       detail: "\(result.entityCount) entities from \(document.savedAt); save the scene to keep it")
            return document.manifest
        } catch {
            let quarantineDetail = quarantineEditorAutosave()
            logConsole("Failed to restore autosaved scene",
                       severity: .warning,
                       detail: "\(error). \(quarantineDetail)")
            return saved
        }
    }

    private func restoreInterruptedPlaySnapshotAtLaunch() -> EditorSceneManifest? {
        do {
            let data = try Data(contentsOf: physicsPlaySnapshotURL)
            let manifest = try JSONDecoder().decode(EditorSceneManifest.self, from: data)
            let result = scene.load(manifest: manifest)
            guard result.error == nil else { throw result.error! }
            reloadScriptsAfterSceneReplacement()
            store.dispatch(.setSelectedEntity(result.selectedEntityID))
            store.dispatch(.setSceneRecoveryPending(true))
            recoverySuppressedRevision = nil
            lastEditorAutosavedRevision = store.state.document.sceneRevision
            editorAutosaveElapsed = 0

            let recoveredManifest = scene.manifest(selectedEntityID: result.selectedEntityID)
            do {
                try GameSaveDocument(slot: GameSaveDocument.autoSaveSlot,
                                     manifest: recoveredManifest).write(to: editorAutosaveURL)
                deletePersistedPhysicsPlaySnapshot()
            } catch {
                logConsole("Recovered interrupted Play but could not convert its snapshot to autosave",
                           severity: .warning,
                           detail: String(describing: error))
            }
            logConsole("Recovered scene from an interrupted Play session",
                       severity: .warning,
                       detail: "\(result.entityCount) entities; save the scene to keep it")
            return recoveredManifest
        } catch {
            let quarantineDetail = quarantineInterruptedPlaySnapshot()
            logConsole("Failed to restore interrupted Play snapshot",
                       severity: .warning,
                       detail: "\(error). \(quarantineDetail)")
            return nil
        }
    }

    /// Called after an explicit "Discard" choice. It removes the recovery
    /// file and suppresses shutdown autosave for this exact scene revision.
    public func discardAutosavedScene() {
        store.dispatch(.setSceneRecoveryPending(false))
        recoverySuppressedRevision = store.state.document.sceneRevision
        editorAutosaveElapsed = 0
        lastEditorAutosavedRevision = nil
        do {
            if FileManager.default.fileExists(atPath: editorAutosaveURL.path) {
                try FileManager.default.removeItem(at: editorAutosaveURL)
            }
        } catch {
            logConsole("Failed to discard autosaved scene",
                       severity: .warning,
                       detail: String(describing: error))
        }
    }

    private var sceneManifestURL: URL {
        URL(fileURLWithPath: projectDirectory, isDirectory: true)
            .appendingPathComponent(".guava", isDirectory: true)
            .appendingPathComponent("editor-scene-manifest.json")
    }

    private var editorAutosaveURL: URL {
        GameSaveDocument.url(slot: GameSaveDocument.autoSaveSlot,
                             projectDirectory: projectDirectory)
    }

    func openSceneManifest(clearRecoveryOnSuccess: Bool,
                                   logMissing: Bool) -> EditorSceneManifest? {
        openSceneManifest(from: sceneManifestURL,
                          clearRecoveryOnSuccess: clearRecoveryOnSuccess,
                          logMissing: logMissing)
    }

    func openSceneManifest(from sourceURL: URL,
                                   clearRecoveryOnSuccess: Bool,
                                   logMissing: Bool) -> EditorSceneManifest? {
        do {
            let data = try Data(contentsOf: sourceURL)
            let manifest = try JSONDecoder().decode(EditorSceneManifest.self, from: data)
            let result = scene.load(manifest: manifest)
            guard result.error == nil else { throw result.error! }
            reloadScriptsAfterSceneReplacement()
            store.dispatch(.setSelectedEntity(result.selectedEntityID))
            store.dispatch(.markSceneSaved(store.state.document.sceneRevision))
            store.dispatch(.setSceneRecoveryPending(false))
            recoverySuppressedRevision = nil
            if clearRecoveryOnSuccess {
                removeEditorAutosave()
            }
            logConsole("Opened scene manifest",
                       detail: "\(result.entityCount) entities restored from revision \(manifest.revision) · \(sourceURL.path)")
            return manifest
        } catch CocoaError.fileReadNoSuchFile {
            if logMissing {
                logConsole("No saved scene manifest",
                           severity: .warning,
                           detail: sourceURL.path)
            }
            return nil
        } catch {
            logConsole("Failed to open scene manifest",
                       severity: .error,
                       detail: String(describing: error))
            return nil
        }
    }

    func autosaveSceneIfNeeded(elapsed: Double, force: Bool = false) {
        guard store.state.timing.playbackState == .stopped,
              hasUnsavedSceneChanges,
              recoverySuppressedRevision != store.state.document.sceneRevision else {
            if !hasUnsavedSceneChanges {
                editorAutosaveElapsed = 0
            }
            return
        }
        editorAutosaveElapsed += min(max(elapsed, 0), Self.editorAutosaveInterval)
        guard force || editorAutosaveElapsed >= Self.editorAutosaveInterval,
              lastEditorAutosavedRevision != store.state.document.sceneRevision else { return }
        do {
            let document = GameSaveDocument(
                slot: GameSaveDocument.autoSaveSlot,
                manifest: scene.manifest(selectedEntityID: store.state.selection.selectedEntityID)
            )
            try document.write(to: editorAutosaveURL)
            lastEditorAutosavedRevision = store.state.document.sceneRevision
            editorAutosaveElapsed = 0
            logConsole("Autosaved scene recovery snapshot",
                       detail: editorAutosaveURL.lastPathComponent)
        } catch {
            editorAutosaveElapsed = 0
            logConsole("Failed to autosave scene recovery snapshot",
                       severity: .warning,
                       detail: String(describing: error))
        }
    }

    func removeEditorAutosave() {
        store.dispatch(.setSceneRecoveryPending(false))
        recoverySuppressedRevision = nil
        editorAutosaveElapsed = 0
        lastEditorAutosavedRevision = nil
        try? FileManager.default.removeItem(at: editorAutosaveURL)
    }

    private func quarantineEditorAutosave() -> String {
        guard FileManager.default.fileExists(atPath: editorAutosaveURL.path) else {
            return "The recovery file was already absent."
        }
        let quarantineURL = editorAutosaveURL.deletingPathExtension()
            .appendingPathExtension("corrupt-\(UUID().uuidString).json")
        do {
            try FileManager.default.moveItem(at: editorAutosaveURL, to: quarantineURL)
            return "The unreadable recovery file was moved to \(quarantineURL.lastPathComponent)."
        } catch {
            return "The unreadable recovery file was preserved at \(editorAutosaveURL.path) because quarantine failed: \(error)"
        }
    }

    private func quarantineInterruptedPlaySnapshot() -> String {
        guard FileManager.default.fileExists(atPath: physicsPlaySnapshotURL.path) else {
            return "The interrupted Play snapshot was already absent."
        }
        let quarantineURL = physicsPlaySnapshotURL.deletingPathExtension()
            .appendingPathExtension("corrupt-\(UUID().uuidString).json")
        do {
            try FileManager.default.moveItem(at: physicsPlaySnapshotURL, to: quarantineURL)
            return "The unreadable snapshot was moved to \(quarantineURL.lastPathComponent)."
        } catch {
            return "The unreadable snapshot was preserved at \(physicsPlaySnapshotURL.path) because quarantine failed: \(error)"
        }
    }

    private func fileModificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }
}
