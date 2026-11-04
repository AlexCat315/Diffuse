//! Resident particle images, including retryable decode failures and a white
//! fallback.

use std::sync::Arc;

use std::collections::{BTreeMap, BTreeSet};

use cove_graphics::rhi::{
    Device, RhiResult, Sampler, SamplerAddressMode, SamplerDescriptor, SamplerFilter,
    SamplerMipFilter, Texture,
};
use cove_logging::{Level, LogEvent};
use diffuse_assets::import::image_asset_decoder::{DecodedTextureAsset, ImageAssetDecoder};

use crate::native::mesh::native_mesh_store::NativeMeshStore;
use crate::support::log;

pub struct NativeParticleTextures {
    device: Arc<Device>,
    pub sampler: Sampler,
    fallback: Texture,
    images: BTreeMap<String, Texture>,
    failures: BTreeSet<String>,
}

impl NativeParticleTextures {
    pub fn new(device: &Arc<Device>) -> RhiResult<Self> {
        let sampler = device.make_sampler(SamplerDescriptor {
            min_filter: SamplerFilter::Linear,
            mag_filter: SamplerFilter::Linear,
            mip_filter: SamplerMipFilter::Nearest,
            address_mode_u: SamplerAddressMode::ClampToEdge,
            address_mode_v: SamplerAddressMode::ClampToEdge,
            ..SamplerDescriptor::default()
        })?;
        let fallback = match NativeMeshStore::texture(
            device,
            &DecodedTextureAsset::new(vec![255, 255, 255, 255], 1, 1),
        ) {
            Ok(fallback) => fallback,
            Err(error) => {
                device.destroy_sampler(sampler);
                return Err(error);
            }
        };
        Ok(NativeParticleTextures {
            device: device.clone(),
            sampler,
            fallback,
            images: BTreeMap::new(),
            failures: BTreeSet::new(),
        })
    }

    /// Swift's `deinit` destroys every resident texture and the sampler.
    pub fn destroy(&self) {
        for texture in self.images.values() {
            self.device.destroy_texture(*texture);
        }
        self.device.destroy_texture(self.fallback);
        self.device.destroy_sampler(self.sampler);
    }

    pub fn texture(&mut self, path: Option<&str>) -> Texture {
        let Some(path) = path else {
            return self.fallback;
        };
        if let Some(existing) = self.images.get(path) {
            return *existing;
        }
        match ImageAssetDecoder::decode_rgba8_path(path)
            .map_err(|error| cove_graphics::rhi::RhiError::invalid_argument(error.to_string()))
            .and_then(|image| NativeMeshStore::texture(&self.device, &image))
        {
            Ok(result) => {
                self.images.insert(path.to_owned(), result);
                self.failures.remove(path);
                result
            }
            Err(error) => {
                if self.failures.insert(path.to_owned()) {
                    log::renderer().log(&LogEvent::new(
                        Level::Warning,
                        format!("particle texture decode failed: source={path} reason={error}"),
                    ));
                }
                self.fallback
            }
        }
    }
}
