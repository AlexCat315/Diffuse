//! One immutable full-screen pipeline; callers provide frame-owned bindings.

use std::sync::Arc;

use cove_graphics::rhi::{
    BindingLayout, BindingLayoutDescriptor, BindingSetEntry, CommandBuffer, CullMode,
    DepthStencilState, Device, GraphicsPipeline, GraphicsPipelineDescriptor,
    PipelineLayoutDescriptor, RasterizationState, RenderColorTarget, RenderDepthTarget,
    RenderPassDescriptor, RhiResult, ScissorRect, ShaderStage, TextureFormat, Viewport,
};

use crate::core::frame::render_packet::RenderDrawableSize;
use crate::native::targets::native_shader_library::NativeShaderLibrary;

pub struct NativeFullscreenPass {
    device: Arc<Device>,
    bindings: BindingLayout,
    pipeline: GraphicsPipeline,
}

impl NativeFullscreenPass {
    pub fn new(
        device: &Arc<Device>,
        shader: &str,
        color_format: TextureFormat,
        depth: Option<DepthStencilState>,
    ) -> RhiResult<Self> {
        let vs = NativeShaderLibrary::artifact(shader, device.backend_api(), ShaderStage::Vertex)?;
        let fs =
            NativeShaderLibrary::artifact(shader, device.backend_api(), ShaderStage::Fragment)?;
        let bindings = device.make_binding_layout(reflected_binding_layout(&[&vs, &fs])?)?;
        let layout = device.make_pipeline_layout(PipelineLayoutDescriptor::new(vec![bindings]))?;
        let vertex = device.make_shader_module(vs.module_descriptor(&[])?)?;
        let fragment = device.make_shader_module(fs.module_descriptor(&[])?)?;
        let pipeline = device.make_graphics_pipeline(GraphicsPipelineDescriptor {
            color_attachments: vec![cove_graphics::rhi::ColorAttachmentDescriptor::new(
                color_format,
            )],
            depth_format: if depth.is_some() {
                Some(TextureFormat::Depth32Float)
            } else {
                None
            },
            fragment: Some(fragment),
            label: None,
            layout,
            primitive: cove_graphics::rhi::PrimitiveType::TriangleList,
            rasterization: RasterizationState {
                cull_mode: CullMode::None,
                ..RasterizationState::default()
            },
            depth_stencil: depth,
            sample_count: 1,
            stencil_format: None,
            vertex,
            vertex_layout: None,
        })?;
        device.destroy_shader_module(vertex);
        device.destroy_shader_module(fragment);
        Ok(NativeFullscreenPass {
            device: device.clone(),
            bindings,
            pipeline,
        })
    }

    /// Swift's `deinit` destroys the pipeline.
    pub fn destroy(&self) {
        self.device.destroy_graphics_pipeline(self.pipeline);
    }

    pub fn encode(
        &self,
        size: RenderDrawableSize,
        color: RenderColorTarget,
        depth: Option<RenderDepthTarget>,
        entries: Vec<BindingSetEntry>,
        commands: &mut CommandBuffer,
    ) -> RhiResult<()> {
        let set = self.device.make_binding_set(
            self.bindings,
            cove_graphics::rhi::BindingSetDescriptor::new(entries),
        )?;
        let mut descriptor = RenderPassDescriptor::new(vec![color]);
        if let Some(depth) = depth {
            descriptor = descriptor.with_depth(depth);
        }
        commands.render_pass(descriptor, |pass| {
            pass.set_pipeline(self.pipeline);
            pass.set_binding_set(set, 0, Vec::new());
            pass.set_viewport(Viewport::new(size.width as f64, size.height as f64));
            pass.set_scissor(ScissorRect::new(size.width as i64, size.height as i64));
            pass.draw(3, 1, 0, 0);
        });
        Ok(())
    }
}

/// Swift's `BindingLayoutDescriptor(reflecting:)`.
fn reflected_binding_layout(
    artifacts: &[&cove_graphics::rhi::ShaderArtifact],
) -> RhiResult<BindingLayoutDescriptor> {
    let owned: Vec<cove_graphics::rhi::ShaderArtifact> = artifacts
        .iter()
        .map(|artifact| (*artifact).clone())
        .collect();
    cove_graphics::rhi::reflected_binding_layout(&owned)
}
