//! Shared production tuning and binary uniform groups for both renderers.
//!
//! Ported from
//! `Engine/Sources/RenderBackend/Core/Lighting/PostEffectUniforms.swift`. The
//! uniform types live in `core::frame::render_uniforms` (already translated);
//! this module only builds them.

use diffuse_math::simd::simd_compat::{Float4, Float4x4, simd_inverse};

use super::super::frame::render_uniforms::{
    BloomUniforms, PostFrameUniforms, SsaoUniforms, SsrUniforms, TaaUniforms,
};
use crate::core::frame::render_packet::RenderDrawableSize;

pub enum PostEffectUniforms {}

impl PostEffectUniforms {
    pub fn frame(used: RenderDrawableSize, capacity: RenderDrawableSize) -> PostFrameUniforms {
        let width = capacity.width.max(1) as f32;
        let height = capacity.height.max(1) as f32;
        PostFrameUniforms {
            uv_scale_max: Float4::new(
                used.width as f32 / width,
                used.height as f32 / height,
                (used.width as f32 - 0.5).max(0.5) / width,
                (used.height as f32 - 0.5).max(0.5) / height,
            ),
        }
    }

    pub fn ssao(projection: Float4x4, size: RenderDrawableSize) -> SsaoUniforms {
        SsaoUniforms {
            projection,
            inv_projection: simd_inverse(projection),
            resolution_radius: Float4::new(size.width as f32, size.height as f32, 0.45, 0.0),
            tuning: Float4::new(0.025, 0.7, 1.35, 0.0),
        }
    }

    pub fn ssr(projection: Float4x4, size: RenderDrawableSize) -> SsrUniforms {
        SsrUniforms {
            projection,
            inv_projection: simd_inverse(projection),
            resolution_intensity: Float4::new(size.width as f32, size.height as f32, 0.22, 0.0),
            tracing: Float4::new(14.0, 32.0, 0.18, 0.08),
        }
    }

    pub fn taa(size: RenderDrawableSize, history_valid: bool) -> TaaUniforms {
        TaaUniforms {
            params: Float4::new(
                0.12,
                1.0 / size.width.max(1) as f32,
                1.0 / size.height.max(1) as f32,
                if history_valid { 1.0 } else { 0.0 },
            ),
        }
    }

    pub fn bloom(size: RenderDrawableSize) -> BloomUniforms {
        BloomUniforms {
            params: Float4::new(
                1.05,
                0.75,
                1.0 / size.width.max(1) as f32,
                1.0 / size.height.max(1) as f32,
            ),
        }
    }
}
