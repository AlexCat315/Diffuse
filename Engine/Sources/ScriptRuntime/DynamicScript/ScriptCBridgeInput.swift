import SceneRuntime

/// C ABI functions for reading per-frame input state.

/// Returns the axis value for the given input action, or `0` when no context
/// is active.
@_cdecl("guava_input_axis")
public func guavaInputAxis(_ name: UnsafePointer<CChar>) -> Float {
    guard let ctx = _guavaCurrentScriptContext else { return 0 }
    return ctx.input.axis(String(cString: name))
}

/// Returns whether the given input action is currently held.
@_cdecl("guava_input_held")
public func guavaInputHeld(_ name: UnsafePointer<CChar>) -> Bool {
    guard let ctx = _guavaCurrentScriptContext else { return false }
    return ctx.input.isHeld(String(cString: name))
}

/// Returns whether the given input action was pressed this frame (leading edge).
@_cdecl("guava_input_just_pressed")
public func guavaInputJustPressed(_ name: UnsafePointer<CChar>) -> Bool {
    guard let ctx = _guavaCurrentScriptContext else { return false }
    return ctx.input.isJustPressed(String(cString: name))
}

/// Returns whether the given input action was released this frame (trailing edge).
@_cdecl("guava_input_just_released")
public func guavaInputJustReleased(_ name: UnsafePointer<CChar>) -> Bool {
    guard let ctx = _guavaCurrentScriptContext else { return false }
    return ctx.input.isJustReleased(String(cString: name))
}
