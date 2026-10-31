//! Cubic Bézier splines and the parallel-transported tube sweep.
//!
//! Ported from `Engine/Sources/AssetPipeline/Geometry/BezierSpline.swift`.

use diffuse_math::simd::simd_compat::{Float2, Float3, simd_cross, simd_dot, simd_length_squared};
use serde::{Deserialize, Serialize};

use crate::geometry::polygon_mesh::{
    GeometryError, GeometryLimits, PolygonFace, PolygonMesh, geometry_finite, geometry_unit,
};

/// One control point. Handles are absolute positions in the same space as
/// `position`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct BezierControlPoint {
    pub position: Float3,
    #[serde(rename = "handleIn")]
    pub handle_in: Float3,
    #[serde(rename = "handleOut")]
    pub handle_out: Float3,
}

impl BezierControlPoint {
    pub fn new(position: Float3, handle_in: Float3, handle_out: Float3) -> Self {
        BezierControlPoint {
            position,
            handle_in,
            handle_out,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize, Default)]
pub struct BezierSpline {
    pub points: Vec<BezierControlPoint>,
    pub closed: bool,
}

impl BezierSpline {
    pub fn new(points: Vec<BezierControlPoint>, closed: bool) -> Self {
        BezierSpline { points, closed }
    }

    /// The `!(x > 0.0)` comparisons are deliberate: they are the NaN-safe spelling of
    /// Swift's `guard x > 0 else`, which takes the fallback path for NaN as well as
    /// for zero. Rewriting them as `x <= 0.0` would let NaN through and change the
    /// geometry output.
    #[allow(clippy::neg_cmp_op_on_partial_ord)]
    pub fn position(&self, segment: i64, t: f32) -> Result<Float3, GeometryError> {
        let count = if self.closed {
            self.points.len() as i64
        } else {
            self.points.len() as i64 - 1
        };
        if !(self.points.len() >= 2)
            || !(segment >= 0)
            || !(segment < count)
            || !t.is_finite()
            || !(0.0..=1.0).contains(&t)
            || !self.points.iter().all(|point| {
                geometry_finite(point.position)
                    && geometry_finite(point.handle_in)
                    && geometry_finite(point.handle_out)
            })
        {
            return Err(GeometryError::invalid_parameter(
                "Bezier segment/control points",
            ));
        }
        Ok(self.sample(segment as usize, t))
    }

    fn sample(&self, segment: usize, t: f32) -> Float3 {
        let a = self.points[segment].clone();
        let b = self.points[(segment + 1) % self.points.len()].clone();
        let u = 1.0 - t;
        a.position * (u * u * u)
            + a.handle_out * (3.0 * u * u * t)
            + b.handle_in * (3.0 * u * t * t)
            + b.position * (t * t * t)
    }

