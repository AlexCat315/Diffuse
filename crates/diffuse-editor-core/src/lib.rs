//! Crate root. See MIGRATION.md §5.
pub mod editor_core_resource_bundle;
pub mod localization;
pub mod ai;
pub mod application;
pub mod assets;
pub mod bridge;
pub mod contributions;
pub mod diagnostics;
pub mod editing;
pub mod geometry;
pub mod input;
pub mod projects;
pub mod rendering;
pub mod scene;
pub mod scripting;
pub mod state;
pub mod tasks;
#[cfg(test)]
pub mod tests;
pub mod version_control;
pub mod workstation;
