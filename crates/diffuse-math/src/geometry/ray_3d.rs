//! `Ray3D`.

use crate::bounds::bounds_3d::Bounds3D;
use crate::simd::simd_compat::{Float3, simd_length_squared};

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Ray3D {
    pub origin: Float3,
    pub direction: Float3,
}

impl Ray3D {
    /// `Ray3D(origin:direction:normalizeDirection:)`; a zero-length direction
    /// becomes `(0, 0, -1)`, matching Swift.
    pub fn new(origin: Float3, direction: Float3, normalize_direction: bool) -> Self {
        let direction = if normalize_direction {
            let length_squared = simd_length_squared(direction);
            if length_squared > f32::EPSILON {
                direction / length_squared.sqrt()
            } else {
                Float3::new(0.0, 0.0, -1.0)
            }
        } else {
            direction
        };
        Ray3D { origin, direction }
    }

    /// The Swift default normalizes the direction.
    #[inline]
    pub fn normalized(origin: Float3, direction: Float3) -> Self {
        Self::new(origin, direction, true)
    }

    #[inline]
    pub fn point_at(&self, distance: f32) -> Float3 {
        self.origin + self.direction * distance
    }

    /// Axis component lookup used by the slab test.
    #[inline]
    fn axis(value: Float3, index: usize) -> f32 {
        match index {
            0 => value.x,
            1 => value.y,
            _ => value.z,
        }
    }

    /// Nearest intersection distance with an AABB, or `None`.
    pub fn distance_to_bounds(&self, bounds: Bounds3D) -> Option<f32> {
        if bounds.is_empty() {
            return None;
        }
        let mut t_min: f32 = 0.0;
        let mut t_max: f32 = f32::INFINITY;
        for axis in 0..3 {
            let origin_value = Self::axis(self.origin, axis);
            let direction_value = Self::axis(self.direction, axis);
            if direction_value.abs() <= f32::EPSILON {
                if origin_value < Self::axis(bounds.min, axis)
                    || origin_value > Self::axis(bounds.max, axis)
                {
                    return None;
                }
                continue;
            }
            let inverse = 1.0 / direction_value;
            let mut near = (Self::axis(bounds.min, axis) - origin_value) * inverse;
            let mut far = (Self::axis(bounds.max, axis) - origin_value) * inverse;
            if near > far {
                core::mem::swap(&mut near, &mut far);
            }
            t_min = t_min.max(near);
            t_max = t_max.min(far);
            if t_min > t_max {
                return None;
            }
        }
        Some(t_min)
    }
}
