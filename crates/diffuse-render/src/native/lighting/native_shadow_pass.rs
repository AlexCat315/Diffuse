//! A color depth atlas preserves the existing five-tap shadow filtering
//! contract.

use std::sync::Arc;

use std::collections::BTreeMap;

use cove_graphics::rhi::{
    BindingLayout, BindingLayoutDescriptor, BindingResource, BindingSet, BindingSetDescriptor,
    BindingSetEntry, ColorAttachmentDescriptor, CommandBuffer, CompareOp, CullMode,
    DepthStencilState, Device, DrawIndexedArguments, FrontWinding, GraphicsPipeline,
    PipelineLayout, PipelineLayoutDescriptor, RasterizationState, RenderColorTarget,
    RenderDepthTarget, RenderPassDescriptor, RhiResult, ScissorRect, ShaderModule, Texture,
    TextureDescriptor, TextureFormat, TextureUsage, VertexLayoutDescriptor, Viewport,
};
use diffuse_math::simd::simd_compat::MATRIX_IDENTITY_FLOAT4X4;
use diffuse_scene::entity_id::EntityID;

use crate::core::frame::render_packet::RenderPacket;
use crate::core::lighting::shadow_atlas_plan::{ShadowAtlasLight, ShadowAtlasPlan};
use crate::core::lighting::uniforms::ShadowRenderUniforms;
use crate::core::mesh::mesh_instance_uniforms::MeshInstanceUniforms;
use crate::native::lighting::native_lighting_resources::NativeUniformUpload;
use crate::native::mesh::native_mesh_batch_planner::{
    NativeMeshBatch, NativeMeshBatchKey, NativeMeshBatchPlanner,
};
use crate::native::mesh::native_mesh_store::{NativeMeshGeometry, NativeMeshStore};
use crate::native::mesh::native_mesh_vertex_layout::NativeMeshVertexLayout;
use crate::native::mesh::native_skin_bindings::NativeSkinBindings;
use crate::native::targets::native_shader_library::NativeShaderLibrary;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
struct NativeShadowPipelineKey {
    mirrored: bool,
    double_sided: bool,
}

pub struct NativeShadowDraw {
    pub batch: NativeMeshBatch,
    pub bindings: BindingSet,
    pub pipeline: GraphicsPipeline,
}

pub struct NativeShadowTile {
    pub light: ShadowAtlasLight,
    pub draws: Vec<NativeShadowDraw>,
}

struct NativeShadowTargets {
    size: u32,
    color: Texture,
    depth: Texture,
}

impl NativeShadowTargets {
    fn destroy(&self, device: &Arc<Device>) {
        device.destroy_texture(self.color);
        device.destroy_texture(self.depth);
    }
}

pub struct NativeShadowPass {
    device: Arc<Device>,
    bindings: BindingLayout,
    layout: PipelineLayout,
    vertex: ShaderModule,
    fragment: ShaderModule,
    pipelines: BTreeMap<NativeShadowPipelineKey, GraphicsPipeline>,
    targets: Option<NativeShadowTargets>,
}

impl NativeShadowPass {
    pub fn new(device: &Arc<Device>) -> RhiResult<Self> {
        let vs = NativeShaderLibrary::artifact(
            "shadow_mesh",
            device.backend_api(),
            cove_graphics::rhi::ShaderStage::Vertex,
        )?;
        let fs = NativeShaderLibrary::artifact(
            "shadow_mesh",
            device.backend_api(),
            cove_graphics::rhi::ShaderStage::Fragment,
        )?;
        let bindings = device.make_binding_layout(reflected_layout(&[&vs, &fs])?)?;
        let layout = device.make_pipeline_layout(PipelineLayoutDescriptor::new(vec![bindings]))?;
        let module = device.make_shader_module(vs.module_descriptor(&[])?)?;
        let fragment = match device.make_shader_module(fs.module_descriptor(&[])?) {
            Ok(fragment) => fragment,
            Err(error) => {
                device.destroy_shader_module(module);
                return Err(error);
            }
        };
        Ok(NativeShadowPass {
            device: device.clone(),
            bindings,
            layout,
            vertex: module,
            fragment,
            pipelines: BTreeMap::new(),
            targets: None,
        })
    }

