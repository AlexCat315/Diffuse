import SceneRuntime

/// C ABI functions for timing information.

/// Returns the delta time (seconds) for the current frame.
@_cdecl("cove_delta_time")
public func coveDeltaTime() -> Float {
    guard let ctx = _coveCurrentScriptContext else { return 0 }
    return Float(ctx.deltaTime)
}
