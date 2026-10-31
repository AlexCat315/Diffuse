//! Ear clipping on the dominant projection plane.
//!
//! Ported from `Engine/Sources/AssetPipeline/Geometry/PolygonTriangulation.swift`.
//! Returns corner indices so UV seams and material boundaries survive.

use diffuse_math::simd::simd_compat::{Double2, Float3, simd_length_squared};

use crate::geometry::polygon_mesh::{GeometryError, PolygonFace, geometry_finite, geometry_normal};

/// Triangulates `face` into corner indices (a multiple of three).
/// The `!(x > 0.0)` comparisons are deliberate: they are the NaN-safe spelling of
/// Swift's `guard x > 0 else`, which takes the fallback path for NaN as well as
/// for zero. Rewriting them as `x <= 0.0` would let NaN through and change the
/// geometry output.
#[allow(clippy::neg_cmp_op_on_partial_ord)]
pub fn triangulate(face: &PolygonFace, positions: &[Float3]) -> Result<Vec<usize>, GeometryError> {
    let normal = geometry_normal(face, positions);
    if !geometry_finite(normal) || !(simd_length_squared(normal) > 1e-20) {
        return Err(GeometryError::invalid_mesh("degenerate polygon"));
    }
    let n = Float3::new(normal.x.abs(), normal.y.abs(), normal.z.abs());
    let axis = if n.x > n.y && n.x > n.z {
        0
    } else if n.y > n.z {
        1
    } else {
        2
    };
    let origin = positions[face.vertices[0] as usize];
    let points: Vec<Double2> = face
        .vertices
        .iter()
        .map(|index| {
            let p = positions[*index as usize] - origin;
            match axis {
                0 => Double2::new(f64::from(p.y), f64::from(p.z)),
                1 => Double2::new(f64::from(p.z), f64::from(p.x)),
                _ => Double2::new(f64::from(p.x), f64::from(p.y)),
            }
        })
        .collect();
    fn cross(a: Double2, b: Double2, c: Double2) -> f64 {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }
    let extent = points
        .iter()
        .fold(0.0_f64, |acc, p| acc.max(p.x.abs().max(p.y.abs())));
    let epsilon = (extent * extent * 1e-12).max(1e-24);
    let distance_epsilon = (extent * 1e-12).max(1e-15);
    fn on_segment(p: Double2, a: Double2, b: Double2, distance_epsilon: f64) -> bool {
        p.x >= a.x.min(b.x) - distance_epsilon
            && p.x <= a.x.max(b.x) + distance_epsilon
            && p.y >= a.y.min(b.y) - distance_epsilon
            && p.y <= a.y.max(b.y) + distance_epsilon
    }
    let zero = Double2::new(0.0, 0.0);
    let area = (0..points.len()).fold(0.0_f64, |acc, index| {
        acc + cross(zero, points[index], points[(index + 1) % points.len()])
    });
    if !(area.abs() > epsilon) {
        return Err(GeometryError::invalid_mesh("zero-area polygon"));
    }
    let sign = if area > 0.0 { 1.0 } else { -1.0 };
    // Reject crossing edges explicitly; an ear alone does not prove simplicity.
    for i in 0..points.len() {
        let next_i = (i + 1) % points.len();
        for j in (i + 1)..points.len() {
            let next_j = (j + 1) % points.len();
            if next_i == j || next_j == i {
                continue;
            }
            let a = cross(points[i], points[next_i], points[j]);
            let b = cross(points[i], points[next_i], points[next_j]);
            let c = cross(points[j], points[next_j], points[i]);
            let d = cross(points[j], points[next_j], points[next_i]);
            let crossing = ((a > epsilon && b < -epsilon) || (a < -epsilon && b > epsilon))
                && ((c > epsilon && d < -epsilon) || (c < -epsilon && d > epsilon));
            let touching = (a.abs() <= epsilon
                && on_segment(points[j], points[i], points[next_i], distance_epsilon))
                || (b.abs() <= epsilon
                    && on_segment(points[next_j], points[i], points[next_i], distance_epsilon))
                || (c.abs() <= epsilon
                    && on_segment(points[i], points[j], points[next_j], distance_epsilon))
                || (d.abs() <= epsilon
                    && on_segment(points[next_i], points[j], points[next_j], distance_epsilon));
            if crossing || touching {
                return Err(GeometryError::invalid_mesh("self-intersecting polygon"));
            }
        }
    }
    let mut remaining: Vec<usize> = (0..points.len()).collect();
    let mut result: Vec<usize> = Vec::new();
    while remaining.len() > 3 {
        let mut found = false;
        for i in 0..remaining.len() {
            let a = remaining[(i + remaining.len() - 1) % remaining.len()];
            let b = remaining[i];
            let c = remaining[(i + 1) % remaining.len()];
            if !(sign * cross(points[a], points[b], points[c]) > epsilon) {
                continue;
            }
            let contains = remaining.iter().any(|p| {
                *p != a
                    && *p != b
                    && *p != c
                    && sign * cross(points[a], points[b], points[*p]) >= -epsilon
                    && sign * cross(points[b], points[c], points[*p]) >= -epsilon
                    && sign * cross(points[c], points[a], points[*p]) >= -epsilon
            });
            if contains {
                continue;
            }
            result.extend_from_slice(&[a, b, c]);
            remaining.remove(i);
            found = true;
            break;
        }
        if !found {
            return Err(GeometryError::invalid_mesh(
                "polygon cannot be triangulated",
            ));
        }
    }
    if !(sign
        * cross(
            points[remaining[0]],
            points[remaining[1]],
            points[remaining[2]],
        )
        > epsilon)
    {
        return Err(GeometryError::invalid_mesh("degenerate polygon triangle"));
    }
    result.extend_from_slice(&remaining);
    Ok(result)
}
