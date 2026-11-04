//! Process-level mesh wireframe topology cache: triangle faces deduplicated
//! into edges so the editor can read a real wireframe instead of an AABB
//! approximation.

use std::collections::{HashMap, HashSet};
use std::sync::{Mutex, MutexGuard, OnceLock};

use diffuse_assets::asset_pipeline::MeshAsset;
use diffuse_assets::geometry::polygon_mesh::PolygonMesh;
use diffuse_math::simd::simd_compat::Float3;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct MeshWireframeEdge {
    pub a: Float3,
    pub b: Float3,
}

impl MeshWireframeEdge {
    pub fn new(a: Float3, b: Float3) -> Self {
        MeshWireframeEdge { a, b }
    }
}

/// Registerable wireframe topology description.
/// - `positions`: vertex position pool (local space).
/// - `triangle_indices`: triangle-organized indices (a multiple of 3).
/// - `index_remap`: optional. For glTF multi-submesh splitting and similar
///   cases, remapping a local primitive's indices into the shared position pool.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct MeshWireframeTopology {
    pub positions: Vec<Float3>,
    pub triangle_indices: Vec<u32>,
    pub index_remap: Option<Vec<u32>>,
}

impl MeshWireframeTopology {
    pub fn new(
        positions: Vec<Float3>,
        triangle_indices: Vec<u32>,
        index_remap: Option<Vec<u32>>,
    ) -> Self {
        MeshWireframeTopology {
            positions,
            triangle_indices,
            index_remap,
        }
    }
}

/// Swift's quantized `EdgeKey`: rounded to 1/10 000 and ordered lexicographically
/// so an edge hashes the same from either direction.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
struct EdgeKey {
    ax: u32,
    ay: u32,
    az: u32,
    bx: u32,
    by: u32,
    bz: u32,
}

impl EdgeKey {
    fn new(a: Float3, b: Float3) -> Self {
        let aq = Self::quantize(a);
        let bq = Self::quantize(b);
        if Self::is_lexicographically_sorted(aq, bq) {
            EdgeKey {
                ax: aq.0,
                ay: aq.1,
                az: aq.2,
                bx: bq.0,
                by: bq.1,
                bz: bq.2,
            }
        } else {
            EdgeKey {
                ax: bq.0,
                ay: bq.1,
                az: bq.2,
                bx: aq.0,
                by: aq.1,
                bz: aq.2,
            }
        }
    }

    fn quantize(v: Float3) -> (u32, u32, u32) {
        let s: f32 = 10_000.0;
        let qx = (v.x * s).round() as i32;
        let qy = (v.y * s).round() as i32;
        let qz = (v.z * s).round() as i32;
        (qx as u32, qy as u32, qz as u32)
    }

    fn is_lexicographically_sorted(lhs: (u32, u32, u32), rhs: (u32, u32, u32)) -> bool {
        if lhs.0 != rhs.0 {
            return lhs.0 < rhs.0;
        }
        if lhs.1 != rhs.1 {
            return lhs.1 < rhs.1;
        }
        lhs.2 <= rhs.2
    }
}

pub struct MeshWireframeRegistry {
    lock: Mutex<HashMap<i64, Vec<MeshWireframeEdge>>>,
}

impl MeshWireframeRegistry {
    fn new() -> Self {
        MeshWireframeRegistry {
            lock: Mutex::new(HashMap::new()),
        }
    }

