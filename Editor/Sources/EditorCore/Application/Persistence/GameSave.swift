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
    // MARK: - Game Save

    /// Saves the current runtime scene state to the given slot.
    /// Works both in edit mode and during gameplay (captures post-physics transforms).
    @discardableResult
    public func saveGameState(slot: Int = 0) -> URL? {
        do {
            let url = GameSaveDocument.url(slot: slot, projectDirectory: projectDirectory)
            let manifest = scene.manifest(selectedEntityID: store.state.selection.selectedEntityID)
            let doc = GameSaveDocument(slot: slot, manifest: manifest)
            try doc.write(to: url)
            logConsole("Game state saved", detail: "slot \(slot) → \(url.lastPathComponent)")
            return url
        } catch {
            logConsole("Failed to save game state",
                       severity: .error,
                       detail: String(describing: error))
            return nil
        }
    }

    /// Loads a previously saved game state from the given slot.
    /// Replaces the current scene; returns true on success.
    @discardableResult
    public func loadGameState(slot: Int = 0) -> Bool {
        do {
            let url = GameSaveDocument.url(slot: slot, projectDirectory: projectDirectory)
            guard let doc = try GameSaveDocument.read(from: url) else {
                logConsole("No game save found", severity: .warning, detail: "slot \(slot)")
                return false
            }
            let result = scene.load(manifest: doc.manifest)
            guard result.error == nil else { throw result.error! }
            reloadScriptsAfterSceneReplacement()
            store.dispatch(.setSelectedEntity(result.selectedEntityID))
            store.dispatch(.setSceneRevision(scene.revision))
            logConsole("Game state loaded",
                       detail: "slot \(slot), \(result.entityCount) entities, saved \(doc.savedAt)")
            return true
        } catch {
            logConsole("Failed to load game state",
                       severity: .error,
                       detail: String(describing: error))
            return false
        }
    }

    // MARK: - Physics play snapshot persistence

    var physicsPlaySnapshotURL: URL {
        URL(fileURLWithPath: projectDirectory, isDirectory: true)
            .appendingPathComponent(".guava", isDirectory: true)
            .appendingPathComponent("physics-play-snapshot.json")
    }

    func persistPhysicsPlaySnapshot() {
        guard let snapshot = physicsPlaySnapshot else { return }
        do {
            let guavaDir = physicsPlaySnapshotURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: guavaDir,
                                                    withIntermediateDirectories: true)
            let tmpAdapter = EditorSceneAdapter()
            tmpAdapter.scene = snapshot
            let manifest = tmpAdapter.manifest(selectedEntityID: store.state.selection.selectedEntityID)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(manifest)
            try data.write(to: physicsPlaySnapshotURL, options: [.atomic])
        } catch {
            logConsole("Failed to persist physics play snapshot",
                       severity: .warning,
                       detail: String(describing: error))
        }
    }

    func loadPersistedPhysicsPlaySnapshot() -> SceneRuntime? {
        guard FileManager.default.fileExists(atPath: physicsPlaySnapshotURL.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: physicsPlaySnapshotURL)
            let manifest = try JSONDecoder().decode(EditorSceneManifest.self, from: data)
            let tmpAdapter = EditorSceneAdapter()
            _ = tmpAdapter.load(manifest: manifest, notify: false)
            logConsole("Restored physics play snapshot from disk (crash recovery)",
                       severity: .warning)
            return tmpAdapter.scene
        } catch {
            logConsole("Failed to load persisted physics play snapshot",
                       severity: .warning,
                       detail: String(describing: error))
            return nil
        }
    }

    func deletePersistedPhysicsPlaySnapshot() {
        try? FileManager.default.removeItem(at: physicsPlaySnapshotURL)
    }
}
