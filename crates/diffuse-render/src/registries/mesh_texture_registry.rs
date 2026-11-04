//! Process-wide decoded texture cache for imported mesh assets. RenderBackend
//! fills this beside mesh/material registration so later GPU upload paths can
//! build texture resources without reaching back into AssetRegistry.

use std::collections::HashMap;
use std::sync::{Mutex, MutexGuard, OnceLock};

use diffuse_assets::asset_pipeline::MeshAsset;
use diffuse_assets::import::image_asset_decoder::DecodedTextureAsset;
use diffuse_assets::import::mesh_texture_resolver::MeshTextureResolver;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MeshDecodedTexture {
    pub texture_index: usize,
    pub source_path: String,
    pub texture: DecodedTextureAsset,
}

impl MeshDecodedTexture {
    pub fn new(texture_index: usize, source_path: String, texture: DecodedTextureAsset) -> Self {
        MeshDecodedTexture {
            texture_index,
            source_path,
            texture,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MeshTextureDecodeFailure {
    pub texture_index: usize,
    pub source_uri: Option<String>,
    pub reason: String,
}

impl MeshTextureDecodeFailure {
    pub fn new(texture_index: usize, source_uri: Option<String>, reason: String) -> Self {
        MeshTextureDecodeFailure {
            texture_index,
            source_uri,
            reason,
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct MeshTextureRegistrationReport {
    pub decoded_textures: Vec<MeshDecodedTexture>,
    pub failures: Vec<MeshTextureDecodeFailure>,
}

impl MeshTextureRegistrationReport {
    pub fn new(
        decoded_textures: Vec<MeshDecodedTexture>,
        failures: Vec<MeshTextureDecodeFailure>,
    ) -> Self {
        MeshTextureRegistrationReport {
            decoded_textures,
            failures,
        }
    }
}

pub struct MeshTextureRegistry {
    lock: Mutex<HashMap<i64, MeshTextureRegistrationReport>>,
}

impl MeshTextureRegistry {
    fn new() -> Self {
        MeshTextureRegistry {
            lock: Mutex::new(HashMap::new()),
        }
    }

    /// Swift's `MeshTextureRegistry.shared`.
    pub fn shared() -> &'static Self {
        static SHARED: OnceLock<MeshTextureRegistry> = OnceLock::new();
        SHARED.get_or_init(Self::new)
    }

    fn lock(&self) -> MutexGuard<'_, HashMap<i64, MeshTextureRegistrationReport>> {
        self.lock
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    pub fn register(
        mesh_index: i64,
        mesh: &MeshAsset,
        source_directory: Option<&str>,
    ) -> MeshTextureRegistrationReport {
        let mut decoded_textures: Vec<MeshDecodedTexture> = Vec::new();
        let mut failures: Vec<MeshTextureDecodeFailure> = Vec::new();
        for (texture_index, texture) in mesh.textures.iter().enumerate() {
            match MeshTextureResolver::decode(texture, source_directory) {
                Ok(resolved) => decoded_textures.push(MeshDecodedTexture::new(
                    texture_index,
                    resolved.path,
                    resolved.texture,
                )),
                Err(error) => failures.push(MeshTextureDecodeFailure::new(
                    texture_index,
                    texture.source_uri.clone(),
                    error.to_string(),
                )),
            }
        }

        let report = MeshTextureRegistrationReport::new(decoded_textures, failures);
        let mut guard = Self::shared().lock();
        guard.insert(mesh_index, report.clone());
        report
    }

    pub fn textures(mesh_index: i64) -> Option<MeshTextureRegistrationReport> {
        let guard = Self::shared().lock();
        guard.get(&mesh_index).cloned()
    }

    pub fn clear_all() {
        let mut guard = Self::shared().lock();
        guard.clear();
    }
}
