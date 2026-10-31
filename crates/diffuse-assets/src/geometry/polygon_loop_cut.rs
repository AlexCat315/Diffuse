//! Loop cut with slide across a convex quad ring.
//!
//! Ported from `Engine/Sources/AssetPipeline/Geometry/PolygonLoopCut.swift`.

use std::collections::{BTreeMap, BTreeSet};

use diffuse_math::simd::simd_compat::Float2;

use crate::geometry::polygon_loop_cut_plan::PolygonLoopCutPlan;
use crate::geometry::polygon_mesh::{
    GeometryError, GeometryLimits, PolygonFace, PolygonMesh, PolygonMeshEdge,
};
use crate::geometry::polygon_triangulation::triangulate;

/// One edge's corner chain, run in the direction the face traverses it.
struct Boundary {
    vertices: Vec<i64>,
    uvs: Option<Vec<Float2>>,
}

impl PolygonMesh {
    /// Cuts the opposite-edge ring through convex planar quads. Non-quads stop
    /// propagation and receive shared edge vertices, preserving a connected
    /// surface. Slide shifts an evenly spaced bundle by one interval, without
    /// collapsing endpoints.
    /// The `!(x >= 0.0)` comparisons are deliberate: they are the NaN-safe
    /// spelling of Swift's `guard x >= 0 else`, which takes the fallback path for
    /// NaN as well as for negatives. Rewriting them as `x < 0.0` would let NaN
    /// through and change the geometry output.
    #[allow(clippy::neg_cmp_op_on_partial_ord)]
    pub fn loop_cut(
        &mut self,
        seed: PolygonMeshEdge,
        cuts: i64,
        slide: f32,
        limits: GeometryLimits,
    ) -> Result<BTreeSet<PolygonMeshEdge>, GeometryError> {
        self.validate(limits)?;
        if !(1..=64).contains(&cuts) || !slide.is_finite() || !(slide.abs() < 1.0) {
            return Err(GeometryError::invalid_parameter("loop cut count/slide"));
        }
        let plan = PolygonLoopCutPlan::new(self, seed)?;
        let mut terminal_corners: i64 = 0;
        for (index, face) in self.faces.iter().enumerate() {
            if plan.faces.contains_key(&(index as i64)) {
                continue;
            }
            let vertices = &face.vertices;
            let touched = (0..vertices.len())
                .filter(|corner| {
                    plan.starts.contains_key(&PolygonMeshEdge::new(
                        vertices[*corner],
                        vertices[(*corner + 1) % vertices.len()],
                    ))
                })
                .count() as i64;
            terminal_corners += touched * cuts;
        }
        let corners = self.corner_count();
        limits.check(
            self.positions.len() as i64 + plan.starts.len() as i64 * cuts,
            corners + plan.faces.len() as i64 * cuts * 4 + terminal_corners,
        )?;
        let fractions: Vec<f32> = (0..cuts)
            .map(|index| (index as f32 + 1.0 + slide) / (cuts as f32 + 1.0))
            .collect();
        let mut result = self.clone();
        let mut cut_vertices: BTreeMap<PolygonMeshEdge, Vec<i64>> = BTreeMap::new();
        for edge in plan.starts.keys() {
            let start = plan.starts[edge];
            let end = if start == edge.a { edge.b } else { edge.a };
            let mut indices: Vec<i64> = Vec::with_capacity(fractions.len());
            for t in &fractions {
                let index = result.positions.len() as i64;
                result.positions.push(
                    self.positions[start as usize]
                        + (self.positions[end as usize] - self.positions[start as usize]) * *t,
                );
                indices.push(index);
            }
            cut_vertices.insert(*edge, indices);
        }
        let boundary = |face: &PolygonFace, a: usize, b: usize| -> Boundary {
            let start = face.vertices[a];
            let end = face.vertices[b];
            let edge = PolygonMeshEdge::new(start, end);
            let forward = plan.starts.get(&edge) == Some(&start);
            let ids: Vec<i64> = if forward {
                cut_vertices[&edge].clone()
            } else {
                cut_vertices[&edge].iter().rev().copied().collect()
            };
            let amounts: Vec<f32> = if forward {
                fractions.clone()
            } else {
                fractions.iter().rev().map(|value| 1.0 - *value).collect()
            };
            let inner_uvs = face.uvs.as_ref().map(|values| {
                amounts
                    .iter()
                    .map(|amount| values[a] + (values[b] - values[a]) * *amount)
                    .collect::<Vec<Float2>>()
            });
            let mut vertices = vec![start];
            vertices.extend_from_slice(&ids);
            vertices.push(end);
            let uvs = match (&face.uvs, inner_uvs) {
                (Some(values), Some(inner)) => {
                    let mut uvs = vec![values[a]];
                    uvs.extend_from_slice(&inner);
                    uvs.push(values[b]);
                    Some(uvs)
                }
                _ => None,
            };
            Boundary { vertices, uvs }
        };
        let mut selected: BTreeSet<PolygonMeshEdge> = BTreeSet::new();
        for (index, face) in self.faces.iter().enumerate() {
            let Some(k) = plan.faces.get(&(index as i64)).copied() else {
                let mut ids: Vec<i64> = Vec::new();
                let mut uvs: Option<Vec<Float2>> = if face.uvs.is_none() {
                    None
                } else {
                    Some(Vec::new())
                };
                for i in 0..face.vertices.len() {
                    let j = (i + 1) % face.vertices.len();
                    let edge = PolygonMeshEdge::new(face.vertices[i], face.vertices[j]);
                    if cut_vertices.contains_key(&edge) {
                        let chain = boundary(face, i, j);
                        let keep = chain.vertices.len() - 1;
                        ids.extend_from_slice(&chain.vertices[..keep]);
                        if let (Some(chain_uvs), Some(target)) = (chain.uvs, uvs.as_mut()) {
                            target.extend_from_slice(&chain_uvs[..keep]);
                        }
                    } else {
                        ids.push(face.vertices[i]);
                        if let (Some(values), Some(target)) = (&face.uvs, uvs.as_mut()) {
                            target.push(values[i]);
                        }
                    }
                }
                result.faces[index] = PolygonFace::new(ids, uvs, face.material_index);
                continue;
            };
            let a = boundary(face, k as usize, ((k + 1) % 4) as usize);
            let b = boundary(face, ((k + 3) % 4) as usize, ((k + 2) % 4) as usize);
            for i in 0..=cuts as usize {
                let uv = face.uvs.as_ref().map(|_| {
                    let a_uvs = a.uvs.as_ref().expect("quad UVs follow the source face");
                    let b_uvs = b.uvs.as_ref().expect("quad UVs follow the source face");
                    vec![a_uvs[i], a_uvs[i + 1], b_uvs[i + 1], b_uvs[i]]
                });
                let band = PolygonFace::new(
                    vec![
                        a.vertices[i],
                        a.vertices[i + 1],
                        b.vertices[i + 1],
                        b.vertices[i],
                    ],
                    uv,
                    face.material_index,
                );
                if i == 0 {
                    result.faces[index] = band;
                } else {
                    result.faces.push(band);
                }
                if (i as i64) < cuts {
                    selected.insert(PolygonMeshEdge::new(a.vertices[i + 1], b.vertices[i + 1]));
                }
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
}
