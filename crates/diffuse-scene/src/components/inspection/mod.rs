//! Component inspection metadata.
//!
//! `inspection` shadows its parent's name because `Docs/rust-migration-files.json`
//! maps `Components/Inspection/Inspection.swift` to exactly this path and §5.1
//! forbids inventing a different one. The `module_inception` allow is scoped to the
//! declaration for that reason.

pub mod animation;
pub mod builtin_inspection;
pub mod physics;
pub mod rendering;

#[allow(clippy::module_inception)]
pub mod inspection;
