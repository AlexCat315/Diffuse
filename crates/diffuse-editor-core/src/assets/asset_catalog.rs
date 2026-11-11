//! Translation of Editor/Sources/EditorCore/Assets/AssetCatalog.swift.
//!
//! The editor-facing projection of `AssetRegistry`: stable IDs, display names,
//! relative/absolute paths and the import kind that drives drag payloads.

use std::collections::BTreeMap;

use diffuse_assets::asset_registry::{
    AssetRegistry, AssetRegistryEntry, AssetRegistryError, ImportableAssetKind,
};

use crate::rendering::viewport::viewport_host::ViewportScreenFrame;
use crate::state::editor_state::EditorAssetDragPayload;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EditorAsset {
    pub id: String,
    pub name: String,
    pub relative_path: String,
    pub absolute_path: String,
    pub kind: ImportableAssetKind,
    pub mesh_index: i64,
}

impl EditorAsset {
    pub fn new(
        id: impl Into<String>,
        name: impl Into<String>,
        relative_path: impl Into<String>,
        absolute_path: impl Into<String>,
        kind: ImportableAssetKind,
        mesh_index: i64,
    ) -> Self {
        EditorAsset {
            id: id.into(),
            name: name.into(),
            relative_path: relative_path.into(),
            absolute_path: absolute_path.into(),
            kind,
            mesh_index,
        }
    }

    pub fn drag_payload(&self) -> EditorAssetDragPayload {
        EditorAssetDragPayload::new(
            self.id.clone(),
            self.name.clone(),
            self.kind.scene_kind_label(),
        )
    }
}

pub struct EditorAssetCatalog;

impl EditorAssetCatalog {
    /// `loadProject(at:preferredMeshIndices:)`; the default map is empty.
    pub fn load_project(
        root_path: &str,
        preferred_mesh_indices: &BTreeMap<String, i64>,
    ) -> Result<Vec<EditorAsset>, AssetRegistryError> {
        AssetRegistry::shared()
            .load_project(root_path, preferred_mesh_indices)
            .map(|entries| entries.iter().map(make_asset).collect())
    }

    pub fn load_project_default(root_path: &str) -> Result<Vec<EditorAsset>, AssetRegistryError> {
        Self::load_project(root_path, &BTreeMap::new())
    }

    pub fn entries() -> Vec<EditorAsset> {
        AssetRegistry::shared()
            .entries_snapshot()
            .iter()
            .map(make_asset)
            .collect()
    }

    pub fn asset_for(id: &str) -> Option<EditorAsset> {
        AssetRegistry::shared().entry(id).as_ref().map(make_asset)
    }
}

fn make_asset(entry: &AssetRegistryEntry) -> EditorAsset {
    EditorAsset {
        id: entry.id.clone(),
        name: entry.name.clone(),
        relative_path: entry.relative_path.clone(),
        absolute_path: entry.absolute_path.clone(),
        kind: entry.kind,
        mesh_index: entry.mesh_index,
    }
}

/// 进程内的视口落点矩形。AssetBrowser 行在指针抬起时通过它判断
/// 当前光标是否落在视口内。值由 ViewportPanel 在每一帧通过
/// `ViewportHost.onScreenFrameChange` 更新，不处于多线程读写环境。
pub struct EditorViewportDropTarget;

impl EditorViewportDropTarget {
    /// Swift's `nonisolated(unsafe) static var`.
    pub fn frame() -> Option<ViewportScreenFrame> {
        *FRAME
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    pub fn set_frame(frame: Option<ViewportScreenFrame>) {
        *FRAME
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = frame;
    }
}

static FRAME: std::sync::Mutex<Option<ViewportScreenFrame>> = std::sync::Mutex::new(None);
