//! Sky background, HDR reference grid and final display conversion.

use std::sync::Arc;

use cove_graphics::rhi::{
    BindingResource, BindingSetEntry, CommandBuffer, DepthStencilState, Device, RhiResult, Sampler,
    SamplerAddressMode, SamplerDescriptor, SamplerFilter, SamplerMipFilter, Texture, TextureFormat,
};
use diffuse_math::simd::simd_compat::{Float4, simd_inverse};
use diffuse_scene::rendering::render_scene::RenderCameraProjection;

use crate::core::frame::render_camera_matrices::RenderCameraMatrices;
use crate::core::frame::render_packet::{RenderDrawableSize, RenderPacket};
use crate::core::frame::render_uniforms::{SkyboxUniforms, TonemapUniforms};
use crate::core::lighting::post_effect_uniforms::PostEffectUniforms;
use crate::core::render_settings::Backdrop;
use crate::native::lighting::native_lighting_resources::NativeUniformUpload;
use crate::native::passes::native_editor_grid_pass::NativeEditorGridPass;
use crate::native::passes::native_fullscreen_pass::NativeFullscreenPass;

pub struct NativeHDRPasses {
    device: Arc<Device>,
    sky: NativeFullscreenPass,
    tone: NativeFullscreenPass,
    grid: NativeEditorGridPass,
    sampler: Sampler,
}

impl NativeHDRPasses {
    pub fn new(device: &Arc<Device>) -> RhiResult<Self> {
        let sky = NativeFullscreenPass::new(
            device,
            "skybox",
            TextureFormat::Rgba16Float,
            Some(DepthStencilState {
                depth_compare: cove_graphics::rhi::CompareOp::LessOrEqual,
                depth_write_enabled: false,
            }),
        )?;
        let tone = NativeFullscreenPass::new(device, "tonemap", TextureFormat::Bgra8Unorm, None)?;
        let grid = NativeEditorGridPass::with_formats(
            device,
            TextureFormat::Rgba16Float,
            TextureFormat::Depth32Float,
        )?;
        let sampler = device.make_sampler(SamplerDescriptor {
            min_filter: SamplerFilter::Linear,
            mag_filter: SamplerFilter::Linear,
            mip_filter: SamplerMipFilter::Nearest,
            address_mode_u: SamplerAddressMode::ClampToEdge,
            address_mode_v: SamplerAddressMode::ClampToEdge,
            ..SamplerDescriptor::default()
        })?;
        Ok(NativeHDRPasses {
            device: device.clone(),
            sky,
            tone,
            grid,
            sampler,
        })
    }

    /// Swift's `deinit` destroys the sampler and both passes.
    pub fn destroy(&self) {
        self.grid.destroy();
        self.tone.destroy();
        self.sky.destroy();
        self.device.destroy_sampler(self.sampler);
    }

    pub fn encode_sky(
        &self,
        packet: &RenderPacket,
        matrices: &RenderCameraMatrices,
        hdr: Texture,
        depth: Texture,
        commands: &mut CommandBuffer,
    ) -> RhiResult<()> {
        let studio = packet.render_settings.viewport.backdrop == Backdrop::Studio;
        let flat = studio || packet.scene.camera.projection == RenderCameraProjection::Orthographic;
        let uniforms = SkyboxUniforms {
            inv_view_proj: simd_inverse(matrices.view_projection),
            sky_tint: Float4::new(0.10, 0.20, 0.42, if flat { 1.0 } else { 0.0 }),
            horizon_tint: Float4::new(0.95, 0.48, 0.18, 1.0),
            ground_tint: if studio {
                Float4::new(0.012, 0.019, 0.016, 1.0)
            } else {
                Float4::new(0.03, 0.04, 0.05, 1.0)
            },
        };
        self.sky.encode(
            packet.drawable_size,
            cove_graphics::rhi::RenderColorTarget::clearing(hdr, [0.01, 0.01, 0.02, 1.0]),
            Some(cove_graphics::rhi::RenderDepthTarget::new(depth)),
            vec![BindingSetEntry::new(
                0,
                NativeUniformUpload::binding(uniforms, &self.device)?,
            )],
            commands,
        )
    }

    pub fn encode_grid(
        &self,
        packet: &RenderPacket,
        hdr: Texture,
        depth: Texture,
        commands: &mut CommandBuffer,
    ) -> RhiResult<()> {
        self.grid.encode(
            packet,
            cove_graphics::rhi::RenderColorTarget::new(hdr),
            cove_graphics::rhi::RenderDepthTarget::new(depth),
            commands,
        )
    }

    pub fn encode_tonemap(
        &self,
        size: RenderDrawableSize,
        capacity: RenderDrawableSize,
        hdr: Texture,
        output: Texture,
        bloom: Option<Texture>,
        commands: &mut CommandBuffer,
    ) -> RhiResult<()> {
        let tone_uniforms = TonemapUniforms {
            params: Float4::new(1.0, 0.85, if bloom.is_none() { 0.0 } else { 1.0 }, 1.0),
        };
        let frame = PostEffectUniforms::frame(size, capacity);
        self.tone.encode(
            size,
            cove_graphics::rhi::RenderColorTarget::clearing(output, [0.0, 0.0, 0.0, 1.0]),
            None,
            vec![
                BindingSetEntry::new(0, BindingResource::Sampler(self.sampler)),
                BindingSetEntry::new(1, BindingResource::Texture(hdr)),
                BindingSetEntry::new(2, BindingResource::Texture(bloom.unwrap_or(hdr))),
                BindingSetEntry::new(
                    3,
                    NativeUniformUpload::binding(tone_uniforms, &self.device)?,
                ),
                BindingSetEntry::new(4, NativeUniformUpload::binding(frame, &self.device)?),
            ],
            commands,
        )
    }
}
