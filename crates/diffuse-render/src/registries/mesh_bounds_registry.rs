//! Process-level mesh bounding-box registry.
//!
//! RenderBackend fills this when meshes are uploaded; the editor (or any
//! read-only consumer) can query the local-space AABB by mesh index for
//! picking, frustum culling and debug visualization.
//!
//! Swift uses `NSLock` with copy-on-write snapshot reads; a `Mutex` over the
//! dictionary preserves the same contract (MIGRATION.md §5.5).

use std::collections::HashMap;
use std::sync::{Mutex, MutexGuard, OnceLock};

use diffuse_math::bounds::bounds_3d::Bounds3D;
use diffuse_math::simd::simd_compat::Float3;

pub struct MeshBoundsRegistry {
    lock: Mutex<HashMap<i64, Bounds3D>>,
}

fn storage() -> &'static MeshBoundsRegistry {
    static SHARED: OnceLock<MeshBoundsRegistry> = OnceLock::new();
    SHARED.get_or_init(|| MeshBoundsRegistry {
        lock: Mutex::new(HashMap::new()),
    })
}

impl MeshBoundsRegistry {
    /// Swift's private `init`; the shared instance is the only entry point.
    fn new() -> Self {
        MeshBoundsRegistry {
            lock: Mutex::new(HashMap::new()),
        }
    }

    fn shared() -> &'static Self {
        storage()
    }

    fn lock(&self) -> MutexGuard<'_, HashMap<i64, Bounds3D>> {
        self.lock
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    pub fn register_min_max(mesh_index: i64, min: Float3, max: Float3) {
        Self::register(mesh_index, Bounds3D::new(min, max));
    }

    pub fn register(mesh_index: i64, bounds: Bounds3D) {
        let mut guard = Self::shared().lock();
        guard.insert(mesh_index, bounds);
    }

    pub fn bounds(mesh_index: i64) -> Option<(Float3, Float3)> {
        let bounds = Self::bounds_3d(mesh_index)?;
        Some((bounds.min, bounds.max))
    }

    pub fn bounds_3d(mesh_index: i64) -> Option<Bounds3D> {
        let guard = Self::shared().lock();
        guard.get(&mesh_index).copied()
    }

    pub fn clear_all() {
        let mut guard = Self::shared().lock();
        guard.clear();
    }

    pub fn remove(mesh_index: i64) {
        let mut guard = Self::shared().lock();
        guard.remove(&mesh_index);
    }
}

impl Default for MeshBoundsRegistry {
    fn default() -> Self {
        Self::new()
    }
}
