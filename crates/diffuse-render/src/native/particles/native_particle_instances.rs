//! GPU particle source/sort buffers and the sort + instance-conversion
//! kernels. Sort and conversion programs share a physical workgroup size with
//! simulation.

use cove_graphics::rhi::{
    BindingResource, Buffer, BufferDescriptor, BufferUsage, CommandBuffer, Device, RhiResult,
};
use diffuse_math::simd::simd_compat::Float3;
use diffuse_scene::rendering::render_scene::{ParticleRenderBatch, RenderParticleSimulationBatch};

use crate::core::particles::particle_instance_gpu_data::{
    GPUParticleAppearance, GPUParticleAppearanceData, GPUParticleCurveKeyframe,
    GPUParticleSimulationInstanceEncodeReport, GPUParticleSimulationInstanceUniforms,
    GPUParticleSimulationSortEncodeReport, GPUParticleSortItem, GPUParticleSortPlan,
    GPUParticleSortPrepareUniforms,
};
use crate::core::particles::particle_simulation_gpu_data::GPUParticleSimulationState;
use crate::native::lighting::native_lighting_resources::NativeUniformUpload;
use crate::native::passes::native_compute_pass::NativeComputePass;

pub struct NativeParticleSourceBuffer {
    pub device: Device,
    pub buffer: Buffer,
    pub capacity: usize,
}

impl NativeParticleSourceBuffer {
    pub fn new(device: &Device, capacity: usize) -> RhiResult<Self> {
        let buffer =
            device.make_buffer(BufferDescriptor::labelled(
                capacity
                    * std::mem::size_of::<
                        crate::core::particles::particle_gpu_data::GPUParticleInstance,
                    >(),
                BufferUsage::STORAGE_READ
                    | BufferUsage::STORAGE_WRITE
                    | BufferUsage::TRANSFER_SOURCE
                    | BufferUsage::TRANSFER_DESTINATION,
                "native-particle-source",
            ))?;
        Ok(NativeParticleSourceBuffer {
            device: device.clone(),
            buffer,
            capacity,
        })
    }

    /// Swift's `deinit` destroys the buffer.
    pub fn destroy(&self) {
        self.device.destroy_buffer(self.buffer);
    }
}

pub struct NativeParticleSortBuffer {
    pub device: Device,
    pub buffer: Buffer,
    pub capacity: usize,
}

impl NativeParticleSortBuffer {
    pub fn new(device: &Device, count: usize) -> RhiResult<Self> {
        let capacity = GPUParticleSortPlan::capacity_for(count);
        let buffer = device.make_buffer(BufferDescriptor::labelled(
            capacity
                * std::mem::size_of::<
                    crate::core::particles::particle_instance_gpu_data::GPUParticleSortItem,
                >(),
            BufferUsage::STORAGE_READ | BufferUsage::STORAGE_WRITE | BufferUsage::TRANSFER_SOURCE,
            "native-particle-sort",
        ))?;
        Ok(NativeParticleSortBuffer {
            device: device.clone(),
            buffer,
            capacity,
        })
    }

    /// Swift's `deinit` destroys the buffer.
    pub fn destroy(&self) {
        self.device.destroy_buffer(self.buffer);
    }
}

#[derive(Default)]
pub struct NativeParticleSimulationRender {
    pub source: Option<NativeParticleSourceBuffer>,
    pub batches: Vec<ParticleRenderBatch>,
    pub instance_count: usize,
}

pub struct NativeParticleInstanceKernels {
    device: Device,
    workgroup_size: usize,
    prepare: NativeComputePass,
    bitonic: NativeComputePass,
    convert: NativeComputePass,
}

impl NativeParticleInstanceKernels {
    pub fn new(device: &Device, workgroup_size: usize) -> RhiResult<Self> {
        let state_stride = std::mem::size_of::<
            crate::core::particles::particle_simulation_gpu_data::GPUParticleSimulationState,
        >() as i64;
        let item_stride = std::mem::size_of::<
            crate::core::particles::particle_instance_gpu_data::GPUParticleSortItem,
        >() as i64;
        let mut prepare_strides = std::collections::BTreeMap::new();
        prepare_strides.insert(1, state_stride);
        prepare_strides.insert(2, item_stride);
        let prepare = NativeComputePass::with_options(
            device,
            "particle_sort_prepare",
            &prepare_strides,
            Some(workgroup_size),
        )?;
        let mut bitonic_strides = std::collections::BTreeMap::new();
        bitonic_strides.insert(1, item_stride);
        let bitonic = NativeComputePass::with_options(
            device,
            "particle_sort_bitonic",
            &bitonic_strides,
            Some(workgroup_size),
        )?;
        let mut convert_strides = std::collections::BTreeMap::new();
        convert_strides.insert(1, state_stride);
        convert_strides.insert(
            2,
            std::mem::size_of::<crate::core::particles::particle_gpu_data::GPUParticleInstance>()
                as i64,
        );
        convert_strides.insert(3, item_stride);
        convert_strides.insert(
            4,
            std::mem::size_of::<
                crate::core::particles::particle_instance_gpu_data::GPUParticleAppearance,
            >() as i64,
        );
        convert_strides.insert(
            5,
            std::mem::size_of::<
                crate::core::particles::particle_instance_gpu_data::GPUParticleCurveKeyframe,
            >() as i64,
        );
        let convert = NativeComputePass::with_options(
            device,
            "particle_sim_to_instance",
            &convert_strides,
            Some(workgroup_size),
        )?;
        Ok(NativeParticleInstanceKernels {
            device: device.clone(),
            workgroup_size,
            prepare,
            bitonic,
            convert,
        })
    }

