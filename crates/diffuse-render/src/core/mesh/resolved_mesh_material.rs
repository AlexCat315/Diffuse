//! Imported material values combined with runtime overrides.
//!
//! Ported from
//! `Engine/Sources/RenderBackend/Core/Mesh/ResolvedMeshMaterial.swift`.

use diffuse_assets::asset_pipeline::MeshMaterial;
use diffuse_math::simd::simd_compat::Float4;
use diffuse_scene::rendering::render_scene::{MaterialAlphaMode, RenderMaterial};

/// Imported primitive values combined with runtime overrides. Both renderers
/// use this resolution so texture and coverage rules stay consistent.
#[derive(Clone, Debug, PartialEq)]
pub struct ResolvedMeshMaterial {
    pub color: Float4,
    pub alpha_mode: MaterialAlphaMode,
    pub cutoff: f32,
    pub double_sided: bool,
    pub base_texture: Option<i64>,
    pub normal_texture: Option<i64>,
    pub mr_texture: Option<i64>,
}

impl ResolvedMeshMaterial {
    pub fn new(imported: &MeshMaterial, runtime: &RenderMaterial) -> Self {
        ResolvedMeshMaterial {
            color: imported.base_color_factor * runtime.base_color_factor,
            alpha_mode: runtime.alpha_mode.unwrap_or(imported.alpha_mode),
            cutoff: runtime.alpha_cutoff.unwrap_or(imported.alpha_cutoff),
            double_sided: runtime.double_sided.unwrap_or(imported.double_sided),
            base_texture: runtime
                .base_color_texture_index
                .or(imported.base_color_texture_index),
            normal_texture: runtime
                .normal_texture_index
                .or(imported.normal_texture_index),
            mr_texture: imported.metallic_roughness_texture_index,
        }
    }
}
