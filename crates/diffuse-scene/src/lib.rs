//! Crate root. See MIGRATION.md §5.
pub mod components;
pub mod entity_id;
pub mod input_action;
pub mod media;
pub mod particles;
pub mod physics;
pub mod rendering;
pub mod runtime_world;
pub mod scene_bootstrap;
pub mod scene_graph;
pub mod scene_runtime;
pub mod scheduling;
pub mod scripting;
pub mod serialization;
#[cfg(test)]
mod tests;
