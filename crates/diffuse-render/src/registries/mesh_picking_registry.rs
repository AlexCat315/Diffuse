//! Immutable triangle BVH used for mesh picking, plus the process-wide
//! registry behind it.

use std::collections::HashMap;
use std::sync::{Mutex, MutexGuard, OnceLock};

use diffuse_assets::asset_pipeline::{BuiltinMesh, MeshAsset};
use diffuse_assets::asset_registry::AssetRegistry;
use diffuse_math::simd::simd_compat::{Float3, Float4, Float4x4};
use diffuse_math::simd::simd_compat::{simd_cross, simd_dot, simd_length, simd_max, simd_min};

/// `Float3`'s component accessor: Swift subscripts by axis, so the BVH code
/// keeps an axis-indexed view.
fn component(vector: Float3, axis: usize) -> f32 {
    match axis {
        0 => vector.x,
        1 => vector.y,
        _ => vector.z,
    }
}

struct PickingTriangle {
    a: Float3,
    b: Float3,
    c: Float3,
    min: Float3,
    max: Float3,
}

struct PickingNode {
    min: Float3,
    max: Float3,
    left: i64,
    right: i64,
    triangles: Vec<usize>,
}

/// Immutable triangle BVH. Ray directions need not be normalized, so a ray
/// transformed into mesh space keeps its world-space distance parameter.
#[derive(Clone, Default)]
pub struct MeshPickingSurface {
    triangles: Vec<PickingTriangle>,
    nodes: Vec<PickingNode>,
}

impl MeshPickingSurface {
    pub fn new(positions: &[Float3], indices: &[u32]) -> Self {
        let mut surface = MeshPickingSurface::default();
        let triangle_count = indices.len() - indices.len() % 3;
        let mut i = 0;
        while i < triangle_count {
            let ids = [
                indices[i] as usize,
                indices[i + 1] as usize,
                indices[i + 2] as usize,
            ];
            if !ids.iter().all(|id| *id < positions.len()) {
                i += 3;
                continue;
            }
            let a = positions[ids[0]];
            let b = positions[ids[1]];
            let c = positions[ids[2]];
            let finite = [a, b, c]
                .iter()
                .all(|v| v.x.is_finite() && v.y.is_finite() && v.z.is_finite());
            if !finite {
                i += 3;
                continue;
            }
            surface.triangles.push(PickingTriangle {
                a,
                b,
                c,
                min: simd_min(a, simd_min(b, c)),
                max: simd_max(a, simd_max(b, c)),
            });
            i += 3;
        }
        if !surface.triangles.is_empty() {
            let ids: Vec<usize> = (0..surface.triangles.len()).collect();
            surface.build(ids);
        }
        surface
    }