    /// Swift's `deinit` destroys the three programs.
    pub fn destroy(&self) {
        self.convert.destroy();
        self.bitonic.destroy();
        self.prepare.destroy();
    }

    #[allow(clippy::too_many_arguments)]
    pub fn encode(
        &self,
        batch: &RenderParticleSimulationBatch,
        state: &crate::native::particles::native_particle_simulation::NativeParticleSimulationState,
        sort: &NativeParticleSortBuffer,
        camera_eye: Float3,
        source: &NativeParticleSourceBuffer,
        base_instance: usize,
        commands: &mut CommandBuffer,
    ) -> RhiResult<GPUParticleSimulationInstanceEncodeReport> {
        let plan = GPUParticleSortPlan::new(batch.render_particle_count() as usize);
        let sort_groups = self.groups(plan.capacity);
        self.prepare.encode(
            vec![
                cove_graphics::rhi::BindingSetEntry::new(
                    0,
                    NativeUniformUpload::binding(
                        GPUParticleSortPrepareUniforms::from_batch(
                            batch,
                            camera_eye,
                            plan.capacity,
                        ),
                        &self.device,
                    )?,
                ),
                cove_graphics::rhi::BindingSetEntry::new(
                    1,
                    BindingResource::StorageBuffer {
                        buffer: state.state,
                        offset: 0,
                    },
                ),
                cove_graphics::rhi::BindingSetEntry::new(
                    2,
                    BindingResource::StorageBuffer {
                        buffer: sort.buffer,
                        offset: 0,
                    },
                ),
            ],
            sort_groups,
            commands,
        )?;
        for stage in &plan.stages {
            self.bitonic.encode(
                vec![
                    cove_graphics::rhi::BindingSetEntry::new(
                        0,
                        NativeUniformUpload::binding(stage.uniforms(plan.capacity), &self.device)?,
                    ),
                    cove_graphics::rhi::BindingSetEntry::new(
                        1,
                        BindingResource::StorageBuffer {
                            buffer: sort.buffer,
                            offset: 0,
                        },
                    ),
                ],
                sort_groups,
                commands,
            )?;
        }
        let appearance = GPUParticleAppearanceData::from_batch(batch);
        // SAFETY: `appearances` is a live `Vec` of `#[repr(C)]` `Copy` values.
        let appearance_bytes = unsafe {
            std::slice::from_raw_parts(
                appearance.appearances.as_ptr().cast::<u8>(),
                appearance.appearances.len()
                    * std::mem::size_of::<
                        crate::core::particles::particle_instance_gpu_data::GPUParticleAppearance,
                    >(),
            )
        };
        let palette = self.device.upload_transient(appearance_bytes, 256)?;
        // A valid storage binding is required even when neither curve reads keys.
        let keys: Vec<GPUParticleCurveKeyframe> = if appearance.keyframes.is_empty() {
            vec![GPUParticleCurveKeyframe {
                time_value: diffuse_math::simd::simd_compat::Float4::ZERO,
            }]
        } else {
            appearance.keyframes.clone()
        };
        // SAFETY: same reasoning for the keyframe vector.
        let key_bytes = unsafe {
            std::slice::from_raw_parts(
                keys.as_ptr().cast::<u8>(),
                keys.len() * std::mem::size_of::<crate::core::particles::particle_instance_gpu_data::GPUParticleCurveKeyframe>(),
            )
        };
        let key_upload = self.device.upload_transient(key_bytes, 256)?;
        let instance_groups = self.groups(batch.render_instance_count() as usize);
        self.convert.encode(
            vec![
                cove_graphics::rhi::BindingSetEntry::new(
                    0,
                    NativeUniformUpload::binding(
                        GPUParticleSimulationInstanceUniforms::from_batch(
                            batch,
                            base_instance,
                            &appearance,
                        ),
                        &self.device,
                    )?,
                ),
                cove_graphics::rhi::BindingSetEntry::new(
                    1,
                    BindingResource::StorageBuffer {
                        buffer: state.state,
                        offset: 0,
                    },
                ),
                cove_graphics::rhi::BindingSetEntry::new(
                    2,
                    BindingResource::StorageBuffer {
                        buffer: source.buffer,
                        offset: 0,
                    },
                ),
                cove_graphics::rhi::BindingSetEntry::new(
                    3,
                    BindingResource::StorageBuffer {
                        buffer: sort.buffer,
                        offset: 0,
                    },
                ),
                cove_graphics::rhi::BindingSetEntry::new(
                    4,
                    BindingResource::StorageBuffer {
                        buffer: palette.buffer,
                        offset: palette.offset,
                    },
                ),
                cove_graphics::rhi::BindingSetEntry::new(
                    5,
                    BindingResource::StorageBuffer {
                        buffer: key_upload.buffer,
                        offset: key_upload.offset,
                    },
                ),
            ],
            instance_groups,
            commands,
        )?;
        Ok(GPUParticleSimulationInstanceEncodeReport {
            render_instance_count: batch.render_instance_count() as usize,
            instance_dispatch_workgroups: instance_groups,
            sort_report: GPUParticleSimulationSortEncodeReport {
                pass_count: plan.stages.len() + 1,
                item_count: batch.render_particle_count() as usize,
                padded_item_count: plan.capacity,
                dispatch_workgroups: sort_groups * (plan.stages.len() + 1),
            },
        })
    }

    fn groups(&self, count: usize) -> i64 {
        ((count + self.workgroup_size - 1) / self.workgroup_size) as i64
    }
}
