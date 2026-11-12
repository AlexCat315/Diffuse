//! Translation of Editor/Sources/EditorUI/Panels/ScriptEditor/Template.swift.
//!
//! Source emitted for scripts created from the Files tree or a Swift tab.
//! Mirrors the documented `GameScript: ScriptBehavior` contract: one type per
//! file, discovered by the runtime through its C ABI entry point.
//!
//! The template still emits Swift because user scripts remain Swift sources in
//! the current authoring flow; only the editor host moved to Rust.

pub struct ScriptTemplate;

impl ScriptTemplate {
    pub const DEFAULT: &'static str = r#"import ScriptRuntime

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
"#;

    /// Swift's `` static let `default` ``.
    pub fn default_template() -> &'static str {
        Self::DEFAULT
    }
}
