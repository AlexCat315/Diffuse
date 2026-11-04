use super::grid_image::GridImage;
use cove_graphics::rhi::{
    Device, DeviceConfig, GraphicsApi, RhiError, RhiResult, platform_default_backends,
};
use diffuse_assets::asset_registry::AssetRegistry;
use diffuse_render::native::native_renderer::NativeRenderer;
use diffuse_render::surface::in_game_ui_providing::InGameUIProviding;
use diffuse_render::{RenderFrameStats, RenderPacket, RenderSettings};

/// An independent device/session for determinism and reset comparisons.
pub struct SceneCapture {
    pub device: Device,
    pub renderer: NativeRenderer,
}
impl SceneCapture {
    pub fn new(
        validation: bool,
        api: Option<GraphicsApi>,
        in_game_ui: Option<Box<dyn InGameUIProviding>>,
    ) -> RhiResult<Self> {
        let device = Device::make(DeviceConfig {
            preferred_backends: api
                .map(|api| vec![api])
                .unwrap_or_else(platform_default_backends),
            enable_validation: validation,
            ..DeviceConfig::default()
        })?;
        let renderer = NativeRenderer::new(
            &device,
            None,
            AssetRegistry::shared(),
            in_game_ui,
            &RenderSettings::default(),
            &[64],
        )?;
        Ok(Self { device, renderer })
    }

    pub fn render(&mut self, packet: &RenderPacket) -> RhiResult<RenderFrameStats> {
        self.renderer.render_checked(packet)?;
        Ok(self.renderer.current_frame_stats())
    }

    pub fn finish(&self) -> RhiResult<()> {
        self.device.wait_until_idle()
    }

    pub fn readback(&self) -> RhiResult<Vec<u8>> {
        let surface = self.renderer.current_viewport_surface_state();
        if !surface.is_valid() {
            return Err(RhiError::invalid_argument(
                "scene capture has no published frame",
            ));
        }
        let image = surface
            .image
            .as_ref()
            .ok_or_else(|| RhiError::invalid_argument("scene capture has no published frame"))?;
        GridImage::readback(&self.device, image.resource.texture(), surface.region.size)
    }
}
impl Drop for SceneCapture {
    fn drop(&mut self) {
        let _ = self.device.wait_until_idle();
    }
}
