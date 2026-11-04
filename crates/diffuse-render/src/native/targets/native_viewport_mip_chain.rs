//! Independent 2D mip levels: every first-level sample is clamped to the
//! scene's used region, so allocation padding never enters the pyramid. All
//! three NativeRHI backends use this path.

use cove_graphics::rhi::{
    BindingResource, CommandBuffer, Device, RenderColorTarget, RhiResult, Sampler,
    SamplerAddressMode, SamplerDescriptor, SamplerFilter, SamplerMipFilter, TextureDescriptor,
    TextureFormat, TextureResource, TextureUsage,
};
use diffuse_math::simd::simd_compat::Float4;

use crate::core::frame::render_packet::RenderDrawableSize;
use crate::core::lighting::post_effect_uniforms::PostEffectUniforms;
use crate::native::lighting::native_lighting_resources::NativeUniformUpload;
use crate::native::passes::native_fullscreen_pass::NativeFullscreenPass;

pub struct NativeViewportMipChain {
    device: Device,
    pass: NativeFullscreenPass,
    sampler: Sampler,
    levels: Vec<TextureResource>,
}

impl NativeViewportMipChain {
    pub fn new(device: &Device) -> RhiResult<Self> {
        // The fullscreen FXAA program has a linear resampling path when edge
        // offsets are zero: all luma taps agree and the early return samples
        // the original color. Keep this mode isolated from authored FXAA
        // settings.
        let pass = NativeFullscreenPass::new(device, "fxaa", TextureFormat::Bgra8Unorm, None)?;
        let sampler = device.make_sampler(SamplerDescriptor {
            min_filter: SamplerFilter::Linear,
            mag_filter: SamplerFilter::Linear,
            mip_filter: SamplerMipFilter::Nearest,
            address_mode_u: SamplerAddressMode::ClampToEdge,
            address_mode_v: SamplerAddressMode::ClampToEdge,
            ..SamplerDescriptor::default()
        })?;
        Ok(NativeViewportMipChain {
            device: device.clone(),
            pass,
            sampler,
            levels: Vec::new(),
        })
    }

    /// Swift's `deinit` destroys the sampler; `Drop` does the same.
    pub fn sampler(&self) -> Sampler {
        self.sampler
    }

    pub fn record(
        &mut self,
        source: &TextureResource,
        used: RenderDrawableSize,
        commands: &mut CommandBuffer,
    ) -> RhiResult<Vec<TextureResource>> {
        let mut sizes: Vec<RenderDrawableSize> = Vec::new();
        let mut size = used;
        while size.width > 1 || size.height > 1 {
            size = RenderDrawableSize::new((size.width / 2).max(1), (size.height / 2).max(1));
            sizes.push(size);
        }
        let mismatched = self.levels.len() != sizes.len()
            || self.levels.iter().zip(sizes.iter()).any(|(level, size)| {
                level.descriptor().width != size.width as usize
                    || level.descriptor().height != size.height as usize
            });
        if mismatched {
            self.levels = sizes
                .iter()
                .map(|size| {
                    TextureResource::new(
                        self.device.clone(),
                        TextureDescriptor::new(
                            size.width as usize,
                            size.height as usize,
                            TextureFormat::Bgra8Unorm,
                            TextureUsage::SAMPLED
                                | TextureUsage::COLOR_TARGET
                                | TextureUsage::TRANSFER_SOURCE,
                        )
                        .with_label("viewport-mip"),
                    )
                })
                .collect::<RhiResult<Vec<_>>>()?;
        }
        let mut previous = source.clone();
        let mut used_size = used;
        for (level, size) in self.levels.iter().zip(sizes.iter()) {
            let capacity = RenderDrawableSize::new(
                previous.descriptor().width as u32,
                previous.descriptor().height as u32,
            );
            self.pass.encode(
                *size,
                RenderColorTarget::new(level.texture()),
                None,
                vec![
                    cove_graphics::rhi::BindingSetEntry::new(
                        0,
                        BindingResource::Sampler(self.sampler),
                    ),
                    cove_graphics::rhi::BindingSetEntry::new(
                        1,
                        BindingResource::Texture(previous.texture()),
                    ),
                    cove_graphics::rhi::BindingSetEntry::new(
                        2,
                        BindingResource::Texture(previous.texture()),
                    ),
                    cove_graphics::rhi::BindingSetEntry::new(
                        3,
                        NativeUniformUpload::binding(Float4::ZERO, &self.device)?,
                    ),
                    cove_graphics::rhi::BindingSetEntry::new(
                        4,
                        NativeUniformUpload::binding(
                            PostEffectUniforms::frame(used_size, capacity),
                            &self.device,
                        )?,
                    ),
                ],
                commands,
            )?;
            previous = level.clone();
            used_size = *size;
        }
        Ok(self.levels.clone())
    }
}
