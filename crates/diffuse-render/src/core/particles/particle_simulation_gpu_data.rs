//! Shared binary layouts for the WGSL and Slang simulation programs.
//!
//! Ported from
//! `Engine/Sources/RenderBackend/Core/Particles/ParticleSimulationGPUData.swift`.
//! Layouts match `ParticleSimUniforms` in `particle_simulate.slang` and
//! `ParticleSimState`/`ParticleSimMetadata`/`ParticleSimEvent` in
//! `particle_simulation_common.slang`, plus the spawn/state-maintenance uniform
//! structs in `particle_spawn_append.slang`, `particle_state_clear.slang` and
//! `particle_state_compact.slang`.

use diffuse_math::simd::simd_compat::{
    Float3, Float4, Float4x4, MATRIX_IDENTITY_FLOAT4X4, UInt4, simd_clamp_scalar, simd_inverse,
};
use diffuse_scene::particles::particle_types::{
    Particle, ParticleCollisionMode, ParticleForceMode, ParticleVectorFieldMode,
};
use diffuse_scene::rendering::render_scene::RenderParticleSimulationBatch;

use crate::core::render_stats::{
    GPUParticleSimulationEventRecord, GPUParticleSimulationEventSnapshot,
    GPUParticleSimulationEventTrigger,
};

/// The simulation uniform block; matches `ParticleSimUniforms` in
/// `particle_simulate.slang` (9×16 + 2×64 = 272 bytes, 16-aligned).
#[repr(C, align(16))]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GPUParticleSimulationUniforms {
    /// x: delta time, y: particle count, z: elapsed time, w: event buffer capacity.
    pub time: Float4,
    /// xyz: acceleration.
    pub gravity: Float4,
    /// x: strength, y: scale, z: speed, w: normalized seed phase.
    pub noise: Float4,
    /// xyz: vector-field bias direction, w: strength.
    pub vector_field_direction_strength: Float4,
    /// x: scale, y: scroll speed, z: field mode (0 none, 1 uniform, 2 curl).
    pub vector_field_params: Float4,
    /// xyz: force center, w: force radius. Radius 0 means unbounded.
    pub force_center_radius: Float4,
    /// xyz: force axis, w: force mode (0 none, 1 radial, 2 vortex).
    pub force_axis_mode: Float4,
    /// x: force strength, y: force falloff.
    pub force_params: Float4,
    /// x: collision mode (0 none, 1 local plane, 2 world plane), y: plane y, z: restitution, w: damping.
    pub collision_params: Float4,
    pub collision_to_world: Float4x4,
    pub collision_to_local: Float4x4,
}

impl GPUParticleSimulationUniforms {
    /// `static let maximumExactParticleCount = 1 << 24` — the shared
    /// WGSL/Slang ABI stores dispatch counts in Float32, so counts above this
    /// lose exactness.
    pub const MAXIMUM_EXACT_PARTICLE_COUNT: i64 = 1 << 24;

    /// `isFinite` — every float lane of the struct is finite.
    pub fn is_finite(&self) -> bool {
        let finite4 = |value: Float4| {
            value.x.is_finite() && value.y.is_finite() && value.z.is_finite() && value.w.is_finite()
        };
        finite4(self.time)
            && finite4(self.gravity)
            && finite4(self.noise)
            && finite4(self.vector_field_direction_strength)
            && finite4(self.vector_field_params)
            && finite4(self.force_center_radius)
            && finite4(self.force_axis_mode)
            && finite4(self.force_params)
            && finite4(self.collision_params)
            && self
                .collision_to_world
                .columns
                .iter()
                .all(|column| finite4(*column))
            && self
                .collision_to_local
                .columns
                .iter()
                .all(|column| finite4(*column))
    }

