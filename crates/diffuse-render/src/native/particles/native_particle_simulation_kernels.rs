//! Physics and lifecycle programs for one physical workgroup size.

use std::collections::BTreeMap;

use cove_graphics::rhi::{Buffer, CommandBuffer, Device, RhiResult};
use diffuse_math::simd::simd_compat::UInt4;
use diffuse_scene::rendering::render_scene::RenderParticleSimulationBatch;

use crate::core::particles::particle_simulation_gpu_data::{
    GPUParticleSimulationEvent, GPUParticleSimulationMetadata, GPUParticleSimulationState,
    GPUParticleSimulationUniforms, GPUParticleSpawnUniforms, GPUParticleStateMaintenanceUniforms,
};
use crate::native::lighting::native_lighting_resources::NativeUniformUpload;
use crate::native::particles::native_particle_simulation::NativeParticleSimulationState;
use crate::native::passes::native_compute_pass::NativeComputePass;

pub struct NativeParticleSimulationKernels {
    device: Device,
    workgroup_size: usize,
    simulate: NativeComputePass,
    spawn: NativeComputePass,
    clear: NativeComputePass,
    compact: NativeComputePass,
    reset: NativeComputePass,
    finalize: NativeComputePass,
}

impl NativeParticleSimulationKernels {
    pub fn new(device: &Device, workgroup_size: usize) -> RhiResult<Self> {
        let state = std::mem::size_of::<
            crate::core::particles::particle_simulation_gpu_data::GPUParticleSimulationState,
        >() as i64;
        let metadata = std::mem::size_of::<
            crate::core::particles::particle_simulation_gpu_data::GPUParticleSimulationMetadata,
        >() as i64;
        let mut simulate_strides = BTreeMap::new();
        simulate_strides.insert(1, state);
        simulate_strides.insert(2, metadata);
        simulate_strides.insert(
            3,
            std::mem::size_of::<
                crate::core::particles::particle_simulation_gpu_data::GPUParticleSimulationEvent,
            >() as i64,
        );
        let simulate = NativeComputePass::with_options(
            device,
            "particle_simulate",
            &simulate_strides,
            Some(workgroup_size),
        )?;
        let mut spawn_strides = BTreeMap::new();
        spawn_strides.insert(1, state);
        spawn_strides.insert(2, state);
        spawn_strides.insert(3, metadata);
        let spawn = NativeComputePass::with_options(
            device,
            "particle_spawn_append",
            &spawn_strides,
            Some(workgroup_size),
        )?;
        let mut clear_strides = BTreeMap::new();
        clear_strides.insert(1, state);
        let clear = NativeComputePass::with_options(
            device,
            "particle_state_clear",
            &clear_strides,
            Some(workgroup_size),
        )?;
        let mut compact_strides = BTreeMap::new();
        compact_strides.insert(1, state);
        compact_strides.insert(2, state);
        compact_strides.insert(3, metadata);
        let compact = NativeComputePass::with_options(
            device,
            "particle_state_compact",
            &compact_strides,
            Some(workgroup_size),
        )?;
        let mut reset_strides = BTreeMap::new();
        reset_strides.insert(0, metadata);
        let reset = NativeComputePass::with_options(
            device,
            "particle_metadata_reset",
            &reset_strides,
            None,
        )?;
        let mut finalize_strides = BTreeMap::new();
        finalize_strides.insert(0, metadata);
        let finalize = NativeComputePass::with_options(
            device,
            "particle_state_finalize",
            &finalize_strides,
            None,
        )?;
        Ok(NativeParticleSimulationKernels {
            device: device.clone(),
            workgroup_size,
            simulate,
            spawn,
            clear,
            compact,
            reset,
            finalize,
        })
    }

    /// Swift's `deinit` destroys all six programs.
    pub fn destroy(&self) {
        self.finalize.destroy();
        self.reset.destroy();
        self.compact.destroy();
        self.clear.destroy();
        self.spawn.destroy();
        self.simulate.destroy();
    }

