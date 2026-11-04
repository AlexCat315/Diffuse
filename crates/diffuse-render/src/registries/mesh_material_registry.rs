//! Process-wide mesh material metadata cache. RenderBackend fills this when
//! mesh assets are uploaded; later render paths can resolve material and
//! texture metadata by mesh index without reaching back into AssetRegistry.

use std::collections::HashMap;
use std::sync::{Mutex, MutexGuard, OnceLock};

use diffuse_assets::asset_pipeline::{MeshAsset, MeshMaterial, MeshTexture};

#[derive(Clone, Debug, PartialEq)]
pub struct MeshMaterialSet {
    pub materials: Vec<MeshMaterial>,
    pub textures: Vec<MeshTexture>,
}

impl MeshMaterialSet {
    pub fn new(materials: Vec<MeshMaterial>, textures: Vec<MeshTexture>) -> Self {
        MeshMaterialSet {
            materials,
            textures,
        }
    }
}

pub struct MeshMaterialRegistry {
    lock: Mutex<HashMap<i64, MeshMaterialSet>>,
}

impl MeshMaterialRegistry {
    fn new() -> Self {
        MeshMaterialRegistry {
            lock: Mutex::new(HashMap::new()),
        }
    }

    /// Swift's `MeshMaterialRegistry.shared`.
    pub fn shared() -> &'static Self {
        static SHARED: OnceLock<MeshMaterialRegistry> = OnceLock::new();
        SHARED.get_or_init(Self::new)
    }

    fn lock(&self) -> MutexGuard<'_, HashMap<i64, MeshMaterialSet>> {
        self.lock
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    pub fn register_mesh(mesh_index: i64, mesh: &MeshAsset) {
        Self::register(mesh_index, mesh.materials.clone(), mesh.textures.clone());
    }

    pub fn register(mesh_index: i64, materials: Vec<MeshMaterial>, textures: Vec<MeshTexture>) {
        let mut guard = Self::shared().lock();
        guard.insert(
            mesh_index,
            MeshMaterialSet::new(
                if materials.is_empty() {
                    vec![MeshMaterial::fallback()]
                } else {
                    materials
                },
                textures,
            ),
        );
    }

    pub fn materials(mesh_index: i64) -> Option<MeshMaterialSet> {
        let guard = Self::shared().lock();
        guard.get(&mesh_index).cloned()
    }

    pub fn clear_all() {
        let mut guard = Self::shared().lock();
        guard.clear();
    }
}
