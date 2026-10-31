//! `Plane3D`.

use crate::bounds::bounds_3d::Bounds3D;
use crate::simd::simd_compat::{Float3, simd_dot, simd_length};

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Plane3D {
    pub normal: Float3,
    pub distance: f32,
}

impl Plane3D {
    /// `Plane3D(normal:distance:normalize:)`.
    pub fn new(normal: Float3, distance: f32, normalize: bool) -> Self {
        if normalize {
            let length = simd_length(normal);
            if length > f32::EPSILON {
                return Plane3D {
                    normal: normal / length,
                    distance: distance / length,
                };
            }
        }
        Plane3D { normal, distance }
    }

    /// The Swift default normalizes.
    #[inline]
    pub fn normalized(normal: Float3, distance: f32) -> Self {
        Self::new(normal, distance, true)
    }

    /// `Plane3D(normal:point:)`.
    pub fn from_point(normal: Float3, point: Float3) -> Self {
        let length = simd_length(normal);
        let safe_normal = if length > f32::EPSILON {
            normal / length
        } else {
            Float3::new(0.0, 1.0, 0.0)
        };
        Plane3D {
            normal: safe_normal,
            distance: -simd_dot(safe_normal, point),
        }
    }

    #[inline]
    pub fn signed_distance(&self, point: Float3) -> f32 {
        simd_dot(self.normal, point) + self.distance
    }

    pub fn max_signed_distance(&self, bounds: Bounds3D) -> f32 {
        if bounds.is_empty() {
            return f32::NEG_INFINITY;
        }
        let point = Float3::new(
            if self.normal.x >= 0.0 {
                bounds.max.x
            } else {
                bounds.min.x
            },
            if self.normal.y >= 0.0 {
                bounds.max.y
            } else {
                bounds.min.y
            },
            if self.normal.z >= 0.0 {
                bounds.max.z
            } else {
                bounds.min.z
            },
        );
        self.signed_distance(point)
    }

    pub fn min_signed_distance(&self, bounds: Bounds3D) -> f32 {
        if bounds.is_empty() {
            return f32::INFINITY;
        }
        let point = Float3::new(
            if self.normal.x >= 0.0 {
                bounds.min.x
            } else {
                bounds.max.x
            },
            if self.normal.y >= 0.0 {
                bounds.min.y
            } else {
                bounds.max.y
            },
            if self.normal.z >= 0.0 {
                bounds.min.z
            } else {
                bounds.max.z
            },
        );
        self.signed_distance(point)
    }
}
