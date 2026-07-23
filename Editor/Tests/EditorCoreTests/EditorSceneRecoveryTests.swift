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
}
