//! User-script C ABI surface.
//!
//! MIGRATION.md §4 D1: user scripts are Rust cdylibs that reach the engine only
//! through [`abi::HostApi`]. This crate is std-only so it is the single
//! dependency a script crate needs.

pub mod abi;
pub mod authoring;
pub mod context;
pub mod export;

pub use abi::{
    ABI_VERSION, Bytes, CharacterStance, Color4, GroundState, HostApi, Slice, Transform3,
};
pub use authoring::{
    ScriptAuthoring, ScriptBehavior, ScriptDefinition, ScriptDefinitionBuilder, ScriptParameters,
    ScriptProperty, ScriptPropertyOption, ScriptPropertyValue,
};
pub use context::ScriptContext;
pub use export::{CatalogEntry, ScriptInstance, ScriptInstanceApi};

/// Re-exported so the [`diffuse_scripts!`] macro can name the trait through the
/// crate path.
pub use authoring::ScriptAuthoring as ScriptDefinitionSource;
