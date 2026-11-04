//! An owned scene output retained by viewport snapshots.
//!
//! The publication state (`ViewportSurfacePublication`) lives beside it in
//! `viewport_surface` because Swift keeps both in Surface/; the owned image
//! type itself is what UI consumers hold.

use cove_graphics::rhi::TextureResource;

/// An owned scene output. Surface snapshots and UI geometry retain this lease;
/// replacing a renderer's target does not invalidate an older snapshot.
pub struct ViewportImage {
    // The resource is immutable; Device serializes access and destruction.
    pub resource: TextureResource,
    pub mipmaps: Vec<TextureResource>,
}

impl ViewportImage {
    pub fn new(resource: TextureResource, mipmaps: Vec<TextureResource>) -> Self {
        ViewportImage { resource, mipmaps }
    }
}
