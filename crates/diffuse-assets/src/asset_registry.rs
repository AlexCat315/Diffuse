//! Project asset scanning and the mesh index registry.
//!
//! Ported from `Engine/Sources/AssetPipeline/AssetRegistry.swift`.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use cove_logging::{Level, LogEvent, LogSystem};
use cove_system::paths::PathIdentity;

use crate::asset_pipeline::{MeshAsset, MeshTopologySlice, OBJLoader};
use crate::geometry::geometry_document::GeometryDocument;
use crate::geometry::polygon_mesh::{GeometryLimits, PolygonMesh};
use crate::import::gltf_importer::GLTFImporter;
use crate::mesh::mesh_asset_catalog::MeshAssetCatalog;
use crate::project_resource_walker::files;

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum AssetRegistryError {
    #[error("invalid project root: {0}")]
    InvalidProjectRoot(String),
}

/// The importable formats a project scan recognises.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum ImportableAssetKind {
    Gltf,
    Glb,
    Obj,
    Dmesh,
    Png,
    Jpg,
    Jpeg,
    Webp,
    Tga,
    Bmp,
    Gif,
    Svg,
}

impl ImportableAssetKind {
    /// Swift declared `String` raw values; this is what `Codable` persists.
    pub fn raw_value(&self) -> &'static str {
        match self {
            ImportableAssetKind::Gltf => "gltf",
            ImportableAssetKind::Glb => "glb",
            ImportableAssetKind::Obj => "obj",
            ImportableAssetKind::Dmesh => "dmesh",
            ImportableAssetKind::Png => "png",
            ImportableAssetKind::Jpg => "jpg",
            ImportableAssetKind::Jpeg => "jpeg",
            ImportableAssetKind::Webp => "webp",
            ImportableAssetKind::Tga => "tga",
            ImportableAssetKind::Bmp => "bmp",
            ImportableAssetKind::Gif => "gif",
            ImportableAssetKind::Svg => "svg",
        }
    }

    /// Maps a lowercased file extension, or `None` for anything unimportable.
    pub fn from_extension(extension: &str) -> Option<Self> {
        Some(match extension {
            "gltf" => ImportableAssetKind::Gltf,
            "glb" => ImportableAssetKind::Glb,
            "obj" => ImportableAssetKind::Obj,
            "dmesh" => ImportableAssetKind::Dmesh,
            "png" => ImportableAssetKind::Png,
            "jpg" => ImportableAssetKind::Jpg,
            "jpeg" => ImportableAssetKind::Jpeg,
            "webp" => ImportableAssetKind::Webp,
            "tga" => ImportableAssetKind::Tga,
            "bmp" => ImportableAssetKind::Bmp,
            "gif" => ImportableAssetKind::Gif,
            "svg" => ImportableAssetKind::Svg,
            _ => return None,
        })
    }

    pub fn scene_kind_label(&self) -> &'static str {
        if self.is_texture() {
            "Texture"
        } else {
            "Static Mesh"
        }
    }

    pub fn is_mesh(&self) -> bool {
        matches!(
            self,
            ImportableAssetKind::Gltf
                | ImportableAssetKind::Glb
                | ImportableAssetKind::Obj
                | ImportableAssetKind::Dmesh
        )
    }

    pub fn is_texture(&self) -> bool {
        !self.is_mesh()
    }
}

/// One scanned project asset.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AssetRegistryEntry {
    pub id: String,
    pub name: String,
    pub relative_path: String,
    pub absolute_path: String,
    pub kind: ImportableAssetKind,
    pub mesh_index: i64,
}

/// A mesh registered against a stable index, plus its optional source data.
#[derive(Clone, Debug, PartialEq)]
pub struct RegisteredMeshAsset {
    pub mesh_index: i64,
    pub asset_id: String,
    pub kind: ImportableAssetKind,
    pub source_directory: Option<String>,
    pub mesh: MeshAsset,
    pub topology_slices: Option<Vec<MeshTopologySlice>>,
    /// Evaluated polygon boundaries, before GPU triangulation.
    pub polygon_mesh: Option<PolygonMesh>,
}

/// Registers project assets and hands out stable GPU mesh slots.
pub struct AssetRegistry {
    state: Mutex<RegistryState>,
}

