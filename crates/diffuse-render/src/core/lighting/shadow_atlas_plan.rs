//! The packed shadow-atlas result for one frame.
//!
//! Ported from `Engine/Sources/RenderBackend/Core/Lighting/ShadowAtlasPlan.swift`.

use std::collections::BTreeMap;

use diffuse_math::simd::simd_compat::Float4x4;

use super::uniforms::{ShadowLightBinding, ShadowUniforms};

/// One shadow-casting light's tile assignment in the atlas.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ShadowAtlasLight {
    pub scene_light_index: usize,
    pub slot: usize,
    pub cascade_index: usize,
    pub tile_x: u32,
    pub tile_y: u32,
    pub light_view_projection: Float4x4,
}

/// The atlas layout plus the uniforms derived from it.
#[derive(Clone, Debug, PartialEq)]
pub struct ShadowAtlasPlan {
    pub uniforms: ShadowUniforms,
    pub lights: Vec<ShadowAtlasLight>,
    pub tile_size: u32,
    pub atlas_size: u32,
    pub grid_dimension: u32,
    pub cascade_count: usize,
}

impl ShadowAtlasPlan {
    pub fn new(
        uniforms: ShadowUniforms,
        lights: Vec<ShadowAtlasLight>,
        tile_size: u32,
        atlas_size: u32,
        grid_dimension: u32,
        cascade_count: usize,
    ) -> Self {
        ShadowAtlasPlan {
            uniforms,
            lights,
            tile_size,
            atlas_size,
            grid_dimension,
            cascade_count,
        }
    }

    pub fn shadow_tile_count(&self) -> usize {
        self.lights.len()
    }

    pub fn shadowed_light_count(&self) -> usize {
        self.shadow_bindings_by_light_index().len()
    }

    /// `shadowBindingsByLightIndex` — one binding per scene light, keeping the
    /// smallest base slot and the largest cascade count seen for it.
    pub fn shadow_bindings_by_light_index(&self) -> BTreeMap<usize, ShadowLightBinding> {
        let mut partial: BTreeMap<usize, ShadowLightBinding> = BTreeMap::new();
        for light in &self.lights {
            let existing = partial.get(&light.scene_light_index);
            let base_slot = match existing {
                Some(binding) => binding.base_slot.min(light.slot),
                None => light.slot,
            };
            let cascade_count = match existing {
                Some(binding) => binding.cascade_count.max(light.cascade_index + 1),
                None => light.cascade_index + 1,
            };
            partial.insert(
                light.scene_light_index,
                ShadowLightBinding::new(base_slot, cascade_count),
            );
        }
        partial
    }
}
