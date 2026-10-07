import Foundation
import GuavaUICompose
import GuavaUIRuntime
import RenderBackend
import SceneRuntime
import SIMDCompat
import Testing
@testable import EditorCore

@Suite("Editor viewport camera isolation", .serialized)
@MainActor
struct EditorViewportCameraIsolationTests {
    @Test("navigation preserves authored camera, saved scene, and undo history")
    func navigationPreservesScene() throws {
        let adapter = EditorSceneAdapter()
        adapter.setEditorViewportCameraEnabled(true)
        adapter.tickScene()
        let before = adapter.manifest()
        let cameraBefore = adapter.currentRenderCamera()
        let frame = ViewportScreenFrame(x: 0, y: 0, width: 800, height: 600)
        adapter.setViewportProjection(.orthographic)
        adapter.orbitCamera(deltaScreenX: 30, deltaScreenY: 10, in: frame)
        adapter.panCamera(deltaScreenX: 20, deltaScreenY: 10, in: frame)
        adapter.dollyCamera(deltaScreenY: 15)
        adapter.zoomCamera(factor: 0.8)
        adapter.freelookCamera(deltaScreenX: 5, deltaScreenY: 5,
                              pressedScancodes: [26], modifiers: [])
        adapter.lookAlongAxis(SIMD3<Float>(1, 0, 0))
        adapter.frameEntities(Set(adapter.roots.map(\.id)))
        #expect(adapter.currentRenderCamera() != cameraBefore)
        #expect(adapter.currentRenderScene().camera == adapter.currentRenderCamera())
        #expect(adapter.manifest() == before)
        #expect(!adapter.canUndoEdit)
        #expect(!adapter.canRedoEdit)
    }

    @Test("play and pause use the game camera and stopping restores the editor view")
    func playbackRestoresEditorView() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("guava-camera-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try EditorApplication(projectDirectory: directory.path, seedPreviewScene: true)
        defer { app.shutdown() }
        app.scene.tickScene()
        app.scene.lookAlongAxis(SIMD3<Float>(0, -1, 0), orthographic: true)
        app.scene.zoomCamera(factor: 0.7)
        let editorCamera = app.scene.currentRenderCamera()
        let gameCamera = try #require(app.scene.scene.extractedRenderScene?.scene.camera)
        #expect(editorCamera != gameCamera)
        #expect(app.saveSceneManifest() != nil)
        #expect(!app.hasUnsavedSceneChanges)
        let savedScene = app.scene.manifest()
        app.applyPlaybackState(.playing)
        #expect(app.store.viewportMode == .game)
        #expect(app.store.gamePreviewResolution == .fit)
        #expect(!app.scene.usesEditorViewportCamera)
        #expect(app.scene.currentRenderScene().camera == gameCamera)
        app.scene.orbitCamera(deltaScreenX: 40, deltaScreenY: 20,
                              in: ViewportScreenFrame(x: 0, y: 0, width: 800, height: 600))
        app.scene.setViewportProjection(.perspective)
        app.applyPlaybackState(.paused)
        #expect(app.store.viewportMode == .game)
        #expect(app.scene.currentRenderCamera() == gameCamera)
        app.applyPlaybackState(.stopped)
        #expect(app.store.viewportMode == .scene)
        #expect(!app.store.gamePreviewFocused)
        #expect(app.scene.usesEditorViewportCamera)
        #expect(app.scene.currentRenderCamera() == editorCamera)
        #expect(app.scene.manifest() == savedScene)
        #expect(!app.hasUnsavedSceneChanges)
        let selectedID = try #require(app.scene.defaultSelectionID)
        app.scene.setEntityLocalTranslation(selectedID, to: SIMD3<Float>(7, 2, 1))
        #expect(app.hasUnsavedSceneChanges)
        app.applyPlaybackState(.playing)
        app.scene.tickScene(deltaTime: 1.0 / 60.0, frameIndex: 1)
        app.applyPlaybackState(.stopped)
        #expect(app.hasUnsavedSceneChanges)
        #expect(app.scene.entityLocalTranslation(selectedID) == SIMD3<Float>(7, 2, 1))
    }
}
