import Foundation
import GuavaUICompose
import GuavaUIRuntime
import SceneRuntime
import SIMDCompat
import Testing
@testable import EditorCore

@Suite("Editor orthographic navigation and snapping", .serialized)
@MainActor
struct EditorViewportNavigationTests {
    private let frame = ViewportScreenFrame(x: 0, y: 0, width: 800, height: 600)

    @Test("orthographic point and box picking select offset geometry without a perspective ray")
    func orthographicPicking() throws {
        let adapter = EditorSceneAdapter()
        adapter.setEditorViewportCameraEnabled(true)
        adapter.lookAlongAxis(SIMD3<Float>(0, 0, -1), orthographic: true)
        let first = try #require(adapter.spawnEntity(template: .cube))
        let second = try #require(adapter.spawnEntity(template: .cube))
        adapter.setEntityLocalTranslation(first, to: SIMD3<Float>(-1.5, 0, 0))
        adapter.setEntityLocalTranslation(second, to: SIMD3<Float>(1.5, 0, -3))
        adapter.tickScene()
        let projection = try #require(EditorViewportProjection(camera: adapter.currentRenderCamera(), frame: frame))
        let center = try #require(projection.project(SIMD3<Float>(1.5, 0, -3)))
        #expect(adapter.pickEntity(cursorX: center.x, cursorY: center.y, in: frame) == second)
        let selected = adapter.pickEntities(in: UIRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10), frame: frame)
        #expect(selected == [second])
    }

    @Test("projection switches preserve focus-plane scale and orthographic pan follows pixels")
    func projectionAndNavigation() throws {
        let adapter = EditorSceneAdapter()
        adapter.setEditorViewportCameraEnabled(true)
        adapter.tickScene()
        let perspective = adapter.currentRenderCamera()
        let p = try #require(EditorViewportProjection(camera: perspective, frame: frame))
        let point = perspective.target + p.cameraRight * 0.5
        let before = try #require(p.project(point))
        adapter.setViewportProjection(.orthographic)
        let orthographic = adapter.currentRenderCamera()
        let op = try #require(EditorViewportProjection(camera: orthographic, frame: frame))
        let after = try #require(op.project(point))
        #expect(abs(after.x - before.x) < 0.001 && abs(after.y - before.y) < 0.001)
        adapter.setViewportProjection(.perspective)
        #expect(simd_distance(adapter.currentRenderCamera().eye, perspective.eye) < 1e-4)
        adapter.setViewportProjection(.orthographic)
        adapter.panCamera(deltaScreenX: 60, deltaScreenY: 30, in: frame)
        let moved = try #require(EditorViewportProjection(camera: adapter.currentRenderCamera(), frame: frame)?.project(point))
        #expect(abs(moved.x - after.x - 60) < 0.001)
        #expect(abs(moved.y - after.y - 30) < 0.001)
        let panned = adapter.currentRenderCamera()
        adapter.zoomCamera(factor: 0.5)
        let zoomed = adapter.currentRenderCamera()
        #expect(zoomed.eye == panned.eye && zoomed.target == panned.target)
        #expect(abs(zoomed.orthographicHeight - panned.orthographicHeight * 0.5) < 1e-5)
        adapter.dollyCamera(deltaScreenY: 20)
        #expect(adapter.currentRenderCamera().eye == zoomed.eye)
        #expect(adapter.currentRenderCamera().orthographicHeight > zoomed.orthographicHeight)
        adapter.lookAlongAxis(SIMD3<Float>(0, -1, 0), orthographic: true)
        adapter.freelookCamera(deltaScreenX: 0, deltaScreenY: 0, pressedScancodes: [], modifiers: [])
        #expect(EditorViewportProjection(camera: adapter.currentRenderCamera(), frame: frame) != nil)
    }

    @Test("orthographic gizmo drag follows the cursor and applies configurable translation snapping")
    func orthographicGizmoDrag() throws {
        let camera = RenderCamera(eye: SIMD3<Float>(0, 0, 5), target: .zero,
                                  projection: .orthographic, orthographicHeight: 6)
        let controller = EditorGizmoController()
        controller.updateSnapshot(.init(mode: .translate, space: .world, camera: camera, frame: frame,
            entityID: 1, entityWorldPosition: .zero, entityWorldMatrix: matrix_identity_float4x4,
            entityLocalMatrix: matrix_identity_float4x4, parentWorldMatrix: matrix_identity_float4x4,
            axisLength: 1))
        let drag = try #require(controller.beginDrag(cursorX: 450, cursorY: 300))
        #expect(drag.axis == .x)
        let matrix = try #require(controller.updateDrag(cursorX: 513, cursorY: 300))
        #expect(abs(matrix.columns.3.x - 0.63) < 1e-4)
        let state = EditorState(translateSnapEnabled: true, translateSnapStep: 0.25)
        let snapped = EditorTransformSnapping.apply(matrix, mode: .translate, state: state)
        #expect(snapped.columns.3.x == 0.75)
    }

    @Test("gizmo keeps its screen size and supports picking and dragging beyond the far plane",
          arguments: [RenderCamera.Projection.perspective, .orthographic],
          [Float(5), 500, 50_000])
    func distantGizmo(projection: RenderCamera.Projection, distance: Float) throws {
        let camera = RenderCamera(eye: SIMD3<Float>(0, 0, distance), fovYRadians: .pi / 3,
                                  projection: projection, orthographicHeight: distance)
        let length = EditorGizmoController.axisLength(camera: camera, position: .zero,
                                                     viewportHeight: frame.height)
        let snapshot = EditorGizmoController.Snapshot(mode: .translate, space: .world,
            camera: camera, frame: frame, entityID: 1, entityWorldPosition: .zero,
            entityWorldMatrix: matrix_identity_float4x4, entityLocalMatrix: matrix_identity_float4x4,
            parentWorldMatrix: matrix_identity_float4x4, axisLength: length)
        let projector = try #require(ScreenProjector(snapshot))
        let tip = try #require(projector.project(SIMD3<Float>(length, 0, 0)))
        #expect(abs(tip.x - 496) < 0.01 && abs(tip.y - 300) < 0.01)
        #expect(projector.project(camera.eye + SIMD3<Float>(0, 0, 1)) == nil)
        let sceneProjection = try #require(EditorViewportProjection(camera: camera, frame: frame))
        if distance > camera.far { #expect(sceneProjection.project(.zero) == nil) }
        let controller = EditorGizmoController()
        controller.updateSnapshot(snapshot)
        let drag = try #require(controller.beginDrag(cursorX: tip.x - 4, cursorY: tip.y))
        #expect(drag.axis == .x)
        let moved = try #require(controller.updateDrag(cursorX: tip.x + 20, cursorY: tip.y))
        #expect(abs(moved.columns.3.x / length - 0.25) < 0.001)
    }

    @Test("gizmo screen size accounts for field of view, viewport height, and off-center pivots",
          arguments: [Float.pi / 6, .pi / 2], [Float(300), 1200])
    func gizmoProjectionScale(fov: Float, height: Float) throws {
        let camera = RenderCamera(eye: SIMD3<Float>(0, 0, 500), fovYRadians: fov)
        let pivot = SIMD3<Float>(200, 0, 0)
        let frame = ViewportScreenFrame(x: 40, y: 20, width: 1600, height: height)
        let p = try #require(EditorViewportProjection(camera: camera, frame: frame))
        let length = EditorGizmoController.axisLength(camera: camera, position: pivot, viewportHeight: height)
        let origin = try #require(p.project(pivot, clipToFarPlane: false))
        let tip = try #require(p.project(pivot + SIMD3<Float>(length, 0, 0), clipToFarPlane: false))
        #expect(abs(tip.x - origin.x - 96) < 0.01)
    }

    @Test("custom rotation and scale steps preserve the other transform components")
    func rotationAndScaleSteps() {
        let angle: Float = 22 * .pi / 180
        var matrix = simd_float4x4(simd_quatf(angle: angle, axis: SIMD3<Float>(0, 0, 1)))
        matrix.columns.0 *= 1.23
        matrix.columns.1 *= 1.44
        matrix.columns.2 *= 0.84
        matrix.columns.3 = SIMD4<Float>(3, -2, 5, 1)
        let state = EditorState(rotateSnapEnabled: true, scaleSnapEnabled: true,
                                rotateSnapStepDegrees: 15, scaleSnapStep: 0.2)
        let rotated = EditorTransformSnapping.apply(matrix, mode: .rotate, state: state)
        #expect(abs(atan2f(rotated.columns.0.y, rotated.columns.0.x) - .pi / 12) < 1e-4)
        #expect(rotated.columns.3 == matrix.columns.3)
        #expect(abs(simd_length(SIMD3<Float>(rotated.columns.0.x, rotated.columns.0.y, rotated.columns.0.z)) - 1.23) < 1e-4)
        let scaled = EditorTransformSnapping.apply(matrix, mode: .scale, state: state)
        #expect(abs(simd_length(SIMD3<Float>(scaled.columns.0.x, scaled.columns.0.y, scaled.columns.0.z)) - 1.2) < 1e-4)
        #expect(abs(simd_length(SIMD3<Float>(scaled.columns.1.x, scaled.columns.1.y, scaled.columns.1.z)) - 1.4) < 1e-4)
        #expect(scaled.columns.3 == matrix.columns.3)
        #expect(abs(atan2f(scaled.columns.0.y, scaled.columns.0.x) - angle) < 1e-4)
        #expect(EditorTransformSnapping.apply(matrix, mode: .scale, state: EditorState()) == matrix)
    }

    @Test("snap steps round-trip, support legacy state, and reject invalid values")
    func snapStateCompatibility() throws {
        var state = EditorState(translateSnapStep: 0.125, rotateSnapStepDegrees: 30, scaleSnapStep: 0.01)
        let data = try JSONEncoder().encode(state)
        let restored = try JSONDecoder().decode(EditorState.self, from: data)
        #expect(restored.translateSnapStep == 0.125 && restored.rotateSnapStepDegrees == 30 && restored.scaleSnapStep == 0.01)
        var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["translateSnapStep", "rotateSnapStepDegrees", "scaleSnapStep"] { legacy.removeValue(forKey: key) }
        let old = try JSONDecoder().decode(EditorState.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(old.translateSnapStep == 0.5 && old.rotateSnapStepDegrees == 5 && old.scaleSnapStep == 0.05)
        EditorReducer.reduce(state: &state, action: .setTranslateSnapStep(.nan))
        EditorReducer.reduce(state: &state, action: .setRotateSnapStepDegrees(500))
        EditorReducer.reduce(state: &state, action: .setScaleSnapStep(0.0001))
        #expect(state.translateSnapStep == 0.5 && state.rotateSnapStepDegrees == 180 && state.scaleSnapStep == 0.001)
    }

    @Test("snap settings persist per project and grid changes request a display refresh")
    func snapProjectPersistence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("guava-snap-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try EditorApplication(projectDirectory: directory.path)
        func sceneContent() throws -> Data {
            let encoded = try JSONEncoder().encode(app.scene.manifest())
            var content = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            // Export timestamps describe when a snapshot was requested.
            content.removeValue(forKey: "lastModifiedAt")
            return try JSONSerialization.data(withJSONObject: content, options: [.sortedKeys])
        }
        let scene = try sceneContent()
        var displayRequests = 0
        app.setDisplayInvalidationHandler { displayRequests += 1 }
        app.store.dispatch(.setTranslateSnapEnabled(true))
        app.store.dispatch(.setRotateSnapEnabled(true))
        app.store.dispatch(.setScaleSnapEnabled(true))
        app.store.dispatch(.setTranslateSnapStep(0.25))
        app.store.dispatch(.setRotateSnapStepDegrees(15))
        app.store.dispatch(.setScaleSnapStep(0.1))
        #expect(displayRequests == 6)
        #expect(try sceneContent() == scene)
        #expect(!app.hasUnsavedSceneChanges)
        let settings = EditorViewportSnapSettings(state: app.store.state)
        let url = directory.appendingPathComponent(".guava/editor-snap-settings.json")
        #expect(try JSONDecoder().decode(EditorViewportSnapSettings.self, from: Data(contentsOf: url)) == settings)
        app.shutdown()
        let reopened = try EditorApplication(projectDirectory: directory.path)
        defer { reopened.shutdown() }
        #expect(EditorViewportSnapSettings(state: reopened.store.state) == settings)
    }

    @Test("front, side, and top asset drops follow the editor reference plane")
    func orthographicDropPlanes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("guava-ortho-drop-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try EditorApplication(projectDirectory: directory.path)
        defer { app.shutdown() }
        for axis in [SIMD3<Float>(0, 0, -1), SIMD3<Float>(-1, 0, 0), SIMD3<Float>(0, -1, 0)] {
            app.scene.lookAlongAxis(axis, orthographic: true)
            let p = try #require(EditorViewportProjection(camera: app.scene.currentRenderCamera(), frame: frame))
            let point = app.dropWorldPosition(cursorX: 530, cursorY: 240, frame: frame)
            #expect(abs(simd_dot(point, axis)) < 1e-4)
            let projected = try #require(p.project(point))
            #expect(abs(projected.x - 530) < 0.001 && abs(projected.y - 240) < 0.001)
        }
    }
}
