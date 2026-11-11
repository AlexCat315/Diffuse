//! Translation of Editor/Sources/EditorCore/Editing/Viewport/EditorViewportProjection.swift.
//!
//! Screen projection and cursor rays for the editor viewport, plus the shared
//! "Frame Selected" framing policy.

use std::f32::consts::PI;

use diffuse_math::camera::camera_matrices::CameraMatrices;
use diffuse_math::simd::simd_compat::{
    Float3, Float4x4, simd_cross, simd_dot, simd_length, simd_max, simd_min, simd_normalize,
};
use diffuse_render::RenderCameraProjectionMatrix;
use diffuse_scene::rendering::render_scene::{RenderCamera, RenderCameraProjection};

use crate::rendering::viewport::viewport_host::ViewportScreenFrame;

pub struct EditorViewportProjection {
    pub camera: RenderCamera,
    pub frame: ViewportScreenFrame,
    pub view_matrix: Float4x4,
    pub projection_matrix: Float4x4,
    pub view_projection_matrix: Float4x4,
    pub camera_forward: Float3,
    pub camera_right: Float3,
    pub camera_up: Float3,
    pub aspect: f32,
    pub tan_half_fov: f32,
}

impl EditorViewportProjection {
    pub fn new(camera: RenderCamera, frame: ViewportScreenFrame) -> Option<Self> {
        if !(frame.width > 0.0 && frame.height > 0.0) {
            return None;
        }
        let forward_raw = camera.target - camera.eye;
        if simd_length(forward_raw) <= 1e-5 {
            return None;
        }
        let forward = simd_normalize(forward_raw);
        let right_raw = simd_cross(forward, camera.up);
        if simd_length(right_raw) <= 1e-5 {
            return None;
        }
        let right = simd_normalize(right_raw);
        let up = simd_normalize(simd_cross(right, forward));
        let aspect = frame.width / frame.height;
        let view = CameraMatrices::look_at_rh(camera.eye, camera.target, up);
        let projection = camera.projection_matrix(aspect);
        let view_projection_matrix = projection * view;
        let tan_half_fov = (camera.fov_y_radians * 0.5).tan();

        Some(EditorViewportProjection {
            camera,
            frame,
            view_matrix: view,
            projection_matrix: projection,
            view_projection_matrix,
            camera_forward: forward,
            camera_right: right,
            camera_up: up,
            aspect,
            tan_half_fov,
        })
    }

    /// Editor handles may remain visible beyond the scene's far plane.
    /// Near-plane and behind-camera rejection still apply to those overlays.
    pub fn project(&self, world_point: Float3, clip_to_far_plane: bool) -> Option<(f32, f32)> {
        let offset = world_point - self.camera.eye;
        let depth = simd_dot(offset, self.camera_forward);
        if depth < self.camera.near
            || depth <= 1e-4
            || (clip_to_far_plane && depth > self.camera.far)
        {
            return None;
        }
        let half_height = if self.camera.projection == RenderCameraProjection::Orthographic {
            RenderCamera::sanitized_orthographic_height(self.camera.orthographic_height) * 0.5
        } else {
            depth * self.tan_half_fov
        };
        let ndc_x = simd_dot(offset, self.camera_right) / (half_height * self.aspect);
        let ndc_y = simd_dot(offset, self.camera_up) / half_height;
        let sx = self.frame.x + (ndc_x * 0.5 + 0.5) * self.frame.width;
        let sy = self.frame.y + (1.0 - (ndc_y * 0.5 + 0.5)) * self.frame.height;
        Some((sx, sy))
    }

    /// `project(_:)` with Swift's `clipToFarPlane` default.
    pub fn project_default(&self, world_point: Float3) -> Option<(f32, f32)> {
        self.project(world_point, true)
    }

    pub fn cursor_ray(&self, x: f32, y: f32) -> (Float3, Float3) {
        let u = (x - self.frame.x) / self.frame.width;
        let v = (y - self.frame.y) / self.frame.height;
        let ndc_x = 2.0 * u - 1.0;
        let ndc_y = 1.0 - 2.0 * v;
        if self.camera.projection == RenderCameraProjection::Orthographic {
            let half_height =
                RenderCamera::sanitized_orthographic_height(self.camera.orthographic_height) * 0.5;
            let origin = self.camera.eye
                + self.camera_forward * self.camera.near
                + self.camera_right * (ndc_x * self.aspect * half_height)
                + self.camera_up * (ndc_y * half_height);
            return (origin, self.camera_forward);
        }
        let direction = simd_normalize(
            self.camera_forward
                + self.camera_right * (ndc_x * self.aspect * self.tan_half_fov)
                + self.camera_up * (ndc_y * self.tan_half_fov),
        );
        (self.camera.eye, direction)
    }
}

