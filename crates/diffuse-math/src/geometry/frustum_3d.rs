//! `Frustum3D` — six planes extracted from a view-projection matrix.

use crate::bounds::bounds_3d::Bounds3D;
use crate::geometry::plane_3d::Plane3D;
use crate::simd::simd_compat::{Float3, Float4, Float4x4};

#[derive(Clone, Debug, PartialEq)]
pub struct Frustum3D {
    pub planes: Vec<Plane3D>,
}

impl Frustum3D {
    #[inline]
    pub fn new(planes: Vec<Plane3D>) -> Self {
        Frustum3D { planes }
    }

    pub fn from_view_projection(view_projection: Float4x4) -> Self {
        let r0 = Self::row(0, view_projection);
        let r1 = Self::row(1, view_projection);
        let r2 = Self::row(2, view_projection);
        let r3 = Self::row(3, view_projection);
        Frustum3D {
            planes: vec![
                Self::plane(r3 + r0),
                Self::plane(r3 - r0),
                Self::plane(r3 + r1),
                Self::plane(r3 - r1),
                Self::plane(r2),
                Self::plane(r3 - r2),
            ],
        }
    }

    pub fn contains_sphere(&self, center: Float3, radius: f32) -> bool {
        for plane in &self.planes {
            if plane.signed_distance(center) < -radius {
                return false;
            }
        }
        true
    }

    pub fn intersects(&self, bounds: Bounds3D) -> bool {
        if bounds.is_empty() {
            return false;
        }
        for plane in &self.planes {
            if plane.max_signed_distance(bounds) < 0.0 {
                return false;
            }
        }
        true
    }

    fn plane(value: Float4) -> Plane3D {
        Plane3D::normalized(Float3::new(value.x, value.y, value.z), value.w)
    }

    fn row(index: usize, matrix: Float4x4) -> Float4 {
        Float4::new(
            Self::column_component(matrix.columns[0], index),
            Self::column_component(matrix.columns[1], index),
            Self::column_component(matrix.columns[2], index),
            Self::column_component(matrix.columns[3], index),
        )
    }

    fn column_component(column: Float4, index: usize) -> f32 {
        match index {
            0 => column.x,
            1 => column.y,
            2 => column.z,
            _ => column.w,
        }
    }
}
