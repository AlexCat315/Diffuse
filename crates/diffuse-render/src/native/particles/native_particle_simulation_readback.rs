//! Copies each frame's counters/events before the next frame resets them.

use cove_graphics::rhi::{Buffer, BufferDescriptor, BufferUsage, CommandBuffer, Device, RhiResult};

use crate::core::particles::particle_simulation_gpu_data::{
    GPUParticleSimulationEvent, GPUParticleSimulationMetadata,
};
use crate::core::render_stats::{
    GPUParticleSimulationEventRecord, GPUParticleSimulationEventSnapshot,
};
use crate::native::particles::native_particle_simulation::NativeParticleSimulationState;

pub struct NativeParticleSimulationReadback {
    device: Device,
    metadata: Buffer,
    events: Buffer,
    capacity: usize,
    slot: usize,
    emitter: Option<u64>,
}

impl NativeParticleSimulationReadback {
    pub fn new(
        device: &Device,
        state: &NativeParticleSimulationState,
        slot: usize,
        emitter: Option<u64>,
        commands: &mut CommandBuffer,
    ) -> RhiResult<Self> {
        let capacity = state.event_capacity;
        let metadata = device.make_buffer(BufferDescriptor::new(
            std::mem::size_of::<
                crate::core::particles::particle_simulation_gpu_data::GPUParticleSimulationMetadata,
            >(),
            BufferUsage::TRANSFER_DESTINATION | BufferUsage::TRANSFER_SOURCE,
        ))?;
        let events = match device.make_buffer(BufferDescriptor::new(
            capacity * std::mem::size_of::<crate::core::particles::particle_simulation_gpu_data::GPUParticleSimulationEvent>(),
            BufferUsage::TRANSFER_DESTINATION | BufferUsage::TRANSFER_SOURCE,
        )) {
            Ok(events) => events,
            Err(error) => {
                device.destroy_buffer(metadata);
                return Err(error);
            }
        };
        commands.copy_pass(|copy| {
            copy.copy_buffer(
                state.metadata,
                0,
                metadata,
                0,
                std::mem::size_of::<crate::core::particles::particle_simulation_gpu_data::GPUParticleSimulationMetadata>(),
            );
            copy.copy_buffer(
                state.events,
                0,
                events,
                0,
                capacity * std::mem::size_of::<crate::core::particles::particle_simulation_gpu_data::GPUParticleSimulationEvent>(),
            );
        });
        Ok(NativeParticleSimulationReadback {
            device: device.clone(),
            metadata,
            events,
            capacity,
            slot,
            emitter,
        })
    }

    /// Swift's `deinit` destroys both readback buffers.
    pub fn destroy(&self) {
        self.device.destroy_buffer(self.metadata);
        self.device.destroy_buffer(self.events);
    }

    pub fn read(&self) -> RhiResult<GPUParticleSimulationEventSnapshot> {
        let mut counters = GPUParticleSimulationMetadata::default();
        // SAFETY: `counters` is a live `#[repr(C)]` value; `read_buffer_data`
        // fills exactly its byte extent.
        unsafe {
            let bytes = std::slice::from_raw_parts_mut(
                (&mut counters as *mut GPUParticleSimulationMetadata).cast::<u8>(),
                std::mem::size_of::<GPUParticleSimulationMetadata>(),
            );
            self.device.read_buffer_data(self.metadata, 0, bytes)?;
        }
        let count = (self.capacity as u32).min(counters.event_count) as usize;
        let stride = std::mem::size_of::<
            crate::core::particles::particle_simulation_gpu_data::GPUParticleSimulationEvent,
        >();
        let mut data = vec![0u8; count * stride];
        if count > 0 {
            self.device.read_buffer_data(self.events, 0, &mut data)?;
        }
        let records: Vec<GPUParticleSimulationEventRecord> = data
            .chunks_exact(stride)
            .map(|chunk| {
                // SAFETY: the chunk is exactly one fully initialized event.
                let event = unsafe {
                    chunk
                        .as_ptr()
                        .cast::<GPUParticleSimulationEvent>()
                        .read_unaligned()
                };
                event.record()
            })
            .collect();
        Ok(counters.snapshot(self.slot, self.emitter, self.capacity, records))
    }
}