/// Production framing policy shared by every "Frame Selected" entry point.
///
/// The policy fits a conservative bounding sphere around the complete world
/// AABB. A sphere keeps the result stable as the camera rotates and lets the
/// narrower of the horizontal and vertical fields of view drive the distance.
pub struct EditorViewportFraming;

/// The camera pose produced by [`EditorViewportFraming::pose`].
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct EditorViewportFramingPose {
    pub eye: Float3,
    pub target: Float3,
    pub up: Float3,
    pub orthographic_height: Option<f32>,
}

impl EditorViewportFramingPose {
    pub fn new(eye: Float3, target: Float3, up: Float3, orthographic_height: Option<f32>) -> Self {
        EditorViewportFramingPose {
            eye,
            target,
            up,
            orthographic_height,
        }
    }
}

impl EditorViewportFraming {
    pub fn pose(
        camera: &RenderCamera,
        bounds_min: Float3,
        bounds_max: Float3,
        viewport_aspect_ratio: Option<f32>,
        padding: f32,
    ) -> EditorViewportFramingPose {
        let bounds_are_finite = [
            bounds_min.x,
            bounds_min.y,
            bounds_min.z,
            bounds_max.x,
            bounds_max.y,
            bounds_max.z,
        ]
        .iter()
        .all(|value| value.is_finite());
        let safe_min = if bounds_are_finite {
            bounds_min
        } else {
            Float3::splat(-0.25)
        };
        let safe_max = if bounds_are_finite {
            bounds_max
        } else {
            Float3::splat(0.25)
        };
        let lower = simd_min(safe_min, safe_max);
        let upper = simd_max(safe_min, safe_max);
        let target = (lower + upper) * 0.5;
        let half_extents = (upper - lower) * 0.5;
        let radius = simd_length(half_extents).max(0.25);

        let requested_aspect = viewport_aspect_ratio.unwrap_or(camera.aspect_ratio);
        let aspect = if requested_aspect.is_finite() {
            requested_aspect.max(0.05)
        } else {
            1.0
        };
        let requested_half_fov = camera.fov_y_radians * 0.5;
        let vertical_half_fov = (PI * 0.49).min((PI / 180.0 * 2.5).max(requested_half_fov));
        let horizontal_half_fov = (vertical_half_fov.tan() * aspect).atan();
        let limiting_half_fov = (PI / 180.0 * 2.5).max(vertical_half_fov.min(horizontal_half_fov));
        let safe_padding = if padding.is_finite() {
            padding.max(1.0)
        } else {
            1.3
        };
        let fitted_distance = radius / limiting_half_fov.sin().max(0.04) * safe_padding;
        let distance = 0.5_f32
            .max(radius + (camera.near * 2.0).max(0.05))
            .max(fitted_distance);

        let mut backward = camera.eye - camera.target;
        if !backward.x.is_finite()
            || !backward.y.is_finite()
            || !backward.z.is_finite()
            || simd_length(backward) < 1e-5
        {
            backward = Float3::new(0.0, 0.25, 1.0);
        }
        backward = simd_normalize(backward);
        let forward = -backward;
        let mut safe_up = camera.up;
        if !safe_up.x.is_finite()
            || !safe_up.y.is_finite()
            || !safe_up.z.is_finite()
            || simd_length(safe_up) < 1e-5
            || simd_length(simd_cross(forward, safe_up)) < 1e-4
        {
            safe_up = if simd_dot(forward, Float3::new(0.0, 1.0, 0.0)).abs() < 0.92 {
                Float3::new(0.0, 1.0, 0.0)
            } else {
                Float3::new(0.0, 0.0, 1.0)
            };
        }
        safe_up = simd_normalize(safe_up);
        EditorViewportFramingPose::new(
            target + backward * distance,
            target,
            safe_up,
            if camera.projection == RenderCameraProjection::Orthographic {
                Some(radius * 2.0 * safe_padding / aspect.min(1.0))
            } else {
                None
            },
        )
    }

    /// `pose(camera:boundsMin:boundsMax:)` with Swift's default arguments.
    pub fn pose_default(
        camera: &RenderCamera,
        bounds_min: Float3,
        bounds_max: Float3,
    ) -> EditorViewportFramingPose {
        Self::pose(camera, bounds_min, bounds_max, None, 1.3)
    }
}
