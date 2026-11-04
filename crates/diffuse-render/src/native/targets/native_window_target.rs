//! One renderer's window target; other windows keep independent swapchains.

use cove_graphics::rhi::{Device, RhiError, RhiResult, SwapchainImage, SwapchainResource};

use crate::core::frame::render_packet::{RenderDrawableSize, RenderSurfaceDescriptor};
use crate::native::targets::native_render_targets::NativeRenderTargets;

pub struct NativeWindowTarget {
    device: Device,
    surface: RenderSurfaceDescriptor,
    resource: Option<SwapchainResource>,
    configured_size: Option<RenderDrawableSize>,
}

impl NativeWindowTarget {
    pub fn new(device: Device, surface: RenderSurfaceDescriptor) -> Self {
        NativeWindowTarget {
            device,
            surface,
            resource: None,
            configured_size: None,
        }
    }

    pub fn configure(&mut self, size: RenderDrawableSize) -> RhiResult<()> {
        if self.configured_size == Some(size) {
            return Ok(());
        }
        let descriptor = NativeRenderTargets::surface_descriptor(&self.surface, size);
        if let Some(resource) = &self.resource {
            self.device
                .configure_swapchain(resource.swapchain(), descriptor)?;
        } else {
            self.resource = Some(SwapchainResource::new(self.device.clone(), descriptor)?);
        }
        self.configured_size = Some(size);
        Ok(())
    }

    pub fn acquire(&self) -> RhiResult<SwapchainImage> {
        let Some(resource) = &self.resource else {
            return Err(RhiError::SwapchainAcquireFailed(
                "window target is not configured".into(),
            ));
        };
        self.device.acquire_swapchain_image(resource.swapchain())
    }
}
