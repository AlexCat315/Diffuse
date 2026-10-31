//! Built-in box and grid polygon sources.
//!
//! Ported from `Engine/Sources/AssetPipeline/Geometry/GeometryPrimitives.swift`.

use diffuse_math::simd::simd_compat::{Float2, Float3};

use crate::geometry::polygon_mesh::{
    GeometryError, GeometryLimits, PolygonFace, PolygonMesh, geometry_finite,
};

/// Factory for the primitive control meshes.
pub struct GeometryPrimitives;

impl GeometryPrimitives {
    /// The `!(x > 0.0)` comparisons are deliberate: they are the NaN-safe spelling of
    /// Swift's `guard x > 0 else`, which takes the fallback path for NaN as well as
    /// for zero. Rewriting them as `x <= 0.0` would let NaN through and change the
    /// geometry output.
    #[allow(clippy::neg_cmp_op_on_partial_ord)]
    pub fn box_mesh(size: Float3) -> Result<PolygonMesh, GeometryError> {
        if !geometry_finite(size) || !(size.x > 0.0) || !(size.y > 0.0) || !(size.z > 0.0) {
            return Err(GeometryError::invalid_parameter("box size"));
        }
        let points: [Float3; 8] = [
            Float3::new(-1.0, -1.0, -1.0),
            Float3::new(1.0, -1.0, -1.0),
            Float3::new(1.0, 1.0, -1.0),
            Float3::new(-1.0, 1.0, -1.0),
            Float3::new(-1.0, -1.0, 1.0),
            Float3::new(1.0, -1.0, 1.0),
            Float3::new(1.0, 1.0, 1.0),
            Float3::new(-1.0, 1.0, 1.0),
        ];
        let uv: Vec<Float2> = vec![
            Float2::new(0.0, 0.0),
            Float2::new(1.0, 0.0),
            Float2::new(1.0, 1.0),
            Float2::new(0.0, 1.0),
        ];
        let indices: [[i64; 4]; 6] = [
            [0, 3, 2, 1],
            [4, 5, 6, 7],
            [0, 1, 5, 4],
            [3, 7, 6, 2],
            [0, 4, 7, 3],
            [1, 2, 6, 5],
        ];
        Ok(PolygonMesh::new(
            points.iter().map(|point| *point * size * 0.5).collect(),
            indices
                .iter()
                .map(|face| PolygonFace::new(face.to_vec(), Some(uv.clone()), 0))
                .collect(),
        ))
    }

    /// `GeometryPrimitives.box()` with Swift's `size = SIMD3(repeating: 1)`.
    pub fn unit_box() -> Result<PolygonMesh, GeometryError> {
        GeometryPrimitives::box_mesh(Float3::ONE)
    }

    /// XZ grid with upward-facing quads and normalized UVs.
    /// The `!(x > 0.0)` comparisons are deliberate: they are the NaN-safe spelling of
    /// Swift's `guard x > 0 else`, which takes the fallback path for NaN as well as
    /// for zero. Rewriting them as `x <= 0.0` would let NaN through and change the
    /// geometry output.
    #[allow(clippy::neg_cmp_op_on_partial_ord)]
    pub fn grid(
        size: Float2,
        segments: (i64, i64),
        limits: GeometryLimits,
    ) -> Result<PolygonMesh, GeometryError> {
        let (segments_x, segments_y) = segments;
        if !size.x.is_finite()
            || !size.y.is_finite()
            || !(size.x > 0.0)
            || !(size.y > 0.0)
            || !(segments_x > 0)
            || !(segments_y > 0)
            || !(segments_x < limits.max_vertices)
            || !(segments_y < limits.max_vertices)
        {
            return Err(GeometryError::invalid_parameter("grid size/segments"));
        }
        if !(segments_x < limits.max_vertices / (segments_y + 1))
            || !(segments_x <= limits.max_face_corners / 4 / segments_y)
        {
            return Err(GeometryError::BudgetExceeded);
        }
        let mut points: Vec<Float3> = Vec::new();
        let mut faces: Vec<PolygonFace> = Vec::new();
        for y in 0..=segments_y {
            for x in 0..=segments_x {
                points.push(Float3::new(
                    (x as f32 / segments_x as f32 - 0.5) * size.x,
                    0.0,
                    (y as f32 / segments_y as f32 - 0.5) * size.y,
                ));
            }
        }
        for y in 0..segments_y {
            for x in 0..segments_x {
                let a = y * (segments_x + 1) + x;
                let b = a + segments_x + 1;
                let u0 = x as f32 / segments_x as f32;
                let u1 = (x + 1) as f32 / segments_x as f32;
                let v0 = y as f32 / segments_y as f32;
                let v1 = (y + 1) as f32 / segments_y as f32;
                faces.push(PolygonFace::new(
                    vec![a, b, b + 1, a + 1],
                    Some(vec![
                        Float2::new(u0, v0),
                        Float2::new(u0, v1),
                        Float2::new(u1, v1),
                        Float2::new(u1, v0),
                    ]),
                    0,
                ));
            }
        }
        Ok(PolygonMesh::new(points, faces))
    }
}
