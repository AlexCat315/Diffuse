//! GPU-side particle render data: instance layout, draw args and culling
//! uniforms.
//!
//! Ported from `Engine/Sources/RenderBackend/Core/Particles/ParticleGPUData.swift`.
//! Layouts match `ParticleInstance` in `particle_common.slang`,
//! `ParticleCullUniforms`/`ParticleCullBatch` in `particle_cull_compact.slang`
//! and `ParticleUniforms` in `particles.slang`.

use diffuse_math::simd::simd_compat::{Float4, Float4x4, UInt4};
use diffuse_scene::rendering::render_scene::RenderParticle;

/// GPU mirror of `RenderParticle`. `position_size` packs world position (xyz) and
/// size (w); layout matches `ParticleInstance` in `particles.wgsl`.
#[repr(C, align(16))]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GPUParticleInstance {
    pub position_size: Float4,
    /// x: billboard rotation, y: `RenderParticleShape.rawValue`,
    /// z/w: ribbon V offset/scale.
    pub rotation: Float4,
    pub color: Float4,
    pub uv_rect: Float4,
    pub axis_stretch: Float4,
    pub ribbon_color: Float4,
    /// x/y: ribbon start/end width. z/w reserved.
    pub ribbon_params: Float4,
}

// MIGRATION.md §5.3: the bytes uploaded to the GPU must not change.
const _: () = assert!(core::mem::size_of::<GPUParticleInstance>() == 112);
const _: () = assert!(core::mem::align_of::<GPUParticleInstance>() == 16);

impl GPUParticleInstance {
    pub fn is_finite(&self) -> bool {
        Self::finite(self.position_size)
            && Self::finite(self.rotation)
            && Self::finite(self.color)
            && Self::finite(self.uv_rect)
            && Self::finite(self.axis_stretch)
            && Self::finite(self.ribbon_color)
            && Self::finite(self.ribbon_params)
    }

    fn finite(value: Float4) -> bool {
        value.x.is_finite() && value.y.is_finite() && value.z.is_finite() && value.w.is_finite()
    }

    /// `init(particle:)`.
    pub fn from_particle(particle: &RenderParticle) -> Self {
        GPUParticleInstance {
            position_size: Float4::new(
                particle.position.x,
                particle.position.y,
                particle.position.z,
                particle.size,
            ),
            rotation: Float4::new(
                particle.rotation,
                particle.shape.raw_value() as f32,
                particle.texture_v_offset,
                particle.texture_v_scale,
            ),
            color: particle.color,
            uv_rect: particle.uv_rect,
            axis_stretch: Float4::new(
                particle.alignment_axis.x,
                particle.alignment_axis.y,
                particle.alignment_axis.z,
                particle.stretch,
            ),
            ribbon_color: particle.end_color,
            ribbon_params: Float4::new(particle.start_size, particle.end_size, 0.0, 0.0),
        }
    }
}

/// Non-indexed indirect draw arguments. Layout matches native and WebGPU's
/// DrawIndirectArgs: vertexCount, instanceCount, firstVertex, firstInstance.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GPUParticleIndirectDrawArgs {
    pub vertex_count: u32,
    pub instance_count: u32,
    pub first_vertex: u32,
    pub first_instance: u32,
}

impl GPUParticleIndirectDrawArgs {
    pub fn new(
        vertex_count: u32,
        instance_count: u32,
        first_vertex: u32,
        first_instance: u32,
    ) -> Self {
        GPUParticleIndirectDrawArgs {
            vertex_count,
            instance_count,
            first_vertex,
            first_instance,
        }
    }
}

// MIGRATION.md §5.3: the bytes uploaded to the GPU must not change.
const _: () = assert!(core::mem::size_of::<GPUParticleIndirectDrawArgs>() == 16);
const _: () = assert!(core::mem::align_of::<GPUParticleIndirectDrawArgs>() == 4);

/// Uniforms for GPU particle culling and compaction; matches
/// `ParticleCullUniforms` in `particle_cull_compact.slang`.
#[repr(C, align(16))]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GPUParticleCullUniforms {
    pub view_proj: Float4x4,
    /// x: batch count.
    pub params: UInt4,
}

impl GPUParticleCullUniforms {
    pub fn new(view_proj: Float4x4, params: UInt4) -> Self {
        GPUParticleCullUniforms { view_proj, params }
    }
}

// MIGRATION.md §5.3: the bytes uploaded to the GPU must not change.
const _: () = assert!(core::mem::size_of::<GPUParticleCullUniforms>() == 80);
const _: () = assert!(core::mem::align_of::<GPUParticleCullUniforms>() == 16);

/// Per-render-batch source and destination ranges for GPU culling. The culling
/// shader preserves order inside each batch by compacting visible instances
/// into the range beginning at `output_start`; matches `ParticleCullBatch` in
/// `particle_cull_compact.slang`.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GPUParticleCullBatch {
    pub source_start: u32,
    pub source_count: u32,
    pub output_start: u32,
    pub _padding: u32,
}

impl GPUParticleCullBatch {
    /// Swift's memberwise init; `_padding` defaults to 0.
    pub fn new(source_start: u32, source_count: u32, output_start: u32) -> Self {
        GPUParticleCullBatch {
            source_start,
            source_count,
            output_start,
            _padding: 0,
        }
    }
}

// MIGRATION.md §5.3: the bytes uploaded to the GPU must not change.
const _: () = assert!(core::mem::size_of::<GPUParticleCullBatch>() == 16);
const _: () = assert!(core::mem::align_of::<GPUParticleCullBatch>() == 4);

/// Per-frame billboard uniforms; matches `ParticleUniforms` in
/// `particles.slang`.
#[repr(C, align(16))]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ParticleUniforms {
    pub view_proj: Float4x4,
    pub camera_right: Float4,
    pub camera_up: Float4,
    pub camera_forward: Float4,
}

impl ParticleUniforms {
    pub fn new(
        view_proj: Float4x4,
        camera_right: Float4,
        camera_up: Float4,
        camera_forward: Float4,
    ) -> Self {
        ParticleUniforms {
            view_proj,
            camera_right,
            camera_up,
            camera_forward,
        }
    }
}

// MIGRATION.md §5.3: the bytes uploaded to the GPU must not change.
const _: () = assert!(core::mem::size_of::<ParticleUniforms>() == 112);
const _: () = assert!(core::mem::align_of::<ParticleUniforms>() == 16);