    /// Swift's `deinit` releases every resident object.
    pub fn destroy(&self) {
        if let Some(targets) = &self.targets {
            targets.destroy(&self.device);
        }
        for pipeline in self.pipelines.values() {
            self.device.destroy_graphics_pipeline(*pipeline);
        }
        self.device.destroy_shader_module(self.vertex);
        self.device.destroy_shader_module(self.fragment);
    }

    pub fn atlas(&self) -> Option<Texture> {
        self.targets.as_ref().map(|targets| targets.color)
    }

    pub fn ensure_targets(&mut self, plan: &ShadowAtlasPlan) -> RhiResult<()> {
        if plan.lights.is_empty()
            || self
                .targets
                .as_ref()
                .is_some_and(|targets| targets.size == plan.atlas_size)
        {
            return Ok(());
        }
        let color = self.device.make_texture(
            TextureDescriptor::new(
                plan.atlas_size as usize,
                plan.atlas_size as usize,
                TextureFormat::Rgba16Float,
                TextureUsage::SAMPLED | TextureUsage::COLOR_TARGET,
            )
            .with_label("native-shadow-atlas"),
        )?;
        let depth = match self.device.make_texture(
            TextureDescriptor::new(
                plan.atlas_size as usize,
                plan.atlas_size as usize,
                TextureFormat::Depth32Float,
                TextureUsage::DEPTH_STENCIL_TARGET,
            )
            .with_label("native-shadow-depth"),
        ) {
            Ok(depth) => depth,
            Err(error) => {
                self.device.destroy_texture(color);
                return Err(error);
            }
        };
        if let Some(previous) = self.targets.replace(NativeShadowTargets {
            size: plan.atlas_size,
            color,
            depth,
        }) {
            previous.destroy(&self.device);
        }
        Ok(())
    }

    pub fn prepare(
        &mut self,
        packet: &RenderPacket,
        store: &NativeMeshStore,
        plan: &ShadowAtlasPlan,
        skin: &NativeSkinBindings,
        deformables: &BTreeMap<EntityID, NativeMeshGeometry>,
    ) -> RhiResult<Vec<NativeShadowTile>> {
        if plan.lights.is_empty() {
            return Ok(Vec::new());
        }
        let batches = NativeMeshBatchPlanner::prepare(
            packet,
            store,
            MATRIX_IDENTITY_FLOAT4X4,
            deformables,
            true,
        )?
        .0;
        // Every atlas tile shares the same caster geometry/instances. Upload it
        // once; only the 64-byte light matrix differs between tiles.
        let mut uploads = Vec::with_capacity(batches.len());
        for batch in &batches {
            uploads.push(
                self.device
                    .upload_transient(uniforms_bytes(&batch.uniforms), 256)?,
            );
        }
        let mut tiles = Vec::with_capacity(plan.lights.len());
        for light in &plan.lights {
            let view = NativeUniformUpload::binding(
                ShadowRenderUniforms {
                    light_view_projection: light.light_view_projection,
                },
                &self.device,
            )?;
            let mut draws = Vec::with_capacity(batches.len());
            for (index, batch) in batches.iter().enumerate() {
                let upload = uploads[index];
                let base_texture = batch
                    .key
                    .base_texture
                    .and_then(|texture_index| batch.mesh.textures.get(&texture_index).copied())
                    .unwrap_or(store.fallbacks[0]);
                let set = self.device.make_binding_set(
                    self.bindings,
                    BindingSetDescriptor::new(vec![
                        BindingSetEntry::new(
                            0,
                            BindingResource::UniformBuffer {
                                buffer: upload.buffer,
                                offset: upload.offset,
                                size: Some(std::mem::size_of::<MeshInstanceUniforms>()),
                            },
                        ),
                        BindingSetEntry::new(
                            1,
                            BindingResource::StorageBuffer {
                                buffer: upload.buffer,
                                offset: upload.offset,
                            },
                        ),
                        BindingSetEntry::new(2, BindingResource::Sampler(store.sampler)),
                        BindingSetEntry::new(3, BindingResource::Texture(base_texture)),
                        BindingSetEntry::new(4, view),
                        BindingSetEntry::new(11, skin.palette(batch.skin_entity).parameters),
                        BindingSetEntry::new(12, skin.palette(batch.skin_entity).matrices),
                    ]),
                )?;
                draws.push(NativeShadowDraw {
                    batch: batch.clone(),
                    bindings: set,
                    pipeline: self.pipeline_for(batch.key)?,
                });
            }
            tiles.push(NativeShadowTile {
                light: *light,
                draws,
            });
        }
        Ok(tiles)
    }

