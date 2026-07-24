import EngineKernel
import SceneRuntime
import ScriptRuntime
import Testing
import SIMDCompat

@Suite("Camera controller scripts")
struct CameraControllerTests {
    @Test("first-person look updates the render camera target")
    func firstPersonUpdatesCameraComponent() throws {
        let scripts = ScriptRuntime()
        let handle = scripts.register(named: "camera.first-person") {
            .firstPersonCamera(lookSensitivity: 0.01)
        }
        var runtime = SceneRuntime()
        runtime.setScriptDriver(scripts)
        runtime.setResource(InputActionMap.guavaDefault)
        let entity = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(), for: entity)
        _ = runtime.setComponent(CameraComponent(target: SIMD3<Float>(0, 0, -1)), for: entity)
        _ = runtime.setComponent(ScriptComponent(handle), for: entity)

        _ = runtime.tick(deltaTime: 0.1, inputEvents: [
            .mouseButtonDown(MouseButtonEvent(button: .right, x: 0, y: 0, clicks: 1)),
            .mouseMotion(MouseMotionEvent(x: 50, y: 0, deltaX: 50, deltaY: 0)),
        ])

        let camera = try #require(runtime.component(CameraComponent.self, for: entity))
        #expect(abs(camera.target.x) > 0.1)
        #expect(abs(simd_length(camera.target) - 1) < 0.001)
    }

    @Test("orbit camera authors the camera target and responds to wheel zoom")
    func orbitUpdatesCameraComponentAndZoom() throws {
        let target = SIMD3<Float>(1, 2, 3)
        let scripts = ScriptRuntime()
        let handle = scripts.register(named: "camera.orbit") {
            .orbitCamera(target: target, distance: 10, zoomSpeed: 2)
        }
        var runtime = SceneRuntime()
        runtime.setScriptDriver(scripts)
        runtime.setResource(InputActionMap.guavaDefault)
        let entity = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(), for: entity)
        _ = runtime.setComponent(CameraComponent(), for: entity)
        _ = runtime.setComponent(ScriptComponent(handle), for: entity)

        _ = runtime.tick(deltaTime: 0.1)
        let initialDistance = simd_length(
            try #require(runtime.localTransform(for: entity)).translation - target
        )
        _ = runtime.tick(deltaTime: 0.1, inputEvents: [
            .mouseWheel(MouseWheelEvent(x: 0, y: 1)),
        ])

        let camera = try #require(runtime.component(CameraComponent.self, for: entity))
        let zoomedDistance = simd_length(
            try #require(runtime.localTransform(for: entity)).translation - target
        )
        #expect(camera.target == target)
        #expect(abs(initialDistance - 10) < 0.001)
        #expect(abs(zoomedDistance - 8) < 0.001)
    }
}
