//! Face splitting and triangulation without smoothing or vertex motion.
//!
//! Ported from `Engine/Sources/AssetPipeline/Geometry/PolygonSubdivision.swift`.

use std::collections::{BTreeMap, BTreeSet};

use diffuse_math::simd::simd_compat::{Float2, Float3, simd_cross, simd_dot, simd_length_squared};

use crate::geometry::polygon_mesh::{
    GeometryError, GeometryLimits, PolygonFace, PolygonMesh, PolygonMeshEdge, geometry_normal,
};
use crate::geometry::polygon_triangulation::triangulate;

impl PolygonMesh {
    /// Splits selected polygons into quads without smoothing or moving the
    /// existing vertices. Shared midpoints are inserted into adjacent faces.
    /// The `!(x > 0.0)` comparisons are deliberate: they are the NaN-safe spelling of
    /// Swift's `guard x > 0 else`, which takes the fallback path for NaN as well as
    /// for zero. Rewriting them as `x <= 0.0` would let NaN through and change the
    /// geometry output.
    #[allow(clippy::neg_cmp_op_on_partial_ord)]
    pub fn subdivide_faces(
        &mut self,
        selection: &BTreeSet<i64>,
        limits: GeometryLimits,
    ) -> Result<BTreeSet<i64>, GeometryError> {
        self.validate(limits)?;
        if selection.is_empty()
            || !selection
                .iter()
                .all(|index| (*index >= 0) && ((*index as usize) < self.faces.len()))
        {
            return Err(GeometryError::invalid_parameter(
                "subdivision face selection",
            ));
        }
        let _ = self.edge_uses()?;
        for index in selection {
            let face = &self.faces[*index as usize];
            let normal = geometry_normal(face, &self.positions);
            let count = face.vertices.len() as f32;
            let center = face.vertices.iter().fold(Float3::ZERO, |acc, vertex| {
                acc + self.positions[*vertex as usize] / count
            });
            let tolerance = simd_length_squared(normal) * 1e-6;
            let convex = (0..face.vertices.len()).all(|i| {
                let a = self.positions[face.vertices[i] as usize];
                let b = self.positions[face.vertices[(i + 1) % face.vertices.len()] as usize];
                simd_dot(simd_cross(b - a, center - a), normal) >= -tolerance
            });
            if !convex {
                return Err(GeometryError::invalid_mesh(
                    "subdivide concave faces after triangulating them",
                ));
            }
        }
        let mut split_set: BTreeSet<PolygonMeshEdge> = BTreeSet::new();
        for index in selection {
            let vertices = &self.faces[*index as usize].vertices;
            for i in 0..vertices.len() {
                split_set.insert(PolygonMeshEdge::new(
                    vertices[i],
                    vertices[(i + 1) % vertices.len()],
                ));
            }
        }
        let split_edges: Vec<PolygonMeshEdge> = split_set.iter().copied().collect();
        let selected_corners: i64 = selection
            .iter()
            .map(|index| self.faces[*index as usize].vertices.len() as i64)
            .sum();
        let mut other_corners: i64 = 0;
        for (index, face) in self.faces.iter().enumerate() {
            if selection.contains(&(index as i64)) {
                continue;
            }
            let vertices = &face.vertices;
            other_corners += vertices.len() as i64
                + (0..vertices.len())
                    .filter(|corner| {
                        split_set.contains(&PolygonMeshEdge::new(
                            vertices[*corner],
                            vertices[(*corner + 1) % vertices.len()],
                        ))
                    })
                    .count() as i64;
        }
        if selected_corners > (limits.max_face_corners - other_corners) / 4 {
            return Err(GeometryError::BudgetExceeded);
        }
        limits.check(
            self.positions.len() as i64 + split_edges.len() as i64 + selection.len() as i64,
            other_corners + selected_corners * 4,
        )?;
        let mut result = PolygonMesh::new(self.positions.clone(), Vec::new());
        let mut midpoints: BTreeMap<PolygonMeshEdge, i64> = BTreeMap::new();
        for edge in &split_edges {
            midpoints.insert(*edge, result.positions.len() as i64);
            result
                .positions
                .push((self.positions[edge.a as usize] + self.positions[edge.b as usize]) * 0.5);
        }
        let mut selected: BTreeSet<i64> = BTreeSet::new();
        for (index, face) in self.faces.iter().enumerate() {
            let count = face.vertices.len();
            if selection.contains(&(index as i64)) {
                let center = result.positions.len() as i64;
                result
                    .positions
                    .push(face.vertices.iter().fold(Float3::ZERO, |acc, vertex| {
                        acc + self.positions[*vertex as usize] / count as f32
                    }));
                let center_uv = face.uvs.as_ref().map(|uvs| {
                    uvs.iter()
                        .fold(Float2::ZERO, |acc, uv| acc + *uv / count as f32)
                });
                for i in 0..count {
                    let prev = (i + count - 1) % count;
                    let next = (i + 1) % count;
                    let uv = face.uvs.as_ref().map(|uvs| {
                        vec![
                            uvs[i],
                            (uvs[i] + uvs[next]) * 0.5,
                            center_uv.expect("UVs exist when the face carries them"),
                            (uvs[prev] + uvs[i]) * 0.5,
                        ]
                    });
                    selected.insert(result.faces.len() as i64);
                    result.faces.push(PolygonFace::new(
                        vec![
                            face.vertices[i],
                            midpoints[&PolygonMeshEdge::new(face.vertices[i], face.vertices[next])],
                            center,
                            midpoints[&PolygonMeshEdge::new(face.vertices[prev], face.vertices[i])],
                        ],
                        uv,
                        face.material_index,
                    ));
                }
            } else {
                let mut vertices: Vec<i64> = Vec::new();
                let mut uvs: Option<Vec<Float2>> = if face.uvs.is_none() {
                    None
                } else {
                    Some(Vec::new())
                };
                for i in 0..count {
                    let next = (i + 1) % count;
                    vertices.push(face.vertices[i]);
                    if let Some(values) = &face.uvs
                        && let Some(target) = uvs.as_mut()
                    {
                        target.push(values[i]);
                    }
                    let edge = PolygonMeshEdge::new(face.vertices[i], face.vertices[next]);
                    if let Some(midpoint) = midpoints.get(&edge) {
                        vertices.push(*midpoint);
                        if let Some(values) = &face.uvs
                            && let Some(target) = uvs.as_mut()
                        {
                            target.push((values[i] + values[next]) * 0.5);
                        }
                    }
                }
                result
                    .faces
                    .push(PolygonFace::new(vertices, uvs, face.material_index));
            }
        }
        result.validate(limits)?;
        let _ = result.edge_uses()?;
        for face in &result.faces {
            let _ = triangulate(face, &result.positions)?;
        }
        *self = result;
        Ok(selected)
    }

