//! NativeRHI mesh pass: preparation resolves visibility/materials and
//! allocates only frame-owned instance data; pipeline variants and immutable
//! layouts remain resident.

use std::collections::BTreeMap;

use cove_graphics::rhi::{
    BindingLayout, BindingResource, BindingSet, BindingSetDescriptor, BindingSetEntry,
    ColorAttachmentDescriptor, CommandBuffer, CompareOp, CullMode, DepthStencilState, Device,
    DrawIndexedArguments, FrontWinding, GraphicsPipeline, PipelineLayout, PipelineLayoutDescriptor,
    RenderColorTarget, RenderDepthTarget, RenderPassDescriptor, RhiError, RhiResult, ScissorRect,
    VertexLayoutDescriptor, Viewport,
};
use diffuse_scene::entity_id::EntityID;
use diffuse_scene::rendering::render_scene::MaterialAlphaMode;

use crate::core::frame::render_camera_matrices::RenderCameraMatrices;
use crate::core::frame::render_packet::{RenderDrawableSize, RenderPacket};
use crate::core::frame::render_uniforms::StylizedCharacterUniforms;
use crate::core::mesh::mesh_instance_uniforms::MeshInstanceUniforms;
use crate::core::mesh::mesh_outline_policy::MeshOutlinePolicy;
use crate::core::mesh::mesh_visibility_plan::MeshVisibilityPlan;
use crate::core::render_settings::RenderSettings;
use crate::native::lighting::native_lighting_resources::{
    NativeLightingBindings, NativeUniformUpload,
};
use crate::native::mesh::native_mesh_batch_planner::{
    NativeMeshBatch, NativeMeshBatchKey, NativeMeshBatchPlanner,
};
use crate::native::mesh::native_mesh_shaders::{NativeMeshShaderRole, NativeMeshShaders};
use crate::native::mesh::native_mesh_store::{NativeMeshGeometry, NativeMeshStore};
use crate::native::mesh::native_mesh_vertex_layout::NativeMeshVertexLayout;
use crate::native::mesh::native_skin_bindings::NativeSkinBindings;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum NativeMeshPassKind {
    Color,
    Depth,
    Outline,
}

#[derive(Clone)]
pub struct NativePreparedMeshDraw {
    pub batch: NativeMeshBatch,
    pub bindings: BindingSet,
    /// Per-draw offsets for the layout's dynamic slots, ordered by ascending
    /// slot (draw/instances, scene lights, shadows, style).
    pub dynamic_offsets: Vec<u32>,
    pub base_pipeline: GraphicsPipeline,
    pub depth_pipeline: Option<GraphicsPipeline>,
    pub outline_pipeline: Option<GraphicsPipeline>,
}

