//! Resident GPU particle simulation. Resident simulation data is transient and
//! follows an emitter, never the batch slot; a frame owns its proposed
//! residency and snapshots until submission succeeds.

use std::sync::Arc;

use std::collections::{BTreeMap, BTreeSet};

use cove_graphics::rhi::{
    Buffer, BufferDescriptor, BufferUsage, CommandBuffer, Device, RhiError, RhiResult,
};

use crate::core::particles::simulation_report::GPUParticleSimulationEncodeReport;
use crate::native::particles::native_particle_instances::{
    NativeParticleInstanceKernels, NativeParticleSimulationRender, NativeParticleSortBuffer,
    NativeParticleSourceBuffer,
};
use crate::native::particles::native_particle_simulation_kernels::NativeParticleSimulationKernels;
use crate::native::particles::native_particle_simulation_readback::NativeParticleSimulationReadback;
use diffuse_scene::rendering::render_scene::{ParticleRenderBatch, RenderScene};

pub struct NativeParticleSimulationState {
    pub device: Arc<Device>,
    pub capacity: usize,
    pub event_capacity: usize,
    pub state: Buffer,
    pub compact: Buffer,
    pub metadata: Buffer,
    pub events: Buffer,
}

impl NativeParticleSimulationState {
    pub fn new(device: &Arc<Device>, capacity: usize) -> RhiResult<Self> {
        if capacity == 0
            || capacity
                > crate::core::particles::particle_simulation_gpu_data::GPUParticleSimulationUniforms::MAXIMUM_EXACT_PARTICLE_COUNT as usize
        {
            return Err(RhiError::invalid_argument(
                "particle capacity exceeds the Float32 simulation ABI",
            ));
        }
        let event_capacity = capacity * 2;
        let event_capacity = event_capacity.max(1);
        let mut allocated: Vec<Buffer> = Vec::new();
        let buffers = (|| {
            let mut make = |size: usize| -> RhiResult<Buffer> {
                let result = device.make_buffer(BufferDescriptor::new(
                    size,
                    BufferUsage::STORAGE_READ
                        | BufferUsage::STORAGE_WRITE
                        | BufferUsage::TRANSFER_SOURCE
                        | BufferUsage::TRANSFER_DESTINATION,
                ))?;
                allocated.push(result);
                Ok(result)
            };
            let state = make(capacity * std::mem::size_of::<crate::core::particles::particle_simulation_gpu_data::GPUParticleSimulationState>())?;
            let compact = make(capacity * std::mem::size_of::<crate::core::particles::particle_simulation_gpu_data::GPUParticleSimulationState>())?;
            let metadata = make(std::mem::size_of::<
                crate::core::particles::particle_simulation_gpu_data::GPUParticleSimulationMetadata,
            >())?;
            let events = make(event_capacity * std::mem::size_of::<crate::core::particles::particle_simulation_gpu_data::GPUParticleSimulationEvent>())?;
            Ok((state, compact, metadata, events))
        })();
        match buffers {
            Ok((state, compact, metadata, events)) => Ok(NativeParticleSimulationState {
                device: device.clone(),
                capacity,
                event_capacity,
                state,
                compact,
                metadata,
                events,
            }),
            Err(error) => {
                for buffer in allocated {
                    device.destroy_buffer(buffer);
                }
                Err(error)
            }
        }
    }

