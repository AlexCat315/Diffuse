import SceneRuntime

/// Shared state for the C ABI bridge.
///
/// Scripts compiled out-of-process cannot import `ScriptRuntime` directly, so
/// the engine re-exports the operations they need as plain C functions. Each
/// C function reads the "current" script context from the process-global slot
/// defined here. `ScriptRuntime` sets the slot immediately before invoking a
/// script callback and clears it immediately after.
///
/// Bridge functions are organised into separate files by feature area
/// (`ScriptCBridgeInput.swift`, `ScriptCBridgeCharacter.swift`, ...). All of
/// them rely on the slot declared here.

/// The script context for the callback currently executing on this thread.
/// Script execution is single-threaded, so no locking is required.
nonisolated(unsafe) var _guavaCurrentScriptContext: ScriptContext?

/// Sets the context that C bridge functions will operate on.
/// `ScriptRuntime` calls this before invoking a script callback and passes
/// `nil` afterwards so stray calls from background threads fail safely.
@_spi(ScriptCBridge)
public func guavaSetCurrentScriptContext(_ context: ScriptContext?) {
    _guavaCurrentScriptContext = context
}
