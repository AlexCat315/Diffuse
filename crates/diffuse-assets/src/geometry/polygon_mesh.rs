//! Editable polygon control meshes, shared validation and Newell's normal.
//!
//! Ported from `Engine/Sources/AssetPipeline/Geometry/PolygonMesh.swift`.

use std::collections::{BTreeSet, HashMap};

use diffuse_math::simd::simd_compat::{
    Float2, Float3, simd_cross, simd_length, simd_length_squared,
};
use serde::{Deserialize, Serialize};

use crate::asset_pipeline::MeshTopologySlice;
use crate::geometry::polygon_triangulation::triangulate;

/// Every geometry failure, matching Swift's `GeometryError` cases one for one.
#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum GeometryError {
    #[error("Invalid geometry: {0}")]
    InvalidMesh(String),
    #[error("Invalid geometry parameter: {0}")]
    InvalidParameter(String),
    #[error("Geometry evaluation exceeded its vertex/corner budget")]
    BudgetExceeded,
    #[error("Unsupported geometry document version: {0}")]
    UnsupportedVersion(i64),
}

impl GeometryError {
    pub fn invalid_mesh(reason: impl Into<String>) -> Self {
        GeometryError::InvalidMesh(reason.into())
    }

    pub fn invalid_parameter(name: impl Into<String>) -> Self {
        GeometryError::InvalidParameter(name.into())
    }

    pub fn budget_exceeded() -> Self {
        GeometryError::BudgetExceeded
    }

    /// Swift's `unsupportedVersion(version)`.
    pub fn unsupported_version(version: i64) -> Self {
        GeometryError::UnsupportedVersion(version)
    }
}

/// Bounds both control topology and the expanded GPU stream before allocation.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct GeometryLimits {
    pub max_vertices: i64,
    pub max_face_corners: i64,
}

impl Default for GeometryLimits {
    fn default() -> Self {
        GeometryLimits::new(250_000, 1_000_000)
    }
}

impl GeometryLimits {
    pub fn new(max_vertices: i64, max_face_corners: i64) -> Self {
        GeometryLimits {
            max_vertices,
            max_face_corners,
        }
    }

    pub(crate) fn check(&self, vertices: i64, corners: i64) -> Result<(), GeometryError> {
        if vertices >= 0
            && corners >= 0
            && vertices <= self.max_vertices
            && corners <= self.max_face_corners
        {
            Ok(())
        } else {
            Err(GeometryError::BudgetExceeded)
        }
    }
}

/// One authored polygon: its corner vertices, optional per-corner UVs and
/// material slot.
///
/// Swift's synthesised `Codable` writes `vertices`, `uvs` when non-nil, then
/// `materialIndex` (MIGRATION.md §5.4).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PolygonFace {
    pub vertices: Vec<i64>,
    /// Per-corner UVs allow seams without splitting the editable control mesh.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub uvs: Option<Vec<Float2>>,
    pub material_index: i64,
}

impl PolygonFace {
    pub fn new(vertices: Vec<i64>, uvs: Option<Vec<Float2>>, material_index: i64) -> Self {
        PolygonFace {
            vertices,
            uvs,
            material_index,
        }
    }

    /// Swift's memberwise defaults: `uvs: nil`, `materialIndex: 0`.
    pub fn with_vertices(vertices: Vec<i64>) -> Self {
        PolygonFace {
            vertices,
            uvs: None,
            material_index: 0,
        }
    }
}

/// Authored polygon topology, independent of the triangulated render stream.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct PolygonMesh {
    pub positions: Vec<Float3>,
    pub faces: Vec<PolygonFace>,
}

impl PolygonMesh {
    pub fn new(positions: Vec<Float3>, faces: Vec<PolygonFace>) -> Self {
        PolygonMesh { positions, faces }
    }

    /// The `!(x > 0.0)` comparisons are deliberate: they are the NaN-safe spelling of
    /// Swift's `guard x > 0 else`, which takes the fallback path for NaN as well as
    /// for zero. Rewriting them as `x <= 0.0` would let NaN through and change the
    /// geometry output.
    #[allow(clippy::neg_cmp_op_on_partial_ord)]
    pub fn validate(&self, limits: GeometryLimits) -> Result<(), GeometryError> {
        limits.check(self.positions.len() as i64, 0)?;
        if self.faces.is_empty() && !self.positions.is_empty() {
            return Err(GeometryError::invalid_mesh(
                "orphan vertices without a surface",
            ));
        }
        if !self.positions.iter().all(|value| geometry_finite(*value)) {
            return Err(GeometryError::invalid_mesh("non-finite position"));
        }
        let mut corners: i64 = 0;
        for face in &self.faces {
            let corner_count = face.vertices.len() as i64;
            if !(3..=256).contains(&corner_count)
                || !has_unique_vertices(&face.vertices)
                || !face
                    .vertices
                    .iter()
                    .all(|index| (*index >= 0) && ((*index as usize) < self.positions.len()))
                || face.material_index < 0
            {
                return Err(GeometryError::invalid_mesh(
                    "invalid polygon indices/material",
                ));
            }
            if corner_count > limits.max_face_corners - corners {
                return Err(GeometryError::BudgetExceeded);
            }
            corners += corner_count;
            if let Some(uvs) = &face.uvs
                && (uvs.len() as i64 != corner_count
                    || !uvs.iter().all(|uv| uv.x.is_finite() && uv.y.is_finite()))
            {
                return Err(GeometryError::invalid_mesh("invalid corner UVs"));
            }
        }
        Ok(())
    }