    pub fn encode(
        &self,
        tiles: &[NativeShadowTile],
        plan: &ShadowAtlasPlan,
        commands: &mut CommandBuffer,
    ) {
        let Some(targets) = &self.targets else {
            return;
        };
        if tiles.is_empty() {
            return;
        }
        commands.render_pass(
            RenderPassDescriptor::new(vec![RenderColorTarget::clearing(
                targets.color,
                [1.0, 1.0, 1.0, 1.0],
            )])
            .with_depth(RenderDepthTarget::new(targets.depth)),
            |pass| {
                for tile in tiles {
                    let x = (tile.light.tile_x * plan.tile_size) as i64;
                    let y = (tile.light.tile_y * plan.tile_size) as i64;
                    pass.set_viewport(Viewport::at(
                        x as f64,
                        y as f64,
                        plan.tile_size as f64,
                        plan.tile_size as f64,
                    ));
                    pass.set_scissor(ScissorRect::at(
                        x,
                        y,
                        plan.tile_size as i64,
                        plan.tile_size as i64,
                    ));
                    for draw in &tile.draws {
                        pass.set_pipeline(draw.pipeline);
                        pass.set_binding_set(draw.bindings, 0, Vec::new());
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
                }
            },
        );
    }

    fn pipeline_for(&mut self, key: NativeMeshBatchKey) -> RhiResult<GraphicsPipeline> {
        let variant = NativeShadowPipelineKey {
            mirrored: key.mirrored,
            double_sided: key.double_sided,
        };
        if let Some(existing) = self.pipelines.get(&variant) {
            return Ok(*existing);
        }
        let pipeline =
            self.device
                .make_graphics_pipeline(cove_graphics::rhi::GraphicsPipelineDescriptor {
                    color_attachments: vec![ColorAttachmentDescriptor::new(
                        TextureFormat::Rgba16Float,
                    )],
                    depth_format: Some(cove_graphics::rhi::TextureFormat::Depth32Float),
                    depth_stencil: Some(DepthStencilState {
                        depth_compare: CompareOp::Less,
                        depth_write_enabled: true,
                    }),
                    fragment: Some(self.fragment),
                    label: Some("native-shadow"),
                    layout: self.layout,
                    primitive: cove_graphics::rhi::PrimitiveType::TriangleList,
                    rasterization: RasterizationState {
                        cull_mode: if key.double_sided {
                            CullMode::None
                        } else {
                            CullMode::Back
                        },
                        front_winding: if key.mirrored {
                            FrontWinding::Clockwise
                        } else {
                            FrontWinding::CounterClockwise
                        },
                        fill_mode: cove_graphics::rhi::FillMode::Fill,
                    },
                    sample_count: 1,
                    stencil_format: None,
                    vertex: self.vertex,
                    vertex_layout: Some(VertexLayoutDescriptor::new(
                        NativeMeshVertexLayout::descriptor(),
                        NativeMeshVertexLayout::buffer_layouts(),
                    )),
                })?;
        self.pipelines.insert(variant, pipeline);
        Ok(pipeline)
    }
}

/// Swift's `BindingLayoutDescriptor(reflecting:)`.
fn reflected_layout(
    artifacts: &[&cove_graphics::rhi::ShaderArtifact],
) -> RhiResult<BindingLayoutDescriptor> {
    let owned: Vec<cove_graphics::rhi::ShaderArtifact> = artifacts
        .iter()
        .map(|artifact| (*artifact).clone())
        .collect();
    cove_graphics::rhi::reflected_binding_layout(&owned)
}

/// Flat byte image of one batch's instance uniforms.
fn uniforms_bytes(uniforms: &[MeshInstanceUniforms]) -> &[u8] {
    // SAFETY: the slice is a live `Vec<MeshInstanceUniforms>` of `#[repr(C)]`
    // `Copy` values, so the byte range is fully initialized.
    unsafe {
        std::slice::from_raw_parts(
            uniforms.as_ptr().cast::<u8>(),
            std::mem::size_of_val(uniforms),
        )
    }
}
