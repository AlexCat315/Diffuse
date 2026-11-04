//! GPU particle output buffers. Outputs grow independently by responsibility;
//! source instances are frame uploads.

use cove_graphics::rhi::{Buffer, BufferDescriptor, BufferUsage, Device, RhiResult};

use crate::core::particles::particle_gpu_data::{GPUParticleIndirectDrawArgs, GPUParticleInstance};

pub struct NativeParticleBuffers {
    device: Device,
    pub visible: Option<Buffer>,
    pub indirect: Option<Buffer>,
    instance_capacity: usize,
    batch_capacity: usize,
}

impl NativeParticleBuffers {
    pub fn new(device: &Device) -> Self {
        NativeParticleBuffers {
            device: device.clone(),
            visible: None,
            indirect: None,
            instance_capacity: 0,
            batch_capacity: 0,
        }
    }

    /// Swift's `deinit` destroys both buffers.
    pub fn destroy(&self) {
        if let Some(visible) = self.visible {
            self.device.destroy_buffer(visible);
        }
        if let Some(indirect) = self.indirect {
            self.device.destroy_buffer(indirect);
        }
    }

    pub fn ensure(&mut self, instances: usize, batches: usize) -> RhiResult<()> {
        if instances > self.instance_capacity {
            let capacity = instances.max(self.instance_capacity * 2).max(256);
            let next = self.device.make_buffer(BufferDescriptor::labelled(
                capacity
                    * std::mem::size_of::<
                        crate::core::particles::particle_gpu_data::GPUParticleInstance,
                    >(),
                BufferUsage::STORAGE_READ
                    | BufferUsage::STORAGE_WRITE
                    | BufferUsage::TRANSFER_SOURCE,
                "native-particle-visible",
            ))?;
            if let Some(visible) = self.visible.replace(next) {
                self.device.destroy_buffer(visible);
            }
            self.instance_capacity = capacity;
        }
        if batches > self.batch_capacity {
            let capacity = batches.max(self.batch_capacity * 2).max(64);
            let next = self.device.make_buffer(BufferDescriptor::labelled(
                capacity
                    * std::mem::size_of::<
                        crate::core::particles::particle_gpu_data::GPUParticleIndirectDrawArgs,
                    >(),
                BufferUsage::STORAGE_WRITE | BufferUsage::INDIRECT | BufferUsage::TRANSFER_SOURCE,
                "native-particle-indirect",
            ))?;
            if let Some(indirect) = self.indirect.replace(next) {
                self.device.destroy_buffer(indirect);
            }
            self.batch_capacity = capacity;
        }
        Ok(())
    }
}