    pub fn encode(
        &self,
        batch: &RenderParticleSimulationBatch,
        state: &NativeParticleSimulationState,
        reseed: bool,
        delta_time: f32,
        elapsed_time: f32,
        commands: &mut CommandBuffer,
    ) -> RhiResult<usize> {
        let persisted = batch
            .particles
            .len()
            .min(state.capacity)
            .min(batch.plan.particle_capacity as usize);
        let requested = batch.spawn_particles.len().min(state.capacity);
        let seeded_spawn =
            requested.min(0usize.max(batch.plan.particle_capacity as usize - persisted));
        let count = if reseed {
            persisted + seeded_spawn
        } else {
            state.capacity
        };
        let maintenance = NativeUniformUpload::binding(
            GPUParticleStateMaintenanceUniforms {
                params: UInt4::new(count as u32, state.capacity as u32, 0, 0),
            },
            &self.device,
        )?;
        if reseed {
            // Allocation and anonymous reseeding must clear the unused tail too.
            self.clear.encode(
                vec![
                    cove_graphics::rhi::BindingSetEntry::new(0, maintenance),
                    cove_graphics::rhi::BindingSetEntry::new(
                        1,
                        cove_graphics::rhi::BindingResource::StorageBuffer {
                            buffer: state.state,
                            offset: 0,
                        },
                    ),
                ],
                self.groups(state.capacity),
                commands,
            )?;
            let particles: Vec<GPUParticleSimulationState> = batch
                .particles
                .iter()
                .take(persisted)
                .map(GPUParticleSimulationState::from_particle)
                .collect();
            Self::copy(&self.device, &particles, state.state, commands)?;
            let metadata = GPUParticleSimulationMetadata::with_append_cursor(persisted);
            Self::copy_metadata(&self.device, &metadata, state.metadata, commands)?;
        } else {
            self.reset.encode(
                vec![cove_graphics::rhi::BindingSetEntry::new(
                    0,
                    cove_graphics::rhi::BindingResource::StorageBuffer {
                        buffer: state.metadata,
                        offset: 0,
                    },
                )],
                1,
                commands,
            )?;
        }
        if requested > 0 {
            let states: Vec<GPUParticleSimulationState> = batch
                .spawn_particles
                .iter()
                .take(requested)
                .map(GPUParticleSimulationState::from_particle)
                .collect();
            // SAFETY: `states` is a live `Vec` of `#[repr(C)]` `Copy` values.
            let state_bytes = unsafe {
                std::slice::from_raw_parts(
                    states.as_ptr().cast::<u8>(),
                    states.len() * std::mem::size_of::<crate::core::particles::particle_simulation_gpu_data::GPUParticleSimulationState>(),
                )
            };
            let input = self.device.upload_transient(state_bytes, 256)?;
            let uniform = NativeUniformUpload::binding(
                GPUParticleSpawnUniforms {
                    params: UInt4::new(requested as u32, state.capacity as u32, 0, 0),
                },
                &self.device,
            )?;
            self.spawn.encode(
                vec![
                    cove_graphics::rhi::BindingSetEntry::new(0, uniform),
                    cove_graphics::rhi::BindingSetEntry::new(
                        1,
                        cove_graphics::rhi::BindingResource::StorageBuffer {
                            buffer: input.buffer,
                            offset: input.offset,
                        },
                    ),
                    cove_graphics::rhi::BindingSetEntry::new(
                        2,
                        cove_graphics::rhi::BindingResource::StorageBuffer {
                            buffer: state.state,
                            offset: 0,
                        },
                    ),
                    cove_graphics::rhi::BindingSetEntry::new(
                        3,
                        cove_graphics::rhi::BindingResource::StorageBuffer {
                            buffer: state.metadata,
                            offset: 0,
                        },
                    ),
                ],
                self.groups(requested),
                commands,
            )?;
        }
        let uniforms = GPUParticleSimulationUniforms::from_batch(
            batch,
            delta_time,
            elapsed_time,
            count,
            state.event_capacity,
        );
        self.simulate.encode(
            vec![
                cove_graphics::rhi::BindingSetEntry::new(
                    0,
                    NativeUniformUpload::binding(uniforms, &self.device)?,
                ),
                cove_graphics::rhi::BindingSetEntry::new(
                    1,
                    cove_graphics::rhi::BindingResource::StorageBuffer {
                        buffer: state.state,
                        offset: 0,
                    },
                ),
                cove_graphics::rhi::BindingSetEntry::new(
                    2,
                    cove_graphics::rhi::BindingResource::StorageBuffer {
                        buffer: state.metadata,
                        offset: 0,
                    },
                ),
                cove_graphics::rhi::BindingSetEntry::new(
                    3,
                    cove_graphics::rhi::BindingResource::StorageBuffer {
                        buffer: state.events,
                        offset: 0,
                    },
                ),
            ],
            self.groups(count),
            commands,
        )?;
        self.clear.encode(
            vec![
                cove_graphics::rhi::BindingSetEntry::new(0, maintenance),
                cove_graphics::rhi::BindingSetEntry::new(
                    1,
                    cove_graphics::rhi::BindingResource::StorageBuffer {
                        buffer: state.compact,
                        offset: 0,
                    },
                ),
            ],
            self.groups(state.capacity),
            commands,
        )?;
        self.compact.encode(
            vec![
                cove_graphics::rhi::BindingSetEntry::new(0, maintenance),
                cove_graphics::rhi::BindingSetEntry::new(
                    1,
                    cove_graphics::rhi::BindingResource::StorageBuffer {
                        buffer: state.state,
                        offset: 0,
                    },
                ),
                cove_graphics::rhi::BindingSetEntry::new(
                    2,
                    cove_graphics::rhi::BindingResource::StorageBuffer {
                        buffer: state.compact,
                        offset: 0,
                    },
                ),
                cove_graphics::rhi::BindingSetEntry::new(
                    3,
                    cove_graphics::rhi::BindingResource::StorageBuffer {
                        buffer: state.metadata,
                        offset: 0,
                    },
                ),
            ],
            1,
            commands,
        )?;
        self.finalize.encode(
            vec![cove_graphics::rhi::BindingSetEntry::new(
                0,
                cove_graphics::rhi::BindingResource::StorageBuffer {
                    buffer: state.metadata,
                    offset: 0,
                },
            )],
            1,
            commands,
        )?;
        commands.copy_pass(|copy| {
            copy.copy_buffer(
                state.compact,
                0,
                state.state,
                0,
                state.capacity * std::mem::size_of::<crate::core::particles::particle_simulation_gpu_data::GPUParticleSimulationState>(),
            );
        });
        Ok(count)
    }

