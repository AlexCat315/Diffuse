//! Per-frame render target set for one renderer.

use cove_graphics::rhi::{
    Device, NativeSurfaceKind, RhiResult, SurfaceDescriptor, TextureDescriptor, TextureFormat,
    TextureResource, TextureUsage,
};

use crate::core::frame::render_packet::{RenderDrawableSize, RenderSurfaceDescriptor};

pub struct NativeRenderTargets {
    /// Allocated capacity; scene passes render only the packet's used extent.
    pub size: RenderDrawableSize,
    pub color: Option<TextureResource>,
    pub hdr: Option<TextureResource>,
    pub depth: TextureResource,
}

impl NativeRenderTargets {
    pub fn surface_descriptor(
        surface: &RenderSurfaceDescriptor,
        size: RenderDrawableSize,
    ) -> SurfaceDescriptor {
        // Swift starts from a nil-handle descriptor at the given size; the RHI's
        // builder starts from the platform default kind, which each branch then
        // overrides exactly as the Swift `switch` did.
        let mut descriptor =
            SurfaceDescriptor::new(0).with_size(size.width as usize, size.height as usize);
        match surface {
            RenderSurfaceDescriptor::MetalLayer(layer) => {
                descriptor.kind = NativeSurfaceKind::MetalLayer;
                descriptor.native_handle = *layer;
            }
            RenderSurfaceDescriptor::Win32Window { hwnd, .. } => {
                descriptor.kind = NativeSurfaceKind::Win32Window;
                descriptor.native_handle = *hwnd;
            }
            RenderSurfaceDescriptor::XlibWindow { display, window } => {
                descriptor.kind = NativeSurfaceKind::XlibWindow;
                descriptor.display = *display;
                descriptor.native_handle = *window as usize;
            }
            RenderSurfaceDescriptor::WaylandSurface { display, surface } => {
                descriptor.kind = NativeSurfaceKind::WaylandSurface;
                descriptor.display = *display;
                descriptor.native_handle = *surface;
            }
        }
        descriptor
    }

    pub fn make(
        device: &Device,
        size: RenderDrawableSize,
        offscreen: bool,
        hdr: bool,
    ) -> RhiResult<Self> {
        let depth = TextureResource::new(
            device.clone(),
            TextureDescriptor::new(
                size.width as usize,
                size.height as usize,
                TextureFormat::Depth32Float,
                TextureUsage::DEPTH_STENCIL_TARGET | TextureUsage::SAMPLED,
            )
            .with_label("native-render-depth"),
        )?;
        let color = if offscreen {
            Some(TextureResource::new(
                device.clone(),
                TextureDescriptor::new(
                    size.width as usize,
                    size.height as usize,
                    TextureFormat::Bgra8Unorm,
                    TextureUsage::COLOR_TARGET
                        | TextureUsage::SAMPLED
                        | TextureUsage::TRANSFER_SOURCE,
                )
                .with_label("native-render-color"),
            )?)
        } else {
            None
        };
        let scene_hdr = if hdr {
            Some(TextureResource::new(
                device.clone(),
                TextureDescriptor::new(
                    size.width as usize,
                    size.height as usize,
                    TextureFormat::Rgba16Float,
                    TextureUsage::COLOR_TARGET
                        | TextureUsage::SAMPLED
                        | TextureUsage::TRANSFER_SOURCE
                        | TextureUsage::TRANSFER_DESTINATION,
                )
                .with_label("native-scene-hdr"),
            )?)
        } else {
            None
        };
        Ok(NativeRenderTargets {
            size,
            color,
            hdr: scene_hdr,
            depth,
        })
    }
}
