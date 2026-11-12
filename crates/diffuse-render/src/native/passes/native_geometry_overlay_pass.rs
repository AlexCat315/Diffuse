//! The editor geometry overlay: expanded CPU vertices drawn with per-fragment
//! depth visibility, through two pipelines (surface and x-ray).

use std::sync::Arc;

use cove_graphics::rhi::{
    ColorAttachmentDescriptor, ColorLoadAction, CommandBuffer, CompareOp, CullMode,
    DepthLoadAction, DepthStencilState, Device, GraphicsPipeline, PipelineLayoutDescriptor,
    RenderColorTarget, RenderDepthTarget, RenderPassDescriptor, RhiResult, ScissorRect, Texture,
    VertexAttribute, VertexBufferLayout, VertexFormat, VertexInputRate, VertexLayoutDescriptor,
    Viewport,
};

use crate::core::frame::render_camera_matrices::RenderCameraMatrices;
use crate::core::frame::render_packet::RenderPacket;
use crate::native::passes::native_overlay_geometry::NativeOverlayGeometry;
use crate::native::passes::native_overlay_geometry::NativeOverlayVertex;
use crate::native::targets::native_shader_library::NativeShaderLibrary;

pub struct NativeGeometryOverlayPass {
    device: Arc<Device>,
    visible: GraphicsPipeline,
    xray: GraphicsPipeline,
}

impl NativeGeometryOverlayPass {
    pub fn new(device: &Arc<Device>) -> RhiResult<Self> {
        let vertex = device.make_shader_module(
            NativeShaderLibrary::artifact(
                "editor_geometry",
                device.backend_api(),
                cove_graphics::rhi::ShaderStage::Vertex,
            )?
            .module_descriptor(&[])?,
        )?;
        let fragment = device.make_shader_module(
            NativeShaderLibrary::artifact(
                "editor_geometry",
                device.backend_api(),
                cove_graphics::rhi::ShaderStage::Fragment,
            )?
            .module_descriptor(&[])?,
        )?;
        let layout = device.make_pipeline_layout(PipelineLayoutDescriptor::new(Vec::new()))?;
        let vertices = VertexLayoutDescriptor::new(
            (0..7)
                .map(|index| VertexAttribute::new(index as u32, VertexFormat::Float4, index * 16))
                .collect(),
            vec![VertexBufferLayout {
                stride: std::mem::size_of::<NativeOverlayVertex>(),
                step_rate: VertexInputRate::PerVertex,
            }],
        );
        let build = |compare: CompareOp| -> RhiResult<GraphicsPipeline> {
            device.make_graphics_pipeline(cove_graphics::rhi::GraphicsPipelineDescriptor {
                color_attachments: vec![ColorAttachmentDescriptor::blended(
                    cove_graphics::rhi::TextureFormat::Bgra8Unorm,
                )],
                depth_format: Some(cove_graphics::rhi::TextureFormat::Depth32Float),
                depth_stencil: Some(DepthStencilState {
                    depth_compare: compare,
                    depth_write_enabled: false,
                }),
                fragment: Some(fragment),
                label: None,
                layout,
                primitive: cove_graphics::rhi::PrimitiveType::TriangleList,
                rasterization: cove_graphics::rhi::RasterizationState {
                    cull_mode: CullMode::None,
                    ..cove_graphics::rhi::RasterizationState::default()
                },
                sample_count: 1,
                stencil_format: None,
                vertex,
                vertex_layout: Some(vertices.clone()),
            })
        };
        let visible = build(CompareOp::LessOrEqual)?;
        let xray = match build(CompareOp::Always) {
            Ok(xray) => xray,
            Err(error) => {
                device.destroy_graphics_pipeline(visible);
                device.destroy_shader_module(vertex);
                device.destroy_shader_module(fragment);
                return Err(error);
            }
        };
        device.destroy_shader_module(vertex);
        device.destroy_shader_module(fragment);
        Ok(NativeGeometryOverlayPass {
            device: device.clone(),
            visible,
            xray,
        })
    }

    /// Swift's `deinit` destroys both pipelines.
    pub fn destroy(&self) {
        self.device.destroy_graphics_pipeline(self.visible);
        self.device.destroy_graphics_pipeline(self.xray);
    }

    pub fn encode(
        &self,
        packet: &RenderPacket,
        color: Texture,
        depth: Texture,
        commands: &mut CommandBuffer,
    ) -> RhiResult<usize> {
        let matrix =
            RenderCameraMatrices::make(&packet.scene, packet.drawable_size).view_projection;
        let mut draws = 0;
        for overlay in &packet.scene.geometry_overlays {
            if overlay.triangles.is_empty() && overlay.lines.is_empty() && overlay.points.is_empty()
            {
                continue;
            }
            let vertices = NativeOverlayGeometry::make(
                overlay,
                matrix,
                packet.drawable_size.height as f32 / overlay.viewport_size.y,
            )?;
            if vertices.is_empty() {
                continue;
            }
            // SAFETY: the vertex slice is a live `Vec<NativeOverlayVertex>`; the
            // byte range is fully initialized `Copy` data.
            let data = unsafe {
                std::slice::from_raw_parts(
                    vertices.as_ptr().cast::<u8>(),
                    vertices.len() * std::mem::size_of::<NativeOverlayVertex>(),
                )
            };
            let upload = self.device.upload_transient(data, 256)?;
            let pipeline = if overlay.xray {
                self.xray
            } else {
                self.visible
            };
            // Swift loads both attachments: the overlay composites into the
            // resolved scene color and clips against the scene depth.
            commands.render_pass(
                RenderPassDescriptor::new(vec![RenderColorTarget {
                    load_action: ColorLoadAction::Load,
                    ..RenderColorTarget::new(color)
                }])
                .with_depth(RenderDepthTarget::new(depth).with_load_action(DepthLoadAction::Load)),
                |pass| {
                    pass.set_pipeline(pipeline);
                    pass.set_viewport(Viewport::new(
                        packet.drawable_size.width as f64,
                        packet.drawable_size.height as f64,
                    ));
                    pass.set_scissor(ScissorRect::new(
                        packet.drawable_size.width as i64,
                        packet.drawable_size.height as i64,
                    ));
                    pass.set_vertex_buffer(upload.buffer, upload.offset, 0);
                    pass.draw(vertices.len() as i64, 1, 0, 0);
                },
            );
            draws += 1;
        }
        Ok(draws)
    }
}
