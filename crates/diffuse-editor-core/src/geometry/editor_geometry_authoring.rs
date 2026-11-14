//! `Editor/Sources/EditorCore/Geometry/EditorGeometryAuthoring.swift`.

use std::cell::RefCell;
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::Arc;
use std::time::SystemTime;

use cove_system::atomic_file::AtomicFile;
use cove_system::files::Access;
use cove_system::paths::PathIdentity;
use diffuse_assets::asset_registry::{AssetRegistry, AssetRegistryError, ImportableAssetKind};
use diffuse_assets::geometry::bezier_spline::{BezierControlPoint, BezierSpline};
use diffuse_assets::geometry::geometry_baker::GeometryShading;
use diffuse_assets::geometry::geometry_document::{GeometryDocument, GeometrySource};
use diffuse_assets::geometry::geometry_modifier::{GeometryModifier, GeometryModifierEntry};
use diffuse_assets::geometry::polygon_mesh::{GeometryError, GeometryLimits, PolygonMesh};
use diffuse_math::simd::simd_compat::{Float2, Float3, Float4x4, Int2};

use crate::assets::asset_catalog::{EditorAsset, EditorAssetCatalog};
use crate::geometry::editor_mesh_picker::EditorMeshPicker;
use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
use crate::state::editor_reducer::EditorAction;
use crate::state::editor_state::{EditorConsoleSeverity, PlaybackState};
use crate::state::editor_store::EditorStore;
use crate::workstation::documents::EditorDocumentWorkspace;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum EditorGeometryPreset {
    Box,
    Plane,
    Curve,
}

impl EditorGeometryPreset {
    /// Swift's `CaseIterable` order.
    pub const ALL: [EditorGeometryPreset; 3] = [
        EditorGeometryPreset::Box,
        EditorGeometryPreset::Plane,
        EditorGeometryPreset::Curve,
    ];

    pub fn raw_value(self) -> &'static str {
        match self {
            EditorGeometryPreset::Box => "box",
            EditorGeometryPreset::Plane => "plane",
            EditorGeometryPreset::Curve => "curve",
        }
    }

    pub fn display_name(self) -> &'static str {
        match self {
            EditorGeometryPreset::Box => "Mesh Cube",
            EditorGeometryPreset::Plane => "Mesh Plane",
            EditorGeometryPreset::Curve => "Bezier Curve",
        }
    }

    pub fn document(self) -> GeometryDocument {
        match self {
            EditorGeometryPreset::Box => GeometryDocument::with_source(
                self.display_name(),
                GeometrySource::Box { size: Float3::ONE },
            ),
            EditorGeometryPreset::Plane => GeometryDocument::with_source(
                self.display_name(),
                GeometrySource::Grid {
                    size: Float2::new(2.0, 2.0),
                    segments: Int2::new(1, 1),
                },
            ),
            EditorGeometryPreset::Curve => {
                let spline = BezierSpline::new(
                    vec![
                        BezierControlPoint::new(
                            Float3::new(-1.0, 0.0, 0.0),
                            Float3::new(-2.0, 0.0, 0.0),
                            Float3::new(-0.5, 1.0, 0.0),
                        ),
                        BezierControlPoint::new(
                            Float3::new(1.0, 0.0, 0.0),
                            Float3::new(0.5, 1.0, 0.0),
                            Float3::new(2.0, 0.0, 0.0),
                        ),
                    ],
                    false,
                );
                let mut document = GeometryDocument::with_source(
                    self.display_name(),
                    GeometrySource::Tube {
                        spline,
                        radius: 0.1,
                        radial_segments: 12,
                        samples_per_segment: 24,
                        capped: true,
                    },
                );
                document.shading = GeometryShading::Smooth;
                document
            }
        }
    }
}

