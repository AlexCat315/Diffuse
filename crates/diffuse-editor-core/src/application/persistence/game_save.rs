//! `Editor/Sources/EditorCore/Application/Persistence/GameSave.swift`.

use std::fs;
use std::io;
use std::path::PathBuf;

use diffuse_scene::scene_runtime::SceneRuntime;

use crate::application::editor_application::EditorApplication;
use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
use crate::scene::game_save_document::GameSaveDocument;
use crate::state::editor_state::EditorConsoleSeverity;

use super::scene_persistence::{EditorScenePersistence, read_manifest, write_manifest};

impl EditorScenePersistence {
    pub(crate) fn physics_play_snapshot_path(&self) -> PathBuf {
        self.project().join(".cove/physics-play-snapshot.json")
    }

    pub(super) fn persist_physics_play_snapshot(&self) {
        let manifest = self.play_snapshot.borrow().as_ref().map(|snapshot| {
            Self::manifest_for_snapshot(snapshot.scene.clone(), self.store.selected_entity_id())
        });
        if let Some(manifest) = manifest
            && let Err(error) = write_manifest(&self.physics_play_snapshot_path(), &manifest)
        {
            self.log(
                "Failed to persist physics play snapshot",
                EditorConsoleSeverity::Warning,
                error.to_string(),
            );
        }
    }

    pub(super) fn load_persisted_physics_play_snapshot(&self) -> Option<SceneRuntime> {
        let result = read_manifest(&self.physics_play_snapshot_path()).and_then(|manifest| {
            let adapter = EditorSceneAdapter::with_defaults(false);
            let loaded = adapter.load_with_notify(&manifest, false);
            if let Some(error) = loaded.error {
                return Err(error.into());
            }
            Ok(adapter.scene())
        });
        match result {
            Ok(scene) => {
                self.store.dispatch(
                    crate::state::editor_reducer::EditorAction::AppendConsoleMessage {
                        message: "Restored physics play snapshot from disk (crash recovery)".into(),
                        severity: EditorConsoleSeverity::Warning,
                        detail: None,
                        target: None,
                        next_step: None,
                    },
                );
                Some(scene)
            }
            Err(super::scene_persistence::ScenePersistenceError::Io(error))
                if error.kind() == io::ErrorKind::NotFound =>
            {
                None
            }
            Err(error) => {
                self.log(
                    "Failed to load persisted physics play snapshot",
                    EditorConsoleSeverity::Warning,
                    error.to_string(),
                );
                None
            }
        }
    }

    pub(crate) fn delete_persisted_physics_play_snapshot(&self) {
        let _ = fs::remove_file(self.physics_play_snapshot_path());
    }
}

impl EditorApplication {
    pub fn save_game_state(&self, slot: i64) -> Option<PathBuf> {
        let persistence = self.scene_persistence();
        let path = GameSaveDocument::url(slot, persistence.project());
        let manifest = self
            .scene
            .manifest_for_selection(self.store.selected_entity_id());
        if let Err(error) = GameSaveDocument::new(slot, manifest).write(&path) {
            persistence.log(
                "Failed to save game state",
                EditorConsoleSeverity::Error,
                error.to_string(),
            );
            return None;
        }
        persistence.log(
            "Game state saved",
            EditorConsoleSeverity::Info,
            format!(
                "slot {slot} → {}",
                path.file_name().unwrap_or_default().to_string_lossy()
            ),
        );
        Some(path)
    }

    pub fn load_game_state(&self, slot: i64) -> bool {
        let persistence = self.scene_persistence();
        let path = GameSaveDocument::url(slot, persistence.project());
        let result = (|| {
            let Some(document) = GameSaveDocument::read(&path)? else {
                return Ok(None);
            };
            let result = self.load_persisted_scene(&document.manifest)?;
            self.reload_scripts_after_scene_replacement();
            persistence.publish_selection(&result);
            Ok::<_, super::scene_persistence::ScenePersistenceError>(Some(format!(
                "slot {slot}, {} entities, saved {}",
                result.entity_count, document.saved_at,
            )))
        })();
        match result {
            Ok(Some(detail)) => {
                persistence.log("Game state loaded", EditorConsoleSeverity::Info, detail);
                true
            }
            Ok(None) => {
                persistence.log(
                    "No game save found",
                    EditorConsoleSeverity::Warning,
                    format!("slot {slot}"),
                );
                false
            }
            Err(error) => {
                persistence.log(
                    "Failed to load game state",
                    EditorConsoleSeverity::Error,
                    error.to_string(),
                );
                false
            }
        }
    }
}