    /// Replaces each selected polygon with its triangulation, keeping material
    /// and per-corner UVs.
    pub fn triangulate_faces(
        &mut self,
        selection: &BTreeSet<i64>,
        limits: GeometryLimits,
    ) -> Result<BTreeSet<i64>, GeometryError> {
        self.validate(limits)?;
        if selection.is_empty()
            || !selection
                .iter()
                .all(|index| (*index >= 0) && ((*index as usize) < self.faces.len()))
        {
            return Err(GeometryError::invalid_parameter(
                "triangulation face selection",
            ));
        }
        let mut corners: i64 = 0;
        for (index, face) in self.faces.iter().enumerate() {
            let count = face.vertices.len() as i64;
            corners += if selection.contains(&(index as i64)) {
                (count - 2) * 3
            } else {
                count
            };
        }
        limits.check(self.positions.len() as i64, corners)?;
        let mut result = self.clone();
        let mut polygons: Vec<PolygonFace> = Vec::new();
        let mut selected: BTreeSet<i64> = BTreeSet::new();
        for (index, face) in self.faces.iter().enumerate() {
            if !selection.contains(&(index as i64)) {
                polygons.push(face.clone());
                continue;
            }
            let triangles = triangulate(face, &self.positions)?;
            let mut i = 0;
            while i < triangles.len() {
                let corners = &triangles[i..(i + 3)];
                selected.insert(polygons.len() as i64);
                polygons.push(PolygonFace::new(
                    corners
                        .iter()
                        .map(|corner| face.vertices[*corner])
                        .collect(),
                    face.uvs
                        .as_ref()
                        .map(|uvs| corners.iter().map(|corner| uvs[*corner]).collect()),
                    face.material_index,
                ));
                i += 3;
            }
        }
        result.faces = polygons;
        result.validate(limits)?;
        *self = result;
        Ok(selected)
    }
}