    /// Parallel-transported frames avoid the flips of a fixed world-up sweep.
    /// The `!(x > 0.0)` comparisons are deliberate: they are the NaN-safe spelling of
    /// Swift's `guard x > 0 else`, which takes the fallback path for NaN as well as
    /// for zero. Rewriting them as `x <= 0.0` would let NaN through and change the
    /// geometry output.
    #[allow(clippy::neg_cmp_op_on_partial_ord)]
    pub fn tube(
        &self,
        parameters: TubeParameters,
        limits: GeometryLimits,
    ) -> Result<PolygonMesh, GeometryError> {
        let TubeParameters {
            radius,
            radial_segments,
            samples_per_segment,
            capped,
        } = parameters;
        let minimum_points = if self.closed { 3 } else { 2 };
        if !(self.points.len() >= minimum_points)
            || !((self.points.len() as i64) <= limits.max_vertices)
            || !radius.is_finite()
            || !(radius > 0.0)
            || !(3..=256).contains(&radial_segments)
            || !(1..=4096).contains(&samples_per_segment)
        {
            return Err(GeometryError::invalid_parameter("tube parameters"));
        }
        let _ = self.position(0, 0.0)?;
        let segments: i64 = if self.closed {
            self.points.len() as i64
        } else {
            self.points.len() as i64 - 1
        };
        if !(segments <= (limits.max_vertices / radial_segments - 1) / samples_per_segment) {
            return Err(GeometryError::BudgetExceeded);
        }
        let steps = segments * samples_per_segment;
        let ring_count = steps + if self.closed { 0 } else { 1 };
        let cap_corners = if !self.closed && capped {
            radial_segments * 2
        } else {
            0
        };
        limits.check(
            ring_count * radial_segments,
            steps * radial_segments * 4 + cap_corners,
        )?;
        let mut centers: Vec<Float3> = Vec::new();
        for i in 0..ring_count {
            let segment = (i / samples_per_segment).min(segments - 1);
            let t = (i - segment * samples_per_segment) as f32 / samples_per_segment as f32;
            centers.push(self.sample(segment as usize, t));
        }
        if !centers.iter().all(|center| geometry_finite(*center)) {
            return Err(GeometryError::invalid_mesh("non-finite curve sample"));
        }
        let mut tangents: Vec<Float3> = Vec::new();
        for i in 0..centers.len() {
            let previous = if self.closed {
                centers[(i + centers.len() - 1) % centers.len()]
            } else {
                centers[i.saturating_sub(1)]
            };
            let following = if self.closed {
                centers[(i + 1) % centers.len()]
            } else {
                centers[(centers.len() - 1).min(i + 1)]
            };
            let forward = simd_length_squared(following - centers[i]) > 1e-16;
            let last_open = !self.closed && i == centers.len() - 1;
            if !(forward || last_open) || !(simd_length_squared(following - previous) > 1e-16) {
                return Err(GeometryError::invalid_mesh(
                    "coincident samples or cusp in curve",
                ));
            }
            tangents.push(geometry_unit(
                following - previous,
                Float3::new(0.0, 1.0, 0.0),
            ));
        }
        let transport = |normal: Float3, from: Float3, to: Float3| -> Float3 {
            let axis = simd_cross(from, to);
            let cosine = simd_dot(from, to);
            if cosine < -0.9999 {
                return geometry_unit(
                    normal - to * simd_dot(normal, to),
                    Float3::new(0.0, 1.0, 0.0),
                );
            }
            let rotated = normal
                + simd_cross(axis, normal)
                + simd_cross(axis, simd_cross(axis, normal)) / (1.0 + cosine).max(1e-6);
            geometry_unit(
                rotated - to * simd_dot(rotated, to),
                Float3::new(0.0, 1.0, 0.0),
            )
        };
        let reference = if tangents[0].y.abs() < 0.9 {
            Float3::new(0.0, 1.0, 0.0)
        } else {
            Float3::new(1.0, 0.0, 0.0)
        };
        let mut normals: Vec<Float3> = vec![geometry_unit(
            simd_cross(reference, tangents[0]),
            Float3::new(0.0, 1.0, 0.0),
        )];
        for i in 1..centers.len() {
            let previous = normals[i - 1];
            normals.push(transport(previous, tangents[i - 1], tangents[i]));
        }
        if self.closed {
            let last = normals[centers.len() - 1];
            let end = transport(last, tangents[centers.len() - 1], tangents[0]);
            let correction =
                simd_dot(tangents[0], simd_cross(end, normals[0])).atan2(simd_dot(end, normals[0]));
            for i in 0..normals.len() {
                let angle = correction * i as f32 / centers.len() as f32;
                normals[i] =
                    normals[i] * angle.cos() + simd_cross(tangents[i], normals[i]) * angle.sin();
            }
        }
        let mut positions: Vec<Float3> = Vec::new();
        let mut faces: Vec<PolygonFace> = Vec::new();
        for i in 0..centers.len() {
            let binormal = simd_cross(tangents[i], normals[i]);
            for j in 0..radial_segments {
                let angle = 2.0 * std::f32::consts::PI * j as f32 / radial_segments as f32;
                positions.push(
                    centers[i] + (normals[i] * angle.cos() + binormal * angle.sin()) * radius,
                );
            }
        }
        for i in 0..steps {
            let next = (i + 1) % ring_count;
            for j in 0..radial_segments {
                let k = (j + 1) % radial_segments;
                let u = j as f32 / radial_segments as f32;
                let v = i as f32 / steps as f32;
                let un = (j + 1) as f32 / radial_segments as f32;
                let vn = (i + 1) as f32 / steps as f32;
                faces.push(PolygonFace::new(
                    vec![
                        i * radial_segments + j,
                        i * radial_segments + k,
                        next * radial_segments + k,
                        next * radial_segments + j,
                    ],
                    Some(vec![
                        Float2::new(u, v),
                        Float2::new(un, v),
                        Float2::new(un, vn),
                        Float2::new(u, vn),
                    ]),
                    0,
                ));
            }
        }
        if !self.closed && capped {
            let cap_uvs: Vec<Float2> = (0..radial_segments)
                .map(|j| {
                    let a = 2.0 * std::f32::consts::PI * j as f32 / radial_segments as f32;
                    Float2::new(0.5 + 0.5 * a.cos(), 0.5 + 0.5 * a.sin())
                })
                .collect();
            faces.push(PolygonFace::new(
                (0..radial_segments).rev().collect(),
                Some(cap_uvs.iter().rev().copied().collect()),
                0,
            ));
            faces.push(PolygonFace::new(
                (0..radial_segments)
                    .map(|j| (ring_count - 1) * radial_segments + j)
                    .collect(),
                Some(cap_uvs),
                0,
            ));
        }
        Ok(PolygonMesh::new(positions, faces))
    }
}

/// Swift's `tube(...)` parameter list, grouped so the call stays readable.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TubeParameters {
    pub radius: f32,
    pub radial_segments: i64,
    pub samples_per_segment: i64,
    pub capped: bool,
}

impl Default for TubeParameters {
    fn default() -> Self {
        TubeParameters {
            radius: 0.0,
            radial_segments: 12,
            samples_per_segment: 16,
            capped: true,
        }
    }
}

impl TubeParameters {
    pub fn new(radius: f32) -> Self {
        TubeParameters {
            radius,
            ..TubeParameters::default()
        }
    }
}
