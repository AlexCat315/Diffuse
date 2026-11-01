//! Crate root. See MIGRATION.md §5.
pub mod controllers;
pub mod core;
pub mod dynamic_script;
pub mod input;
pub mod interop;
pub mod presets;
#[cfg(test)]
pub mod tests;

pub use core::script_component::{ScriptBinding, ScriptBindingID, ScriptComponent, ScriptHandle};
pub use interop::component_registry_script_codec::{
    ComponentRegistryScriptCodec, ScriptAuthoringDefaults,
};
