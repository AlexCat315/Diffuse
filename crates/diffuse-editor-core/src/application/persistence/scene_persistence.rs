//! `Editor/Sources/EditorCore/Application/Persistence/ScenePersistence.swift`.

use std::cell::{Cell, RefCell};
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::time::SystemTime;

use cove_system::atomic_file::AtomicFile;
use cove_system::files::Access;
use diffuse_assets::swift_json::{SwiftJsonError, to_sorted_pretty};
use diffuse_scene::scene_runtime::SceneRuntime;

use crate::application::editor_application::EditorApplication;
use crate::geometry::editor_mesh_editing::EditorMeshEditing;
use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
use crate::scene::game_save_document::{GameSaveDocument, GameSaveDocumentError};
use crate::scene::manifest::editor_scene_manifest::{
    EditorSceneManifest, EditorSceneManifestLoadError, EditorSceneManifestLoadResult,
};
use crate::state::editor_reducer::EditorAction;
use crate::state::editor_state::{EditorConsoleSeverity, PlaybackState};
use crate::state::editor_store::EditorStore;

#[derive(Debug, thiserror::Error)]
pub(crate) enum ScenePersistenceError {
    #[error(transparent)]
    Io(#[from] io::Error),
    #[error(transparent)]
    Decode(#[from] serde_json::Error),
    #[error(transparent)]
    Encode(#[from] SwiftJsonError),
    #[error(transparent)]
    InvalidManifest(#[from] EditorSceneManifestLoadError),
    #[error(transparent)]
    GameSave(#[from] GameSaveDocumentError),
}

#[derive(Default)]
struct AutosaveState {
    elapsed: f64,
    last_revision: Option<u64>,
    suppressed_revision: Option<u64>,
}

pub(crate) struct PlaySnapshot {
    pub scene: SceneRuntime,
    pub authored_revision: u64,
}

pub(crate) struct EditorScenePersistence {
    project: PathBuf,
    pub(super) scene: EditorSceneAdapter,
    pub(super) store: Rc<EditorStore>,
    pub(super) play_snapshot: RefCell<Option<PlaySnapshot>>,
    autosave: Cell<AutosaveState>,
}

impl EditorScenePersistence {
    pub(crate) const AUTOSAVE_INTERVAL: f64 = 10.0;

    pub(crate) fn new(project: PathBuf, scene: EditorSceneAdapter, store: Rc<EditorStore>) -> Self {
        Self {
            project,
            scene,
            store,
            play_snapshot: RefCell::default(),
            autosave: Cell::default(),
        }
    }

    pub(super) fn project(&self) -> &Path {
        &self.project
    }

    pub(crate) fn scene_manifest_path(&self) -> PathBuf {
        self.project.join(".cove/editor-scene-manifest.json")
    }

    pub(crate) fn autosave_path(&self) -> PathBuf {
        GameSaveDocument::url(GameSaveDocument::AUTO_SAVE_SLOT, &self.project)
    }

    pub(crate) fn authored_scene_manifest(&self) -> (EditorSceneManifest, bool) {
        let selected = self.store.selected_entity_id();
        if self.store.playback_state() != PlaybackState::Stopped
            && let Some(snapshot) = self.play_snapshot.borrow().as_ref()
        {
            return (
                Self::manifest_for_snapshot(snapshot.scene.clone(), selected),
                true,
            );
        }
        (self.scene.manifest_for_selection(selected), false)
    }

    pub(super) fn manifest_for_snapshot(
        scene: SceneRuntime,
        selection: Option<u64>,
    ) -> EditorSceneManifest {
        let adapter = EditorSceneAdapter::with_defaults(false);
        adapter.set_scene(scene);
        adapter.manifest_for_selection(selection)
    }

    pub(crate) fn save_scene_manifest(&self, mesh: Option<&EditorMeshEditing>) -> Option<PathBuf> {
        if mesh.is_some_and(|mesh| mesh.has_interactive_edit() && !mesh.commit_interactive_edit()) {
            return None;
        }
        let (manifest, used_play_snapshot) = self.authored_scene_manifest();
        let path = self.scene_manifest_path();
        if let Err(error) = write_manifest(&path, &manifest) {
            self.log(
                "Failed to save scene manifest",
                EditorConsoleSeverity::Error,
                error.to_string(),
            );
            return None;
        }
        if used_play_snapshot && let Some(snapshot) = self.play_snapshot.borrow_mut().as_mut() {
            snapshot.authored_revision = manifest.revision;
        }
        self.store
            .dispatch(EditorAction::SetSceneRevision(manifest.revision));
        self.store
            .dispatch(EditorAction::MarkSceneSaved(manifest.revision));
        self.remove_editor_autosave();
        let message = if used_play_snapshot {
            "Saved authored scene snapshot during playback"
        } else {
            "Saved scene manifest"
        };
        self.log(
            message,
            EditorConsoleSeverity::Info,
            path.display().to_string(),
        );
        Some(path)
    }

    pub(crate) fn open_scene_manifest(
        &self,
        source: &Path,
        clear_recovery: bool,
        log_missing: bool,
        replace: impl Fn(
            &EditorSceneManifest,
        ) -> Result<EditorSceneManifestLoadResult, ScenePersistenceError>,
    ) -> Option<EditorSceneManifest> {
        let manifest = match read_manifest(source) {
            Ok(manifest) => manifest,
            Err(ScenePersistenceError::Io(error)) if error.kind() == io::ErrorKind::NotFound => {
                if log_missing {
                    self.log(
                        "No saved scene manifest",
                        EditorConsoleSeverity::Warning,
                        source.display().to_string(),
                    );
                }
                return None;
            }
            Err(error) => {
                self.log(
                    "Failed to open scene manifest",
                    EditorConsoleSeverity::Error,
                    error.to_string(),
                );
                return None;
            }
        };
        match replace(&manifest) {
            Ok(result) => {
                self.publish_selection(&result);
                self.store
                    .dispatch(EditorAction::MarkSceneSaved(self.store.scene_revision()));
                self.autosave.take();
                if clear_recovery {
                    self.remove_editor_autosave();
                }
                self.log(
                    "Opened scene manifest",
                    EditorConsoleSeverity::Info,
                    format!(
                        "{} entities restored from revision {} · {}",
                        result.entity_count,
                        manifest.revision,
                        source.display(),
                    ),
                );
                Some(manifest)
            }
            Err(error) => {
                self.log(
                    "Failed to open scene manifest",
                    EditorConsoleSeverity::Error,
                    error.to_string(),
                );
                None
            }
        }
    }

    pub(crate) fn restore_project_scene_at_launch(
        &self,
        replace: impl Fn(
            &EditorSceneManifest,
        ) -> Result<EditorSceneManifestLoadResult, ScenePersistenceError>,
    ) -> Option<EditorSceneManifest> {
        let saved_path = self.scene_manifest_path();
        let saved = self.open_scene_manifest(&saved_path, false, false, &replace);
        let saved_date = modification_date(&saved_path);
        let autosave_path = self.autosave_path();
        let autosave_date = modification_date(&autosave_path);
        let play_date = modification_date(&self.physics_play_snapshot_path());

        if play_date > saved_date.max(autosave_date) {
            if let Some(recovered) = self.restore_interrupted_play(&replace) {
                return Some(recovered);
            }
        } else if play_date.is_some() {
            self.delete_persisted_physics_play_snapshot();
        }

        if saved.is_some() && autosave_date <= saved_date {
            self.remove_editor_autosave();
            return saved;
        }
        let recovered = (|| {
            let Some(document) = GameSaveDocument::read(&autosave_path)? else {
                return Ok(None);
            };
            let result = replace(&document.manifest)?;
            self.mark_recovered(&result);
            self.log(
                "Recovered autosaved scene",
                EditorConsoleSeverity::Warning,
                format!(
                    "{} entities from {}; save the scene to keep it",
                    result.entity_count, document.saved_at,
                ),
            );
            Ok::<_, ScenePersistenceError>(Some(document.manifest))
        })();
        match recovered {
            Ok(manifest) => manifest.or(saved),
            Err(error) => {
                self.log(
                    "Failed to restore autosaved scene",
                    EditorConsoleSeverity::Warning,
                    format!("{error}. {}", quarantine(&autosave_path, "recovery file")),
                );
                saved
            }
        }
    }

    fn restore_interrupted_play(
        &self,
        replace: impl Fn(
            &EditorSceneManifest,
        ) -> Result<EditorSceneManifestLoadResult, ScenePersistenceError>,
    ) -> Option<EditorSceneManifest> {
        let path = self.physics_play_snapshot_path();
        let result = match read_manifest(&path).and_then(|manifest| replace(&manifest)) {
            Ok(result) => result,
            Err(error) => {
                self.log(
                    "Failed to restore interrupted Play snapshot",
                    EditorConsoleSeverity::Warning,
                    format!(
                        "{error}. {}",
                        quarantine(&path, "interrupted Play snapshot")
                    ),
                );
                return None;
            }
        };
        self.mark_recovered(&result);
        let manifest = self.scene.manifest_for_selection(result.selected_entity_id);
        let document = GameSaveDocument::new(GameSaveDocument::AUTO_SAVE_SLOT, manifest.clone());
        match document.write(&self.autosave_path()) {
            Ok(()) => self.delete_persisted_physics_play_snapshot(),
            Err(error) => self.log(
                "Recovered interrupted Play but could not convert its snapshot to autosave",
                EditorConsoleSeverity::Warning,
                error.to_string(),
            ),
        }
        self.log(
            "Recovered scene from an interrupted Play session",
            EditorConsoleSeverity::Warning,
            format!(
                "{} entities; save the scene to keep it",
                result.entity_count
            ),
        );
        Some(manifest)
    }

    pub(super) fn publish_selection(&self, result: &EditorSceneManifestLoadResult) {
        self.store
            .dispatch(EditorAction::SetSelectedEntity(result.selected_entity_id));
        self.store
            .dispatch(EditorAction::SetSceneRevision(self.scene.revision()));
    }

    pub(crate) fn load_scene(
        &self,
        manifest: &EditorSceneManifest,
    ) -> Result<EditorSceneManifestLoadResult, ScenePersistenceError> {
        let mut result = self.scene.load(manifest);
        match result.error.take() {
            Some(error) => Err(error.into()),
            None => Ok(result),
        }
    }

    fn mark_recovered(&self, result: &EditorSceneManifestLoadResult) {
        self.publish_selection(result);
        self.store
            .dispatch(EditorAction::SetSceneRecoveryPending(true));
        self.autosave.set(AutosaveState {
            last_revision: Some(self.store.scene_revision()),
            ..AutosaveState::default()
        });
    }

    pub(crate) fn autosave_scene_if_needed(&self, elapsed: f64, force: bool) {
        let mut state = self.autosave.take();
        let revision = self.store.scene_revision();
        if state.suppressed_revision != Some(revision) {
            state.suppressed_revision = None;
        }
        let dirty = self.store.scene_dirty();
        if !dirty {
            state.elapsed = 0.0;
        }
        if self.store.playback_state() != PlaybackState::Stopped
            || !dirty
            || state.suppressed_revision.is_some()
        {
            self.autosave.set(state);
            return;
        }
        state.elapsed += elapsed.max(0.0).min(Self::AUTOSAVE_INTERVAL);
        if (!force && state.elapsed < Self::AUTOSAVE_INTERVAL)
            || state.last_revision == Some(revision)
        {
            self.autosave.set(state);
            return;
        }
        let path = self.autosave_path();
        let result = GameSaveDocument::new(
            GameSaveDocument::AUTO_SAVE_SLOT,
            self.scene
                .manifest_for_selection(self.store.selected_entity_id()),
        )
        .write(&path);
        state.elapsed = 0.0;
        if result.is_ok() {
            state.last_revision = Some(revision);
        }
        self.autosave.set(state);
        match result {
            Ok(()) => self.log(
                "Autosaved scene recovery snapshot",
                EditorConsoleSeverity::Info,
                path.file_name()
                    .unwrap_or_default()
                    .to_string_lossy()
                    .into_owned(),
            ),
            Err(error) => self.log(
                "Failed to autosave scene recovery snapshot",
                EditorConsoleSeverity::Warning,
                error.to_string(),
            ),
        }
    }

    pub(crate) fn discard_autosaved_scene(&self) {
        self.autosave.set(AutosaveState {
            suppressed_revision: Some(self.store.scene_revision()),
            ..AutosaveState::default()
        });
        self.store
            .dispatch(EditorAction::SetSceneRecoveryPending(false));
        if let Err(error) = fs::remove_file(self.autosave_path())
            && error.kind() != io::ErrorKind::NotFound
        {
            self.log(
                "Failed to discard autosaved scene",
                EditorConsoleSeverity::Warning,
                error.to_string(),
            );
        }
    }

    fn remove_editor_autosave(&self) {
        self.autosave.take();
        self.store
            .dispatch(EditorAction::SetSceneRecoveryPending(false));
        let _ = fs::remove_file(self.autosave_path());
    }

    pub(super) fn log(&self, message: &str, severity: EditorConsoleSeverity, detail: String) {
        self.store.dispatch(EditorAction::AppendConsoleMessage {
            message: message.into(),
            severity,
            detail: Some(detail),
            target: None,
            next_step: None,
        });
    }
}

pub(super) fn write_manifest(
    path: &Path,
    manifest: &EditorSceneManifest,
) -> Result<(), ScenePersistenceError> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let text = to_sorted_pretty(manifest)?;
    AtomicFile::write(text.as_bytes(), path, Access::Inherit)?;
    Ok(())
}

pub(super) fn read_manifest(path: &Path) -> Result<EditorSceneManifest, ScenePersistenceError> {
    Ok(serde_json::from_slice(&fs::read(path)?)?)
}

fn modification_date(path: &Path) -> Option<SystemTime> {
    fs::metadata(path).ok()?.modified().ok()
}

fn quarantine(path: &Path, label: &str) -> String {
    let quarantine = path.with_extension(format!(
        "corrupt-{}.json",
        diffuse_kernel::codable::new_uuid()
    ));
    match fs::rename(path, &quarantine) {
        Ok(()) => format!(
            "The unreadable {label} was moved to {}.",
            quarantine.file_name().unwrap_or_default().to_string_lossy()
        ),
        Err(error) if error.kind() == io::ErrorKind::NotFound && !path.exists() => {
            format!("The {label} was already absent.")
        }
        Err(error) => format!(
            "The unreadable {label} was preserved at {} because quarantine failed: {error}",
            path.display()
        ),
    }
}

impl EditorApplication {
    pub(crate) fn scene_persistence(&self) -> &EditorScenePersistence {
        self.scene_persistence.get_or_init(|| {
            EditorScenePersistence::new(
                self.project_directory.clone().into(),
                self.scene.clone(),
                Rc::clone(&self.store),
            )
        })
    }

    pub fn has_unsaved_scene_changes(&self) -> bool {
        self.store.scene_dirty()
    }

    pub fn save_scene_manifest(&self) -> Option<PathBuf> {
        self.scene_persistence()
            .save_scene_manifest(self.mesh_editing.get().map(Rc::as_ref))
    }

    pub fn authored_scene_manifest(&self) -> (EditorSceneManifest, bool) {
        self.scene_persistence().authored_scene_manifest()
    }

    pub fn open_scene_manifest(&self) -> Option<EditorSceneManifest> {
        self.open_scene_manifest_at(&self.scene_persistence().scene_manifest_path())
    }

    pub fn open_scene_manifest_at(&self, path: &Path) -> Option<EditorSceneManifest> {
        self.scene_persistence()
            .open_scene_manifest(path, true, true, |manifest| {
                self.replace_persisted_scene(manifest)
            })
    }

    pub fn restore_project_scene_at_launch(&self) -> Option<EditorSceneManifest> {
        self.scene_persistence()
            .restore_project_scene_at_launch(|manifest| self.replace_persisted_scene(manifest))
    }

    pub fn autosave_scene_if_needed(&self, elapsed: f64, force: bool) {
        self.scene_persistence()
            .autosave_scene_if_needed(elapsed, force);
    }

    pub fn discard_autosaved_scene(&self) {
        self.scene_persistence().discard_autosaved_scene();
    }

    fn replace_persisted_scene(
        &self,
        manifest: &EditorSceneManifest,
    ) -> Result<EditorSceneManifestLoadResult, ScenePersistenceError> {
        let result = self.load_persisted_scene(manifest)?;
        self.store
            .dispatch(EditorAction::SetPendingConfirmationRequest(None));
        self.store.dispatch(EditorAction::BeginSceneDocument);
        self.reload_scripts_after_scene_replacement();
        Ok(result)
    }

    pub(super) fn load_persisted_scene(
        &self,
        manifest: &EditorSceneManifest,
    ) -> Result<EditorSceneManifestLoadResult, ScenePersistenceError> {
        if manifest.schema_version != EditorSceneManifest::CURRENT_SCHEMA_VERSION {
            return Err(
                EditorSceneManifestLoadError::UnsupportedVersion(manifest.schema_version).into(),
            );
        }
        if let Some(mesh) = self.mesh_editing.get() {
            mesh.leave();
        }
        if let Some(authoring) = self.geometry_authoring.get() {
            authoring.cancel_interactive_edit();
        }
        let result = self.scene_persistence().load_scene(manifest)?;
        self.request_display_refresh();
        Ok(result)
    }
}
