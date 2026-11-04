//! Stable GPU compaction feeds one indirect draw per authored texture/blend
//! batch.

use std::collections::BTreeMap;

use cove_graphics::rhi::{
    AttachmentBlendState, BindingLayout, BindingLayoutDescriptor, BindingResource, BindingSet,
    BindingSetDescriptor, BindingSetEntry, BlendFactor, BlendOperation, ColorAttachmentDescriptor,
    CommandBuffer, CompareOp, ComputePipeline, CullMode, DepthStencilState, Device,
    GraphicsPipeline, PipelineLayout, PipelineLayoutDescriptor, RasterizationState,
    RenderColorTarget, RenderDepthTarget, RenderPassDescriptor, RhiError, RhiResult, ScissorRect,
    ShaderModule, Texture, Viewport,
};
use diffuse_math::simd::simd_compat::{
    Float3, Float4, UInt4, simd_cross, simd_length, simd_normalize,
};
use diffuse_scene::rendering::render_scene::{
    ParticleBlendMode, ParticleRenderBatchPlan, RenderScene,
};

use crate::core::frame::render_camera_matrices::RenderCameraMatrices;
use crate::core::frame::render_packet::RenderDrawableSize;
use crate::core::particles::particle_gpu_data::{
    GPUParticleCullBatch, GPUParticleCullUniforms, GPUParticleIndirectDrawArgs,
    GPUParticleInstance, ParticleUniforms,
};
use crate::native::lighting::native_lighting_resources::NativeUniformUpload;
use crate::native::mesh::native_mesh_store::NativeMeshStore;
use crate::native::particles::native_particle_buffers::NativeParticleBuffers;
use crate::native::particles::native_particle_instances::NativeParticleSimulationRender;
use crate::native::particles::native_particle_textures::NativeParticleTextures;
use crate::native::passes::native_compute_pass::NativeComputePass;
use crate::native::targets::native_shader_library::NativeShaderLibrary;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
struct NativeParticlePipelineKey {
    hdr: bool,
    blend: ParticleBlendMode,
}

pub struct NativeParticleDraw {
    pub pipeline: GraphicsPipeline,
    pub bindings: BindingSet,
}

pub struct NativeParticleFrame {
    pub draws: Vec<NativeParticleDraw>,
    pub indirect: Buffer,
    pub candidates: usize,
}

pub struct NativeParticlePass {
    device: Device,
    bindings: BindingLayout,
    layout: PipelineLayout,
    vertex: ShaderModule,
    fragment: ShaderModule,
    cull: NativeComputePass,
    textures: NativeParticleTextures,
    pub buffers: NativeParticleBuffers,
    pipelines: BTreeMap<NativeParticlePipelineKey, GraphicsPipeline>,
}

