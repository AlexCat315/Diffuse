//! GPU uniform blocks shared by the native render passes.
//!
//! MIGRATION.md §5.3: these structs are uploaded verbatim, so their layout must
//! match the Swift values exactly. `Float4` is 16 bytes/16-aligned and `Float4x4`
//! is 64 bytes/16-aligned, so every block below is a multiple of 16 with no
//! padding. The compile-time assertions at the end of this file enforce that.

use diffuse_math::simd::simd_compat::{Float4, Float4x4};

/// Sky/background pass uniforms.
#[repr(C, align(16))]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct SkyboxUniforms {
    pub inv_view_proj: Float4x4,
    /// RGB sky colour; `w` selects the neutral orthographic backdrop.
    pub sky_tint: Float4,
    pub horizon_tint: Float4,
    pub ground_tint: Float4,
}

/// Tonemap pass parameters.
#[repr(C, align(16))]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct TonemapUniforms {
    pub params: Float4,
}

/// Bloom pass parameters.
#[repr(C, align(16))]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct BloomUniforms {
    pub params: Float4,
}

/// TAA pass parameters.
#[repr(C, align(16))]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct TaaUniforms {
    pub params: Float4,
}

/// SSAO pass uniforms.
#[repr(C, align(16))]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct SsaoUniforms {
    pub projection: Float4x4,
    pub inv_projection: Float4x4,
    pub resolution_radius: Float4,
    pub tuning: Float4,
}

/// SSR pass uniforms.
#[repr(C, align(16))]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct SsrUniforms {
    pub projection: Float4x4,
    pub inv_projection: Float4x4,
    pub resolution_intensity: Float4,
    pub tracing: Float4,
}

/// Stylized-character pass uniforms.
#[repr(C, align(16))]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct StylizedCharacterUniforms {
    pub toon_thresholds: Float4,
    pub toon_levels: Float4,
    pub ink_wash_color: Float4,
    pub params: Float4,
}

impl StylizedCharacterUniforms {
    /// `init(style:)` — packs the four scalar strengths into `params` in Swift's
    /// order.
    pub fn from_style(style: &crate::core::render_settings::StylizedCharacterStyle) -> Self {
        StylizedCharacterUniforms {
            toon_thresholds: style.toon_thresholds,
            toon_levels: style.toon_levels,
            ink_wash_color: style.ink_wash_color,
            params: Float4::new(
                style.paper_grain_strength,
                style.rim_strength,
                style.material_bias_strength,
                style.outline_width,
            ),
        }
    }
}

/// Shared per-frame uniforms for fullscreen post passes.
///
/// Targets are allocated grow-only, so the rendered image occupies the
/// `uv_scale` sub-region of each texture; `uv_max` is the half-texel-inset clamp
/// bound neighbour taps must not exceed.
#[repr(C, align(16))]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct PostFrameUniforms {
    /// `xy` = used / allocated, `zw` = (used - 0.5) / allocated.
    pub uv_scale_max: Float4,
}

// MIGRATION.md §5.3: the bytes uploaded to the GPU must not change.
const _: () = assert!(core::mem::size_of::<SkyboxUniforms>() == 112);
const _: () = assert!(core::mem::align_of::<SkyboxUniforms>() == 16);
const _: () = assert!(core::mem::size_of::<TonemapUniforms>() == 16);
const _: () = assert!(core::mem::size_of::<BloomUniforms>() == 16);
const _: () = assert!(core::mem::size_of::<TaaUniforms>() == 16);
const _: () = assert!(core::mem::size_of::<SsaoUniforms>() == 160);
const _: () = assert!(core::mem::align_of::<SsaoUniforms>() == 16);
const _: () = assert!(core::mem::size_of::<SsrUniforms>() == 160);
const _: () = assert!(core::mem::align_of::<SsrUniforms>() == 16);
const _: () = assert!(core::mem::size_of::<StylizedCharacterUniforms>() == 64);
const _: () = assert!(core::mem::align_of::<StylizedCharacterUniforms>() == 16);
const _: () = assert!(core::mem::size_of::<PostFrameUniforms>() == 16);
