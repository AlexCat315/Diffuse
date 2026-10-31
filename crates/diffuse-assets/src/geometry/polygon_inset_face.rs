//! Plan for insetting one convex planar face.
//!
//! Ported from `Engine/Sources/AssetPipeline/Geometry/PolygonInsetFace.swift`.

use diffuse_math::simd::simd_compat::{
    Double2, Float3, simd_cross, simd_dot, simd_dot_f64_2, simd_length, simd_length_squared,
};

use crate::geometry::polygon_mesh::GeometryError;
use crate::geometry::polygon_mesh::{
    GEOMETRY_UNIT_FALLBACK, PolygonFace, geometry_normal, geometry_unit,
};
use crate::geometry::polygon_triangulation::triangulate;
use crate::geometry::polygon_uv_projection::PolygonUVProjection;

#[derive(Clone, Debug, PartialEq)]
pub(crate) struct PolygonInsetFace {
    pub(crate) origin: Float3,
    pub(crate) x: Float3,
    pub(crate) y: Float3,
    pub(crate) points: Vec<Double2>,
    pub(crate) inward: Vec<Double2>,
    pub(crate) uv: Option<PolygonUVProjection>,
    pub(crate) safe_distance: f32,
}

impl PolygonInsetFace {
    /// The `!(x > 0.0)` comparisons are deliberate: they are the NaN-safe spelling of
    /// Swift's `guard x > 0 else`, which takes the fallback path for NaN as well as
    /// for zero. Rewriting them as `x <= 0.0` would let NaN through and change the
    /// geometry output.
    #[allow(clippy::neg_cmp_op_on_partial_ord)]
    pub(crate) fn new(
        face: &PolygonFace,
        positions: &[Float3],
    ) -> Result<PolygonInsetFace, GeometryError> {
        // Swift runs the triangulation first purely for its validation side effect.
        let _ = triangulate(face, positions)?;
        let origin = positions[face.vertices[0] as usize];
        let normal = geometry_unit(geometry_normal(face, positions), GEOMETRY_UNIT_FALLBACK);
        let edge = positions[face.vertices[1] as usize] - origin;
        if !(simd_length_squared(edge) > 0.0) {
            return Err(GeometryError::invalid_mesh("inset has a zero-length edge"));
        }
        let x = geometry_unit(edge, GEOMETRY_UNIT_FALLBACK);
        let y = simd_cross(normal, x);
        let start = origin;
        let axis_x = x;
        let axis_y = y;
        let vertices: Vec<Float3> = face
            .vertices
            .iter()
            .map(|index| positions[*index as usize])
            .collect();
        let extent = vertices
            .iter()
            .fold(0.0_f32, |acc, value| acc.max(simd_length(*value - start)));
        if !vertices
            .iter()
            .all(|value| simd_dot(*value - start, normal).abs() <= (1e-6_f32).max(extent * 1e-5))
        {
            return Err(GeometryError::invalid_mesh("inset requires planar faces"));
        }
        let points: Vec<Double2> = vertices
            .iter()
            .map(|value| {
                let p = *value - start;
                Double2::new(
                    f64::from(simd_dot(p, axis_x)),
                    f64::from(simd_dot(p, axis_y)),
                )
            })
            .collect();
        let mut normals: Vec<Double2> = Vec::new();
        for i in 0..points.len() {
            let edge = points[(i + 1) % points.len()] - points[i];
            let length = simd_dot_f64_2(edge, edge).sqrt();
            if !(length.is_finite() && length > 0.0) {
                return Err(GeometryError::invalid_mesh("inset has a zero-length edge"));
            }
            normals.push(Double2::new(-edge.y, edge.x) / length);
        }
        for i in 0..points.len() {
            let a = normals[(i + points.len() - 1) % points.len()];
            let b = normals[i];
            if !(a.x * b.y - a.y * b.x >= -1e-10 && 1.0 + simd_dot_f64_2(a, b) > 1e-8) {
                return Err(GeometryError::invalid_mesh(
                    "inset currently requires convex faces",
                ));
            }
        }
        let inward = normals.clone();
        let center = points
            .iter()
            .fold(Double2::ZERO, |acc, p| acc + *p / points.len() as f64);
        let radius = (0..points.len())
            .map(|index| simd_dot_f64_2(center - points[index], normals[index]))
            .fold(f64::INFINITY, f64::min);
        if !(radius.is_finite() && radius > 0.0) {
            return Err(GeometryError::invalid_mesh("degenerate inset face"));
        }
        // A short chamfer can disappear before the polygon reaches its center.
        // Bound every miter against every offset edge, including distant edges.
        let mut maximum = radius;
        for i in 0..points.len() {
            let a = normals[(i + points.len() - 1) % points.len()];
            let b = normals[i];
            let velocity = (a + b) / (1.0 + simd_dot_f64_2(a, b));
            for j in 0..points.len() {
                if j == i || j == (i + points.len() - 1) % points.len() {
                    continue;
                }
                let closing = 1.0 - simd_dot_f64_2(velocity, normals[j]);
                if closing > 1e-10 {
                    maximum =
                        maximum.min(simd_dot_f64_2(points[i] - points[j], normals[j]) / closing);
                }
            }
        }
        let safe_distance = (maximum * 0.25) as f32;
        if !(safe_distance.is_finite() && safe_distance > 0.0) {
            return Err(GeometryError::invalid_mesh("degenerate inset face"));
        }
        let uv = match &face.uvs {
            Some(uvs) => Some(PolygonUVProjection::new(&vertices, uvs)?),
            None => None,
        };
        Ok(PolygonInsetFace {
            origin,
            x,
            y,
            points,
            inward,
            uv,
            safe_distance,
        })
    }

    pub(crate) fn inset(&self, distance: f32) -> Result<Vec<Float3>, GeometryError> {
        let width = f64::from(distance);
        let tolerance = (1e-12_f64).max(width * 1e-6);
        let result: Vec<Double2> = (0..self.points.len())
            .map(|i| {
                let a = self.inward[(i + self.points.len() - 1) % self.points.len()];
                let b = self.inward[i];
                self.points[i] + (a + b) * (width / (1.0 + simd_dot_f64_2(a, b)))
            })
            .collect();
        let valid = result.iter().all(|point| {
            (0..self.points.len()).all(|index| {
                simd_dot_f64_2(*point - self.points[index], self.inward[index]) >= width - tolerance
            })
        });
        if !valid {
            return Err(GeometryError::invalid_parameter(
                "inset width collapses the face",
            ));
        }
        Ok(result
            .iter()
            .map(|point| self.origin + self.x * (point.x as f32) + self.y * (point.y as f32))
            .collect())
    }
}