impl NativeParticlePass {
    pub fn new(device: &Device) -> RhiResult<Self> {
        let mut cull_strides = BTreeMap::new();
        cull_strides.insert(
            1,
            std::mem::size_of::<crate::core::particles::particle_gpu_data::GPUParticleInstance>()
                as i64,
        );
        cull_strides.insert(2, std::mem::size_of::<GPUParticleCullBatch>() as i64);
        cull_strides.insert(
            3,
            std::mem::size_of::<crate::core::particles::particle_gpu_data::GPUParticleInstance>()
                as i64,
        );
        cull_strides.insert(
            4,
            std::mem::size_of::<
                crate::core::particles::particle_gpu_data::GPUParticleIndirectDrawArgs,
            >() as i64,
        );
        let cull =
            NativeComputePass::with_options(device, "particle_cull_compact", &cull_strides, None)?;
        let textures = NativeParticleTextures::new(device)?;
        let buffers = NativeParticleBuffers::new(device);
        let vs = NativeShaderLibrary::artifact(
            "particles",
            device.backend_api(),
            cove_graphics::rhi::ShaderStage::Vertex,
        )?;
        let fs = NativeShaderLibrary::artifact(
            "particles",
            device.backend_api(),
            cove_graphics::rhi::ShaderStage::Fragment,
        )?;
        let instance_binding_stride = vs
            .interface
            .bindings
            .iter()
            .find(|binding| binding.slot == 1)
            .map(|binding| binding.buffer.element_stride)
            .unwrap_or(-1);
        if instance_binding_stride
            != std::mem::size_of::<crate::core::particles::particle_gpu_data::GPUParticleInstance>()
                as i64
        {
            textures.destroy();
            cull.destroy();
            return Err(RhiError::layout_mismatch(
                "particle instance shader/host stride differs",
            ));
        }
        let bindings =
            device.make_binding_layout(cove_graphics::rhi::reflected_binding_layout(&[
                vs.clone(),
                fs.clone(),
            ])?);
        if bindings.is_err() {
            textures.destroy();
            cull.destroy();
        }
        let bindings = bindings?;
        let layout = device.make_pipeline_layout(PipelineLayoutDescriptor::new(vec![bindings]));
        if layout.is_err() {
            textures.destroy();
            cull.destroy();
        }
        let layout = layout?;
        let vertex = device.make_shader_module(vs.module_descriptor(&[])?)?;
        let fragment = match device.make_shader_module(fs.module_descriptor(&[])?) {
            Ok(fragment) => fragment,
            Err(error) => {
                device.destroy_shader_module(vertex);
                textures.destroy();
                cull.destroy();
                return Err(error);
            }
        };
        Ok(NativeParticlePass {
            device: device.clone(),
            bindings,
            layout,
            vertex,
            fragment,
            cull,
            textures,
            buffers,
            pipelines: BTreeMap::new(),
        })
    }

    /// Swift's `deinit` releases every resident object.
    pub fn destroy(&self) {
        for pipeline in self.pipelines.values() {
            self.device.destroy_graphics_pipeline(*pipeline);
        }
        self.device.destroy_shader_module(self.vertex);
        self.device.destroy_shader_module(self.fragment);
        self.cull.destroy();
        self.textures.destroy();
        self.buffers.destroy();
    }