    /// `init(batch:deltaTime:elapsedTime:dispatchCount:eventCapacity:)`.
    pub fn from_batch(
        batch: &RenderParticleSimulationBatch,
        delta_time: f32,
        elapsed_time: f32,
        dispatch_count: i64,
        event_capacity: i64,
    ) -> Self {
        let field: f32 = match batch.vector_field_mode {
            ParticleVectorFieldMode::None => 0.0,
            ParticleVectorFieldMode::Uniform => 1.0,
            ParticleVectorFieldMode::Curl => 2.0,
        };
        let force: f32 = match batch.force_mode {
            ParticleForceMode::None => 0.0,
            ParticleForceMode::Radial => 1.0,
            ParticleForceMode::Vortex => 2.0,
        };
        let collision: f32 = match batch.collision_mode {
            ParticleCollisionMode::None => 0.0,
            ParticleCollisionMode::LocalPlane => 1.0,
            ParticleCollisionMode::WorldPlane => 2.0,
        };
        GPUParticleSimulationUniforms {
            time: Float4::new(
                0.0f32.max(delta_time),
                dispatch_count as f32,
                0.0f32.max(elapsed_time),
                event_capacity as f32,
            ),
            gravity: Float4::new(batch.gravity.x, batch.gravity.y, batch.gravity.z, 0.0),
            noise: Float4::new(
                0.0f32.max(batch.noise_strength),
                0.0001f32.max(batch.noise_scale),
                0.0f32.max(batch.noise_speed),
                (batch.noise_seed & 0xFFFF) as f32 * 0.0001,
            ),
            vector_field_direction_strength: Float4::new(
                batch.vector_field_direction.x,
                batch.vector_field_direction.y,
                batch.vector_field_direction.z,
                0.0f32.max(batch.vector_field_strength),
            ),
            vector_field_params: Float4::new(
                0.0001f32.max(batch.vector_field_scale),
                batch.vector_field_scroll_speed,
                field,
                0.0,
            ),
            force_center_radius: Float4::new(
                batch.force_center.x,
                batch.force_center.y,
                batch.force_center.z,
                0.0f32.max(batch.force_radius),
            ),
            force_axis_mode: Float4::new(
                batch.force_axis.x,
                batch.force_axis.y,
                batch.force_axis.z,
                force,
            ),
            force_params: Float4::new(
                batch.force_strength,
                0.0f32.max(batch.force_falloff),
                0.0,
                0.0,
            ),
            collision_params: Float4::new(
                collision,
                batch.collision_plane_y,
                simd_clamp_scalar(batch.collision_restitution, 0.0, 1.0),
                simd_clamp_scalar(batch.collision_damping, 0.0, 1.0),
            ),
            collision_to_world: batch.world_transform,
            collision_to_local: if batch.collision_mode == ParticleCollisionMode::WorldPlane {
                simd_inverse(batch.world_transform)
            } else {
                MATRIX_IDENTITY_FLOAT4X4
            },
        }
    }
}

// MIGRATION.md §5.3: the bytes uploaded to the GPU must not change.
const _: () = assert!(core::mem::size_of::<GPUParticleSimulationUniforms>() == 272);
const _: () = assert!(core::mem::align_of::<GPUParticleSimulationUniforms>() == 16);

/// One simulated particle's state; matches `ParticleSimState` in
/// `particle_simulation_common.slang` (80 bytes, 16-aligned).
#[repr(C, align(16))]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GPUParticleSimulationState {
    pub position_lifetime: Float4,
    pub velocity_age: Float4,
    pub size_rotation: Float4,
    pub color: Float4,
    /// x: source generation, y: appearance index, z: texture frame seed, w: reserved.
    pub params: UInt4,
}

impl GPUParticleSimulationState {
    /// `init(particle:)`.
    pub fn from_particle(particle: &Particle) -> Self {
        GPUParticleSimulationState {
            position_lifetime: Float4::new(
                particle.position.x,
                particle.position.y,
                particle.position.z,
                particle.lifetime,
            ),
            velocity_age: Float4::new(
                particle.velocity.x,
                particle.velocity.y,
                particle.velocity.z,
                particle.age,
            ),
            size_rotation: Float4::new(
                particle.size,
                particle.rotation,
                particle.angular_velocity,
                particle.size_scale,
            ),
            color: particle.color,
            params: UInt4::new(
                u32::from(particle.generation),
                u32::from(particle.appearance_index),
                u32::from(particle.texture_frame_seed),
                0,
            ),
        }
    }

    /// `isFinite`.
    pub fn is_finite(&self) -> bool {
        let finite = |value: Float4| {
            value.x.is_finite() && value.y.is_finite() && value.z.is_finite() && value.w.is_finite()
        };
        finite(self.position_lifetime)
            && finite(self.velocity_age)
            && finite(self.size_rotation)
            && finite(self.color)
    }
}

// MIGRATION.md §5.3: the bytes uploaded to the GPU must not change.
const _: () = assert!(core::mem::size_of::<GPUParticleSimulationState>() == 80);
const _: () = assert!(core::mem::align_of::<GPUParticleSimulationState>() == 16);

/// One simulation event; matches `ParticleSimEvent` in
/// `particle_simulation_common.slang` (48 bytes, 16-aligned).
#[repr(C, align(16))]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GPUParticleSimulationEvent {
    /// xyz: event position, w: source lifetime.
    pub position_lifetime: Float4,
    /// xyz: event velocity, w: source age.
    pub velocity_age: Float4,
    /// x: trigger (1 collision, 2 death), y: source index,
    /// z: source generation, w: source appearance index.
    pub params: UInt4,
}

