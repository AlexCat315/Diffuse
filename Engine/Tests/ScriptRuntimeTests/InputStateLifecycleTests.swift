import EngineKernel
import SceneRuntime
import ScriptRuntime
import Testing

@Suite("Input state lifecycle")
struct InputStateLifecycleTests {
    @Test("window focus loss releases held controls and clears axes")
    func focusLossReleasesHeldControls() throws {
        let scripts = ScriptRuntime()
        var runtime = SceneRuntime()
        runtime.setScriptDriver(scripts)

        var map = InputActionMap()
        map.bind("jump", to: .key(Scancode.space))
        map.bind("fire", to: .mouseButton(.left))
        map.bind("dash", to: .gamepadButton(.south))
        map.bind("move_x", to: .gamepadAxis(.leftX))
        runtime.setResource(map)

        _ = runtime.tick(deltaTime: 0.1, inputEvents: [
            .keyDown(KeyEvent(scancode: Scancode.space,
                              keycode: 0,
                              modifiers: [],
                              isRepeat: false)),
            .mouseButtonDown(MouseButtonEvent(button: .left, x: 0, y: 0, clicks: 1)),
            .gamepadButtonDown(GamepadButtonEvent(gamepadID: 7, button: .south)),
            .gamepadAxisMotion(GamepadAxisEvent(gamepadID: 7, axis: .leftX, value: 0.75)),
        ])

        let active = try #require(runtime.resource(InputFrameState.self))
        #expect(active.isHeld("jump"))
        #expect(active.isHeld("fire"))
        #expect(active.isHeld("dash"))
        #expect(active.axis("move_x") == 0.75)

        _ = runtime.tick(deltaTime: 0.1, inputEvents: [.windowFocusLost])

        let released = try #require(runtime.resource(InputFrameState.self))
        #expect(!released.isHeld("jump"))
        #expect(!released.isHeld("fire"))
        #expect(!released.isHeld("dash"))
        #expect(released.isJustReleased("jump"))
        #expect(released.isJustReleased("fire"))
        #expect(released.isJustReleased("dash"))
        #expect(released.axis("move_x") == 0)

        _ = runtime.tick(deltaTime: 0.1)
        let nextFrame = try #require(runtime.resource(InputFrameState.self))
        #expect(nextFrame.justReleased.isEmpty)
        #expect(nextFrame.held.isEmpty)
        #expect(nextFrame.axis("move_x") == 0)
    }

    @Test("window minimization also clears held controls")
    func minimizationReleasesHeldControls() throws {
        let scripts = ScriptRuntime()
        var runtime = SceneRuntime()
        runtime.setScriptDriver(scripts)

        var map = InputActionMap()
        map.bind("jump", to: .key(Scancode.space))
        runtime.setResource(map)

        _ = runtime.tick(deltaTime: 0.1, inputEvents: [
            .keyDown(KeyEvent(scancode: Scancode.space,
                              keycode: 0,
                              modifiers: [],
                              isRepeat: false)),
        ])
        _ = runtime.tick(deltaTime: 0.1, inputEvents: [.windowMinimized])

        let state = try #require(runtime.resource(InputFrameState.self))
        #expect(!state.isHeld("jump"))
        #expect(state.isJustReleased("jump"))
    }
}
