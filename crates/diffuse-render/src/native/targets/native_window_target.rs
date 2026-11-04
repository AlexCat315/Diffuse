//! One renderer's window target; other windows keep independent swapchains.

use std::sync::{Arc, Mutex};

use cove_graphics::rhi::{Device, RhiError, RhiResult, SwapchainImage, SwapchainResource};

use crate::core::frame::render_packet::{RenderDrawableSize, RenderSurfaceDescriptor};
use crate::native::targets::native_render_targets::NativeRenderTargets;

pub struct NativeWindowTarget {
    device: Arc<Device>,
    surface: RenderSurfaceDescriptor,
    // Swift's shared window target mutates its swapchain during configuration.
    state: Mutex<WindowTargetState>,
}

struct WindowTargetState {
    resource: Option<SwapchainResource>,
    configured_size: Option<RenderDrawableSize>,
}

impl NativeWindowTarget {
    pub fn new(device: Arc<Device>, surface: RenderSurfaceDescriptor) -> Self {
        NativeWindowTarget {
            device,
            surface,
            state: Mutex::new(WindowTargetState {
                resource: None,
                configured_size: None,
            }),
        }
    }

    pub fn configure(&self, size: RenderDrawableSize) -> RhiResult<()> {
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if state.configured_size == Some(size) {
            return Ok(());
        }
        let descriptor = NativeRenderTargets::surface_descriptor(&self.surface, size);
        if let Some(resource) = &state.resource {
            self.device
                .configure_swapchain(resource.swapchain(), descriptor)?;
        } else {
            state.resource = Some(SwapchainResource::new(self.device.clone(), descriptor)?);
        }
        state.configured_size = Some(size);
        Ok(())
    }

    pub fn acquire(&self) -> RhiResult<SwapchainImage> {
        let state = self
            .state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let Some(resource) = &state.resource else {
            return Err(RhiError::SwapchainAcquireFailed(
                "window target is not configured".into(),
            ));
        };
        self.device.acquire_swapchain_image(resource.swapchain())
    }
}
