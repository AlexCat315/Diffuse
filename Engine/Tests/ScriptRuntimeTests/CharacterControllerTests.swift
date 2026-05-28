import EngineKernel
import SceneRuntime
import ScriptRuntime
import Testing
import SIMDCompat

@Suite("CharacterController")
struct CharacterControllerTests {

    private func makeScene(parametersJSON: String = "{}") -> (SceneRuntime, EntityID) {
        var runtime = SceneRuntime()
        let scripts = ScriptRuntime()
        runtime.setScriptDriver(scripts)

        let ccScript = scripts.register(Script.characterController())
        let entity = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(0, 5, 0)), for: entity)
        _ = runtime.setComponent(
            Collider(shape: .box(halfExtents: SIMD3<Float>(0.5, 1, 0.5), center: .zero),
                     isTrigger: false, layerID: 1, layerMask: .max),
            for: entity
        )
        _ = runtime.setComponent(
            ScriptComponent(ScriptBinding(ccScript, parametersJSON: parametersJSON)),
            for: entity
        )

        // Register input action bindings
        var map = InputActionMap()
        map.bind("move_forward", to: .key(Scancode.w))
        map.bind("move_back",    to: .key(Scancode.s))
        map.bind("move_left",    to: .key(Scancode.a))
        map.bind("move_right",   to: .key(Scancode.d))
        map.bind("jump",         to: .key(Scancode.space))
        runtime.setResource(map)

        return (runtime, entity)
    }

    private func addGround(to runtime: inout SceneRuntime, at y: Float = 0) {
        let ground = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(0, y, 0)), for: ground)
        _ = runtime.setComponent(
            Collider(shape: .box(halfExtents: SIMD3<Float>(10, 1, 10), center: .zero),
                     isTrigger: false, layerID: 1, layerMask: .max),
            for: ground
        )
    }

    private func keyDown(_ sc: UInt32) -> InputEvent {
        .keyDown(KeyEvent(scancode: sc, keycode: sc, modifiers: [], isRepeat: false))
    }

    private func keyUp(_ sc: UInt32) -> InputEvent {
        .keyUp(KeyEvent(scancode: sc, keycode: sc, modifiers: [], isRepeat: false))
    }

    // MARK: - Gravity

    @Test("gravity pulls entity downward when airborne")
    func gravityPullsDown() {
        var (runtime, entity) = makeScene()
        _ = runtime.tick(deltaTime: 0.1)

        let pos = runtime.localTransform(for: entity)?.translation
        #expect(pos != nil)
        #expect(pos!.y < 5.0)
    }

    // MARK: - Ground detection

    @Test("entity lands on ground and stops")
    func landsOnGround() {
        var (runtime, entity) = makeScene()
        addGround(to: &runtime, at: 0)

        for _ in 0..<100 { _ = runtime.tick(deltaTime: 0.1) }

        let pos = runtime.localTransform(for: entity)?.translation
        #expect(pos != nil)
        #expect(abs(pos!.y - 2.0) < 0.5)
    }

    @Test("entity does not fall through ground")
    func doesNotFallThroughGround() {
        var (runtime, entity) = makeScene()
        addGround(to: &runtime, at: 0)

        for _ in 0..<150 { _ = runtime.tick(deltaTime: 0.1) }

        let pos = runtime.localTransform(for: entity)?.translation
        #expect(pos != nil)
        #expect(pos!.y >= 1.0)
    }

    // MARK: - Jump

    @Test("jump lifts entity upward")
    func jumpLiftsUpward() {
        var (runtime, entity) = makeScene()
        addGround(to: &runtime, at: 0)

        for _ in 0..<100 { _ = runtime.tick(deltaTime: 0.1) }
        let landedY = runtime.localTransform(for: entity)?.translation.y ?? 0

        // Jump via space key press
        _ = runtime.tick(deltaTime: 0.05, inputEvents: [keyDown(Scancode.space)])
        // Release and let the jump carry upward
        _ = runtime.tick(deltaTime: 0.1, inputEvents: [keyUp(Scancode.space)])

        let afterJumpY = runtime.localTransform(for: entity)?.translation.y ?? 0
        #expect(afterJumpY > landedY + 0.1)
    }

    // MARK: - Horizontal movement

    @Test("move_forward moves in -Z")
    func moveForward() {
        var (runtime, entity) = makeScene()
        addGround(to: &runtime, at: 0)

        for _ in 0..<100 { _ = runtime.tick(deltaTime: 0.1) }

        _ = runtime.tick(deltaTime: 0.5, inputEvents: [keyDown(Scancode.w)])

        let pos = runtime.localTransform(for: entity)?.translation
        #expect(pos != nil)
        #expect(pos!.z < -0.5)
    }

    @Test("move_left moves in -X")
    func moveLeft() {
        var (runtime, entity) = makeScene()
        addGround(to: &runtime, at: 0)

        for _ in 0..<100 { _ = runtime.tick(deltaTime: 0.1) }

        _ = runtime.tick(deltaTime: 0.5, inputEvents: [keyDown(Scancode.a)])

        let pos = runtime.localTransform(for: entity)?.translation
        #expect(pos != nil)
        #expect(pos!.x < -0.5)
    }

    // MARK: - Land/leave ground events

    @Test("CharacterLandEvent fires on landing")
    func landEventFires() {
        var (runtime, _) = makeScene()
        addGround(to: &runtime, at: 0)

        for _ in 0..<100 { _ = runtime.tick(deltaTime: 0.1) }

        #expect(runtime.resource(CharacterLandEvent.self) != nil)
    }

    @Test("CharacterLeaveGroundEvent fires on jump")
    func leaveGroundEventFires() {
        var (runtime, _) = makeScene()
        addGround(to: &runtime, at: 0)

        for _ in 0..<100 { _ = runtime.tick(deltaTime: 0.1) }

        // Jump press — starts upward movement
        _ = runtime.tick(deltaTime: 0.05, inputEvents: [keyDown(Scancode.space)])
        // One more frame — entity now airborne, leave-ground event fires
        _ = runtime.tick(deltaTime: 0.1)

        #expect(runtime.resource(CharacterLeaveGroundEvent.self) != nil)
    }
}
