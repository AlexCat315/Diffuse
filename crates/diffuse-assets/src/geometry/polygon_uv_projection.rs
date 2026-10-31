//! Affine surface coordinates that preserve UV interpolation when coplanar
//! topology changes.
//!
//! Ported from `Engine/Sources/AssetPipeline/Geometry/PolygonUVProjection.swift`.
//! A seam stays local to each face's own projection.

use diffuse_math::simd::simd_compat::{Double3, Float2, Float3, simd_distance2, simd_length2};

use crate::geometry::polygon_mesh::GeometryError;

#[derive(Clone, Debug, PartialEq)]
pub(crate) struct PolygonUVProjection {
    origin: Double3,
    e1: Double3,
    e2: Double3,
    d11: f64,
    d12: f64,
    d22: f64,
    determinant: f64,
    uv: Float2,
    du: Float2,
    dv: Float2,
}

impl PolygonUVProjection {
    pub(crate) fn new(
        positions: &[Float3],
        uvs: &[Float2],
    ) -> Result<PolygonUVProjection, GeometryError> {
        if !(positions.len() >= 3 && positions.len() == uvs.len()) {
            return Err(GeometryError::invalid_mesh("invalid UV projection"));
        }
        let points: Vec<Double3> = positions
            .iter()
            .map(|p| Double3::new(f64::from(p.x), f64::from(p.y), f64::from(p.z)))
            .collect();
        let origin = points[0];
        let a = points[0];
        fn length_squared(p: Double3) -> f64 {
            p.x * p.x + p.y * p.y + p.z * p.z
        }
        // Swift's `max(by:)` keeps the earliest index among equal maxima.
        let mut b = 0usize;
        for index in 1..points.len() {
            if length_squared(points[b] - a) < length_squared(points[index] - a) {
                b = index;
            }
        }
        let axis = points[b] - a;
        fn cross_squared(axis: Double3, p: Double3) -> f64 {
            length_squared(Double3::new(
                axis.y * p.z - axis.z * p.y,
                axis.z * p.x - axis.x * p.z,
                axis.x * p.y - axis.y * p.x,
            ))
        }
        let mut c = 0usize;
        for index in 1..points.len() {
            if cross_squared(axis, points[c] - a) < cross_squared(axis, points[index] - a) {
                c = index;
            }
        }
        let e1 = axis;
        let e2 = points[c] - a;
        let d11 = dot3(e1, e1);
        let d12 = dot3(e1, e2);
        let d22 = dot3(e2, e2);
        let determinant = d11 * d22 - d12 * d12;
        if !(determinant.is_finite() && determinant > (1e-30_f64).max(d11 * d22 * 1e-12)) {
            return Err(GeometryError::invalid_mesh("degenerate UV projection"));
        }
        let uv = uvs[0];
        let du = uvs[b] - uv;
        let dv = uvs[c] - uv;
        let spread = uvs
            .iter()
            .fold(0.0_f32, |acc, value| acc.max(simd_length2(*value - uvs[0])));
        let tolerance = (1e-5_f32).max(spread * 1e-5);
        let projection = PolygonUVProjection {
            origin,
            e1,
            e2,
            d11,
            d12,
            d22,
            determinant,
            uv,
            du,
            dv,
        };
        if !positions
            .iter()
            .zip(uvs.iter())
            .all(|(position, uv)| simd_distance2(projection.project(*position), *uv) <= tolerance)
        {
            return Err(GeometryError::invalid_mesh(
                "topology edit would change non-affine UV interpolation",
            ));
        }
        Ok(projection)
    }

    pub(crate) fn project(&self, point: Float3) -> Float2 {
        let offset =
            Double3::new(f64::from(point.x), f64::from(point.y), f64::from(point.z)) - self.origin;
        let u = dot3(offset, self.e1);
        let v = dot3(offset, self.e2);
        self.uv
            + self.du * ((u * self.d22 - v * self.d12) / self.determinant) as f32
            + self.dv * ((v * self.d11 - u * self.d12) / self.determinant) as f32
    }
}

/// `simd_dot` for `SIMD3<Double>`.
fn dot3(a: Double3, b: Double3) -> f64 {
    a.x * b.x + a.y * b.y + a.z * b.z
}