    /// Edits commit only after validation; a failed edit leaves the mesh intact.
    /// The `!(x > 0.0)` comparisons are deliberate: they are the NaN-safe spelling of
    /// Swift's `guard x > 0 else`, which takes the fallback path for NaN as well as
    /// for zero. Rewriting them as `x <= 0.0` would let NaN through and change the
    /// geometry output.
    #[allow(clippy::neg_cmp_op_on_partial_ord)]
    pub fn translate(
        &mut self,
        selection: &BTreeSet<i64>,
        offset: Float3,
        limits: GeometryLimits,
    ) -> Result<(), GeometryError> {
        if !geometry_finite(offset)
            || !selection
                .iter()
                .all(|index| (*index >= 0) && ((*index as usize) < self.positions.len()))
        {
            return Err(GeometryError::invalid_parameter("vertex selection/offset"));
        }
        let mut result = self.clone();
        for index in selection {
            result.positions[*index as usize] += offset;
        }
        result.validate(limits)?;
        *self = result;
        Ok(())
    }

    /// Extrudes one polygon, replacing it with a cap and connecting side quads.
    /// The `!(x > 0.0)` comparisons are deliberate: they are the NaN-safe spelling of
    /// Swift's `guard x > 0 else`, which takes the fallback path for NaN as well as
    /// for zero. Rewriting them as `x <= 0.0` would let NaN through and change the
    /// geometry output.
    #[allow(clippy::neg_cmp_op_on_partial_ord)]
    pub fn extrude_face(
        &mut self,
        index: i64,
        offset: Float3,
        limits: GeometryLimits,
    ) -> Result<(), GeometryError> {
        self.validate(limits)?;
        if !((index >= 0) && ((index as usize) < self.faces.len()))
            || !geometry_finite(offset)
            || simd_length_squared(offset) <= 0.0
        {
            return Err(GeometryError::invalid_parameter("extrusion face/offset"));
        }
        let face = self.faces[index as usize].clone();
        let corners = self.corner_count();
        limits.check(
            self.positions.len() as i64 + face.vertices.len() as i64,
            corners + face.vertices.len() as i64 * 4,
        )?;
        let mut result = self.clone();
        let start = result.positions.len() as i64;
        for vertex in &face.vertices {
            let base = self.positions[*vertex as usize];
            result.positions.push(base + offset);
        }
        result.faces[index as usize] = PolygonFace::new(
            (start..(start + face.vertices.len() as i64)).collect(),
            face.uvs.clone(),
            face.material_index,
        );
        for i in 0..face.vertices.len() {
            let j = (i + 1) % face.vertices.len();
            result.faces.push(PolygonFace::new(
                vec![
                    face.vertices[i],
                    face.vertices[j],
                    start + j as i64,
                    start + i as i64,
                ],
                Some(vec![
                    Float2::new(0.0, 0.0),
                    Float2::new(1.0, 0.0),
                    Float2::new(1.0, 1.0),
                    Float2::new(0.0, 1.0),
                ]),
                face.material_index,
            ));
        }
        result.validate(limits)?;
        *self = result;
        Ok(())
    }

    /// Triangulated control topology, without the renderer's split corners.
    pub fn topology_slice(&self) -> Result<MeshTopologySlice, GeometryError> {
        self.validate(GeometryLimits::default())?;
        let mut triangles: Vec<u32> = Vec::new();
        for face in &self.faces {
            for corner in triangulate(face, &self.positions)? {
                triangles.push(face.vertices[corner] as u32);
            }
        }
        Ok(MeshTopologySlice::new(
            self.positions.clone(),
            triangles,
            None,
        ))
    }

    /// Corners across every face, which Swift spells `faces.reduce(0) { … }`.
    pub(crate) fn corner_count(&self) -> i64 {
        self.faces
            .iter()
            .map(|face| face.vertices.len() as i64)
            .sum()
    }
}

/// An undirected edge between two control vertices, stored ordered.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct PolygonMeshEdge {
    pub a: i64,
    pub b: i64,
}

impl PolygonMeshEdge {
    pub fn new(a: i64, b: i64) -> Self {
        PolygonMeshEdge {
            a: a.min(b),
            b: a.max(b),
        }
    }
}

/// Swift's `typealias PolygonEdge = PolygonMeshEdge`.
pub type PolygonEdge = PolygonMeshEdge;

/// One face corner that uses an edge, and the edge's direction there.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PolygonEdgeUse {
    pub face: i64,
    pub corner: i64,
    pub start: i64,
    pub end: i64,
}