    pub fn prepare(
        &mut self,
        scene: &RenderScene,
        matrices: &RenderCameraMatrices,
        hdr: bool,
        simulated: Option<&NativeParticleSimulationRender>,
        commands: &mut CommandBuffer,
    ) -> RhiResult<Option<NativeParticleFrame>> {
        let gpu_count = simulated.map_or(0, |simulated| simulated.instance_count);
        let count = gpu_count + scene.particles.len();
        if count == 0 {
            return Ok(None);
        }
        let mut batches = simulated
            .map(|simulated| simulated.batches.clone())
            .unwrap_or_default();
        for batch in &ParticleRenderBatchPlan::new(&scene.particles).batches {
            batches.push(
                diffuse_scene::rendering::render_scene::ParticleRenderBatch::new(
                    batch.key.clone(),
                    gpu_count as i64 + batch.start,
                    batch.count,
                ),
            );
        }
        self.buffers.ensure(count, batches.len())?;
        let Some(visible) = self.buffers.visible else {
            return Err(RhiError::OutOfMemory);
        };
        let Some(indirect) = self.buffers.indirect else {
            return Err(RhiError::OutOfMemory);
        };
        let instances: Vec<GPUParticleInstance> = scene
            .particles
            .iter()
            .map(GPUParticleInstance::from_particle)
            .collect();
        let source: BindingResource = if let Some(simulated) = simulated {
            let Some(source_buffer) = simulated.source.as_ref() else {
                return Err(RhiError::OutOfMemory);
            };
            if !instances.is_empty() {
                // SAFETY: `instances` is a live `Vec` of `#[repr(C)]` `Copy`
                // values, so the byte range is fully initialized.
                let instance_bytes = unsafe {
                    std::slice::from_raw_parts(
                        instances.as_ptr().cast::<u8>(),
                        instances.len()
                            * std::mem::size_of::<
                                crate::core::particles::particle_gpu_data::GPUParticleInstance,
                            >(),
                    )
                };
                let upload = self.device.upload_transient(instance_bytes, 256)?;
                commands.copy_pass(|copy| {
                    copy.copy_buffer(
                        upload.buffer,
                        upload.offset,
                        source_buffer.buffer,
                        gpu_count
                            * std::mem::size_of::<
                                crate::core::particles::particle_gpu_data::GPUParticleInstance,
                            >(),
                        instances.len()
                            * std::mem::size_of::<
                                crate::core::particles::particle_gpu_data::GPUParticleInstance,
                            >(),
                    );
                });
            }
            BindingResource::StorageBuffer {
                buffer: source_buffer.buffer,
                offset: 0,
            }
        } else {
            // SAFETY: same reasoning for the frame-owned upload.
            let instance_bytes = unsafe {
                std::slice::from_raw_parts(
                    instances.as_ptr().cast::<u8>(),
                    instances.len()
                        * std::mem::size_of::<
                            crate::core::particles::particle_gpu_data::GPUParticleInstance,
                        >(),
                )
            };
            let upload = self.device.upload_transient(instance_bytes, 256)?;
            BindingResource::StorageBuffer {
                buffer: upload.buffer,
                offset: upload.offset,
            }
        };
        let ranges: Vec<GPUParticleCullBatch> = batches
            .iter()
            .map(|batch| GPUParticleCullBatch {
                source_start: batch.start as u32,
                source_count: batch.count as u32,
                output_start: batch.start as u32,
                padding: 0,
            })
            .collect();
        // SAFETY: `ranges` is a live `Vec` of `#[repr(C)]` `Copy` values.
        let range_bytes = unsafe {
            std::slice::from_raw_parts(
                ranges.as_ptr().cast::<u8>(),
                ranges.len() * std::mem::size_of::<GPUParticleCullBatch>(),
            )
        };
        let descriptors = self.device.upload_transient(range_bytes, 256)?;
        self.cull.encode(
            vec![
                BindingSetEntry::new(
                    0,
                    NativeUniformUpload::binding(
                        GPUParticleCullUniforms {
                            view_proj: matrices.view_projection,
                            params: UInt4::new(batches.len() as u32, 0, 0, 0),
                        },
                        &self.device,
                    )?,
                ),
                BindingSetEntry::new(1, source),
                BindingSetEntry::new(
                    2,
                    BindingResource::StorageBuffer {
                        buffer: descriptors.buffer,
                        offset: descriptors.offset,
                    },
                ),
                BindingSetEntry::new(
                    3,
                    BindingResource::StorageBuffer {
                        buffer: visible,
                        offset: 0,
                    },
                ),
                BindingSetEntry::new(
                    4,
                    BindingResource::StorageBuffer {
                        buffer: indirect,
                        offset: 0,
                    },
                ),
            ],
            batches.len() as i64,
            commands,
        )?;
        let forward = simd_normalize(scene.camera.target - scene.camera.eye);
        let cross = simd_cross(forward, scene.camera.up);
        let length = simd_length(cross);
        let right = if length > 1e-5 {
            cross / length
        } else {
            Float3::new(1.0, 0.0, 0.0)
        };
        let uniforms = NativeUniformUpload::binding(
            ParticleUniforms {
                view_proj: matrices.view_projection,
                camera_right: Float4::new(right.x, right.y, right.z, 0.0),
                camera_up: Float4::new(
                    simd_cross(right, forward).x,
                    simd_cross(right, forward).y,
                    simd_cross(right, forward).z,
                    0.0,
                ),
                camera_forward: Float4::new(forward.x, forward.y, forward.z, 0.0),
            },
            &self.device,
        )?;
        let mut draws = Vec::with_capacity(batches.len());
        for batch in &batches {
            let pipeline = self.pipeline_for(hdr, batch.key.blend_mode)?;
            let texture = self.textures.texture(batch.key.texture_path.as_deref());
            let set = self.device.make_binding_set(
                self.bindings,
                BindingSetDescriptor::new(vec![
                    BindingSetEntry::new(0, uniforms),
                    BindingSetEntry::new(
                        1,
                        BindingResource::StorageBuffer {
                            buffer: visible,
                            offset: 0,
                        },
                    ),
                    BindingSetEntry::new(2, BindingResource::Sampler(self.textures.sampler)),
                    BindingSetEntry::new(3, BindingResource::Texture(texture)),
                    BindingSetEntry::new(
                        4,
                        NativeUniformUpload::binding(
                            UInt4::new(batch.start as u32, 0, 0, 0),
                            &self.device,
                        )?,
                    ),
                ]),
            )?;
            draws.push(NativeParticleDraw {
                pipeline,
                bindings: set,
            });
        }
        Ok(Some(NativeParticleFrame {
            draws,
            indirect,
            candidates: count,
        }))
    }