    fn build(&mut self, ids: Vec<usize>) -> i64 {
        let mut lo = Float3::INFINITY;
        for id in &ids {
            lo = simd_min(lo, self.triangles[*id].min);
        }
        let mut hi = Float3::NEG_INFINITY;
        for id in &ids {
            hi = simd_max(hi, self.triangles[*id].max);
        }
        let index = self.nodes.len() as i64;
        self.nodes.push(PickingNode {
            min: lo,
            max: hi,
            left: -1,
            right: -1,
            triangles: Vec::new(),
        });
        if ids.len() <= 8 {
            self.nodes[index as usize].triangles = ids;
            return index;
        }
        let size = hi - lo;
        let axis = if size.x >= size.y && size.x >= size.z {
            0
        } else if size.y >= size.z {
            1
        } else {
            2
        };
        let mut sorted = ids;
        sorted.sort_by(|&lhs, &rhs| {
            let lhs_key =
                component(self.triangles[lhs].min, axis) + component(self.triangles[lhs].max, axis);
            let rhs_key =
                component(self.triangles[rhs].min, axis) + component(self.triangles[rhs].max, axis);
            lhs_key
                .partial_cmp(&rhs_key)
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        let middle = sorted.len() / 2;
        let left = self.build(sorted[..middle].to_vec());
        let right = self.build(sorted[middle..].to_vec());
        self.nodes[index as usize].left = left;
        self.nodes[index as usize].right = right;
        index
    }

    pub fn hit_distance(
        &self,
        origin: Float3,
        direction: Float3,
        max_distance: f32,
    ) -> Option<f32> {
        if self.nodes.is_empty() {
            return None;
        }
        let mut nearest = max_distance;
        let mut hit = false;
        let mut stack = vec![0usize];
        while let Some(index) = stack.pop() {
            let node = &self.nodes[index];
            let mut near: f32 = 0.0;
            let mut far = nearest;
            for axis in 0..3 {
                let direction_component = component(direction, axis);
                if direction_component.abs() < 1e-12 {
                    if component(origin, axis) < component(node.min, axis)
                        || component(origin, axis) > component(node.max, axis)
                    {
                        far = -1.0;
                        break;
                    }
                } else {
                    let a =
                        (component(node.min, axis) - component(origin, axis)) / direction_component;
                    let b =
                        (component(node.max, axis) - component(origin, axis)) / direction_component;
                    near = near.max(a.min(b));
                    far = far.min(a.max(b));
                }
            }
            if far < near {
                continue;
            }
            if node.left >= 0 {
                stack.push(node.left as usize);
                stack.push(node.right as usize);
                continue;
            }
            for id in &node.triangles {
                let tri = &self.triangles[*id];
                let e1 = tri.b - tri.a;
                let e2 = tri.c - tri.a;
                let p = simd_cross(direction, e2);
                let determinant = simd_dot(e1, p);
                let tolerance = 1e-7 * simd_length(e1) * simd_length(p);
                if determinant.abs() <= tolerance {
                    continue;
                }
                let inv = 1.0 / determinant;
                let offset = origin - tri.a;
                let u = simd_dot(offset, p) * inv;
                if !(-1e-6..=(1.0 + 1e-6)).contains(&u) {
                    continue;
                }
                let q = simd_cross(offset, e1);
                let v = simd_dot(direction, q) * inv;
                if v < -1e-6 || u + v > 1.0 + 1e-6 {
                    continue;
                }
                let t = simd_dot(e2, q) * inv;
                if t > 1e-5 && t < nearest {
                    nearest = t;
                    hit = true;
                }
            }
        }
        hit.then_some(nearest)
    }
}

pub struct MeshPickingRegistry {
    lock: Mutex<PickingStorage>,
}

struct PickingStorage {
    surfaces: HashMap<i64, MeshPickingSurface>,
    assets: HashMap<i64, MeshAsset>,
}

impl MeshPickingRegistry {
    fn new() -> Self {
        MeshPickingRegistry {
            lock: Mutex::new(PickingStorage {
                surfaces: HashMap::new(),
                assets: HashMap::new(),
            }),
        }
    }

    /// Swift's `MeshPickingRegistry.shared`.
    pub fn shared() -> &'static Self {
        static SHARED: OnceLock<MeshPickingRegistry> = OnceLock::new();
        SHARED.get_or_init(Self::new)
    }

    fn lock(&self) -> MutexGuard<'_, PickingStorage> {
        self.lock
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    pub fn register(mesh_index: i64, mesh: &MeshAsset) {
        let positions: Vec<Float3> = (0..mesh.vertex_count() as i64)
            .filter_map(|vertex| mesh.position(vertex))
            .collect();
        let surface = MeshPickingSurface::new(&positions, &mesh.indices);
        let mut guard = Self::shared().lock();
        guard.surfaces.insert(mesh_index, surface);
        guard.assets.insert(mesh_index, mesh.clone());
    }

    pub fn remove(mesh_index: i64) {
        let mut guard = Self::shared().lock();
        guard.surfaces.remove(&mesh_index);
        guard.assets.remove(&mesh_index);
    }

    pub fn surface(mesh_index: i64, joint_matrices: &[Float4x4]) -> Option<MeshPickingSurface> {
        let cached = {
            let guard = Self::shared().lock();
            let cached = guard.surfaces.get(&mesh_index).cloned();
            let cached_asset = guard.assets.get(&mesh_index).cloned();
            (cached, cached_asset)
        };
        let (cached, cached_asset) = cached;
        let Some(cached) = cached else {
            let mesh = AssetRegistry::shared().mesh_asset(mesh_index).or_else(|| {
                if (0..2).contains(&mesh_index) {
                    Some(BuiltinMesh::cube(None))
                } else {
                    None
                }
            })?;
            Self::register(mesh_index, &mesh);
            return Self::surface(mesh_index, joint_matrices);
        };
        if joint_matrices.is_empty() {
            return cached_asset.map(|_| cached);
        }
        let mesh = cached_asset?;
        let mut positions: Vec<Float3> = Vec::new();
        for i in 0..mesh.vertex_count() {
            let offset = i * MeshAsset::VERTEX_FLOAT_COUNT;
            let p = Float4::new(
                mesh.vertices[offset],
                mesh.vertices[offset + 1],
                mesh.vertices[offset + 2],
                1.0,
            );
            let mut skinned = Float4::ZERO;
            let mut total: f32 = 0.0;
            for lane in 0..4 {
                let joint = mesh.vertices[offset + MeshAsset::JOINTS_FLOAT_OFFSET + lane];
                let weight = mesh.vertices[offset + MeshAsset::WEIGHTS_FLOAT_OFFSET + lane];
                if !joint.is_finite()
                    || joint < 0.0
                    || joint >= joint_matrices.len() as f32
                    || weight <= 0.0
                {
                    continue;
                }
                let transformed = joint_matrices[joint as usize] * p;
                skinned = skinned + transformed * weight;
                total += weight;
            }
            let value = if total > 0.0001 { skinned } else { p };
            positions.push(Float3::new(value.x, value.y, value.z));
        }
        Some(MeshPickingSurface::new(&positions, &mesh.indices))
    }
}
