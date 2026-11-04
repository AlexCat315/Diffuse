//! Frame statistics and the GPU particle simulation event payload.
//!
//! Ported from `Engine/Sources/RenderBackend/Core/RenderStats.swift`.

use std::collections::BTreeMap;

use diffuse_math::simd::simd_compat::Float3;

use crate::core::frame::render_frame_plan::RenderPassKind;

/// `GPUParticleSimulationEventTrigger` — a `UInt32` raw-value enum.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
#[repr(u32)]
pub enum GPUParticleSimulationEventTrigger {
    #[default]
    Unknown = 0,
    Collision = 1,
    Death = 2,
}

impl GPUParticleSimulationEventTrigger {
    pub const fn raw_value(self) -> u32 {
        match self {
            GPUParticleSimulationEventTrigger::Unknown => 0,
            GPUParticleSimulationEventTrigger::Collision => 1,
            GPUParticleSimulationEventTrigger::Death => 2,
        }
    }

    pub fn from_raw_value(value: u32) -> Option<Self> {
        match value {
            0 => Some(GPUParticleSimulationEventTrigger::Unknown),
            1 => Some(GPUParticleSimulationEventTrigger::Collision),
            2 => Some(GPUParticleSimulationEventTrigger::Death),
            _ => None,
        }
    }

    /// `init(rawTrigger:)` — unknown raw values fall back to `.unknown`.
    pub fn from_raw_trigger(raw_trigger: u32) -> Self {
        Self::from_raw_value(raw_trigger).unwrap_or(GPUParticleSimulationEventTrigger::Unknown)
    }
}

/// One GPU simulation event, decoded from the event buffer.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GPUParticleSimulationEventRecord {
    pub trigger: GPUParticleSimulationEventTrigger,
    pub source_index: u32,
    pub position: Float3,
    pub lifetime: f32,
    pub velocity: Float3,
    pub age: f32,
    pub generation: u8,
    pub appearance_index: u16,
}

impl GPUParticleSimulationEventRecord {
    /// Swift's defaulted initializer; `generation`/`appearanceIndex` default 0.
    pub fn new(
        trigger: GPUParticleSimulationEventTrigger,
        source_index: u32,
        position: Float3,
        lifetime: f32,
        velocity: Float3,
        age: f32,
        generation: u8,
        appearance_index: u16,
    ) -> Self {
        GPUParticleSimulationEventRecord {
            trigger,
            source_index,
            position,
            lifetime,
            velocity,
            age,
            generation,
            appearance_index,
        }
    }
}

/// A drained simulation snapshot: event records plus the frame's counters.
#[derive(Clone, Debug, PartialEq)]
pub struct GPUParticleSimulationEventSnapshot {
    pub slot: usize,
    pub emitter_raw_value: Option<u64>,
    pub event_capacity: usize,
    pub total_event_count: usize,
    pub dropped_event_count: usize,
    pub records: Vec<GPUParticleSimulationEventRecord>,
    pub alive_particle_count: usize,
    pub expired_particle_count: usize,
    pub collision_event_count: usize,
    pub gpu_spawned_particle_count: usize,
    pub gpu_dropped_spawn_count: usize,
    pub compacted_particle_count: usize,
}

impl GPUParticleSimulationEventSnapshot {
    /// Swift's defaulted initializer: `slot`, `eventCapacity`, and every count
    /// is clamped to `>= 0` (the Rust types are unsigned, so the clamp is the
    /// identity — kept explicit for parity with Swift).
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        slot: usize,
        emitter_raw_value: Option<u64>,
        event_capacity: usize,
        total_event_count: usize,
        dropped_event_count: usize,
        records: Vec<GPUParticleSimulationEventRecord>,
        alive_particle_count: usize,
        expired_particle_count: usize,
        collision_event_count: usize,
        gpu_spawned_particle_count: usize,
        gpu_dropped_spawn_count: usize,
        compacted_particle_count: usize,
    ) -> Self {
        GPUParticleSimulationEventSnapshot {
            slot: slot.max(0),
            emitter_raw_value,
            event_capacity: event_capacity.max(0),
            total_event_count: total_event_count.max(0),
            dropped_event_count: dropped_event_count.max(0),
            records,
            alive_particle_count: alive_particle_count.max(0),
            expired_particle_count: expired_particle_count.max(0),
            collision_event_count: collision_event_count.max(0),
            gpu_spawned_particle_count: gpu_spawned_particle_count.max(0),
            gpu_dropped_spawn_count: gpu_dropped_spawn_count.max(0),
            compacted_particle_count: compacted_particle_count.max(0),
        }
    }
}

