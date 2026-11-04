//! Immutable studio environment and shadow filtering, independent of scene
//! meshes. Also carries `NativeUniformUpload`, the frame-owned uniform helper
//! every pass shares.

use std::sync::Arc;

use cove_graphics::rhi::{
    BindingResource, Device, RhiResult, Sampler, SamplerAddressMode, SamplerDescriptor,
    SamplerFilter, SamplerMipFilter, Texture, TextureDescriptor, TextureFormat, TextureSubresource,
    TextureUsage,
};

use crate::core::frame::render_packet::RenderPacket;
use crate::core::lighting::environment_ibl::StudioEnvironmentIBL;
use crate::core::lighting::shadow_atlas_plan::ShadowAtlasPlan;
use crate::core::lighting::uniforms::SceneLightUniforms;

#[derive(Clone)]
pub struct NativeLightingBindings {
    pub lights: BindingResource,
    pub shadows: BindingResource,
    pub sampler: Sampler,
    pub atlas: Texture,
    pub environment: Texture,
}

pub enum NativeUniformUpload {}

impl NativeUniformUpload {
    /// Copies `value` into the frame's transient upload ring and returns the
    /// bounded uniform-buffer binding for it.
    pub fn binding<T: Copy>(value: T, device: &Device) -> RhiResult<BindingResource> {
        // SAFETY: `value` is a live local of a `Copy` type, so the byte range
        // `[&value, &value + size_of::<T>())` is fully initialized.
        let data = unsafe {
            std::slice::from_raw_parts((&value as *const T).cast::<u8>(), std::mem::size_of::<T>())
        };
        let location = device.upload_transient(data, 256)?;
        Ok(BindingResource::UniformBuffer {
            buffer: location.buffer,
            offset: location.offset,
            size: Some(data.len()),
        })
    }
}

pub struct NativeLightingResources {
    device: Arc<Device>,
    shadow_sampler: Sampler,
    environment: Option<Texture>,
}

impl NativeLightingResources {
    pub fn new(device: &Arc<Device>) -> RhiResult<Self> {
        let shadow_sampler = device.make_sampler(SamplerDescriptor {
            min_filter: SamplerFilter::Linear,
            mag_filter: SamplerFilter::Linear,
            mip_filter: SamplerMipFilter::Nearest,
            address_mode_u: SamplerAddressMode::ClampToEdge,
            address_mode_v: SamplerAddressMode::ClampToEdge,
            ..SamplerDescriptor::default()
        })?;
        Ok(NativeLightingResources {
            device: device.clone(),
            shadow_sampler,
            environment: None,
        })
    }

    /// Swift's `deinit` destroys the environment texture and sampler.
    pub fn destroy(&self) {
        if let Some(environment) = self.environment {
            self.device.destroy_texture(environment);
        }
        self.device.destroy_sampler(self.shadow_sampler);
    }

    pub fn ensure_environment(&mut self) -> RhiResult<()> {
        if self.environment.is_some() {
            return Ok(());
        }
        let levels = StudioEnvironmentIBL::levels();
        let texture = self.device.make_texture(
            TextureDescriptor::new(
                StudioEnvironmentIBL::BASE_WIDTH,
                StudioEnvironmentIBL::BASE_HEIGHT,
                TextureFormat::Rgba16Float,
                TextureUsage::SAMPLED | TextureUsage::TRANSFER_DESTINATION,
            )
            .with_mip_levels(StudioEnvironmentIBL::MIP_COUNT)
            .with_label("native-studio-ibl"),
        )?;
        let upload = (|| {
            for (index, level) in levels.iter().enumerate() {
                // SAFETY: `level.half_rgba` is a live `Vec<u16>`; the byte range
                // covers exactly its initialized storage.
                let data = unsafe {
                    std::slice::from_raw_parts(
                        level.half_rgba.as_ptr().cast::<u8>(),
                        level.half_rgba.len() * 2,
                    )
                };
                self.device.upload_texture_data(
                    texture,
                    data,
                    cove_graphics::rhi::TextureUploadRegion::new(
                        level.width as i64,
                        level.height as i64,
                    ),
                    level.width * 8,
                    TextureSubresource::new(index, 0),
                )?;
            }
            Ok(())
        })();
        match upload {
            Ok(()) => self.environment = Some(texture),
            Err(error) => {
                self.device.destroy_texture(texture);
                return Err(error);
            }
        }
        Ok(())
    }

    pub fn prepare(
        &self,
        packet: &RenderPacket,
        plan: &ShadowAtlasPlan,
        atlas: Option<Texture>,
        fallback: Texture,
    ) -> RhiResult<NativeLightingBindings> {
        let mut lights =
            SceneLightUniforms::new(&packet.scene, &plan.shadow_bindings_by_light_index());
        lights.exposure_and_light_count.z =
            packet.render_settings.shading.debug_view_mode.raw_value() as f32;
        Ok(NativeLightingBindings {
            lights: NativeUniformUpload::binding(lights, &self.device)?,
            shadows: NativeUniformUpload::binding(plan.uniforms, &self.device)?,
            sampler: self.shadow_sampler,
            atlas: atlas.unwrap_or(fallback),
            environment: self.environment.unwrap_or(fallback),
        })
    }
}