impl NativePreparedMeshDraw {
    pub fn pipeline(&self, kind: NativeMeshPassKind) -> GraphicsPipeline {
        match kind {
            NativeMeshPassKind::Color => self.base_pipeline,
            NativeMeshPassKind::Depth => self
                .depth_pipeline
                .expect("depth pipeline exists for the depth pass"),
            NativeMeshPassKind::Outline => self
                .outline_pipeline
                .expect("outline pipeline exists for the outline pass"),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
struct NativeMeshPipelineKey {
    kind: NativeMeshPassKind,
    stylized: bool,
    hdr: bool,
    mirrored: bool,
    double_sided: bool,
    blend: bool,
}

/// A ring-backed uniform block resolved to its persistent chunk buffer and the
/// offset of this frame's data. The descriptor binds the chunk at offset 0 and
/// the per-frame offset is supplied as a dynamic offset at bind time.
#[derive(Clone, Copy)]
struct NativeRingBlock {
    buffer: cove_graphics::rhi::Buffer,
    offset: u32,
    size: usize,
}

fn ring_block(resource: &BindingResource) -> Result<NativeRingBlock, RhiError> {
    if let BindingResource::UniformBuffer {
        buffer,
        offset,
        size: Some(size),
    } = resource
    {
        return Ok(NativeRingBlock {
            buffer: *buffer,
            offset: *offset as u32,
            size: *size,
        });
    }
    Err(RhiError::layout_mismatch(
        "expected a bounded ring uniform block",
    ))
}

pub struct NativeMeshPass {
    device: Device,
    shaders: NativeMeshShaders,
    pipeline_layout: PipelineLayout,
    pipelines: BTreeMap<NativeMeshPipelineKey, GraphicsPipeline>,
}

impl NativeMeshPass {
    pub fn new(device: &Device) -> RhiResult<Self> {
        let shaders = NativeMeshShaders::new(device)?;
        let pipeline_layout =
            device.make_pipeline_layout(PipelineLayoutDescriptor::new(vec![shaders.bindings]))?;
        Ok(NativeMeshPass {
            device: device.clone(),
            shaders,
            pipeline_layout,
            pipelines: BTreeMap::new(),
        })
    }

    /// Swift's `deinit` destroys the pipeline variants.
    pub fn destroy(&self) {
        for pipeline in self.pipelines.values() {
            self.device.destroy_graphics_pipeline(*pipeline);
        }
        self.shaders.destroy();
    }

    pub fn prepare(
        &mut self,
        packet: &RenderPacket,
        store: &NativeMeshStore,
        matrices: &RenderCameraMatrices,
        depth_prepass: bool,
        hdr: bool,
        lighting: &NativeLightingBindings,
        skin: &NativeSkinBindings,
        deformables: &BTreeMap<EntityID, NativeMeshGeometry>,
    ) -> RhiResult<(Vec<NativePreparedMeshDraw>, MeshVisibilityPlan)> {
        let prepared = NativeMeshBatchPlanner::prepare(
            packet,
            store,
            matrices.view_projection,
            deformables,
            false,
        )?;
        let style = ring_block(&NativeUniformUpload::binding(
            StylizedCharacterUniforms::from_style(&packet.render_settings.stylization.style),
            &self.device,
        )?)?;
        let lights = ring_block(&lighting.lights)?;
        let shadows = ring_block(&lighting.shadows)?;
        let mut draws: Vec<NativePreparedMeshDraw> = Vec::new();
        for batch in &prepared.0 {
            let mesh = &batch.mesh;
            let key = &batch.key;
            // SAFETY: the slice is a live `Vec<MeshInstanceUniforms>` of
            // `#[repr(C)]` `Copy` values, so the byte range is initialized.
            let bytes = unsafe {
                std::slice::from_raw_parts(
                    batch.uniforms.as_ptr().cast::<u8>(),
                    batch.uniforms.len() * std::mem::size_of::<MeshInstanceUniforms>(),
                )
            };
            let instance = self.device.upload_transient(bytes, 256)?;
            let instance_offset = instance.offset as u32;
            let base_texture = key
                .base_texture
                .and_then(|texture_index| mesh.textures.get(&texture_index).copied())
                .unwrap_or(store.fallbacks[0]);
            let normal_texture = key
                .normal_texture
                .and_then(|texture_index| mesh.textures.get(&texture_index).copied())
                .unwrap_or(store.fallbacks[1]);
            let mr_texture = key
                .mr_texture
                .and_then(|texture_index| mesh.textures.get(&texture_index).copied())
                .unwrap_or(store.fallbacks[2]);
            let bindings = self.device.make_binding_set(
                self.shaders.bindings,
                BindingSetDescriptor::new(vec![
                    BindingSetEntry::new(
                        0,
                        BindingResource::UniformBuffer {
                            buffer: instance.buffer,
                            offset: 0,
                            size: Some(std::mem::size_of::<MeshInstanceUniforms>()),
                        },
                    ),
                    BindingSetEntry::new(
                        1,
                        BindingResource::StorageBuffer {
                            buffer: instance.buffer,
                            offset: 0,
                        },
                    ),
                    BindingSetEntry::new(2, BindingResource::Sampler(store.sampler)),
                    BindingSetEntry::new(3, BindingResource::Texture(base_texture)),
                    BindingSetEntry::new(
                        4,
                        BindingResource::UniformBuffer {
                            buffer: lights.buffer,
                            offset: 0,
                            size: Some(lights.size),
                        },
                    ),
                    BindingSetEntry::new(5, BindingResource::Texture(normal_texture)),
                    BindingSetEntry::new(6, BindingResource::Texture(mr_texture)),
                    BindingSetEntry::new(
                        7,
                        BindingResource::UniformBuffer {
                            buffer: shadows.buffer,
                            offset: 0,
                            size: Some(shadows.size),
                        },
                    ),
                    BindingSetEntry::new(8, BindingResource::Sampler(lighting.sampler)),
                    BindingSetEntry::new(9, BindingResource::Texture(lighting.atlas)),
                    BindingSetEntry::new(10, BindingResource::Texture(lighting.environment)),
                    BindingSetEntry::new(11, skin.palette(batch.skin_entity).parameters),
                    BindingSetEntry::new(12, skin.palette(batch.skin_entity).matrices),
                    BindingSetEntry::new(
                        13,
                        BindingResource::UniformBuffer {
                            buffer: style.buffer,
                            offset: 0,
                            size: Some(style.size),
                        },
                    ),
                ]),
            )?;
            let dynamic_offsets: Vec<u32> = vec![
                instance_offset,
                instance_offset,
                lights.offset,
                shadows.offset,
                style.offset,
            ];
            let stylized = packet.render_settings.stylization.enabled;
            let base = self.pipeline_for(key, NativeMeshPassKind::Color, hdr, stylized)?;
            let depth = if depth_prepass && key.mode != MaterialAlphaMode::Blend {
                Some(self.pipeline_for(key, NativeMeshPassKind::Depth, hdr, false)?)
            } else {
                None
            };
            let outline = if stylized
                && key.mode != MaterialAlphaMode::Blend
                && MeshOutlinePolicy::includes(Some(mesh.geometry.bounds))
            {
                Some(self.pipeline_for(key, NativeMeshPassKind::Outline, hdr, false)?)
            } else {
                None
            };
            draws.push(NativePreparedMeshDraw {
                batch: batch.clone(),
                bindings,
                dynamic_offsets,
                base_pipeline: base,
                depth_pipeline: depth,
                outline_pipeline: outline,
            });
        }
        Ok((draws, prepared.1))
    }

    pub fn encode(
        &self,
        draws: &[NativePreparedMeshDraw],
        size: RenderDrawableSize,
        color: Option<RenderColorTarget>,
        depth: RenderDepthTarget,
        kind: NativeMeshPassKind,
        commands: &mut CommandBuffer,
    ) {
        let mut descriptor =
            RenderPassDescriptor::new(color.map(|color| vec![color]).unwrap_or_default());
        descriptor = descriptor.with_depth(depth);
        commands.render_pass(descriptor, |pass| {
            pass.set_viewport(Viewport::new(size.width as f64, size.height as f64));
            pass.set_scissor(ScissorRect::new(size.width as i64, size.height as i64));
            for draw in draws {
                pass.set_pipeline(draw.pipeline(kind));
                pass.set_binding_set(draw.bindings, 0, draw.dynamic_offsets.clone());
                pass.set_vertex_buffer(draw.batch.geometry.vertices, 0, 0);
                pass.set_index_buffer(
                    draw.batch.geometry.indices,
                    0,
                    cove_graphics::rhi::IndexType::Uint32,
                );
                pass.draw_indexed(DrawIndexedArguments {
                    index_count: draw.batch.key.index_count,
                    instance_count: draw.batch.uniforms.len() as i64,
                    first_index: draw.batch.key.first_index,
                    ..DrawIndexedArguments::new(draw.batch.key.index_count)
                });
            }
        });
    }

    fn pipeline_for(
        &mut self,
        key: &NativeMeshBatchKey,
        kind: NativeMeshPassKind,
        hdr: bool,
        stylized: bool,
    ) -> RhiResult<GraphicsPipeline> {
        let variant = NativeMeshPipelineKey {
            kind,
            stylized,
            hdr,
            mirrored: key.mirrored,
            double_sided: key.double_sided,
            blend: key.mode == MaterialAlphaMode::Blend,
        };
        self.pipeline(variant)
    }

    pub fn prewarm(&mut self, settings: &RenderSettings) -> RhiResult<()> {
        for mirrored in [false, true] {
            for double_sided in [false, true] {
                for blend in [false, true] {
                    self.pipeline(NativeMeshPipelineKey {
                        kind: NativeMeshPassKind::Color,
                        stylized: settings.stylization.enabled,
                        hdr: settings.shading.pbr,
                        mirrored,
                        double_sided,
                        blend,
                    })?;
                    if !blend && settings.shading.depth_prepass {
                        self.pipeline(NativeMeshPipelineKey {
                            kind: NativeMeshPassKind::Depth,
                            stylized: false,
                            hdr: settings.shading.pbr,
                            mirrored,
                            double_sided,
                            blend: false,
                        })?;
                    }
                    if !blend && settings.stylization.enabled {
                        self.pipeline(NativeMeshPipelineKey {
                            kind: NativeMeshPassKind::Outline,
                            stylized: false,
                            hdr: settings.shading.pbr,
                            mirrored,
                            double_sided,
                            blend: false,
                        })?;
                    }
                }
            }
        }
        Ok(())
    }

    fn pipeline(&mut self, variant: NativeMeshPipelineKey) -> RhiResult<GraphicsPipeline> {
        let kind = variant.kind;
        let hdr = variant.hdr;
        let stylized = variant.stylized;
        if let Some(existing) = self.pipelines.get(&variant) {
            return Ok(*existing);
        }
        let vertex = self.shaders.module(if kind == NativeMeshPassKind::Outline {
            NativeMeshShaderRole::OutlineVertex
        } else {
            NativeMeshShaderRole::Vertex
        });
        let fragment = self.shaders.module(match kind {
            NativeMeshPassKind::Outline => NativeMeshShaderRole::OutlineFragment,
            NativeMeshPassKind::Depth => NativeMeshShaderRole::Depth,
            NativeMeshPassKind::Color => {
                if stylized {
                    NativeMeshShaderRole::Stylized
                } else {
                    NativeMeshShaderRole::Color
                }
            }
        });
        let label = match kind {
            NativeMeshPassKind::Color => "native-mesh-color",
            NativeMeshPassKind::Depth => "native-mesh-depth",
            NativeMeshPassKind::Outline => "native-mesh-outline",
        };
        let pipeline =
            self.device
                .make_graphics_pipeline(cove_graphics::rhi::GraphicsPipelineDescriptor {
                    color_attachments: if kind == NativeMeshPassKind::Depth {
                        Vec::new()
                    } else {
                        vec![ColorAttachmentDescriptor {
                            format: if hdr {
                                cove_graphics::rhi::TextureFormat::Rgba16Float
                            } else {
                                cove_graphics::rhi::TextureFormat::Bgra8Unorm
                            },
                            blend: if variant.blend {
                                cove_graphics::rhi::AttachmentBlendState::ALPHA_BLEND
                            } else {
                                cove_graphics::rhi::AttachmentBlendState::OPAQUE
                            },
                        }]
                    },
                    depth_format: None,
                    depth_stencil: Some(DepthStencilState {
                        depth_compare: if kind == NativeMeshPassKind::Depth {
                            CompareOp::Less
                        } else {
                            CompareOp::LessOrEqual
                        },
                        depth_write_enabled: !variant.blend && kind != NativeMeshPassKind::Outline,
                    }),
                    fragment: Some(fragment),
                    label: Some(label),
                    layout: self.pipeline_layout,
                    primitive: cove_graphics::rhi::PrimitiveType::TriangleList,
                    rasterization: cove_graphics::rhi::RasterizationState {
                        cull_mode: match kind {
                            NativeMeshPassKind::Outline => CullMode::Front,
                            _ if variant.double_sided => CullMode::None,
                            _ => CullMode::Back,
                        },
                        front_winding: if variant.mirrored {
                            FrontWinding::Clockwise
                        } else {
                            FrontWinding::CounterClockwise
                        },
                        fill_mode: cove_graphics::rhi::FillMode::Fill,
                    },
                    sample_count: 1,
                    stencil_format: None,
                    vertex,
                    vertex_layout: Some(VertexLayoutDescriptor::new(
                        NativeMeshVertexLayout::descriptor(),
                        NativeMeshVertexLayout::buffer_layouts(),
                    )),
                })?;
        self.pipelines.insert(variant, pipeline);
        Ok(pipeline)
    }
}
