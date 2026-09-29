/// Source emitted for scripts created from the panel.
///
/// Mirrors the documented `GameScript: ScriptBehavior` contract
/// (`docs/project-scripting.md`): one type per file, discovered by the runtime
/// through its C ABI entry point.
enum ScriptTemplate {
    static let `default` = #"""
import ScriptRuntime

struct GameScript: ScriptBehavior {
    mutating func onStart(_ context: ScriptContext) {
        // Runs once when this script is attached to an entity.
    }

    mutating func onUpdate(_ context: ScriptContext) {
        // Runs once per frame. Delta time is measured in seconds.
        _ = context.deltaTime
    }
}
"""#
}