struct RegistryState {
    project_root: Option<String>,
    entries: Vec<AssetRegistryEntry>,
    meshes: BTreeMap<i64, RegisteredMeshAsset>,
    /// Explicit transient meshes are an overlay, not part of a project scan. A
    /// catalog reload therefore cannot invalidate one between registration and
    /// consumption.
    explicitly_registered_meshes: BTreeMap<i64, RegisteredMeshAsset>,
    /// Stable `relative_path` → `mesh_index` map; survives reloads so indices
    /// never change for known paths.
    path_index: HashMap<String, i64>,
    next_mesh_index: i64,
    mesh_catalog_revision: u64,
}

impl Default for AssetRegistry {
    fn default() -> Self {
        AssetRegistry::new()
    }
}

impl AssetRegistry {
    pub fn shared() -> &'static Self {
        static SHARED: std::sync::OnceLock<AssetRegistry> = std::sync::OnceLock::new();
        SHARED.get_or_init(Self::new)
    }

    /// Index the first imported mesh occupies; 0 and 1 stay reserved.
    pub const IMPORTED_MESH_START_INDEX: i64 = 2;

    /// Directories a project scan never descends into.
    const BUILD_DIRECTORY_NAMES: [&'static str; 5] =
        ["build", ".build", "export", "node_modules", ".gradle"];

    pub fn new() -> Self {
        AssetRegistry {
            state: Mutex::new(RegistryState {
                project_root: None,
                entries: Vec::new(),
                meshes: BTreeMap::new(),
                explicitly_registered_meshes: BTreeMap::new(),
                path_index: HashMap::new(),
                next_mesh_index: Self::IMPORTED_MESH_START_INDEX,
                mesh_catalog_revision: 1,
            }),
        }
    }

    fn state(&self) -> std::sync::MutexGuard<'_, RegistryState> {
        self.state.lock().unwrap_or_else(|error| error.into_inner())
    }

    /// Preserves GPU mesh slots when a project file is renamed or moved.
    pub fn relocate_asset_path(&self, old_path: &str, new_path: &str) {
        let mut state = self.state();
        if let Some(index) = state.path_index.remove(old_path) {
            state.path_index.insert(new_path.to_string(), index);
        }
    }

    /// Scans `root_path`, adopting the persisted mesh indices in
    /// `preferred_mesh_indices` where they are still free.
    pub fn load_project(
        &self,
        root_path: &str,
        preferred_mesh_indices: &BTreeMap<String, i64>,
    ) -> Result<Vec<AssetRegistryEntry>, AssetRegistryError> {
        let root_url = PathIdentity::canonical_url(Path::new(root_path));
        if !root_url.is_dir() {
            return Err(AssetRegistryError::InvalidProjectRoot(
                root_path.to_string(),
            ));
        }
        let root_text = root_url.to_string_lossy().into_owned();

        let candidates = self.find_importable_assets(&root_url);
        let mut loaded_entries: Vec<AssetRegistryEntry> = Vec::new();
        let mut loaded_meshes: BTreeMap<i64, RegisteredMeshAsset> = BTreeMap::new();

        let (mut current_path_index, mut current_next_index, existing_meshes) = {
            let state = self.state();
            if state.project_root.as_deref() == Some(root_text.as_str()) {
                (
                    state.path_index.clone(),
                    state.next_mesh_index,
                    state.meshes.clone(),
                )
            } else {
                (
                    HashMap::new(),
                    Self::IMPORTED_MESH_START_INDEX,
                    BTreeMap::new(),
                )
            }
        };

        // Export bundles persist mesh slots in assets.json. Reserve those slots
        // before assigning new ones so scene references keep pointing at the same
        // meshes.
        let mut used_mesh_indices: BTreeSet<i64> = current_path_index.values().copied().collect();
        for (relative_path, preferred_index) in preferred_mesh_indices {
            if *preferred_index < Self::IMPORTED_MESH_START_INDEX
                || current_path_index.contains_key(relative_path)
                || used_mesh_indices.contains(preferred_index)
            {
                continue;
            }
            current_path_index.insert(relative_path.clone(), *preferred_index);
            used_mesh_indices.insert(*preferred_index);
            current_next_index = current_next_index.max(preferred_index + 1);
        }

        for (url, kind) in candidates {
            let asset_url = PathIdentity::canonical_url(&url);
            let Some(relative_path) = Self::relative_path(&url, &root_url) else {
                LogSystem::logger("com.cove.engine.assets").log(&LogEvent::new(
                    Level::Warning,
                    format!(
                        "AssetRegistry: skipping path outside project root: {}",
                        url.to_string_lossy()
                    ),
                ));
                continue;
            };

            if !kind.is_mesh() {
                loaded_entries.push(AssetRegistryEntry {
                    id: relative_path.clone(),
                    name: file_stem(&asset_url),
                    relative_path,
                    absolute_path: asset_url.to_string_lossy().into_owned(),
                    kind,
                    mesh_index: 0,
                });
                continue;
            }

            // Reuse the existing index for known paths so GPU mesh slots never shift.
            let mesh_index: i64;
            if let Some(existing) = current_path_index.get(&relative_path).copied() {
                mesh_index = existing;
                if kind != ImportableAssetKind::Dmesh
                    && let Some(existing_mesh) = existing_meshes.get(&existing)
                {
                    loaded_meshes.insert(mesh_index, existing_mesh.clone());
                    loaded_entries.push(AssetRegistryEntry {
                        id: relative_path.clone(),
                        name: file_stem(&asset_url),
                        relative_path,
                        absolute_path: asset_url.to_string_lossy().into_owned(),
                        kind,
                        mesh_index,
                    });
                    continue;
                }
            } else {
                while used_mesh_indices.contains(&current_next_index) {
                    current_next_index += 1;
                }
                mesh_index = current_next_index;
                current_next_index += 1;
                current_path_index.insert(relative_path.clone(), mesh_index);
                used_mesh_indices.insert(mesh_index);
            }

            let imported = match self.import_mesh(&url, kind) {
                Ok(imported) => imported,
                Err(error) => {
                    LogSystem::logger("com.cove.engine.assets").log(&LogEvent::new(
                        Level::Warning,
                        format!("AssetRegistry: skipping {} — {}", file_name(&url), error),
                    ));
                    current_path_index.remove(&relative_path);
                    used_mesh_indices.remove(&mesh_index);
                    continue;
                }
            };
            let mut mesh = imported.mesh;
            // Native authoring assets use scene units; array spacing and shell
            // thickness must survive loading and export without rescaling.
            if kind != ImportableAssetKind::Dmesh {
                mesh.normalize_to_unit_bounds(2.0);
            }

            let normalized_slices: Option<Vec<MeshTopologySlice>> =
                if kind == ImportableAssetKind::Dmesh {
                    imported.topology_slices
                } else {
                    match imported.topology_slices {
                        None => None,
                        Some(slices) => {
                            let (min_value, max_value) = mesh.local_bounds();
                            let center = (min_value + max_value) * 0.5;
                            let extent = (max_value.x - min_value.x)
                                .max((max_value.y - min_value.y).max(max_value.z - min_value.z));
                            let scale: f32 = if extent > 0.0 { 2.0 / extent } else { 1.0 };
                            Some(
                                slices
                                    .into_iter()
                                    .map(|slice| {
                                        let mapped = slice
                                            .positions
                                            .iter()
                                            .map(|position| (*position - center) * scale)
                                            .collect();
                                        MeshTopologySlice::new(
                                            mapped,
                                            slice.triangle_indices,
                                            slice.index_remap,
                                        )
                                    })
                                    .collect(),
                            )
                        }
                    }
                };

            let entry = AssetRegistryEntry {
                id: relative_path.clone(),
                name: file_stem(&asset_url),
                relative_path,
                absolute_path: asset_url.to_string_lossy().into_owned(),
                kind,
                mesh_index,
            };
            loaded_entries.push(entry.clone());
            loaded_meshes.insert(
                mesh_index,
                RegisteredMeshAsset {
                    mesh_index,
                    asset_id: entry.id,
                    kind,
                    source_directory: asset_url
                        .parent()
                        .map(|parent| parent.to_string_lossy().into_owned()),
                    mesh,
                    topology_slices: normalized_slices,
                    polygon_mesh: imported.polygon_mesh,
                },
            );
        }

        let mut state = self.state();
        state.project_root = Some(root_text);
        state.entries = loaded_entries.clone();
        state.meshes = loaded_meshes;
        state.mesh_catalog_revision = state.mesh_catalog_revision.wrapping_add(1);
        state.path_index = current_path_index;
        state.next_mesh_index = current_next_index;
        drop(state);
        Ok(loaded_entries)
    }

    /// `load_project` with no persisted indices.
    pub fn load_project_default(
        &self,
        root_path: &str,
    ) -> Result<Vec<AssetRegistryEntry>, AssetRegistryError> {
        self.load_project(root_path, &BTreeMap::new())
    }

    pub fn current_project_root(&self) -> Option<String> {
        self.state().project_root.clone()
    }

    pub fn entries_snapshot(&self) -> Vec<AssetRegistryEntry> {
        self.state().entries.clone()
    }

    /// Atomically pairs content with its revision; unchanged frames do not copy
    /// or hash large meshes. Revisions also cover removal and project resets.
    pub fn mesh_catalog(&self, since: Option<u64>) -> Option<MeshAssetCatalog> {
        let state = self.state();
        if since == Some(state.mesh_catalog_revision) {
            return None;
        }
        let mut merged = state.meshes.clone();
        for (index, registered) in &state.explicitly_registered_meshes {
            merged.insert(*index, registered.clone());
        }
        Some(MeshAssetCatalog::new(
            state.mesh_catalog_revision,
            merged.into_values().collect(),
        ))
    }

    pub fn registered_meshes(&self) -> Vec<RegisteredMeshAsset> {
        let state = self.state();
        let mut merged = state.meshes.clone();
        for (index, registered) in &state.explicitly_registered_meshes {
            merged.insert(*index, registered.clone());
        }
        merged.into_values().collect()
    }

    pub fn entry(&self, id: &str) -> Option<AssetRegistryEntry> {
        self.state()
            .entries
            .iter()
            .find(|entry| entry.id == id)
            .cloned()
    }

    pub fn mesh_asset(&self, mesh_index: i64) -> Option<MeshAsset> {
        let state = self.state();
        state
            .explicitly_registered_meshes
            .get(&mesh_index)
            .map(|registered| registered.mesh.clone())
            .or_else(|| {
                state
                    .meshes
                    .get(&mesh_index)
                    .map(|registered| registered.mesh.clone())
            })
    }

    pub fn polygon_mesh(&self, mesh_index: i64) -> Option<PolygonMesh> {
        let state = self.state();
        state
            .explicitly_registered_meshes
            .get(&mesh_index)
            .or_else(|| state.meshes.get(&mesh_index))
            .and_then(|registered| registered.polygon_mesh.clone())
    }

    pub fn reset(&self) {
        let mut state = self.state();
        state.mesh_catalog_revision = state.mesh_catalog_revision.wrapping_add(1);
        state.project_root = None;
        state.entries.clear();
        state.meshes.clear();
        state.explicitly_registered_meshes.clear();
        state.path_index.clear();
        state.next_mesh_index = Self::IMPORTED_MESH_START_INDEX;
    }

    /// Registers a mesh asset directly at the given index. Intended for tests
    /// that need a pre-built `MeshAsset` without loading from disk.
    pub fn register_for_testing(&self, mesh: MeshAsset, mesh_index: i64) {
        self.register_transient_mesh(
            mesh,
            mesh_index,
            &format!("test:{mesh_index}"),
            ImportableAssetKind::Gltf,
            None,
            None,
        );
    }

    /// Publishes an evaluated preview without replacing the file-backed asset.
    /// Removing the overlay restores the current project catalog at that slot.
    pub fn register_transient_mesh(
        &self,
        mesh: MeshAsset,
        mesh_index: i64,
        asset_id: &str,
        kind: ImportableAssetKind,
        topology_slices: Option<Vec<MeshTopologySlice>>,
        polygon_mesh: Option<PolygonMesh>,
    ) {
        let mut state = self.state();
        state.mesh_catalog_revision = state.mesh_catalog_revision.wrapping_add(1);
        state.explicitly_registered_meshes.insert(
            mesh_index,
            RegisteredMeshAsset {
                mesh_index,
                asset_id: asset_id.to_string(),
                kind,
                source_directory: None,
                mesh,
                topology_slices,
                polygon_mesh,
            },
        );
    }

    /// Removes one explicit mesh without disturbing the active project's catalog
    /// or any other transient registration.
    pub fn unregister_testing_mesh(&self, mesh_index: i64) {
        self.unregister_transient_mesh(mesh_index);
    }

    pub fn unregister_transient_mesh(&self, mesh_index: i64) {
        let mut state = self.state();
        state.mesh_catalog_revision = state.mesh_catalog_revision.wrapping_add(1);
        state.explicitly_registered_meshes.remove(&mesh_index);
    }

    fn relative_path(candidate: &Path, root: &Path) -> Option<String> {
        if !PathIdentity::contains(candidate, root, false) {
            return None;
        }
        Some(PathIdentity::relative_path(candidate, root))
    }

    fn find_importable_assets(&self, root_url: &Path) -> Vec<(PathBuf, ImportableAssetKind)> {
        let found = files(root_url, true, |path| {
            path.file_name()
                .and_then(|name| name.to_str())
                .map(|name| {
                    let lower = name.to_ascii_lowercase();
                    Self::BUILD_DIRECTORY_NAMES.contains(&lower.as_str())
                })
                .unwrap_or(false)
        });
        let found = match found {
            Ok(found) => found,
            Err(error) => {
                LogSystem::logger("com.cove.engine.assets").log(&LogEvent::new(
                    Level::Warning,
                    format!("AssetRegistry: project scan failed — {error}"),
                ));
                return Vec::new();
            }
        };
        let mut results: Vec<(PathBuf, ImportableAssetKind)> = Vec::new();
        for url in found {
            let extension = url
                .extension()
                .and_then(|value| value.to_str())
                .unwrap_or("")
                .to_ascii_lowercase();
            if let Some(kind) = ImportableAssetKind::from_extension(&extension) {
                results.push((url, kind));
            }
        }
        results.sort_by(|lhs, rhs| lhs.0.cmp(&rhs.0));
        results
    }

    fn import_mesh(&self, url: &Path, kind: ImportableAssetKind) -> Result<ImportedMesh, String> {
        let text = url.to_string_lossy().into_owned();
        match kind {
            ImportableAssetKind::Gltf | ImportableAssetKind::Glb => {
                let loaded =
                    GLTFImporter::load_with_topology(&text).map_err(|error| error.to_string())?;
                Ok(ImportedMesh {
                    mesh: loaded.mesh,
                    topology_slices: Some(loaded.topologies),
                    polygon_mesh: None,
                })
            }
            ImportableAssetKind::Obj => {
                let mesh = OBJLoader::load(&text).map_err(|error| error.to_string())?;
                Ok(ImportedMesh {
                    mesh,
                    topology_slices: None,
                    polygon_mesh: None,
                })
            }
            ImportableAssetKind::Dmesh => {
                let document = GeometryDocument::load(&text).map_err(|error| error.to_string())?;
                let evaluated = document
                    .evaluate(GeometryLimits::default())
                    .map_err(|error| error.to_string())?;
                Ok(ImportedMesh {
                    mesh: evaluated.mesh,
                    topology_slices: Some(vec![evaluated.topology_slice]),
                    polygon_mesh: Some(evaluated.control_mesh),
                })
            }
            ImportableAssetKind::Png
            | ImportableAssetKind::Jpg
            | ImportableAssetKind::Jpeg
            | ImportableAssetKind::Webp
            | ImportableAssetKind::Tga
            | ImportableAssetKind::Bmp
            | ImportableAssetKind::Gif
            | ImportableAssetKind::Svg => Err("Texture assets are not mesh-importable".to_string()),
        }
    }
}

/// The three values a successful import produces.
struct ImportedMesh {
    mesh: MeshAsset,
    topology_slices: Option<Vec<MeshTopologySlice>>,
    polygon_mesh: Option<PolygonMesh>,
}

/// `lastPathComponent` without the extension.
fn file_stem(path: &Path) -> String {
    path.file_stem()
        .and_then(|value| value.to_str())
        .unwrap_or("")
        .to_string()
}

/// `lastPathComponent`, including the extension.
fn file_name(path: &Path) -> String {
    path.file_name()
        .and_then(|value| value.to_str())
        .unwrap_or("")
        .to_string()
}
