//! The per-instance mesh uniform block.
//!
//! Ported from
//! `Engine/Sources/RenderBackend/Core/Mesh/MeshInstanceUniforms.swift`.
//! Matches `MeshInstanceUniforms` in `mesh_common.slang`: two column-major
//! matrices plus two float4s (160 bytes, 16-aligned).

use diffuse_math::simd::simd_compat::{Float4, Float4x4};

/// Shared 160-byte GPU instance ABI for native and WGSL mesh passes.
#[repr(C, align(16))]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct MeshInstanceUniforms {
    pub mvp: Float4x4,
    pub model: Float4x4,
    pub color_tint: Float4,
    pub material: Float4,
}

impl MeshInstanceUniforms {
    /// Swift's memberwise init; `material` defaults to `.zero`.
    pub fn new(mvp: Float4x4, model: Float4x4, color_tint: Float4) -> Self {
        MeshInstanceUniforms {
            mvp,
            model,
            color_tint,
            material: Float4::ZERO,
        }
    }

    /// The full memberwise initializer with the `material` argument supplied.
    pub fn with_material(
        mvp: Float4x4,
        model: Float4x4,
        color_tint: Float4,
        material: Float4,
    ) -> Self {
        MeshInstanceUniforms {
            mvp,
            model,
            color_tint,
            material,
        }
    }
}

// MIGRATION.md §5.3: the bytes uploaded to the GPU must not change.
const _: () = assert!(core::mem::size_of::<MeshInstanceUniforms>() == 160);
const _: () = assert!(core::mem::align_of::<MeshInstanceUniforms>() == 16);
