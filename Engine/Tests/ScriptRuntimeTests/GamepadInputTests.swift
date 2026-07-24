import EngineKernel
import SceneRuntime
import ScriptRuntime
import Testing

@Suite("GamepadInput")
struct GamepadInputTests {

    private func makeScene() -> SceneRuntime {
        var runtime = SceneRuntime()
        let scripts = ScriptRuntime()
        runtime.setScriptDriver(scripts)

        let entity = runtime.createEntity()
        _ = runtime.setComponent(ScriptComponent(), for: entity)
        return runtime
    }

    // MARK: - Button bindings

    @Test("gamepad button binding triggers action held")
    func gamepadButtonTriggersHeld() {
        var runtime = makeScene()
        var map = InputActionMap()
        map.bind("jump", to: .gamepadButton(.south))
        runtime.setResource(map)

        _ = runtime.tick(deltaTime: 0.1, inputEvents: [
            .gamepadButtonDown(GamepadButtonEvent(gamepadID: 0, button: .south))
        ])

        let state = runtime.resource(InputFrameState.self)
        #expect(state != nil)
        #expect(state!.isHeld("jump"))
    }

    @Test("gamepad button release clears action")
    func gamepadButtonReleaseClearsAction() {
        var runtime = makeScene()
        var map = InputActionMap()
        map.bind("jump", to: .gamepadButton(.south))
        runtime.setResource(map)

        _ = runtime.tick(deltaTime: 0.1, inputEvents: [
            .gamepadButtonDown(GamepadButtonEvent(gamepadID: 0, button: .south))
        ])
        _ = runtime.tick(deltaTime: 0.1, inputEvents: [
            .gamepadButtonUp(GamepadButtonEvent(gamepadID: 0, button: .south))
        ])

        let state = runtime.resource(InputFrameState.self)
        #expect(state != nil)
        #expect(!state!.isHeld("jump"))
    }

    @Test("gamepad button justPressed fires on first frame only")
    func gamepadButtonJustPressed() {
        var runtime = makeScene()
        var map = InputActionMap()
        map.bind("fire", to: .gamepadButton(.west))
        runtime.setResource(map)

        _ = runtime.tick(deltaTime: 0.1, inputEvents: [
            .gamepadButtonDown(GamepadButtonEvent(gamepadID: 0, button: .west))
        ])

        let s1 = runtime.resource(InputFrameState.self)
        #expect(s1!.isJustPressed("fire"))

        _ = runtime.tick(deltaTime: 0.1) // no events
        let s2 = runtime.resource(InputFrameState.self)
        #expect(!s2!.isJustPressed("fire"))
        #expect(s2!.isHeld("fire")) // still held
    }

    // MARK: - Axis bindings

    @Test("gamepad left stick maps to axis action")
    func gamepadLeftStickAxis() {
        var runtime = makeScene()
        var map = InputActionMap()
        map.bind("move_x", to: .gamepadAxis(.leftX))
        map.bind("move_y", to: .gamepadAxis(.leftY))
        runtime.setResource(map)

        _ = runtime.tick(deltaTime: 0.1, inputEvents: [
            .gamepadAxisMotion(GamepadAxisEvent(gamepadID: 0, axis: .leftX, value: 0.75)),
            .gamepadAxisMotion(GamepadAxisEvent(gamepadID: 0, axis: .leftY, value: -0.5)),
        ])

        let state = runtime.resource(InputFrameState.self)
        #expect(state != nil)
        #expect(abs(state!.axis("move_x") - 0.75) < 0.01)
        #expect(abs(state!.axis("move_y") - (-0.5)) < 0.01)
    }

    @Test("trigger axis maps correctly")
    func triggerAxis() {
        var runtime = makeScene()
        var map = InputActionMap()
        map.bind("accelerate", to: .gamepadAxis(.rightTrigger))
        runtime.setResource(map)

        _ = runtime.tick(deltaTime: 0.1, inputEvents: [
            .gamepadAxisMotion(GamepadAxisEvent(gamepadID: 0, axis: .rightTrigger, value: 0.85)),
        ])

        let state = runtime.resource(InputFrameState.self)
        #expect(state != nil)
        #expect(abs(state!.axis("accelerate") - 0.85) < 0.01)
    }

