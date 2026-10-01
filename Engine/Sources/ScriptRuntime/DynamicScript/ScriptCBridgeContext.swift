import Foundation

/// Shared state for the C ABI bridge.
///
/// C functions read the current callback's context from a thread-local slot.
/// Independent scenes may execute concurrently; a process-global Swift reference
/// would both mix their contexts and race its reference counting.
///
/// Bridge functions are organised into separate files by feature area
/// (`ScriptCBridgeInput.swift`, `ScriptCBridgeCharacter.swift`, ...). All of
/// them rely on the slot declared here.

/// The script context for the callback currently executing on this thread.
private let scriptContextThreadKey = "com.guava.script-runtime.current-context"

var _guavaCurrentScriptContext: ScriptContext? {
    Thread.current.threadDictionary[scriptContextThreadKey] as? ScriptContext
}

/// Sets the context that C bridge functions will operate on.
/// `ScriptRuntime` calls this before invoking a script callback and passes
/// `nil` afterwards so stray calls from background threads fail safely.
@_spi(ScriptCBridge)
public func guavaSetCurrentScriptContext(_ context: ScriptContext?) {
    if let context {
        Thread.current.threadDictionary[scriptContextThreadKey] = context
    } else {
        Thread.current.threadDictionary.removeObject(forKey: scriptContextThreadKey)
    }
}
