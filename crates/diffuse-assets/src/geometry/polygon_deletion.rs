//! Component deletion with vertex compaction.
//!
//! Ported from `Engine/Sources/AssetPipeline/Geometry/PolygonDeletion.swift`.

use std::collections::{BTreeSet, HashMap};

use diffuse_math::simd::simd_compat::Float3;

use crate::geometry::polygon_mesh::{
    GeometryError, GeometryLimits, PolygonFace, PolygonMesh, PolygonMeshEdge,
};
use crate::geometry::polygon_triangulation::triangulate;

impl PolygonMesh {
    /// Deletes the selected components and their incident faces. Unreferenced
    /// vertices are compacted; removing the last face leaves an empty asset.
    pub fn delete(
        &mut self,
        vertex_selection: &BTreeSet<i64>,
        edge_selection: &BTreeSet<PolygonMeshEdge>,
        face_selection: &BTreeSet<i64>,
        limits: GeometryLimits,
    ) -> Result<(), GeometryError> {
        self.validate(limits)?;
        let edges: BTreeSet<PolygonMeshEdge> = self.edges().into_iter().collect();
        if (vertex_selection.is_empty() && edge_selection.is_empty() && face_selection.is_empty())
            || !vertex_selection
                .iter()
                .all(|index| (*index >= 0) && ((*index as usize) < self.positions.len()))
            || !face_selection
                .iter()
                .all(|index| (*index >= 0) && ((*index as usize) < self.faces.len()))
            || !edge_selection.is_subset(&edges)
        {
            return Err(GeometryError::invalid_parameter(
                "delete component selection",
            ));
        }
        let retained: Vec<PolygonFace> = self
            .faces
            .iter()
            .enumerate()
            .filter(|(index, face)| {
                if face_selection.contains(&(*index as i64)) {
                    return false;
                }
                if face
                    .vertices
                    .iter()
                    .any(|vertex| vertex_selection.contains(vertex))
                {
                    return false;
                }
                !(0..face.vertices.len()).any(|corner| {
                    edge_selection.contains(&PolygonMeshEdge::new(
                        face.vertices[corner],
                        face.vertices[(corner + 1) % face.vertices.len()],
                    ))
                })
            })
            .map(|(_, face)| face.clone())
            .collect();
        let result = PolygonMesh::new(self.positions.clone(), retained).compacted();
        result.validate(limits)?;
        for face in &result.faces {
            let _ = triangulate(face, &result.positions)?;
        }
        *self = result;
        Ok(())
    }

    /// Drops unreferenced vertices and renumbers the faces.
    pub(crate) fn compacted(&self) -> PolygonMesh {
        let mut retained: BTreeSet<i64> = BTreeSet::new();
        for face in &self.faces {
            retained.extend(face.vertices.iter().copied());
        }
        let retained: Vec<i64> = retained.into_iter().collect();
        let mut indices: HashMap<i64, i64> = HashMap::new();
        for (offset, vertex) in retained.iter().enumerate() {
            indices.insert(*vertex, offset as i64);
        }
        let positions: Vec<Float3> = retained
            .iter()
            .map(|index| self.positions[*index as usize])
            .collect();
        let faces = self
            .faces
            .iter()
            .map(|face| {
                PolygonFace::new(
                    face.vertices.iter().map(|vertex| indices[vertex]).collect(),
                    face.uvs.clone(),
                    face.material_index,
                )
            })
            .collect();
        PolygonMesh::new(positions, faces)
    }
}
