import EditorCore
import ContextMemory
import Foundation
import Testing

@Suite("Editor scene recovery", .serialized)
struct EditorSceneRecoveryTests {
    @Test("an explicitly selected scene file loads and survives the unsaved prompt")
    func opensExplicitSceneFile() throws {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("guava-editor-open-scene-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: project) }
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let authored = EditorSceneAdapter()
        let cubeID = try #require(authored.spawnEntity(template: .cube))
        let sceneURL = project.appendingPathComponent("alternate-scene.json")
        let encoder = JSONEncoder()
        try encoder.encode(authored.manifest(selectedEntityID: cubeID)).write(to: sceneURL)

        let app = try EditorApplication(projectDirectory: project.path)
        defer { app.shutdown() }
        let opened = try #require(app.openSceneManifest(at: sceneURL))
        #expect(opened.entityCount == authored.manifest().entityCount)
        #expect(app.scene.entitySummary(id: app.store.state.selectedEntityID)?.name == "Cube")

        app.scene.setEntityLocalTranslation(cubeID, to: SIMD3<Float>(1, 2, 3))
        #expect(app.hasUnsavedSceneChanges)
        app.requestOpenSceneManifest(at: sceneURL)
        #expect(app.store.state.pendingCloseRequest?.action == .openScene)
        #expect(app.store.state.pendingCloseRequest?.documentPath == sceneURL.path)
    }

    @Test("corrupt scene recovery is quarantined with a diagnostic")
    func corruptSceneRecoveryIsQuarantined() throws {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("guava-editor-corrupt-recovery-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: project) }
        let recoveryURL = GameSaveDocument.url(slot: GameSaveDocument.autoSaveSlot,
                                               projectDirectory: project.path)
        try FileManager.default.createDirectory(at: recoveryURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let corruptPayload = Data("not a game save".utf8)
        try corruptPayload.write(to: recoveryURL, options: .atomic)

        let app = try EditorApplication(projectDirectory: project.path)
        defer { app.shutdown() }
        #expect(app.restoreProjectSceneAtLaunch() == nil)

        #expect(!FileManager.default.fileExists(atPath: recoveryURL.path))
        let files = try FileManager.default.contentsOfDirectory(
            at: recoveryURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        let quarantinedURL = try #require(files.first {
            $0.lastPathComponent.hasPrefix("slot-255.corrupt-") && $0.pathExtension == "json"
        })
        #expect(try Data(contentsOf: quarantinedURL) == corruptPayload)
        #expect(app.store.state.consoleEntries.contains {
            $0.message == "Failed to restore autosaved scene"
                && $0.severity == .warning
                && ($0.detail?.contains(quarantinedURL.lastPathComponent) ?? false)
        })
    }

    @Test("corrupt AI context memory is quarantined instead of silently disabling memory")
    func corruptContextMemoryIsQuarantined() throws {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("guava-editor-context-memory-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: project) }
        let guavaDirectory = project.appendingPathComponent(".guava", isDirectory: true)
        try FileManager.default.createDirectory(at: guavaDirectory, withIntermediateDirectories: true)
        let memoryURL = guavaDirectory.appendingPathComponent("context_memory.json")
        try Data("not-json".utf8).write(to: memoryURL)

        let app = try EditorApplication(projectDirectory: project.path)

        #expect(!FileManager.default.fileExists(atPath: memoryURL.path))
        #expect(app.store.state.consoleEntries.contains {
            $0.message == "Recovered AI context memory storage" && $0.severity == .warning
        })

        app.shutdown()
        let files = try FileManager.default.contentsOfDirectory(at: guavaDirectory,
                                                                includingPropertiesForKeys: nil)
        #expect(files.contains {
            $0.lastPathComponent.hasPrefix("context_memory.corrupt-")
                && $0.pathExtension == "json"
        })
        let recoveredEntries = try JSONDecoder().decode(
            [ContextEntry].self,
            from: Data(contentsOf: memoryURL)
        )
        #expect(recoveredEntries.isEmpty)
    }

    @Test("core playback state machine rejects stopping-to-paused and no-op transitions")
    func corePlaybackStateMachineRejectsInvalidTransitions() throws {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("guava-editor-playback-policy-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: project) }
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let app = try EditorApplication(projectDirectory: project.path)
        defer { app.shutdown() }

        app.applyPlaybackState(.paused)
        #expect(app.store.playbackState == .stopped)
        app.applyPlaybackState(.stopped)
        #expect(app.store.playbackState == .stopped)
    }

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

    @Test("exporting during playback packages the authored scene, not runtime mutations")
    func exportDuringPlaybackUsesPrePlaySnapshot() throws {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("guava-editor-play-export-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: project) }
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let app = try EditorApplication(projectDirectory: project.path)
        defer { app.shutdown() }
        let entityID = try #require(app.scene.defaultSelectionID)
        let original = try #require(app.scene.entityLocalTranslation(entityID))
        let authored = original + SIMD3<Float>(3, 4, 5)
        let runtimeOnly = original + SIMD3<Float>(30, 40, 50)
        app.scene.setEntityLocalTranslation(entityID, to: authored)
        app.applyPlaybackState(.playing)
        app.scene.setEntityLocalTranslation(entityID, to: runtimeOnly)

        let output = try #require(app.exportProject())
        #expect(try ProjectExporter.readDescriptor(from: output).appName
            == project.lastPathComponent)
        let sceneURL = GameSaveDocument.url(slot: ProjectExporter.sceneSlot,
                                            projectDirectory: output.path)
        let document = try #require(try GameSaveDocument.read(from: sceneURL))
        let restored = EditorSceneAdapter()
        let loadResult = restored.load(manifest: document.manifest, notify: false)
        let restoredID = try #require(loadResult.selectedEntityID)

        #expect(app.store.playbackState == .playing)
        #expect(app.scene.entityLocalTranslation(entityID) == runtimeOnly)
        #expect(restored.entityLocalTranslation(restoredID) == authored)
    }
}