#[derive(Debug, thiserror::Error)]
pub enum GeometryAuthoringError {
    #[error(transparent)]
    Geometry(#[from] GeometryError),
    #[error(transparent)]
    Catalog(#[from] AssetRegistryError),
    #[error(transparent)]
    File(#[from] std::io::Error),
    #[error("{cause}. Could not restore {path}: {rollback}")]
    Rollback {
        cause: Box<Self>,
        path: PathBuf,
        rollback: std::io::Error,
    },
}

struct CachedDocument {
    size: u64,
    modified: Option<SystemTime>,
    document: GeometryDocument,
}

struct GeometryInteractiveEdit {
    entity_id: u64,
    asset: EditorAsset,
    original: GeometryDocument,
    preview: GeometryDocument,
}

/// Main-thread authoring shared by the application, history callbacks and inspector.
pub struct EditorGeometryAuthoring {
    root: PathBuf,
    scene: EditorSceneAdapter,
    store: Rc<EditorStore>,
    documents: Arc<EditorDocumentWorkspace>,
    invalidate_display: Rc<dyn Fn()>,
    cache: RefCell<HashMap<PathBuf, CachedDocument>>,
    interactive: RefCell<Option<GeometryInteractiveEdit>>,
    viewport_pickers: RefCell<HashMap<u64, (Float4x4, Rc<EditorMeshPicker<'static>>)>>,
}

impl EditorGeometryAuthoring {
    pub fn new(
        root: PathBuf,
        scene: EditorSceneAdapter,
        store: Rc<EditorStore>,
        documents: Arc<EditorDocumentWorkspace>,
        invalidate_display: Rc<dyn Fn()>,
    ) -> Rc<Self> {
        let authoring = Rc::new(Self {
            root,
            scene,
            store,
            documents,
            invalidate_display,
            cache: RefCell::new(HashMap::new()),
            interactive: RefCell::new(None),
            viewport_pickers: RefCell::new(HashMap::new()),
        });
        let weak = Rc::downgrade(&authoring);
        let mut provider = authoring.scene.additional_inspector_sections.borrow_mut();
        let previous = provider.take();
        *provider = Some(Rc::new(move |entity| {
            let mut sections = previous
                .as_ref()
                .map_or_else(Vec::new, |provider| provider(entity));
            if let Some(authoring) = weak.upgrade() {
                sections.extend(authoring.inspector_sections(entity));
            }
            sections
        }));
        drop(provider);
        authoring
    }

    pub fn create(&self, preset: EditorGeometryPreset) -> Option<u64> {
        if self.store.playback_state() != PlaybackState::Stopped
            || !self.scene.is_authoring_enabled()
        {
            return None;
        }
        match self.create_asset(preset) {
            Ok(id) => Some(id),
            Err(error) => {
                self.report(&error);
                None
            }
        }
    }

    fn create_asset(&self, preset: EditorGeometryPreset) -> Result<u64, GeometryAuthoringError> {
        let folder = self.root.join("Assets/Geometry");
        if !PathIdentity::contains(&folder, &self.root, false) {
            return Err(
                GeometryError::invalid_parameter("geometry directory outside project").into(),
            );
        }
        fs::create_dir_all(&folder)?;
        let base = preset.display_name().replace(' ', "");
        let mut path = folder.join(format!("{base}.dmesh"));
        let mut suffix = 1;
        while fs::symlink_metadata(&path).is_ok() {
            suffix += 1;
            path = folder.join(format!("{base}{suffix}.dmesh"));
        }
        preset
            .document()
            .save(path_text(&path)?, GeometryLimits::default())?;
        let result = (|| {
            let asset = self
                .load_assets()?
                .into_iter()
                .find(|asset| PathIdentity::same_location(Path::new(&asset.absolute_path), &path))
                .ok_or_else(|| GeometryError::invalid_parameter("geometry asset creation"))?;
            let id = self
                .scene
                .spawn_entity_from_asset_default(&asset)
                .ok_or_else(|| GeometryError::invalid_parameter("geometry asset creation"))?;
            self.store
                .dispatch(EditorAction::SetSelectedEntity(Some(id)));
            self.store.dispatch(EditorAction::AppendConsoleMessage {
                message: format!("Spawned {}", asset.name),
                severity: EditorConsoleSeverity::Info,
                detail: Some(format!("entity {id}")),
                target: None,
                next_step: None,
            });
            self.refresh();
            Ok(id)
        })();
        result.map_err(|cause| self.recover(&path, cause, || fs::remove_file(&path)))
    }

    pub fn document(
        &self,
        entity_id: u64,
    ) -> Result<Option<GeometryDocument>, GeometryAuthoringError> {
        let Some(asset) = self
            .scene
            .referenced_asset(entity_id)
            .filter(|asset| asset.kind == ImportableAssetKind::Dmesh)
        else {
            return Ok(None);
        };
        if let Some(edit) = self.interactive.borrow().as_ref()
            && edit.asset.mesh_index == asset.mesh_index
        {
            return Ok(Some(edit.preview.clone()));
        }
        let path = self.checked_path(&asset)?;
        let metadata = fs::metadata(&path)?;
        let size = metadata.len();
        let modified = metadata.modified().ok();
        if let Some(cached) = self.cache.borrow().get(&path)
            && cached.size == size
            && cached.modified == modified
            && modified.is_some()
        {
            return Ok(Some(cached.document.clone()));
        }
        let document = GeometryDocument::load(path_text(&path)?)?;
        self.cache.borrow_mut().insert(
            path,
            CachedDocument {
                size,
                modified,
                document: document.clone(),
            },
        );
        Ok(Some(document))
    }

    pub fn viewport_picker(
        self: &Rc<Self>,
        entity_id: u64,
    ) -> Option<Rc<EditorMeshPicker<'static>>> {
        let asset = self.scene.referenced_asset(entity_id)?;
        let mesh = AssetRegistry::shared().polygon_mesh(asset.mesh_index)?;
        let world = self.scene.entity_world_matrix(entity_id)?;
        let mut cache = self.viewport_pickers.borrow_mut();
        if let Some((matrix, picker)) = cache.get(&entity_id)
            && *matrix == world
            && picker.mesh == mesh
        {
            return Some(Rc::clone(picker));
        }
        let picker = self.make_picker(entity_id, mesh, world)?;
        if cache.len() > 128 {
            cache.clear();
        }
        cache.insert(entity_id, (world, Rc::clone(&picker)));
        Some(picker)
    }

    pub(super) fn make_picker(
        self: &Rc<Self>,
        entity_id: u64,
        mesh: PolygonMesh,
        world: Float4x4,
    ) -> Option<Rc<EditorMeshPicker<'static>>> {
        let weak = Rc::downgrade(self);
        EditorMeshPicker::new(mesh, world, Some(Box::new(move |origin, direction| {
            weak.upgrade()?.scene.mesh_surface_distance(origin, direction, Some(entity_id))
        }))).ok().map(Rc::new)
    }

    pub fn edit(
        self: &Rc<Self>,
        entity_id: u64,
        update: impl FnOnce(&mut GeometryDocument) -> Result<(), GeometryError>,
    ) -> bool {
        let Some(asset) = self.editable_asset(entity_id) else {
            return false;
        };
        if self.has_interactive_edit() {
            return false;
        }
        let result = (|| {
            let path = self.checked_path(&asset)?;
            let previous = GeometryDocument::load(path_text(&path)?)?;
            let mut next = previous.clone();
            update(&mut next)?;
            if previous == next {
                return Ok(());
            }
            self.replace(&asset, &previous, &next)?;
            self.record_edit(asset.mesh_index, previous, next);
            self.refresh_file();
            Ok(())
        })();
        match result {
            Ok(()) => true,
            Err(error) => {
                self.report(&error);
                false
            }
        }
    }

    pub fn add_modifier(self: &Rc<Self>, operation: GeometryModifier, entity_id: u64) -> bool {
        self.edit(entity_id, |document| {
            document
                .modifiers
                .push(GeometryModifierEntry::with_operation(operation));
            Ok(())
        })
    }

    pub fn remove_modifier(self: &Rc<Self>, id: &str, entity_id: u64) -> bool {
        self.edit(entity_id, |document| {
            let index = document
                .modifiers
                .iter()
                .position(|entry| entry.id == id)
                .ok_or_else(|| GeometryError::invalid_parameter("missing modifier"))?;
            document.modifiers.remove(index);
            Ok(())
        })
    }

    pub fn move_modifier(self: &Rc<Self>, id: &str, offset: isize, entity_id: u64) -> bool {
        self.edit(entity_id, |document| {
            let target = document
                .modifiers
                .iter()
                .position(|entry| entry.id == id)
                .filter(|_| matches!(offset, -1 | 1))
                .and_then(|index| index.checked_add_signed(offset).map(|next| (index, next)))
                .filter(|&(_, next)| next < document.modifiers.len())
                .ok_or_else(|| GeometryError::invalid_parameter("modifier order"))?;
            document.modifiers.swap(target.0, target.1);
            Ok(())
        })
    }

    fn record_edit(self: &Rc<Self>, slot: i64, previous: GeometryDocument, next: GeometryDocument) {
        let snapshots = Rc::new((previous, next));
        let restore = |undo| -> Rc<dyn Fn() -> bool> {
            let authoring = Rc::downgrade(self);
            let snapshots = Rc::clone(&snapshots);
            Rc::new(move || {
                let (previous, next) = &*snapshots;
                let (expected, target) = if undo {
                    (next, previous)
                } else {
                    (previous, next)
                };
                authoring
                    .upgrade()
                    .is_some_and(|authoring| authoring.restore(slot, expected, target))
            })
        };
        let weak = Rc::downgrade(self);
        self.scene.record_asset_edit(
            restore(true),
            restore(false),
            Rc::new(move || {
                if let Some(authoring) = weak.upgrade() {
                    authoring.refresh_file();
                }
            }),
        );
    }

    fn restore(&self, slot: i64, expected: &GeometryDocument, next: &GeometryDocument) -> bool {
        if self.store.playback_state() != PlaybackState::Stopped {
            return false;
        }
        let Some(asset) = EditorAssetCatalog::entries()
            .into_iter()
            .find(|asset| asset.mesh_index == slot && asset.kind == ImportableAssetKind::Dmesh)
        else {
            return false;
        };
        match self.replace(&asset, expected, next) {
            Ok(()) => true,
            Err(error) => {
                self.report(&error);
                false
            }
        }
    }

    fn replace(
        &self,
        asset: &EditorAsset,
        expected: &GeometryDocument,
        next: &GeometryDocument,
    ) -> Result<(), GeometryAuthoringError> {
        let path = self.checked_path(asset)?;
        if self.documents.documents().iter().any(|doc| {
            doc.is_dirty() && (doc.path == asset.relative_path || doc.path == asset.absolute_path)
        }) {
            return Err(GeometryError::invalid_parameter(
                "save or discard the open geometry text draft first",
            )
            .into());
        }
        let text = path_text(&path)?;
        if GeometryDocument::load(text)? != *expected {
            return Err(GeometryError::invalid_parameter(
                "geometry changed on disk; history was retained",
            )
            .into());
        }
        let previous = fs::read(&path)?;
        next.save(text, GeometryLimits::default())?;
        let indexed = self.load_assets().and_then(|assets| {
            if assets
                .iter()
                .any(|item| item.mesh_index == asset.mesh_index && item.id == asset.id)
            {
                Ok(())
            } else {
                Err(GeometryError::invalid_parameter("geometry catalog update").into())
            }
        });
        if let Err(cause) = indexed {
            return Err(self.recover(&path, cause, || {
                AtomicFile::write(&previous, &path, Access::Inherit)
            }));
        }
        self.cache.borrow_mut().remove(&path);
        Ok(())
    }

    fn recover(
        &self,
        path: &Path,
        cause: GeometryAuthoringError,
        rollback: impl FnOnce() -> std::io::Result<()>,
    ) -> GeometryAuthoringError {
        let result = rollback();
        let _ = self.load_assets();
        match result {
            Ok(()) => cause,
            Err(rollback) => GeometryAuthoringError::Rollback {
                cause: Box::new(cause),
                path: path.to_owned(),
                rollback,
            },
        }
    }

    fn load_assets(&self) -> Result<Vec<EditorAsset>, GeometryAuthoringError> {
        Ok(EditorAssetCatalog::load_project_default(path_text(
            &self.root,
        )?)?)
    }

    fn checked_path(&self, asset: &EditorAsset) -> Result<PathBuf, GeometryError> {
        let path = Path::new(&asset.absolute_path);
        if asset.kind != ImportableAssetKind::Dmesh
            || !PathIdentity::contains(path, &self.root, false)
        {
            return Err(GeometryError::invalid_parameter(
                "geometry asset outside project",
            ));
        }
        Ok(PathIdentity::canonical_url(path))
    }

    fn editable_asset(&self, entity_id: u64) -> Option<EditorAsset> {
        if self.store.playback_state() != PlaybackState::Stopped
            || !self.scene.is_authoring_enabled()
            || self.scene.is_entity_locked(entity_id)
        {
            return None;
        }
        self.scene
            .referenced_asset(entity_id)
            .filter(|asset| asset.kind == ImportableAssetKind::Dmesh)
    }

    fn refresh_file(&self) {
        self.scene.refresh_asset_geometry();
        self.documents.reload_unmodified();
        self.refresh();
    }

    fn refresh(&self) {
        self.store.geometry_changed();
        (self.invalidate_display)();
    }

    fn report(&self, error: &GeometryAuthoringError) {
        self.store.dispatch(EditorAction::AppendConsoleMessage {
            message: "Geometry edit failed".into(),
            severity: EditorConsoleSeverity::Error,
            detail: Some(error.to_string()),
            target: None,
            next_step: None,
        });
        self.store.geometry_changed();
    }

    pub fn has_interactive_edit(&self) -> bool {
        self.interactive.borrow().is_some()
    }

    pub fn begin_interactive_edit(&self, entity_id: u64) -> bool {
        if self.has_interactive_edit() {
            return false;
        }
        let Some(asset) = self.editable_asset(entity_id) else {
            return false;
        };
        let result = self
            .checked_path(&asset)
            .and_then(|path| GeometryDocument::load(path_text(&path)?));
        match result {
            Ok(original) => {
                *self.interactive.borrow_mut() = Some(GeometryInteractiveEdit {
                    entity_id,
                    asset,
                    preview: original.clone(),
                    original,
                });
                true
            }
            Err(error) => {
                self.report(&error.into());
                false
            }
        }
    }

    /// Evaluates each preview from its original source without writing to disk.
    pub fn preview_interactive_edit(
        &self,
        update: impl FnOnce(&mut GeometryDocument) -> Result<(), GeometryError>,
    ) -> bool {
        {
            let mut edit = self.interactive.borrow_mut();
            let Some(edit) = edit.as_mut() else {
                return false;
            };
            if self.store.playback_state() != PlaybackState::Stopped
                || self.scene.is_entity_locked(edit.entity_id)
            {
                return false;
            }
            let mut document = edit.original.clone();
            if update(&mut document).is_err() {
                return false;
            }
            let Ok(evaluated) = document.evaluate(GeometryLimits::default()) else {
                return false;
            };
            edit.preview = document;
            AssetRegistry::shared().register_transient_mesh(
                evaluated.mesh,
                edit.asset.mesh_index,
                &edit.asset.id,
                edit.asset.kind,
                Some(vec![evaluated.topology_slice]),
                Some(evaluated.control_mesh),
            );
        }
        self.refresh();
        true
    }

    pub fn commit_interactive_edit(self: &Rc<Self>) -> bool {
        let Some(edit) = self.take_interactive_edit() else {
            return false;
        };
        let success = self.edit(edit.entity_id, |document| {
            if *document != edit.original {
                return Err(GeometryError::invalid_parameter(
                    "geometry changed during drag",
                ));
            }
            *document = edit.preview;
            Ok(())
        });
        if !success {
            let _ = self.load_assets();
            self.scene.refresh_asset_geometry();
        }
        self.refresh();
        success
    }

    pub fn cancel_interactive_edit(&self) -> bool {
        let Some(edit) = self.take_interactive_edit() else {
            return false;
        };
        if let Ok(path) = self.checked_path(&edit.asset)
            && path_text(&path)
                .and_then(GeometryDocument::load)
                .ok()
                .as_ref()
                != Some(&edit.original)
        {
            self.cache.borrow_mut().remove(&path);
            let _ = self.load_assets();
            self.scene.refresh_asset_geometry();
            self.documents.reload_unmodified();
        }
        self.refresh();
        true
    }

    fn take_interactive_edit(&self) -> Option<GeometryInteractiveEdit> {
        let edit = self.interactive.borrow_mut().take()?;
        AssetRegistry::shared().unregister_transient_mesh(edit.asset.mesh_index);
        Some(edit)
    }
}

impl Drop for EditorGeometryAuthoring {
    fn drop(&mut self) {
        let _ = self.take_interactive_edit();
    }
}

fn path_text(path: &Path) -> Result<&str, GeometryError> {
    path.to_str()
        .ok_or_else(|| GeometryError::invalid_parameter("geometry path is not UTF-8"))
}
