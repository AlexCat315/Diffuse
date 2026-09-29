import SceneRuntime

/// C ABI functions for timing information.

/// Returns the delta time (seconds) for the current frame.
@_cdecl("guava_delta_time")
public func guavaDeltaTime() -> Float {
    guard let ctx = _guavaCurrentScriptContext else { return 0 }
    return Float(ctx.deltaTime)
}