    /// Swift's `MeshWireframeRegistry.shared`.
    pub fn shared() -> &'static Self {
        static SHARED: OnceLock<MeshWireframeRegistry> = OnceLock::new();
        SHARED.get_or_init(Self::new)
    }

    fn lock(&self) -> MutexGuard<'_, HashMap<i64, Vec<MeshWireframeEdge>>> {
        self.lock
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    pub fn register_mesh(mesh_index: i64, mesh: &MeshAsset) {
        let edges = Self::extract_wireframe_edges_from_mesh(mesh);
        let mut guard = Self::shared().lock();
        guard.insert(mesh_index, edges);
    }

    pub fn register_polygon_mesh(mesh_index: i64, polygon_mesh: &PolygonMesh) {
        let edges = polygon_mesh
            .edges
            .iter()
            .map(|edge| {
                MeshWireframeEdge::new(
                    polygon_mesh.positions[edge.a as usize],
                    polygon_mesh.positions[edge.b as usize],
                )
            })
            .collect();
        let mut guard = Self::shared().lock();
        guard.insert(mesh_index, edges);
    }

    /// Registers a single topology source (optionally with an index remap).
    pub fn register_topology(mesh_index: i64, topology: &MeshWireframeTopology) {
        let edges = Self::extract_wireframe_edges_from_topology(topology);
        let mut guard = Self::shared().lock();
        guard.insert(mesh_index, edges);
    }

    /// Registers several submesh topologies and merges their edges, deduplicated.
    pub fn register_submeshes(mesh_index: i64, submeshes: &[MeshWireframeTopology]) {
        let mut merged: Vec<MeshWireframeEdge> = Vec::new();
        merged.reserve_capacity(
            submeshes
                .iter()
                .map(|submesh| submesh.triangle_indices.len())
                .sum(),
        );
        let mut seen = HashSet::new();
        for submesh in submeshes {
            for edge in Self::extract_wireframe_edges_from_topology(submesh) {
                let key = EdgeKey::new(edge.a, edge.b);
                if seen.insert(key) {
                    merged.push(edge);
                }
            }
        }
        let mut guard = Self::shared().lock();
        guard.insert(mesh_index, merged);
    }

    pub fn edges(mesh_index: i64) -> Option<Vec<MeshWireframeEdge>> {
        let guard = Self::shared().lock();
        guard.get(&mesh_index).cloned()
    }

    pub fn clear_all() {
        let mut guard = Self::shared().lock();
        guard.clear();
    }

    pub fn remove(mesh_index: i64) {
        let mut guard = Self::shared().lock();
        guard.remove(&mesh_index);
    }

    fn extract_wireframe_edges_from_mesh(mesh: &MeshAsset) -> Vec<MeshWireframeEdge> {
        let stride = MeshAsset::VERTEX_FLOAT_COUNT;
        if stride < 3 {
            return Vec::new();
        }

        let vertex_count = mesh.vertices.len() / stride;
        if vertex_count == 0 || mesh.indices.is_empty() {
            return Vec::new();
        }

        let mut results: Vec<MeshWireframeEdge> = Vec::new();
        results.reserve_capacity(mesh.indices.len());
        let mut seen = HashSet::new();

        let position = |index: u32| -> Option<Float3> {
            let i = index as usize;
            if i >= vertex_count {
                return None;
            }
            let base = i * stride;
            Some(Float3::new(
                mesh.vertices[base],
                mesh.vertices[base + 1],
                mesh.vertices[base + 2],
            ))
        };

        let mut append_edge =
            |i0: u32, i1: u32, seen: &mut HashSet<u64>, results: &mut Vec<MeshWireframeEdge>| {
                if i0 == i1 {
                    return;
                }
                let lo = i0.min(i1);
                let hi = i0.max(i1);
                let key = (u64::from(lo) << 32) | u64::from(hi);
                if seen.contains(&key) {
                    return;
                }
                let (Some(a), Some(b)) = (position(i0), position(i1)) else {
                    return;
                };
                seen.insert(key);
                results.push(MeshWireframeEdge::new(a, b));
            };

        let mut i = 0;
        while i + 2 < mesh.indices.len() {
            let a = mesh.indices[i];
            let b = mesh.indices[i + 1];
            let c = mesh.indices[i + 2];
            append_edge(a, b, &mut seen, &mut results);
            append_edge(b, c, &mut seen, &mut results);
            append_edge(c, a, &mut seen, &mut results);
            i += 3;
        }

        results
    }

    fn extract_wireframe_edges_from_topology(
        topology: &MeshWireframeTopology,
    ) -> Vec<MeshWireframeEdge> {
        if topology.positions.is_empty() || topology.triangle_indices.is_empty() {
            return Vec::new();
        }

        let mut results: Vec<MeshWireframeEdge> = Vec::new();
        results.reserve_capacity(topology.triangle_indices.len());
        let mut seen = HashSet::new();

        let resolve = |index: u32| -> Option<u32> {
            let Some(remap) = topology.index_remap.as_ref() else {
                return Some(index);
            };
            let i = index as usize;
            if i >= remap.len() {
                return None;
            }
            Some(remap[i])
        };

        let position = |index: u32| -> Option<Float3> {
            let i = index as usize;
            topology.positions.get(i).copied()
        };

        let mut append_edge = |raw_i0: u32,
                               raw_i1: u32,
                               seen: &mut HashSet<u64>,
                               results: &mut Vec<MeshWireframeEdge>| {
            let (Some(i0), Some(i1)) = (resolve(raw_i0), resolve(raw_i1)) else {
                return;
            };
            if i0 == i1 {
                return;
            }
            let lo = i0.min(i1);
            let hi = i0.max(i1);
            let key = (u64::from(lo) << 32) | u64::from(hi);
            if seen.contains(&key) {
                return;
            }
            let (Some(a), Some(b)) = (position(i0), position(i1)) else {
                return;
            };
            seen.insert(key);
            results.push(MeshWireframeEdge::new(a, b));
        };

        let mut i = 0;
        while i + 2 < topology.triangle_indices.len() {
            let a = topology.triangle_indices[i];
            let b = topology.triangle_indices[i + 1];
            let c = topology.triangle_indices[i + 2];
            append_edge(a, b, &mut seen, &mut results);
            append_edge(b, c, &mut seen, &mut results);
            append_edge(c, a, &mut seen, &mut results);
            i += 3;
        }

        results
    }
}