    // MARK: - Mixed bindings

    @Test("keyboard and gamepad both contribute to same action")
    func mixedBindingsContribute() {
        var runtime = makeScene()
        var map = InputActionMap()
        map.bind("jump", to: .key(Scancode.space))
        map.bind("jump", to: .gamepadButton(.south))
        runtime.setResource(map)

        // Press via gamepad
        _ = runtime.tick(deltaTime: 0.1, inputEvents: [
            .gamepadButtonDown(GamepadButtonEvent(gamepadID: 0, button: .south))
        ])

        let state = runtime.resource(InputFrameState.self)
        #expect(state!.isHeld("jump"))
        #expect(state!.isJustPressed("jump"))
    }

    @Test("axis bindings accumulate from multiple sources")
    func axisAccumulates() {
        var runtime = makeScene()
        var map = InputActionMap()
        map.bind("look_x", to: .gamepadAxis(.rightX))
        map.bind("look_x", to: .keyAxis(negative: Scancode.left, positive: Scancode.right))
        runtime.setResource(map)

        _ = runtime.tick(deltaTime: 0.1, inputEvents: [
            .gamepadAxisMotion(GamepadAxisEvent(gamepadID: 0, axis: .rightX, value: 0.3)),
        ])

        let state = runtime.resource(InputFrameState.self)
        #expect(abs(state!.axis("look_x") - 0.3) < 0.01)
    }

    @Test("mouse motion axes honor required button gates")
    func mouseMotionButtonGate() {
        var runtime = makeScene()
        var map = InputActionMap()
        map.bind("look_x", to: .mouseMotion(axis: .x, requiredButton: .right, scale: 0.5))
        runtime.setResource(map)

        _ = runtime.tick(deltaTime: 0.1, inputEvents: [
            .mouseMotion(MouseMotionEvent(x: 10, y: 0, deltaX: 10, deltaY: 0)),
        ])
        #expect(runtime.resource(InputFrameState.self)?.axis("look_x") == 0)

        _ = runtime.tick(deltaTime: 0.1, inputEvents: [
            .mouseButtonDown(MouseButtonEvent(button: .right, x: 0, y: 0, clicks: 1)),
            .mouseMotion(MouseMotionEvent(x: 18, y: 0, deltaX: 8, deltaY: 0)),
        ])
        #expect(runtime.resource(InputFrameState.self)?.axis("look_x") == 4)
    }

    @Test("mouse wheel contributes a per-frame camera axis")
    func mouseWheelAxis() {
        var runtime = makeScene()
        var map = InputActionMap()
        map.bind("camera_zoom", to: .mouseWheel(axis: .y, scale: -2))
        runtime.setResource(map)

        _ = runtime.tick(deltaTime: 0.1, inputEvents: [
            .mouseWheel(MouseWheelEvent(x: 0, y: 1.5)),
        ])
        #expect(runtime.resource(InputFrameState.self)?.axis("camera_zoom") == -3)
        _ = runtime.tick(deltaTime: 0.1)
        #expect(runtime.resource(InputFrameState.self)?.axis("camera_zoom") == 0)
    }

    @Test("Guava defaults cover built-in movement, camera, and jump actions")
    func standardInputMap() {
        let map = InputActionMap.guavaDefault
        #expect(map.bindings["move_forward"]?.contains(.key(Scancode.w)) == true)
        #expect(map.bindings["jump"]?.contains(.key(Scancode.space)) == true)
        #expect(map.bindings["look_x"]?.contains(
            .mouseMotion(axis: .x, requiredButton: .right)
        ) == true)
        #expect(map.bindings["camera_zoom"]?.contains(.mouseWheel(axis: .y)) == true)
    }
}
