//! Attribute compatibility checks for a dissolve region.
//!
//! Ported from `Engine/Sources/AssetPipeline/Geometry/PolygonDissolveAttributes.swift`.

use std::collections::{BTreeMap, BTreeSet};

use diffuse_math::simd::simd_compat::{Float2, simd_distance2, simd_dot, simd_length};

use crate::geometry::polygon_mesh::{
    GEOMETRY_UNIT_FALLBACK, GeometryError, PolygonMesh, geometry_normal, geometry_unit,
};
use crate::geometry::polygon_uv_projection::PolygonUVProjection;

impl PolygonMesh {
    /// A merged polygon can store only one material and one UV per boundary
    /// corner. Prove that removing its interior does not discard a seam or
    /// change a piecewise UV mapping into a different interpolation.
    /// The `!(x > 0.0)` comparisons are deliberate: they are the NaN-safe spelling of
    /// Swift's `guard x > 0 else`, which takes the fallback path for NaN as well as
    /// for zero. Rewriting them as `x <= 0.0` would let NaN through and change the
    /// geometry output.
    #[allow(clippy::neg_cmp_op_on_partial_ord)]
    pub(crate) fn dissolve_attributes(
        &self,
        indices: &[usize],
    ) -> Result<Option<BTreeMap<i64, Float2>>, GeometryError> {
        let first = &self.faces[indices[0]];
        let mut vertex_set: BTreeSet<i64> = BTreeSet::new();
        for index in indices {
            vertex_set.extend(self.faces[*index].vertices.iter().copied());
        }
        let vertices: Vec<i64> = vertex_set.into_iter().collect();
        if !indices
            .iter()
            .all(|index| self.faces[*index].material_index == first.material_index)
        {
            return Err(GeometryError::invalid_mesh(
                "dissolve crosses a material boundary",
            ));
        }
        let origin = self.positions[vertices[0] as usize];
        let normal = geometry_unit(
            geometry_normal(first, &self.positions),
            GEOMETRY_UNIT_FALLBACK,
        );
        let extent = vertices.iter().fold(0.0_f32, |acc, index| {
            acc.max(simd_length(self.positions[*index as usize] - origin))
        });
        if !vertices.iter().all(|index| {
            simd_dot(self.positions[*index as usize] - origin, normal).abs()
                <= (1e-6_f32).max(extent * 1e-5)
        }) {
            return Err(GeometryError::invalid_mesh(
                "dissolve requires coplanar faces",
            ));
        }
        let mut values: BTreeMap<i64, Float2> = BTreeMap::new();
        for index in indices {
            let face = &self.faces[*index];
            if face.uvs.is_none() != first.uvs.is_none() {
                return Err(GeometryError::invalid_mesh(
                    "dissolve crosses a UV boundary",
                ));
            }
            let Some(uvs) = &face.uvs else {
                continue;
            };
            for (corner, vertex) in face.vertices.iter().enumerate() {
                if let Some(previous) = values.get(vertex)
                    && simd_distance2(*previous, uvs[corner]) > 1e-5
                {
                    return Err(GeometryError::invalid_mesh("dissolve crosses a UV seam"));
                }
                values.insert(*vertex, uvs[corner]);
            }
        }
        if first.uvs.is_none() {
            return Ok(None);
        }
        let projected_positions: Vec<_> = vertices
            .iter()
            .map(|index| self.positions[*index as usize])
            .collect();
        let projected_uvs: Vec<Float2> = vertices.iter().map(|index| values[index]).collect();
        // Constructed for validation only, mirroring Swift's discarded `_ =`.
        let _ = PolygonUVProjection::new(&projected_positions, &projected_uvs)?;
        Ok(Some(values))
    }
}