    /// Swift's `deinit` destroys all four buffers.
    pub fn destroy(&self) {
        for buffer in [self.state, self.compact, self.metadata, self.events] {
            self.device.destroy_buffer(buffer);
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum NativeParticleSimulationKey {
    Emitter(u64),
    Anonymous(usize),
}

impl NativeParticleSimulationKey {
    pub fn from_batch(
        batch: &diffuse_scene::rendering::render_scene::RenderParticleSimulationBatch,
        slot: usize,
    ) -> Self {
        match batch.emitter_entity.map(|entity| entity.raw_value()) {
            Some(emitter) => NativeParticleSimulationKey::Emitter(emitter),
            None => NativeParticleSimulationKey::Anonymous(slot),
        }
    }
}

pub struct NativeParticleSimulationEntry {
    pub state: NativeParticleSimulationState,
    pub workgroup_size: usize,
    pub initialized: bool,
    pub sort: Option<NativeParticleSortBuffer>,
}

#[derive(Default)]
pub struct NativeParticleSimulationUpdate {
    pub entries: BTreeMap<NativeParticleSimulationKey, NativeParticleSimulationEntry>,
    pub readbacks: Vec<NativeParticleSimulationReadback>,
    pub report: GPUParticleSimulationEncodeReport,
    pub render: Option<NativeParticleSimulationRender>,
}

pub struct NativeParticleSimulation {
    device: Arc<Device>,
    programs: BTreeMap<usize, NativeParticleSimulationKernels>,
    instance_programs: BTreeMap<usize, NativeParticleInstanceKernels>,
    pub source: Option<NativeParticleSourceBuffer>,
    pub entries: BTreeMap<NativeParticleSimulationKey, NativeParticleSimulationEntry>,
    pending: Vec<NativeParticleSimulationReadback>,
    report: GPUParticleSimulationEncodeReport,
}

impl NativeParticleSimulation {
    pub fn new(device: &Arc<Device>) -> Self {
        NativeParticleSimulation {
            device: device.clone(),
            programs: BTreeMap::new(),
            instance_programs: BTreeMap::new(),
            source: None,
            entries: BTreeMap::new(),
            pending: Vec::new(),
            report: GPUParticleSimulationEncodeReport::empty(),
        }
    }

    /// Swift's `deinit` releases the resident programs, entries and source.
    pub fn destroy(&self) {
        for kernels in self.programs.values() {
            kernels.destroy();
        }
        for kernels in self.instance_programs.values() {
            kernels.destroy();
        }
        for entry in self.entries.values() {
            entry.state.destroy();
            if let Some(sort) = &entry.sort {
                sort.destroy();
            }
        }
        if let Some(source) = &self.source {
            source.destroy();
        }
        for readback in &self.pending {
            readback.destroy();
        }
    }

    pub fn prewarm(&mut self, workgroup_sizes: &[usize]) -> RhiResult<()> {
        let mut sizes: BTreeSet<usize> = BTreeSet::new();
        for size in workgroup_sizes {
            sizes.insert(*size);
        }
        for size in sizes {
            if !(1..=256).contains(&size) {
                return Err(RhiError::invalid_argument(
                    "particle workgroup size must be in 1...256",
                ));
            }
            if !self.programs.contains_key(&size) {
                self.programs.insert(
                    size,
                    NativeParticleSimulationKernels::new(&self.device, size)?,
                );
            }
            if !self.instance_programs.contains_key(&size) {
                self.instance_programs.insert(
                    size,
                    NativeParticleInstanceKernels::new(&self.device, size)?,
                );
            }
        }
        Ok(())
    }

    #[allow(
        clippy::manual_div_ceil,
        reason = "Preserve Swift checked addition before division."
    )]
    pub fn prepare(
        &mut self,
        scene: &RenderScene,
        delta_time: f32,
        elapsed_time: f32,
        commands: &mut CommandBuffer,
    ) -> RhiResult<NativeParticleSimulationUpdate> {
        let mut update = NativeParticleSimulationUpdate::default();
        let gpu_count: usize = scene
            .particle_simulation_batches
            .iter()
            .filter(|batch| {
                batch.plan.uses_gpu() && batch.render_on_gpu && batch.particle_count() > 0
            })
            .map(|batch| batch.render_instance_count() as usize)
            .sum();
        if gpu_count > 0 {
            let required = gpu_count + scene.particles.len();
            let buffer = match &self.source {
                Some(source) if source.capacity >= required => NativeParticleSourceBuffer {
                    device: source.device.clone(),
                    buffer: source.buffer,
                    capacity: source.capacity,
                },
                source => {
                    let capacity = required
                        .max(source.as_ref().map_or(0, |source| source.capacity * 2))
                        .max(256);
                    NativeParticleSourceBuffer::new(&self.device, capacity)?
                }
            };
            update.render = Some(NativeParticleSimulationRender {
                source: Some(buffer),
                batches: Vec::new(),
                instance_count: 0,
            });
        }
        for (slot, batch) in scene.particle_simulation_batches.iter().enumerate() {
            if !batch.plan.uses_gpu() || batch.particle_count() <= 0 {
                continue;
            }
            let key = NativeParticleSimulationKey::from_batch(batch, slot);
            if update.entries.contains_key(&key) {
                return Err(RhiError::invalid_argument(
                    "duplicate particle simulation emitter",
                ));
            }
            let group = 256usize.min(1usize.max(batch.plan.workgroup_size as usize));
            let capacity = batch.plan.particle_capacity as usize;
            let entry = match self.entries.remove(&key) {
                Some(previous)
                    if previous.state.capacity >= capacity && previous.workgroup_size == group =>
                {
                    previous
                }
                _ => NativeParticleSimulationEntry {
                    state: NativeParticleSimulationState::new(&self.device, capacity)?,
                    workgroup_size: group,
                    initialized: false,
                    sort: None,
                },
            };
            if !self.programs.contains_key(&group) {
                self.programs.insert(
                    group,
                    NativeParticleSimulationKernels::new(&self.device, group)?,
                );
            }
            let Some(kernels) = self.programs.get(&group) else {
                return Err(RhiError::OutOfMemory);
            };
            let reseed = batch.emitter_entity.is_none() || !entry.initialized;
            let count = kernels.encode(
                batch,
                &entry.state,
                reseed,
                delta_time * batch.simulation_speed,
                elapsed_time,
                commands,
            )?;
            let mut entry = entry;
            if batch.render_on_gpu {
                let Some(render) = update.render.as_mut() else {
                    return Err(RhiError::OutOfMemory);
                };
                if !self.instance_programs.contains_key(&group) {
                    self.instance_programs.insert(
                        group,
                        NativeParticleInstanceKernels::new(&self.device, group)?,
                    );
                }
                if entry
                    .sort
                    .as_ref()
                    .is_none_or(|sort| sort.capacity < batch.render_particle_count() as usize)
                    && let Some(sort) = entry.sort.replace(NativeParticleSortBuffer::new(
                        &self.device,
                        batch.render_particle_count() as usize,
                    )?)
                {
                    sort.destroy();
                }
                let Some(sort) = &entry.sort else {
                    return Err(RhiError::OutOfMemory);
                };
                let Some(instance) = self.instance_programs.get(&group) else {
                    return Err(RhiError::OutOfMemory);
                };
                let Some(source) = render.source.as_ref() else {
                    return Err(RhiError::OutOfMemory);
                };
                let instance_report = instance.encode(
                    batch,
                    &entry.state,
                    sort,
                    scene.camera.eye,
                    source,
                    render.instance_count,
                    commands,
                )?;
                render.batches.push(ParticleRenderBatch::new(
                    diffuse_scene::rendering::render_scene::ParticleRenderBatchKey::new(
                        batch.blend_mode,
                        batch.texture_path.clone(),
                    ),
                    render.instance_count as i64,
                    instance_report.render_instance_count,
                ));
                render.instance_count += instance_report.render_instance_count as usize;
                update.report.render_instance_count += instance_report.render_instance_count;
                update.report.instance_dispatch_workgroups +=
                    instance_report.instance_dispatch_workgroups;
                update.report.sort_pass_count += instance_report.sort_report.pass_count;
                update.report.sort_item_count += instance_report.sort_report.item_count;
                update.report.sort_padded_item_count +=
                    instance_report.sort_report.padded_item_count;
                update.report.sort_dispatch_workgroups +=
                    instance_report.sort_report.dispatch_workgroups;
            }
            update.readbacks.push(NativeParticleSimulationReadback::new(
                &self.device,
                &entry.state,
                slot,
                batch.emitter_entity.map(|entity| entity.raw_value()),
                commands,
            )?);
            entry.initialized = true;
            update.report.batch_count += 1;
            update.report.particle_count += count as i64;
            update.report.dispatch_workgroups += ((count + group - 1) / group) as i64;
            update.report.event_capacity += entry.state.event_capacity as i64;
            update.report.event_buffer_bytes +=
                (entry.state.event_capacity * std::mem::size_of::<crate::core::particles::particle_simulation_gpu_data::GPUParticleSimulationEvent>()) as i64;
            update.entries.insert(key, entry);
        }
        Ok(update)
    }

    pub fn commit(&mut self, update: NativeParticleSimulationUpdate) {
        // Retire residency the previous frame owned but the update no longer
        // carries (Swift released these through class reference counting).
        for (key, entry) in std::mem::take(&mut self.entries) {
            if !update.entries.contains_key(&key) {
                entry.state.destroy();
                if let Some(sort) = &entry.sort {
                    sort.destroy();
                }
            }
        }
        if let Some(previous) = self.source.take() {
            let still_needed = update
                .render
                .as_ref()
                .and_then(|render| render.source.as_ref())
                .is_some_and(|source| source.buffer == previous.buffer);
            if !still_needed {
                previous.destroy();
            }
        }
        self.entries = update.entries;
        self.source = update
            .render
            .as_ref()
            .and_then(|render| render.source.clone());
        self.report = update.report;
        self.pending.extend(update.readbacks);
        if self.pending.len() > 64 {
            let excess = self.pending.len() - 64;
            for readback in self.pending.drain(..excess) {
                readback.destroy();
            }
        }
    }

    /// The encode report of the last committed frame (Swift reads
    /// `simulation.report` inside `renderFrame` before the commit moves the
    /// update).
    pub fn last_report(&self) -> &GPUParticleSimulationEncodeReport {
        &self.report
    }

    pub fn drain(
        &mut self,
        max_snapshots: usize,
    ) -> RhiResult<Vec<crate::core::render_stats::GPUParticleSimulationEventSnapshot>> {
        let mut result = Vec::new();
        for _ in 0..max_snapshots.min(self.pending.len()) {
            // A failed read remains queued, so retrying does not lose events.
            result.push(self.pending[0].read()?);
            let readback = self.pending.remove(0);
            readback.destroy();
        }
        Ok(result)
    }
}

// The instance stride appears in the source-buffer sizing table.
const _: usize =
    std::mem::size_of::<crate::core::particles::particle_gpu_data::GPUParticleInstance>();
