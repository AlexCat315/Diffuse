//! Crate root. See MIGRATION.md §5.
pub mod asset_pipeline;
pub mod asset_registry;
pub mod geometry;
pub mod import;
pub mod mesh;
pub mod project_resource_walker;
pub mod swift_json;

pub use asset_pipeline::AssetPipeline;
pub use mesh::destructible_asset_baker::{
    DestructibleAssetBakeError, DestructibleAssetBakeResult, DestructibleAssetBaker,
    PrefracturedFragmentInput,
};
