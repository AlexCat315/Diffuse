//! Shared camera matrix construction for rendering, editor picking and
//! transform handles.
//!
//! Ported from `Engine/Sources/RenderBackend/Core/Frame/RenderCameraMatrices.swift`.
//! Swift adds `projectionMatrix(aspect:)` to `RenderCamera` through an
//! extension; `RenderCamera` lives in `diffuse-scene`, so the extension becomes
//! an extension trait here (Rust forbids inherent impls on foreign types).

use diffuse_math::camera::camera_matrices::CameraMatrices;
use diffuse_math::simd::simd_compat::Float4x4;
use diffuse_scene::rendering::render_scene::{RenderCamera, RenderCameraProjection, RenderScene};

use super::render_packet::RenderDrawableSize;

/// `extension RenderCamera` — the projection used by rendering, editor picking
/// and transform handles.
pub trait RenderCameraProjectionMatrix {
    fn projection_matrix(&self, aspect: f32) -> Float4x4;
}

impl RenderCameraProjectionMatrix for RenderCamera {
    fn projection_matrix(&self, aspect: f32) -> Float4x4 {
        match self.projection {
            RenderCameraProjection::Perspective => {
                CameraMatrices::perspective_rh_zo(self.fov_y_radians, aspect, self.near, self.far)
            }
            RenderCameraProjection::Orthographic => CameraMatrices::orthographic_rh_zo(
                RenderCamera::sanitized_orthographic_height(self.orthographic_height),
                aspect,
                self.near,
                self.far,
            ),
        }
    }
}

/// The camera matrices for one frame.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RenderCameraMatrices {
    pub projection: Float4x4,
    pub view: Float4x4,
    pub view_projection: Float4x4,
}

impl RenderCameraMatrices {
    pub fn new(projection: Float4x4, view: Float4x4, view_projection: Float4x4) -> Self {
        RenderCameraMatrices {
            projection,
            view,
            view_projection,
        }
    }

    /// `make(scene:drawableSize:)`.
    pub fn make(scene: &RenderScene, drawable_size: RenderDrawableSize) -> Self {
        let aspect = i64::from(drawable_size.width.max(1)) as f32
            / i64::from(drawable_size.height.max(1)) as f32;
        let camera = &scene.camera;
        let projection = camera.projection_matrix(aspect);
        let view = CameraMatrices::look_at_rh(camera.eye, camera.target, camera.up);
        RenderCameraMatrices {
            projection,
            view,
            view_projection: projection * view,
        }
    }
}