/// Everything the renderer measured in one frame.
#[derive(Clone, Debug, PartialEq)]
pub struct RenderFrameStats {
    pub visible_mesh_instance_count: i64,
    pub culled_mesh_instance_count: i64,
    pub lod_mesh_instance_count: i64,
    pub mesh_batch_count: i64,
    pub instanced_mesh_batch_count: i64,
    pub submitted_mesh_triangle_count: i64,
    pub frame_index: i64,
    pub pass_count: i64,
    pub draw_call_count: i64,
    pub pass_draw_call_counts: BTreeMap<RenderPassKind, i64>,
    pub gpu_particle_simulation_batch_count: i64,
    pub gpu_particle_simulation_particle_count: i64,
    pub gpu_particle_simulation_dispatch_workgroups: i64,
    pub gpu_particle_sort_pass_count: i64,
    pub gpu_particle_sort_item_count: i64,
    pub gpu_particle_sort_padded_item_count: i64,
    pub gpu_particle_sort_dispatch_workgroups: i64,
    pub gpu_particle_instance_dispatch_workgroups: i64,
    pub gpu_particle_simulation_event_capacity: i64,
    pub gpu_particle_simulation_event_buffer_bytes: i64,
    pub gpu_particle_render_instance_count: i64,
    pub gpu_particle_indirect_draw_count: i64,
    pub gpu_particle_cull_batch_count: i64,
    pub gpu_particle_cull_candidate_count: i64,
    pub gpu_particle_cull_dispatch_workgroups: i64,
    pub gpu_particle_simulation_encode_ns: u64,
    pub deformable_mesh_count: i64,
    pub deformable_vertex_count: i64,
    pub deformable_triangle_count: i64,
    pub deformable_rejected_mesh_count: i64,
    pub deformable_uploaded_bytes: u64,
    pub deformable_upload_ns: u64,
    pub shadowed_light_count: i64,
    pub shadow_tile_count: i64,
    pub shadow_cascade_count: i64,
    pub shadow_map_resolution: u32,
    pub shadow_atlas_resolution: u32,
    pub active_passes: Vec<RenderPassKind>,
    pub settings_generation: u64,
    pub cpu_prepare_ns: u64,
    pub cpu_encode_ns: u64,
    pub cpu_submit_ns: u64,
    pub cpu_frame_total_ns: u64,
    pub cpu_skybox_encode_ns: u64,
    pub cpu_base_encode_ns: u64,
    pub cpu_post_process_encode_ns: u64,
    pub pass_encode_ns: BTreeMap<RenderPassKind, u64>,
}

impl RenderFrameStats {
    /// Swift's defaulted initializer: `frameIndex` starts at `-1`, everything
    /// else at zero/empty.
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        frame_index: i64,
        pass_count: i64,
        draw_call_count: i64,
        pass_draw_call_counts: BTreeMap<RenderPassKind, i64>,
        gpu_particle_simulation_batch_count: i64,
        gpu_particle_simulation_particle_count: i64,
        gpu_particle_simulation_dispatch_workgroups: i64,
        gpu_particle_sort_pass_count: i64,
        gpu_particle_sort_item_count: i64,
        gpu_particle_sort_padded_item_count: i64,
        gpu_particle_sort_dispatch_workgroups: i64,
        gpu_particle_instance_dispatch_workgroups: i64,
        gpu_particle_simulation_event_capacity: i64,
        gpu_particle_simulation_event_buffer_bytes: i64,
        gpu_particle_render_instance_count: i64,
        gpu_particle_indirect_draw_count: i64,
        gpu_particle_cull_batch_count: i64,
        gpu_particle_cull_candidate_count: i64,
        gpu_particle_cull_dispatch_workgroups: i64,
        gpu_particle_simulation_encode_ns: u64,
        deformable_mesh_count: i64,
        deformable_vertex_count: i64,
        deformable_triangle_count: i64,
        deformable_rejected_mesh_count: i64,
        deformable_uploaded_bytes: u64,
        deformable_upload_ns: u64,
        shadowed_light_count: i64,
        shadow_tile_count: i64,
        shadow_cascade_count: i64,
        shadow_map_resolution: u32,
        shadow_atlas_resolution: u32,
        active_passes: Vec<RenderPassKind>,
        settings_generation: u64,
        cpu_prepare_ns: u64,
        cpu_encode_ns: u64,
        cpu_submit_ns: u64,
        cpu_frame_total_ns: u64,
        cpu_skybox_encode_ns: u64,
        cpu_base_encode_ns: u64,
        cpu_post_process_encode_ns: u64,
        pass_encode_ns: BTreeMap<RenderPassKind, u64>,
    ) -> Self {
        RenderFrameStats {
            frame_index,
            pass_count,
            draw_call_count,
            pass_draw_call_counts,
            gpu_particle_simulation_batch_count,
            gpu_particle_simulation_particle_count,
            gpu_particle_simulation_dispatch_workgroups,
            gpu_particle_sort_pass_count,
            gpu_particle_sort_item_count,
            gpu_particle_sort_padded_item_count,
            gpu_particle_sort_dispatch_workgroups,
            gpu_particle_instance_dispatch_workgroups,
            gpu_particle_simulation_event_capacity,
            gpu_particle_simulation_event_buffer_bytes,
            gpu_particle_render_instance_count,
            gpu_particle_indirect_draw_count,
            gpu_particle_cull_batch_count,
            gpu_particle_cull_candidate_count,
            gpu_particle_cull_dispatch_workgroups,
            gpu_particle_simulation_encode_ns,
            deformable_mesh_count,
            deformable_vertex_count,
            deformable_triangle_count,
            deformable_rejected_mesh_count,
            deformable_uploaded_bytes,
            deformable_upload_ns,
            shadowed_light_count,
            shadow_tile_count,
            shadow_cascade_count,
            shadow_map_resolution,
            shadow_atlas_resolution,
            active_passes,
            settings_generation,
            cpu_prepare_ns,
            cpu_encode_ns,
            cpu_submit_ns,
            cpu_frame_total_ns,
            cpu_skybox_encode_ns,
            cpu_base_encode_ns,
            cpu_post_process_encode_ns,
            pass_encode_ns,
        }
    }

    /// Swift's field defaults: `frameIndex = -1`, everything else zero/empty.
    pub fn untouched() -> Self {
        Self::new(
            -1,
            0,
            0,
            BTreeMap::new(),
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            Vec::new(),
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            BTreeMap::new(),
        )
    }
}

impl Default for RenderFrameStats {
    fn default() -> Self {
        Self::untouched()
    }
}
