//! Axis-aligned reference plane facing an orthographic editor view.
//!
//! Ported from `Engine/Sources/RenderBackend/Core/Lighting/GridPlane.swift`.

use diffuse_math::simd::simd_compat::{Float3, simd_abs, simd_cross};
use diffuse_scene::rendering::render_scene::{RenderCamera, RenderCameraProjection};

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct EditorGridPlane {
    pub u: Float3,
    pub v: Float3,
    pub u_axis: f32,
    pub v_axis: f32,
}

impl EditorGridPlane {
    /// `var normal: SIMD3<Float> { simd_cross(u, v) }`.
    pub fn normal(&self) -> Float3 {
        simd_cross(self.u, self.v)
    }

    pub fn new(u: Float3, v: Float3, u_axis: f32, v_axis: f32) -> Self {
        EditorGridPlane {
            u,
            v,
            u_axis,
            v_axis,
        }
    }

    pub fn make(camera: &RenderCamera) -> Self {
        let forward = simd_abs(camera.target - camera.eye);
        if camera.projection == RenderCameraProjection::Orthographic {
            if forward.z >= forward.x && forward.z >= forward.y {
                return EditorGridPlane::new(
                    Float3::new(1.0, 0.0, 0.0),
                    Float3::new(0.0, 1.0, 0.0),
                    0.0,
                    1.0,
                );
            }
            if forward.x >= forward.y {
                return EditorGridPlane::new(
                    Float3::new(0.0, 0.0, 1.0),
                    Float3::new(0.0, 1.0, 0.0),
                    2.0,
                    1.0,
                );
            }
        }
        EditorGridPlane::new(
            Float3::new(1.0, 0.0, 0.0),
            Float3::new(0.0, 0.0, 1.0),
            0.0,
            2.0,
        )
    }
}
