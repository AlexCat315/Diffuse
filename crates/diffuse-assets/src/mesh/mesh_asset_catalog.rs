//! A coherent mesh snapshot for GPU resource consumers, separate from authored
//! assets.
//!
//! Ported from `Engine/Sources/AssetPipeline/Mesh/MeshAssetCatalog.swift`.

use crate::asset_registry::RegisteredMeshAsset;

#[derive(Clone, Debug, PartialEq)]
pub struct MeshAssetCatalog {
    pub revision: u64,
    pub meshes: Vec<RegisteredMeshAsset>,
}

impl MeshAssetCatalog {
    pub fn new(revision: u64, meshes: Vec<RegisteredMeshAsset>) -> Self {
        MeshAssetCatalog { revision, meshes }
    }
}
