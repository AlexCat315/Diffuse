//! Crate root. See MIGRATION.md §5.
pub mod controllers;
pub mod core;
pub mod dynamic_script;
pub mod input;
pub mod interop;
pub mod presets;
#[cfg(test)]
pub mod tests;

pub use controllers::animation_runtime::AnimationRuntime;
pub use controllers::character_input_controller::{CharacterLandEvent, CharacterLeaveGroundEvent};
pub use core::script_behavior::{ScriptAuthoring, ScriptBehavior};
pub use core::script_component::{ScriptBinding, ScriptBindingID, ScriptComponent, ScriptHandle};
pub use core::script_context::ScriptContext;
pub use core::script_definition::{
    ScriptDefinition, ScriptParameterIssue, ScriptProperty, ScriptPropertyOption,
    ScriptPropertyValue,
};
pub use core::script_lifecycle::{Script, ScriptCallback};
pub use core::script_runtime::ScriptRuntime;
pub use dynamic_script::script_c_bridge_context::{
    ScriptBridgeError, ScriptErrorState, ScriptResourceRegistry,
};
pub use dynamic_script::script_compiler::{
    CompilationResult, ScriptCompilationCancellationToken, ScriptCompileError, ScriptCompiler,
    ScriptCompilerDiagnostic,
};
pub use input::default_input_actions::DefaultInputActions;
pub use interop::component_registry_script_codec::{
    ComponentRegistryScriptCodec, ScriptAuthoringDefaults,
};
pub use interop::scene_serializer_script_support::{
    PrefabScriptSupport, SceneSerializerScriptSupport,
};
pub use interop::script_debug_state::ScriptDebugState;
pub use presets::{script_preset_catalog::ScriptPresetKind, script_presets::ScriptVar};
