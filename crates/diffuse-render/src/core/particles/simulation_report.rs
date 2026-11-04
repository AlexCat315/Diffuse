//! Aggregate GPU particle simulation encode accounting.
//!
//! Ported from
//! `Engine/Sources/RenderBackend/Core/Particles/SimulationReport.swift`.

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GPUParticleSimulationEncodeReport {
    pub batch_count: i64,
    pub particle_count: i64,
    pub dispatch_workgroups: i64,
    pub sort_pass_count: i64,
    pub sort_item_count: i64,
    pub sort_padded_item_count: i64,
    pub sort_dispatch_workgroups: i64,
    pub instance_dispatch_workgroups: i64,
    pub render_instance_count: i64,
    pub event_capacity: i64,
    pub event_buffer_bytes: i64,
}

impl GPUParticleSimulationEncodeReport {
    /// Swift's defaulted initializer; every field is clamped to `>= 0`.
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        batch_count: i64,
        particle_count: i64,
        dispatch_workgroups: i64,
        sort_pass_count: i64,
        sort_item_count: i64,
        sort_padded_item_count: i64,
        sort_dispatch_workgroups: i64,
        instance_dispatch_workgroups: i64,
        render_instance_count: i64,
        event_capacity: i64,
        event_buffer_bytes: i64,
    ) -> Self {
        GPUParticleSimulationEncodeReport {
            batch_count: batch_count.max(0),
            particle_count: particle_count.max(0),
            dispatch_workgroups: dispatch_workgroups.max(0),
            sort_pass_count: sort_pass_count.max(0),
            sort_item_count: sort_item_count.max(0),
            sort_padded_item_count: sort_padded_item_count.max(0),
            sort_dispatch_workgroups: sort_dispatch_workgroups.max(0),
            instance_dispatch_workgroups: instance_dispatch_workgroups.max(0),
            render_instance_count: render_instance_count.max(0),
            event_capacity: event_capacity.max(0),
            event_buffer_bytes: event_buffer_bytes.max(0),
        }
    }

    /// `GPUParticleSimulationEncodeReport()` — every field zero.
    pub fn empty() -> Self {
        Self::new(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    /// `include(batchParticleCount:dispatchWorkgroups:...)` — the omitted sort,
    /// instance and event arguments default to zero.
    pub fn include_batch(&mut self, batch_particle_count: i64, dispatch_workgroups: i64) {
        self.include(
            batch_particle_count,
            dispatch_workgroups,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
        );
    }

    /// The full `include(...)` with every argument expanded.
    #[allow(clippy::too_many_arguments)]
    pub fn include(
        &mut self,
        batch_particle_count: i64,
        dispatch_workgroups: i64,
        sort_pass_count: i64,
        sort_item_count: i64,
        sort_padded_item_count: i64,
        sort_dispatch_workgroups: i64,
        instance_dispatch_workgroups: i64,
        render_instance_count: i64,
        event_capacity: i64,
        event_buffer_bytes: i64,
    ) {
        self.batch_count += 1;
        self.particle_count += batch_particle_count.max(0);
        self.dispatch_workgroups += dispatch_workgroups.max(0);
        self.sort_pass_count += sort_pass_count.max(0);
        self.sort_item_count += sort_item_count.max(0);
        self.sort_padded_item_count += sort_padded_item_count.max(0);
        self.sort_dispatch_workgroups += sort_dispatch_workgroups.max(0);
        self.instance_dispatch_workgroups += instance_dispatch_workgroups.max(0);
        self.render_instance_count += render_instance_count.max(0);
        self.event_capacity += event_capacity.max(0);
        self.event_buffer_bytes += event_buffer_bytes.max(0);
    }
}

impl Default for GPUParticleSimulationEncodeReport {
    fn default() -> Self {
        Self::empty()
    }
}