impl PolygonMesh {
    /// Classifies every edge by the corners that use it, rejecting non-manifold
    /// or inconsistently wound surfaces and disconnected vertex fans.
    pub fn edge_uses(
        &self,
    ) -> Result<HashMap<PolygonMeshEdge, Vec<PolygonEdgeUse>>, GeometryError> {
        let mut result: HashMap<PolygonMeshEdge, Vec<PolygonEdgeUse>> = HashMap::new();
        for (index, face) in self.faces.iter().enumerate() {
            for i in 0..face.vertices.len() {
                let a = face.vertices[i];
                let b = face.vertices[(i + 1) % face.vertices.len()];
                let edge = PolygonEdge::new(a, b);
                let uses = result.entry(edge).or_default();
                uses.push(PolygonEdgeUse {
                    face: index as i64,
                    corner: i as i64,
                    start: a,
                    end: b,
                });
                let uses = result.get(&edge).expect("edge was just inserted");
                // Swift: `guard uses.count <= 2, uses.count == 1 || uses[0].start != a`,
                // so the second corner must traverse the edge the other way.
                let single = uses.len() == 1;
                let same_direction = uses.first().map(|use_| use_.start) == Some(a);
                if uses.len() > 2 || (!single && same_direction) {
                    return Err(GeometryError::invalid_mesh(
                        "non-manifold or inconsistently wound edge",
                    ));
                }
            }
        }
        // Edges alone cannot detect two disconnected surface fans that share one
        // vertex. Union face corners through each shared edge to reject it.
        let mut starts: Vec<usize> = Vec::new();
        let mut corner_vertices: Vec<i64> = Vec::new();
        for face in &self.faces {
            starts.push(corner_vertices.len());
            corner_vertices.extend_from_slice(&face.vertices);
        }
        let mut parents: Vec<usize> = (0..corner_vertices.len()).collect();
        fn root(parents: &mut [usize], index: usize) -> usize {
            let mut cursor = index;
            while parents[cursor] != cursor {
                parents[cursor] = parents[parents[cursor]];
                cursor = parents[cursor];
            }
            cursor
        }
        // Swift iterates `result.values`, whose order is unspecified. Disjoint-set
        // unions are order-independent, so a sorted walk is equivalent.
        let mut edges: Vec<PolygonMeshEdge> = result.keys().copied().collect();
        edges.sort();
        for edge in edges {
            let uses = &result[&edge];
            if uses.len() != 2 {
                continue;
            }
            let a = uses[0];
            let b = uses[1];
            let a_start = starts[a.face as usize] + a.corner as usize;
            let a_end = starts[a.face as usize]
                + ((a.corner as usize + 1) % self.faces[a.face as usize].vertices.len());
            let b_start = starts[b.face as usize] + b.corner as usize;
            let b_end = starts[b.face as usize]
                + ((b.corner as usize + 1) % self.faces[b.face as usize].vertices.len());
            let left = root(&mut parents, a_start);
            let right = root(&mut parents, b_end);
            parents[left] = right;
            let left = root(&mut parents, a_end);
            let right = root(&mut parents, b_start);
            parents[left] = right;
        }
        let mut fans: HashMap<i64, usize> = HashMap::new();
        for (i, vertex) in corner_vertices.iter().enumerate() {
            let fan = root(&mut parents, i);
            if let Some(existing) = fans.get(vertex)
                && *existing != fan
            {
                return Err(GeometryError::invalid_mesh(
                    "disconnected surface fans at vertex",
                ));
            }
            fans.insert(*vertex, fan);
        }
        Ok(result)
    }
}

/// True when every lane is finite.
pub fn geometry_finite(value: Float3) -> bool {
    value.x.is_finite() && value.y.is_finite() && value.z.is_finite()
}

/// Newell's normal, which uses the entire polygon including concave faces.
pub fn geometry_normal(face: &PolygonFace, positions: &[Float3]) -> Float3 {
    let mut normal = Float3::ZERO;
    let origin = positions[face.vertices[0] as usize];
    for i in 0..face.vertices.len() {
        let a = positions[face.vertices[i] as usize] - origin;
        let b = positions[face.vertices[(i + 1) % face.vertices.len()] as usize] - origin;
        normal += simd_cross(a, b);
    }
    normal
}

/// Normalizes `value`, falling back to `fallback` when the length is unusable.
pub fn geometry_unit(value: Float3, fallback: Float3) -> Float3 {
    let length = simd_length(value);
    if length.is_finite() && length > 1e-12 {
        value / length
    } else {
        fallback
    }
}

/// Swift's default fallback for [`geometry_unit`]: world up.
pub const GEOMETRY_UNIT_FALLBACK: Float3 = Float3::new(0.0, 1.0, 0.0);

/// True when `values` has no duplicates, matching `Set(values).count == count`.
fn has_unique_vertices(values: &[i64]) -> bool {
    let mut seen = BTreeSet::new();
    values.iter().all(|value| seen.insert(*value))
}
