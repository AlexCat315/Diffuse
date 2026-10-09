/// Source emitted for scripts created from the panel.
///
/// Mirrors the documented `GameScript: ScriptBehavior` contract
/// (`docs/project-scripting.md`): one type per file, discovered by the runtime
/// through its C ABI entry point.
enum ScriptTemplate {
    static let `default` = #"""
import ScriptRuntime

struct GameScript: ScriptBehavior, ScriptAuthoring {
    static var definition: ScriptDefinition {
        ScriptDefinition(properties: [
            ScriptProperty("speed", label: "Speed", defaultValue: .number(1), minimum: 0),
        ])
    }

    mutating func onStart(_ context: ScriptContext) {
        // Runs once when this script is attached to an entity.
    }

    mutating func onUpdate(_ context: ScriptContext) {
        // Runs once per frame. Delta time is measured in seconds.
        let speed = context.floatParameter("speed") ?? 1
        _ = speed * Float(context.deltaTime)
    }
}
"""#
}
