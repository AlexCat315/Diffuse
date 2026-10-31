//! Connected-region extrusion in control space.
//!
//! Ported from `Engine/Sources/AssetPipeline/Geometry/PolygonEditing.swift`.

use std::collections::{BTreeSet, HashMap};

use diffuse_math::simd::simd_compat::{
    Float2, Float3, Float4, Float4x4, mul_4x4_float4, simd_length_squared,
};

use crate::geometry::polygon_mesh::{
    GeometryError, GeometryLimits, PolygonEdgeUse, PolygonFace, PolygonMesh, PolygonMeshEdge,
    geometry_finite,
};
use crate::geometry::polygon_triangulation::triangulate;

impl PolygonMesh {
    /// Every undirected edge of the mesh, sorted.
    pub fn edges(&self) -> Vec<PolygonMeshEdge> {
        let mut result: BTreeSet<PolygonMeshEdge> = BTreeSet::new();
        for face in &self.faces {
            for i in 0..face.vertices.len() {
                result.insert(PolygonMeshEdge::new(
                    face.vertices[i],
                    face.vertices[(i + 1) % face.vertices.len()],
                ));
            }
        }
        result.into_iter().collect()
    }

    /// Applies an affine transform to a vertex selection in control space.
    /// The `!(x > 0.0)` comparisons are deliberate: they are the NaN-safe spelling of
    /// Swift's `guard x > 0 else`, which takes the fallback path for NaN as well as
    /// for zero. Rewriting them as `x <= 0.0` would let NaN through and change the
    /// geometry output.
    #[allow(clippy::neg_cmp_op_on_partial_ord)]
    pub fn transform(
        &mut self,
        selection: &BTreeSet<i64>,
        matrix: Float4x4,
        limits: GeometryLimits,
    ) -> Result<(), GeometryError> {
        self.validate(limits)?;
        let all_finite = (0..4).all(|column| {
            let value = matrix.column(column);
            value.x.is_finite() && value.y.is_finite() && value.z.is_finite() && value.w.is_finite()
        });
        let c0 = matrix.column(0);
        let c1 = matrix.column(1);
        let c2 = matrix.column(2);
        let c3 = matrix.column(3);
        if !selection
            .iter()
            .all(|index| (*index >= 0) && ((*index as usize) < self.positions.len()))
            || !all_finite
            || !(c0.w.abs() < 1e-6)
            || !(c1.w.abs() < 1e-6)
            || !(c2.w.abs() < 1e-6)
            || !((c3.w - 1.0).abs() < 1e-6)
        {
            return Err(GeometryError::invalid_parameter(
                "vertex selection/affine transform",
            ));
        }
        let mut result = self.clone();
        for index in selection {
            let position = self.positions[*index as usize];
            let p = mul_4x4_float4(matrix, Float4::new(position.x, position.y, position.z, 1.0));
            result.positions[*index as usize] = Float3::new(p.x, p.y, p.z);
        }
        result.validate(limits)?;
        for face in &result.faces {
            let _ = triangulate(face, &result.positions)?;
        }
        *self = result;
        Ok(())
    }

    /// Extrudes connected face regions without generating internal side walls.
    /// Cap face indices are preserved; unused interior base vertices are removed.
    /// The `!(x > 0.0)` comparisons are deliberate: they are the NaN-safe spelling of
    /// Swift's `guard x > 0 else`, which takes the fallback path for NaN as well as
    /// for zero. Rewriting them as `x <= 0.0` would let NaN through and change the
    /// geometry output.
    #[allow(clippy::neg_cmp_op_on_partial_ord)]
    pub fn extrude_faces(
        &mut self,
        selection: &BTreeSet<i64>,
        offset: Float3,
        limits: GeometryLimits,
    ) -> Result<(), GeometryError> {
        self.validate(limits)?;
        if selection.is_empty()
            || !selection
                .iter()
                .all(|index| (*index >= 0) && ((*index as usize) < self.faces.len()))
            || !geometry_finite(offset)
            || !(simd_length_squared(offset) > 0.0)
        {
            return Err(GeometryError::invalid_parameter("extrusion region/offset"));
        }
        let uses = self.edge_uses()?;
        let mut edges: Vec<PolygonMeshEdge> = uses.keys().copied().collect();
        edges.sort();
        let mut boundary: Vec<PolygonEdgeUse> = Vec::new();
        for edge in edges {
            let selected: Vec<PolygonEdgeUse> = uses[&edge]
                .iter()
                .copied()
                .filter(|use_| selection.contains(&use_.face))
                .collect();
            if selected.len() == 1 {
                boundary.push(selected[0]);
            }
        }
        let mut selected_vertices: BTreeSet<i64> = BTreeSet::new();
        for index in selection {
            selected_vertices.extend(self.faces[*index as usize].vertices.iter().copied());
        }
        let mut retained: BTreeSet<i64> = BTreeSet::new();
        for (index, face) in self.faces.iter().enumerate() {
            if !selection.contains(&(index as i64)) {
                retained.extend(face.vertices.iter().copied());
            }
        }
        for edge in &boundary {
            retained.insert(edge.start);
            retained.insert(edge.end);
        }
        let base_vertices: Vec<i64> = retained.into_iter().collect();
        let corners = self.corner_count();
        if boundary.len() as i64 > (limits.max_face_corners - corners) / 4 {
            return Err(GeometryError::BudgetExceeded);
        }
        limits.check(
            base_vertices.len() as i64 + selected_vertices.len() as i64,
            corners + boundary.len() as i64 * 4,
        )?;
        let mut base: HashMap<i64, i64> = HashMap::new();
        for (offset_index, vertex) in base_vertices.iter().enumerate() {
            base.insert(*vertex, offset_index as i64);
        }
        let mut cap: HashMap<i64, i64> = HashMap::new();
        for (offset_index, vertex) in selected_vertices.iter().enumerate() {
            cap.insert(*vertex, base_vertices.len() as i64 + offset_index as i64);
        }
        let mut positions: Vec<Float3> = base_vertices
            .iter()
            .map(|index| self.positions[*index as usize])
            .collect();
        positions.extend(
            selected_vertices
                .iter()
                .map(|index| self.positions[*index as usize] + offset),
        );
        let mut result = PolygonMesh::new(positions, Vec::new());
        result.faces = self
            .faces
            .iter()
            .enumerate()
            .map(|(index, face)| {
                let remap = if selection.contains(&(index as i64)) {
                    &cap
                } else {
                    &base
                };
                PolygonFace::new(
                    face.vertices.iter().map(|vertex| remap[vertex]).collect(),
                    face.uvs.clone(),
                    face.material_index,
                )
            })
            .collect();
        for edge in &boundary {
            result.faces.push(PolygonFace::new(
                vec![
                    base[&edge.start],
                    base[&edge.end],
                    cap[&edge.end],
                    cap[&edge.start],
                ],
                Some(vec![
                    Float2::new(0.0, 0.0),
                    Float2::new(1.0, 0.0),
                    Float2::new(1.0, 1.0),
                    Float2::new(0.0, 1.0),
                ]),
                self.faces[edge.face as usize].material_index,
            ));
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
