//! Baking the control mesh into the renderer's 24-float vertex stream.
//!
//! Ported from `Engine/Sources/AssetPipeline/Geometry/GeometryBaker.swift`.

use diffuse_math::simd::simd_compat::{Float2, Float3, Float4, simd_cross, simd_dot};

use crate::asset_pipeline::{MeshAsset, MeshMaterial, MeshSubmesh, MeshTopologySlice};
use crate::geometry::polygon_mesh::{
    GEOMETRY_UNIT_FALLBACK, GeometryError, GeometryLimits, PolygonMesh, geometry_normal,
    geometry_unit,
};
use crate::geometry::polygon_triangulation::triangulate;
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum GeometryShading {
    Flat,
    Smooth,
}

/// The result of evaluating a document: control mesh, render mesh and the
/// topology map between them.
#[derive(Clone, Debug, PartialEq)]
pub struct GeometryEvaluation {
    pub control_mesh: PolygonMesh,
    pub mesh: MeshAsset,
    pub topology_slice: MeshTopologySlice,
}

impl PolygonMesh {
    /// Produces the existing 24-float vertex layout, submeshes and topology map.
    pub fn bake(
        &self,
        name: &str,
        shading: GeometryShading,
        materials: &[MeshMaterial],
        limits: GeometryLimits,
    ) -> Result<GeometryEvaluation, GeometryError> {
        self.validate(limits)?;
        if materials.is_empty()
            || !self.faces.iter().all(|face| {
                face.material_index >= 0 && ((face.material_index as usize) < materials.len())
            })
        {
            return Err(GeometryError::invalid_mesh(
                "face references a missing material slot",
            ));
        }
        let corner_count = self.corner_count();
        // GPU vertices split at every face corner, independent of control count.
        if !(corner_count <= limits.max_vertices) {
            return Err(GeometryError::BudgetExceeded);
        }
        let mut smooth_normals: Vec<Float3> = vec![Float3::ZERO; self.positions.len()];
        let face_normals: Vec<Float3> = self
            .faces
            .iter()
            .map(|face| geometry_normal(face, &self.positions))
            .collect();
        if shading == GeometryShading::Smooth {
            for (index, face) in self.faces.iter().enumerate() {
                for vertex in &face.vertices {
                    smooth_normals[*vertex as usize] += face_normals[index];
                }
            }
        }
        let mut vertices: Vec<f32> = Vec::new();
        let mut indices: Vec<u32> = Vec::new();
        let mut remap: Vec<u32> = Vec::new();
        let mut parts: Vec<MeshSubmesh> = Vec::new();
        vertices.reserve(corner_count as usize * MeshAsset::VERTEX_FLOAT_COUNT);
        for (face_index, face) in self.faces.iter().enumerate() {
            let triangles = triangulate(face, &self.positions)?;
            let normal = geometry_unit(face_normals[face_index], GEOMETRY_UNIT_FALLBACK);
            let axis = if normal.x.abs() > normal.y.abs() && normal.x.abs() > normal.z.abs() {
                0
            } else if normal.y.abs() > normal.z.abs() {
                1
            } else {
                2
            };
            let uvs: Vec<Float2> = match &face.uvs {
                Some(uvs) => uvs.clone(),
                None => face
                    .vertices
                    .iter()
                    .map(|vertex| {
                        let p = self.positions[*vertex as usize];
                        match axis {
                            0 => Float2::new(p.y, p.z),
                            1 => Float2::new(p.z, p.x),
                            _ => Float2::new(p.x, p.y),
                        }
                    })
                    .collect(),
            };
            let mut tangents: Vec<Float3> = vec![Float3::ZERO; face.vertices.len()];
            let mut bitangents: Vec<Float3> = tangents.clone();
            let mut i = 0;
            while i < triangles.len() {
                let a = triangles[i];
                let b = triangles[i + 1];
                let c = triangles[i + 2];
                let e1 = self.positions[face.vertices[b] as usize]
                    - self.positions[face.vertices[a] as usize];
                let e2 = self.positions[face.vertices[c] as usize]
                    - self.positions[face.vertices[a] as usize];
                let uv1 = uvs[b] - uvs[a];
                let uv2 = uvs[c] - uvs[a];
                let determinant = uv1.x * uv2.y - uv1.y * uv2.x;
                if determinant.abs() > 1e-12 {
                    let t = (e1 * uv2.y - e2 * uv1.y) / determinant;
                    let b_axis = (e2 * uv1.x - e1 * uv2.x) / determinant;
                    for corner in [triangles[i], triangles[i + 1], triangles[i + 2]] {
                        tangents[corner] += t;
                        bitangents[corner] += b_axis;
                    }
                }
                i += 3;
            }
            let base = remap.len() as u32;
            for i in 0..face.vertices.len() {
                let vertex = face.vertices[i];
                let n = if shading == GeometryShading::Flat {
                    normal
                } else {
                    geometry_unit(smooth_normals[vertex as usize], normal)
                };
                let reference = if n.y.abs() < 0.9 {
                    Float3::new(0.0, 1.0, 0.0)
                } else {
                    Float3::new(1.0, 0.0, 0.0)
                };
                let tangent = geometry_unit(
                    tangents[i] - n * simd_dot(n, tangents[i]),
                    geometry_unit(simd_cross(reference, n), GEOMETRY_UNIT_FALLBACK),
                );
                let sign = if simd_dot(simd_cross(n, tangent), bitangents[i]) < 0.0 {
                    -1.0_f32
                } else {
                    1.0
                };
                MeshAsset::append_vertex(
                    &mut vertices,
                    self.positions[vertex as usize],
                    n,
                    Float3::new(1.0, 1.0, 1.0),
                    uvs[i],
                    Float4::new(tangent.x, tangent.y, tangent.z, sign),
                    face.material_index as f32,
                    Float4::ZERO,
                    Float4::new(1.0, 0.0, 0.0, 0.0),
                );
                remap.push(vertex as u32);
            }
            let start = indices.len() as u32;
            for triangle in &triangles {
                indices.push(base + *triangle as u32);
            }
            match parts.last() {
                Some(previous) if previous.material_index == face.material_index => {
                    let last = parts.len() - 1;
                    parts[last] = MeshSubmesh::new(
                        previous.index_start,
                        previous.index_count + triangles.len() as u32,
                        face.material_index,
                    );
                }
                _ => parts.push(MeshSubmesh::new(
                    start,
                    triangles.len() as u32,
                    face.material_index,
                )),
            }
        }
        if !vertices.iter().all(|value| value.is_finite()) {
            return Err(GeometryError::invalid_mesh("non-finite baked vertex"));
        }
        let topology_slice =
            MeshTopologySlice::new(self.positions.clone(), indices.clone(), Some(remap));
        Ok(GeometryEvaluation {
            control_mesh: self.clone(),
            mesh: MeshAsset {
                materials: materials.to_vec(),
                submeshes: parts,
                ..MeshAsset::new(name.to_string(), vertices, indices)
            },
            topology_slice,
        })
    }

    /// `bake` with Swift's defaults: flat shading, the fallback material.
    pub fn bake_default(&self, name: &str) -> Result<GeometryEvaluation, GeometryError> {
        self.bake(
            name,
            GeometryShading::Flat,
            &[MeshMaterial::fallback()],
            GeometryLimits::default(),
        )
    }
}
