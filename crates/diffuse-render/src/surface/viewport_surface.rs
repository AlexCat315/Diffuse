//! Rendered viewport regions and publication state shared by the renderers.
//!
//! `RenderDrawableSize` lives in `core::frame::render_packet` (its Swift home is
//! RenderPacket.swift); `TextureResource` maps to `cove_graphics::rhi`.

use std::sync::Arc;

use cove_graphics::rhi::TextureResource;
use diffuse_math::simd::simd_compat::Float2;

use crate::core::frame::render_packet::RenderDrawableSize;

/// Rendered extent and allocated capacity. Grow-only scene targets are sampled
/// only inside the used region; padding must never appear in a viewport.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ViewportSamplingRegion {
    pub size: RenderDrawableSize,
    pub capacity: RenderDrawableSize,
}

impl ViewportSamplingRegion {
    pub fn new(size: RenderDrawableSize, capacity: RenderDrawableSize) -> Self {
        ViewportSamplingRegion { size, capacity }
    }

    pub fn is_valid(&self) -> bool {
        self.size.width > 0
            && self.size.height > 0
            && self.size.width <= self.capacity.width
            && self.size.height <= self.capacity.height
    }

    pub fn uv_max(&self) -> Float2 {
        if !self.is_valid() {
            return Float2::ZERO;
        }
        Float2::new(
            self.size.width as f32 / self.capacity.width as f32,
            self.size.height as f32 / self.capacity.height as f32,
        )
    }
}

pub use super::viewport_image::ViewportImage;

/// Render-thread publication state, separate from authored render settings.
#[derive(Clone, Default)]
pub struct ViewportSurfaceState {
    /// Stable while the producer uses the same texture. IDs are local to a
    /// producer; consumers identify the owned image rather than this number.
    pub surface_id: u64,
    pub image: Option<Arc<ViewportImage>>,
    pub region: ViewportSamplingRegion,
}

impl ViewportSurfaceState {
    pub fn with_region(
        surface_id: u64,
        image: Option<Arc<ViewportImage>>,
        region: ViewportSamplingRegion,
    ) -> Self {
        ViewportSurfaceState {
            surface_id,
            image,
            region,
        }
    }

    pub fn is_valid(&self) -> bool {
        let Some(image) = self.image.as_ref() else {
            return false;
        };
        if self.surface_id == 0 || !self.region.is_valid() {
            return false;
        }
        let descriptor = image.resource.descriptor();
        descriptor.dimension == cove_graphics::rhi::TextureDimension::Texture2D
            && descriptor.sample_count == 1
            && descriptor
                .usage
                .contains(cove_graphics::rhi::TextureUsage::SAMPLED)
            && descriptor.width == self.region.capacity.width as usize
            && descriptor.height == self.region.capacity.height as usize
    }
}

impl PartialEq for ViewportSurfaceState {
    /// Swift's `==`: same ID, the *same* image object and an equal region.
    fn eq(&self, other: &Self) -> bool {
        self.surface_id == other.surface_id
            && match (&self.image, &other.image) {
                (Some(lhs), Some(rhs)) => Arc::ptr_eq(lhs, rhs),
                (None, None) => true,
                _ => false,
            }
            && self.region == other.region
    }
}
impl Eq for ViewportSurfaceState {}

/// Swift's `ViewportSurfacePublication`: the render-thread side of the surface.
#[derive(Clone, Default)]
pub struct ViewportSurfacePublication {
    pub state: ViewportSurfaceState,
    next_id: u64,
}

impl ViewportSurfacePublication {
    pub fn publish(
        &mut self,
        resource: Arc<TextureResource>,
        mipmaps: Vec<Arc<TextureResource>>,
        region: ViewportSamplingRegion,
    ) {
        let previous = self
            .state
            .image
            .as_ref()
            .map(|image| image.mipmaps.len())
            .unwrap_or(0);
        let same_image = self
            .state
            .image
            .as_ref()
            .is_some_and(|image| image.resource.texture().id() == resource.texture().id());
        if same_image && previous == mipmaps.len() {
            self.state.region = region;
        } else {
            self.next_id += 1;
            self.state = ViewportSurfaceState::with_region(
                self.next_id,
                Some(Arc::new(ViewportImage::new(resource, mipmaps))),
                region,
            );
        }
    }

    pub fn clear(&mut self) {
        self.state = ViewportSurfaceState::default();
    }
}
