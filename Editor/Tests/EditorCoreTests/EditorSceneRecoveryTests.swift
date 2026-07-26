import EditorCore
import Foundation
import Testing

@Suite("Editor scene recovery", .serialized)
struct EditorSceneRecoveryTests {
    @Test("dirty scene is autosaved on shutdown, restored, and cleared by an explicit save")
    func shutdownRecoveryRoundTrip() throws {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("guava-editor-recovery-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: project) }
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        var first: EditorApplication? = try EditorApplication(projectDirectory: project.path)
        defer { first?.shutdown() }
        let entityID = try #require(first?.scene.defaultSelectionID)
        let original = try #require(first?.scene.entityLocalTranslation(entityID))
        let edited = original + SIMD3<Float>(4, 5, 6)
        first?.scene.setEntityLocalTranslation(entityID, to: edited)
        #expect(first?.hasUnsavedSceneChanges == true)

        first?.shutdown()
        first = nil
        let recoveryURL = GameSaveDocument.url(slot: GameSaveDocument.autoSaveSlot,
                                               projectDirectory: project.path)
        #expect(FileManager.default.fileExists(atPath: recoveryURL.path))

        let restored = try EditorApplication(projectDirectory: project.path)
        defer { restored.shutdown() }
        let recoveredManifest = restored.restoreProjectSceneAtLaunch()
        let restoredID = try #require(restored.store.state.selectedEntityID)
        #expect(recoveredManifest != nil)
        #expect(restored.scene.entityLocalTranslation(restoredID) == edited)
        #expect(restored.hasUnsavedSceneChanges == true)
        #expect(restored.store.sceneRecoveryPending == true)

        #expect(restored.saveSceneManifest() != nil)
        #expect(restored.hasUnsavedSceneChanges == false)
        #expect(!FileManager.default.fileExists(atPath: recoveryURL.path))
    }

    @Test("saving during playback persists the authored scene, not runtime mutations")
    func saveDuringPlaybackUsesPrePlaySnapshot() throws {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("guava-editor-play-save-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: project) }
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let app = try EditorApplication(projectDirectory: project.path)
        defer { app.shutdown() }
        let entityID = try #require(app.scene.defaultSelectionID)
        let original = try #require(app.scene.entityLocalTranslation(entityID))
        let authored = original + SIMD3<Float>(2, 3, 4)
        let runtimeOnly = original + SIMD3<Float>(20, 30, 40)
        app.scene.setEntityLocalTranslation(entityID, to: authored)
        app.applyPlaybackState(.playing)
        app.scene.setEntityLocalTranslation(entityID, to: runtimeOnly)

        let savedURL = try #require(app.saveSceneManifest())
        #expect(app.store.playbackState == .playing)
        #expect(app.scene.entityLocalTranslation(entityID) == runtimeOnly)

        let data = try Data(contentsOf: savedURL)
        let manifest = try JSONDecoder().decode(EditorSceneManifest.self, from: data)
        let restored = EditorSceneAdapter()
        let loadResult = restored.load(manifest: manifest, notify: false)
        let restoredID = try #require(loadResult.selectedEntityID)
        #expect(restored.entityLocalTranslation(restoredID) == authored)

        app.applyPlaybackState(.stopped)
        #expect(app.scene.entityLocalTranslation(entityID) == authored)
        #expect(!app.hasUnsavedSceneChanges)
    }
}
