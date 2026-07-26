import SceneRuntime

public extension InputActionMap {
    /// Standard bindings used by Guava's built-in character and camera scripts.
    /// Projects may replace the resource with their own map at any time.
    static var guavaDefault: InputActionMap {
        var map = InputActionMap()

        map.bind("move_forward", to: .key(Scancode.w))
        map.bind("move_forward", to: .key(Scancode.up))
        map.bind("move_forward", to: .gamepadButton(.dpadUp))
        map.bind("move_back", to: .key(Scancode.s))
        map.bind("move_back", to: .key(Scancode.down))
        map.bind("move_back", to: .gamepadButton(.dpadDown))
        map.bind("move_left", to: .key(Scancode.a))
        map.bind("move_left", to: .key(Scancode.left))
        map.bind("move_left", to: .gamepadButton(.dpadLeft))
        map.bind("move_right", to: .key(Scancode.d))
        map.bind("move_right", to: .key(Scancode.right))
        map.bind("move_right", to: .gamepadButton(.dpadRight))
        map.bind("move_up", to: .key(Scancode.e))
        map.bind("move_down", to: .key(Scancode.q))
        map.bind("move_x", to: .keyAxis(negative: Scancode.a, positive: Scancode.d))
        map.bind("move_y", to: .keyAxis(negative: Scancode.s, positive: Scancode.w))

        map.bind("jump", to: .key(Scancode.space))
        map.bind("jump", to: .gamepadButton(.south))
        map.bind("crouch", to: .key(Scancode.lctrl))
        map.bind("crouch", to: .gamepadButton(.east))

        map.bind("look_x", to: .mouseMotion(axis: .x, requiredButton: .right))
        map.bind("look_y", to: .mouseMotion(axis: .y, requiredButton: .right))
        map.bind("look_x", to: .gamepadAxis(.rightX))
        map.bind("look_y", to: .gamepadAxis(.rightY))
        map.bind("orbit_x", to: .mouseMotion(axis: .x, requiredButton: .right))
        map.bind("orbit_y", to: .mouseMotion(axis: .y, requiredButton: .right))
        map.bind("orbit_x", to: .gamepadAxis(.rightX))
        map.bind("orbit_y", to: .gamepadAxis(.rightY))
        map.bind("camera_zoom", to: .mouseWheel(axis: .y))
        return map
    }
}
