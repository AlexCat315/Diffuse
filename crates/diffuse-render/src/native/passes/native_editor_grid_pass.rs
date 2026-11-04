//! The editor's existing grid pass, recorded through NativeRHI. The caller owns
//! targets and the frame; default load actions preserve scene color and depth.

use std::sync::Arc;

use cove_graphics::rhi::{
    BindingLayout, BindingResource, BindingSetDescriptor, BindingSetEntry,
    ColorAttachmentDescriptor, CommandBuffer, CompareOp, DepthStencilState, Device,
    GraphicsPipeline, PipelineLayoutDescriptor, RenderColorTarget, RenderDepthTarget,
    RenderPassDescriptor, RhiError, RhiResult, ScissorRect, ShaderStage, Viewport,
};

use crate::core::frame::render_packet::RenderPacket;
use crate::core::lighting::grid_uniforms::EditorGridUniforms;
use crate::native::targets::native_shader_library::NativeShaderLibrary;

pub struct NativeEditorGridPass {
    device: Arc<Device>,
    pipeline: GraphicsPipeline,
    binding_layout: BindingLayout,
    uniform_slot: u32,
}

impl NativeEditorGridPass {
    pub fn new(device: &Arc<Device>) -> RhiResult<Self> {
        Self::with_formats(
            device,
            cove_graphics::rhi::TextureFormat::Bgra8Unorm,
            cove_graphics::rhi::TextureFormat::Depth32Float,
        )
    }

    pub fn with_formats(
        device: &Arc<Device>,
        color_format: cove_graphics::rhi::TextureFormat,
        depth_format: cove_graphics::rhi::TextureFormat,
    ) -> RhiResult<Self> {
        let vertex = NativeShaderLibrary::artifact(
            "editor_grid",
            device.backend_api(),
            ShaderStage::Vertex,
        )?;
        let fragment = NativeShaderLibrary::artifact(
            "editor_grid",
            device.backend_api(),
            ShaderStage::Fragment,
        )?;
        let Some(uniform) = fragment
            .interface
            .bindings
            .iter()
            .find(|binding| binding.name == "grid")
        else {
            return Err(RhiError::layout_mismatch(
                "editor grid expects one uniform block in space0",
            ));
        };
        if uniform.binding_type != cove_graphics::rhi::BindingType::UniformBuffer
            || uniform.space != 0
            || fragment.interface.bindings.len() != 1
        {
            return Err(RhiError::layout_mismatch(
                "editor grid expects one uniform block in space0",
            ));
        }
        let uniform_slot = uniform.slot;
        let binding_layout = device.make_binding_layout(fragment.binding_layout_descriptor(0)?)?;
        let layout =
            device.make_pipeline_layout(PipelineLayoutDescriptor::new(vec![binding_layout]))?;
        let vertex_module = device.make_shader_module(vertex.module_descriptor(&[])?)?;
        let fragment_module = device.make_shader_module(fragment.module_descriptor(&[])?)?;
        let rasterization = cove_graphics::rhi::RasterizationState {
            cull_mode: cove_graphics::rhi::CullMode::None,
            ..cove_graphics::rhi::RasterizationState::default()
        };
        let depth_stencil = DepthStencilState {
            depth_compare: CompareOp::LessOrEqual,
            depth_write_enabled: false,
        };
        let pipeline =
            device.make_graphics_pipeline(cove_graphics::rhi::GraphicsPipelineDescriptor {
                color_attachments: vec![ColorAttachmentDescriptor::blended(color_format)],
                depth_format: Some(depth_format),
                depth_stencil: Some(depth_stencil),
                fragment: Some(fragment_module),
                label: Some("editor-grid"),
                layout,
                primitive: cove_graphics::rhi::PrimitiveType::TriangleList,
                rasterization,
                sample_count: 1,
                stencil_format: None,
                vertex: vertex_module,
                vertex_layout: None,
            });
        device.destroy_shader_module(vertex_module);
        device.destroy_shader_module(fragment_module);
        let pipeline = pipeline?;
        Ok(NativeEditorGridPass {
            device: device.clone(),
            pipeline,
            binding_layout,
            uniform_slot,
        })
    }

    /// Swift's `deinit` destroys the pipeline.
    pub fn destroy(&self) {
        self.device.destroy_graphics_pipeline(self.pipeline);
    }

    pub fn encode(
        &self,
        packet: &RenderPacket,
        color: RenderColorTarget,
        depth: RenderDepthTarget,
        commands: &mut CommandBuffer,
    ) -> RhiResult<()> {
        let size = packet.drawable_size;
        if size.width == 0
            || size.height == 0
            || !packet.render_settings.viewport.grid_spacing.is_finite()
        {
            return Err(RhiError::invalid_argument(
                "grid requires a nonempty viewport and finite spacing",
            ));
        }
        let uniforms = EditorGridUniforms::make(packet);
        let data = uniforms_bytes(&uniforms);
        let upload = self.device.upload_transient(data, 256)?;
        let bindings = self.device.make_binding_set(
            self.binding_layout,
            BindingSetDescriptor::new(vec![BindingSetEntry::new(
                self.uniform_slot,
                BindingResource::UniformBuffer {
                    buffer: upload.buffer,
                    offset: upload.offset,
                    size: Some(data.len()),
                },
            )]),
        )?;
        commands.render_pass(
            RenderPassDescriptor::new(vec![color]).with_depth(depth),
            |pass| {
                pass.set_pipeline(self.pipeline);
                pass.set_binding_set(bindings, 0, Vec::new());
                pass.set_viewport(Viewport::new(size.width as f64, size.height as f64));
                pass.set_scissor(ScissorRect::new(size.width as i64, size.height as i64));
                pass.draw(3, 1, 0, 0);
            },
        );
        Ok(())
    }
}

/// `withUnsafeBytes(of: uniforms) { Data($0) }`.
fn uniforms_bytes(uniforms: &EditorGridUniforms) -> &[u8] {
    // SAFETY: uniforms is a live, fully initialized value; the returned slice
    // borrows it and covers exactly the repr(C) shader block.
    // EditorGridUniforms is a `#[repr(C, align(16))]` uniform block, so its
    // memory image is exactly what the grid shader reads.
    unsafe {
        std::slice::from_raw_parts(
            (uniforms as *const EditorGridUniforms).cast::<u8>(),
            std::mem::size_of::<EditorGridUniforms>(),
        )
    }
}
