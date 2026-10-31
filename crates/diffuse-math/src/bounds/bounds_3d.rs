//! `Bounds3D` — an axis-aligned bounding box.

use crate::simd::simd_compat::{Float3, Float4, Float4x4, simd_max, simd_min};

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Bounds3D {
    pub min: Float3,
    pub max: Float3,
}

impl Bounds3D {
    #[inline]
    pub const fn new(min: Float3, max: Float3) -> Self {
        Bounds3D { min, max }
    }

    /// `Bounds3D.empty`: inverted so the first `include` wins on every axis.
    pub const EMPTY: Bounds3D = Bounds3D {
        min: Float3::INFINITY,
        max: Float3::NEG_INFINITY,
    };

    /// `Bounds3D(points:)`; an empty input yields a zero box.
    pub fn from_points(points: impl IntoIterator<Item = Float3>) -> Self {
        let mut bounds = Bounds3D::EMPTY;
        for point in points {
            bounds.include(point);
        }
        if bounds.is_empty() {
            Bounds3D::new(Float3::ZERO, Float3::ZERO)
        } else {
            bounds
        }
    }

    #[inline]
    pub fn is_empty(&self) -> bool {
        self.min.x > self.max.x || self.min.y > self.max.y || self.min.z > self.max.z
    }

    #[inline]
    pub fn center(&self) -> Float3 {
        if self.is_empty() {
            return Float3::ZERO;
        }
        (self.min + self.max) * 0.5
    }

    #[inline]
    pub fn extent(&self) -> Float3 {
        if self.is_empty() {
            return Float3::ZERO;
        }
        self.max - self.min
    }

    #[inline]
    pub fn half_extent(&self) -> Float3 {
        self.extent() * 0.5
    }

    #[inline]
    pub fn include(&mut self, point: Float3) {
        self.min = simd_min(self.min, point);
        self.max = simd_max(self.max, point);
    }

    #[inline]
    pub fn contains(&self, point: Float3) -> bool {
        if self.is_empty() {
            return false;
        }
        point.x >= self.min.x
            && point.x <= self.max.x
            && point.y >= self.min.y
            && point.y <= self.max.y
            && point.z >= self.min.z
            && point.z <= self.max.z
    }

    #[inline]
    pub fn closest_point(&self, point: Float3) -> Float3 {
        if self.is_empty() {
            return Float3::ZERO;
        }
        simd_min(simd_max(point, self.min), self.max)
    }

    pub fn union(&self, other: Bounds3D) -> Bounds3D {
        if self.is_empty() {
            return other;
        }
        if other.is_empty() {
            return *self;
        }
        Bounds3D::new(simd_min(self.min, other.min), simd_max(self.max, other.max))
    }

    pub fn intersection(&self, other: Bounds3D) -> Option<Bounds3D> {
        if self.is_empty() || other.is_empty() {
            return None;
        }
        let intersection =
            Bounds3D::new(simd_max(self.min, other.min), simd_min(self.max, other.max));
        if intersection.is_empty() {
            None
        } else {
            Some(intersection)
        }
    }

    #[inline]
    pub fn intersects(&self, other: Bounds3D) -> bool {
        self.intersection(other).is_some()
    }

    #[inline]
    pub fn expanded_scalar(&self, amount: f32) -> Bounds3D {
        self.expanded(Float3::splat(amount))
    }

    pub fn expanded(&self, amount: Float3) -> Bounds3D {
        if self.is_empty() {
            return *self;
        }
        Bounds3D::new(self.min - amount, self.max + amount)
    }

    pub fn transformed(&self, matrix: Float4x4) -> Bounds3D {
        if self.is_empty() {
            return *self;
        }
        let mut result = Bounds3D::EMPTY;
        for x in [self.min.x, self.max.x] {
            for y in [self.min.y, self.max.y] {
                for z in [self.min.z, self.max.z] {
                    let point = matrix * Float4::new(x, y, z, 1.0);
                    result.include(point.xyz());
                }
            }
        }
        result
    }
}