    fn groups(&self, count: usize) -> i64 {
        1i64.max(((count + self.workgroup_size - 1) / self.workgroup_size) as i64)
    }

    fn copy<T: Copy>(
        device: &Device,
        values: &[T],
        to: Buffer,
        commands: &mut CommandBuffer,
    ) -> RhiResult<()> {
        if values.is_empty() {
            return Ok(());
        }
        // SAFETY: `values` is a live slice of `Copy` values; the byte range is
        // fully initialized.
        let data = unsafe {
            std::slice::from_raw_parts(values.as_ptr().cast::<u8>(), std::mem::size_of_val(values))
        };
        let upload = device.upload_transient(data, 256)?;
        commands.copy_pass(|copy| {
            copy.copy_buffer(upload.buffer, upload.offset, to, 0, data.len());
        });
        Ok(())
    }

    fn copy_metadata(
        device: &Device,
        metadata: &GPUParticleSimulationMetadata,
        to: Buffer,
        commands: &mut CommandBuffer,
    ) -> RhiResult<()> {
        // SAFETY: `metadata` is a live `#[repr(C)]` value.
        let data = unsafe {
            std::slice::from_raw_parts(
                (metadata as *const GPUParticleSimulationMetadata).cast::<u8>(),
                std::mem::size_of::<GPUParticleSimulationMetadata>(),
            )
        };
        let upload = device.upload_transient(data, 256)?;
        commands.copy_pass(|copy| {
            copy.copy_buffer(upload.buffer, upload.offset, to, 0, data.len());
        });
        Ok(())
    }
}
