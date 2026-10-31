//! Per-face inset operations on the control mesh.
//!
//! Ported from `Engine/Sources/AssetPipeline/Geometry/PolygonInset.swift`.

use std::collections::BTreeSet;

use diffuse_math::simd::simd_compat::Float2;

use crate::geometry::polygon_inset_face::PolygonInsetFace;
use crate::geometry::polygon_mesh::{GeometryError, GeometryLimits, PolygonFace, PolygonMesh};
use crate::geometry::polygon_triangulation::triangulate;

impl PolygonMesh {
    /// The largest inset the tightest selected face can absorb, capped at
    /// `preferred`.
    /// The `!(x > 0.0)` comparisons are deliberate: they are the NaN-safe spelling of
    /// Swift's `guard x > 0 else`, which takes the fallback path for NaN as well as
    /// for zero. Rewriting them as `x <= 0.0` would let NaN through and change the
    /// geometry output.
    #[allow(clippy::neg_cmp_op_on_partial_ord)]
    pub fn suggested_inset_distance(
        &self,
        selection: &BTreeSet<i64>,
        preferred: f32,
        limits: GeometryLimits,
    ) -> Result<f32, GeometryError> {
        self.validate(limits)?;
        if selection.is_empty()
            || !selection
                .iter()
                .all(|index| (*index >= 0) && ((*index as usize) < self.faces.len()))
            || !preferred.is_finite()
            || !(preferred > 0.0)
        {
            return Err(GeometryError::invalid_parameter("inset selection/width"));
        }
        let mut distance = preferred;
        for index in selection {
            let plan = PolygonInsetFace::new(&self.faces[*index as usize], &self.positions)?;
            distance = distance.min(plan.safe_distance);
        }
        Ok(distance)
    }

    /// Insets each selected convex planar face independently. Cap face indices
    /// stay stable; all original boundary vertices, materials and UV seams remain.
    /// The `!(x > 0.0)` comparisons are deliberate: they are the NaN-safe spelling of
    /// Swift's `guard x > 0 else`, which takes the fallback path for NaN as well as
    /// for zero. Rewriting them as `x <= 0.0` would let NaN through and change the
    /// geometry output.
    #[allow(clippy::neg_cmp_op_on_partial_ord)]
    pub fn inset(
        &mut self,
        selection: &BTreeSet<i64>,
        distance: f32,
        limits: GeometryLimits,
    ) -> Result<(), GeometryError> {
        self.validate(limits)?;
        if selection.is_empty()
            || !selection
                .iter()
                .all(|index| (*index >= 0) && ((*index as usize) < self.faces.len()))
            || !distance.is_finite()
            || !(distance > 0.0)
        {
            return Err(GeometryError::invalid_parameter("inset selection/width"));
        }
        let _ = self.edge_uses()?;
        let corners = self.corner_count();
        let selected_corners: i64 = selection
            .iter()
            .map(|index| self.faces[*index as usize].vertices.len() as i64)
            .sum();
        if selected_corners > (limits.max_face_corners - corners) / 4 {
            return Err(GeometryError::BudgetExceeded);
        }
        limits.check(
            self.positions.len() as i64 + selected_corners,
            corners + selected_corners * 4,
        )?;
        let mut result = self.clone();
        for index in selection {
            let face = self.faces[*index as usize].clone();
            let plan = PolygonInsetFace::new(&face, &self.positions)?;
            let points = plan.inset(distance)?;
            let base = result.positions.len() as i64;
            result.positions.extend_from_slice(&points);
            let cap_uvs: Option<Vec<Float2>> = plan.uv.as_ref().map(|projection| {
                points
                    .iter()
                    .map(|point| projection.project(*point))
                    .collect()
            });
            result.faces[*index as usize] = PolygonFace::new(
                (base..(base + points.len() as i64)).collect(),
                cap_uvs.clone(),
                face.material_index,
            );
            for i in 0..face.vertices.len() {
                let j = (i + 1) % face.vertices.len();
                let uvs = face.uvs.as_ref().map(|uvs| {
                    let cap = cap_uvs
                        .as_ref()
                        .expect("cap UVs exist when the source face carries UVs");
                    vec![uvs[i], uvs[j], cap[j], cap[i]]
                });
                result.faces.push(PolygonFace::new(
                    vec![
                        face.vertices[i],
                        face.vertices[j],
                        base + j as i64,
                        base + i as i64,
                    ],
                    uvs,
                    face.material_index,
                ));
            }
        }
        result.validate(limits)?;
        let _ = result.edge_uses()?;
        for face in &result.faces {
            let _ = triangulate(face, &result.positions)?;
        }
        *self = result;
        Ok(())
    }
}