    pub fn encode(
        &self,
        frame: &NativeParticleFrame,
        size: RenderDrawableSize,
        color: Texture,
        depth: Texture,
        commands: &mut CommandBuffer,
    ) {
        commands.render_pass(
            RenderPassDescriptor::new(vec![RenderColorTarget::new(color)])
                .with_depth(RenderDepthTarget::new(depth)),
            |pass| {
                pass.set_viewport(Viewport::new(size.width as f64, size.height as f64));
                pass.set_scissor(ScissorRect::new(size.width as i64, size.height as i64));
                for (index, draw) in frame.draws.iter().enumerate() {
                    pass.set_pipeline(draw.pipeline);
                    pass.set_binding_set(draw.bindings, 0, Vec::new());
                    pass.draw_indirect(
                        frame.indirect,
                        index * std::mem::size_of::<crate::core::particles::particle_gpu_data::GPUParticleIndirectDrawArgs>(),
                    );
                }
            },
        );
    }

    fn pipeline_for(&mut self, hdr: bool, blend: ParticleBlendMode) -> RhiResult<GraphicsPipeline> {
        let key = NativeParticlePipelineKey { hdr, blend };
        if let Some(existing) = self.pipelines.get(&key) {
            return Ok(*existing);
        }
        let state = if blend == ParticleBlendMode::Alpha {
            AttachmentBlendState::ALPHA_BLEND
        } else {
            AttachmentBlendState {
                enabled: true,
                source_color_blend_factor: BlendFactor::One,
                destination_color_blend_factor: BlendFactor::One,
                color_blend_operation: BlendOperation::Add,
                source_alpha_blend_factor: BlendFactor::Zero,
                destination_alpha_blend_factor: BlendFactor::One,
                alpha_blend_operation: BlendOperation::Add,
            }
        };
        let result =
            self.device
                .make_graphics_pipeline(cove_graphics::rhi::GraphicsPipelineDescriptor {
                    color_attachments: vec![ColorAttachmentDescriptor {
                        format: if hdr {
                            cove_graphics::rhi::TextureFormat::Rgba16Float
                        } else {
                            cove_graphics::rhi::TextureFormat::Bgra8Unorm
                        },
                        blend: state,
                    }],
                    depth_format: None,
                    depth_stencil: Some(DepthStencilState {
                        depth_compare: CompareOp::LessOrEqual,
                        depth_write_enabled: false,
                    }),
                    fragment: Some(self.fragment),
                    label: Some("native-particles"),
                    layout: self.layout,
                    primitive: cove_graphics::rhi::PrimitiveType::TriangleList,
                    rasterization: RasterizationState {
                        cull_mode: CullMode::None,
                        ..RasterizationState::default()
                    },
                    sample_count: 1,
                    stencil_format: None,
                    vertex: self.vertex,
                    vertex_layout: None,
                })?;
        self.pipelines.insert(key, result);
        Ok(result)
    }

    pub fn prewarm(&mut self, hdr: bool) -> RhiResult<()> {
        for blend in ParticleBlendMode::ALL {
            self.pipeline_for(hdr, blend)?;
        }
        Ok(())
    }
}
