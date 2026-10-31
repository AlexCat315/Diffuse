//! Loop-cut ring planning.
//!
//! Ported from `Engine/Sources/AssetPipeline/Geometry/PolygonLoopCutPlan.swift`.

use std::collections::BTreeMap;

use diffuse_math::simd::simd_compat::{simd_dot, simd_length};

use crate::geometry::polygon_inset_face::PolygonInsetFace;
use crate::geometry::polygon_mesh::{
    GEOMETRY_UNIT_FALLBACK, GeometryError, PolygonMesh, PolygonMeshEdge, geometry_normal,
    geometry_unit,
};
use crate::geometry::polygon_triangulation::triangulate;
use crate::geometry::polygon_uv_projection::PolygonUVProjection;

/// Which edges the ring crosses and where each quad is split.
#[derive(Clone, Debug, Default, PartialEq)]
pub(crate) struct PolygonLoopCutPlan {
    /// Start vertex gives a consistent slide direction across the edge ring.
    pub(crate) starts: BTreeMap<PolygonMeshEdge, i64>,
    pub(crate) faces: BTreeMap<i64, i64>,
}

impl PolygonLoopCutPlan {
    pub(crate) fn new(mesh: &PolygonMesh, seed: PolygonMeshEdge) -> Result<Self, GeometryError> {
        let uses = mesh.edge_uses()?;
        if !uses.contains_key(&PolygonMeshEdge::new(seed.a, seed.b)) {
            return Err(GeometryError::invalid_parameter("loop cut seed edge"));
        }
        let mut plan = PolygonLoopCutPlan {
            starts: BTreeMap::new(),
            faces: BTreeMap::new(),
        };
        plan.starts.insert(seed, seed.a);
        let mut pending: Vec<PolygonMeshEdge> = vec![seed];
        let mut cursor = 0usize;
        while cursor < pending.len() {
            let edge = pending[cursor];
            cursor += 1;
            let adjacent = uses
                .get(&PolygonMeshEdge::new(edge.a, edge.b))
                .cloned()
                .unwrap_or_default();
            for use_ in adjacent {
                let face = &mesh.faces[use_.face as usize];
                if face.vertices.len() != 4 {
                    continue;
                }
                let k = (0..face.vertices.len())
                    .find(|index| {
                        PolygonMeshEdge::new(face.vertices[*index], face.vertices[(*index + 1) % 4])
                            == edge
                    })
                    .expect("the use came from a corner of this face")
                    as i64;
                if let Some(previous) = plan.faces.get(&use_.face) {
                    if !(k == *previous || k == (*previous + 2) % 4) {
                        return Err(GeometryError::invalid_mesh("loop cut crosses itself"));
                    }
                } else {
                    let _ = PolygonInsetFace::new(face, &mesh.positions)?;
                    plan.faces.insert(use_.face, k);
                }
                let a = face.vertices[((k + 3) % 4) as usize];
                let b = face.vertices[((k + 2) % 4) as usize];
                let opposite = PolygonMeshEdge::new(a, b);
                let start = if plan.starts.get(&edge) == Some(&face.vertices[k as usize]) {
                    a
                } else {
                    b
                };
                if let Some(previous) = plan.starts.get(&opposite) {
                    if *previous != start {
                        return Err(GeometryError::invalid_mesh("loop cut ring is twisted"));
                    }
                } else {
                    plan.starts.insert(opposite, start);
                    pending.push(opposite);
                }
            }
        }
        if plan.faces.is_empty() {
            return Err(GeometryError::invalid_mesh(
                "loop cut requires a quad strip",
            ));
        }
        for (index, face) in mesh.faces.iter().enumerate() {
            if plan.faces.contains_key(&(index as i64)) {
                continue;
            }
            let touches_ring = (0..face.vertices.len()).any(|corner| {
                plan.starts.contains_key(&PolygonMeshEdge::new(
                    face.vertices[corner],
                    face.vertices[(corner + 1) % face.vertices.len()],
                ))
            });
            if !touches_ring {
                continue;
            }
            let _ = triangulate(face, &mesh.positions)?;
            let vertices: Vec<_> = face
                .vertices
                .iter()
                .map(|index| mesh.positions[*index as usize])
                .collect();
            let origin = vertices[0];
            let normal = geometry_unit(
                geometry_normal(face, &mesh.positions),
                GEOMETRY_UNIT_FALLBACK,
            );
            let extent = vertices
                .iter()
                .fold(0.0_f32, |acc, value| acc.max(simd_length(*value - origin)));
            if !vertices.iter().all(|value| {
                simd_dot(*value - origin, normal).abs() <= (1e-6_f32).max(extent * 1e-5)
            }) {
                return Err(GeometryError::invalid_mesh(
                    "loop cut requires planar terminal faces",
                ));
            }
            if let Some(uv) = &face.uvs {
                let _ = PolygonUVProjection::new(&vertices, uv)?;
            }
        }
        Ok(plan)
    }
}