impl GPUParticleSimulationEvent {
    /// `var record: GPUParticleSimulationEventRecord` — decodes the packed
    /// lanes back into the CPU event vocabulary.
    pub fn record(&self) -> GPUParticleSimulationEventRecord {
        GPUParticleSimulationEventRecord::new(
            GPUParticleSimulationEventTrigger::from_raw_trigger(self.params.x),
            self.params.y,
            Float3::new(
                self.position_lifetime.x,
                self.position_lifetime.y,
                self.position_lifetime.z,
            ),
            self.position_lifetime.w,
            Float3::new(
                self.velocity_age.x,
                self.velocity_age.y,
                self.velocity_age.z,
            ),
            self.velocity_age.w,
            u8::try_from(self.params.z).unwrap_or(u8::MAX),
            u16::try_from(self.params.w).unwrap_or(u16::MAX),
        )
    }
}

// MIGRATION.md §5.3: the bytes uploaded to the GPU must not change.
const _: () = assert!(core::mem::size_of::<GPUParticleSimulationEvent>() == 48);
const _: () = assert!(core::mem::align_of::<GPUParticleSimulationEvent>() == 16);

/// The simulation counters; matches `ParticleSimMetadata` in
/// `particle_simulation_common.slang` (8×u32 = 32 bytes, 4-aligned).
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GPUParticleSimulationMetadata {
    pub alive_count: u32,
    pub expired_count: u32,
    pub collision_count: u32,
    pub spawned_count: u32,
    pub dropped_spawn_count: u32,
    pub append_cursor: u32,
    pub compacted_count: u32,
    pub event_count: u32,
}

impl GPUParticleSimulationMetadata {
    /// Swift's memberwise init with every counter defaulting to zero; the
    /// `append_cursor` argument is the only one callers usually supply.
    pub fn new(append_cursor: i64) -> Self {
        GPUParticleSimulationMetadata {
            alive_count: 0,
            expired_count: 0,
            collision_count: 0,
            spawned_count: 0,
            dropped_spawn_count: 0,
            append_cursor: append_cursor as u32,
            compacted_count: 0,
            event_count: 0,
        }
    }

    /// `GPUParticleSimulationMetadata()` — everything zero.
    pub fn zeroed() -> Self {
        Self::new(0)
    }

    /// `func snapshot(slot:emitter:capacity:records:)`.
    pub fn snapshot(
        &self,
        slot: usize,
        emitter: Option<u64>,
        capacity: usize,
        records: Vec<GPUParticleSimulationEventRecord>,
    ) -> GPUParticleSimulationEventSnapshot {
        GPUParticleSimulationEventSnapshot::new(
            slot,
            emitter,
            capacity,
            self.event_count as usize,
            (self.event_count as usize).saturating_sub(capacity),
            records,
            self.alive_count as usize,
            self.expired_count as usize,
            self.collision_count as usize,
            self.spawned_count as usize,
            self.dropped_spawn_count as usize,
            self.compacted_count as usize,
        )
    }
}

impl Default for GPUParticleSimulationMetadata {
    fn default() -> Self {
        Self::zeroed()
    }
}

// MIGRATION.md §5.3: the bytes uploaded to the GPU must not change.
const _: () = assert!(core::mem::size_of::<GPUParticleSimulationMetadata>() == 32);
const _: () = assert!(core::mem::align_of::<GPUParticleSimulationMetadata>() == 4);

/// Spawn-pass uniforms; matches `ParticleSpawnUniforms` in
/// `particle_spawn_append.slang`.
#[repr(C, align(16))]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GPUParticleSpawnUniforms {
    /// x: requested spawn count, y: particle capacity.
    pub params: UInt4,
}

impl GPUParticleSpawnUniforms {
    pub fn new(params: UInt4) -> Self {
        GPUParticleSpawnUniforms { params }
    }
}

// MIGRATION.md §5.3: the bytes uploaded to the GPU must not change.
const _: () = assert!(core::mem::size_of::<GPUParticleSpawnUniforms>() == 16);

/// State maintenance uniforms; matches `ParticleStateMaintenanceUniforms` in
/// `particle_state_clear.slang` / `particle_state_compact.slang`.
#[repr(C, align(16))]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GPUParticleStateMaintenanceUniforms {
    /// x: active simulation count, y: particle capacity.
    pub params: UInt4,
}

impl GPUParticleStateMaintenanceUniforms {
    pub fn new(params: UInt4) -> Self {
        GPUParticleStateMaintenanceUniforms { params }
    }
}

// MIGRATION.md §5.3: the bytes uploaded to the GPU must not change.
const _: () = assert!(core::mem::size_of::<GPUParticleStateMaintenanceUniforms>() == 16);
