//! `Editor/Sources/EditorCore/Application/Assets/AssetWorkflow.swift`.
//!
//! Asset references, missing-file auditing, relocation and repair. All three
//! mutating paths require a stopped simulation because they change the catalog
//! the running scene resolves through.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use diffuse_assets::asset_registry::AssetRegistry;

use crate::application::editor_application::EditorApplication;
use crate::assets::asset_catalog::{EditorAsset, EditorAssetCatalog};
use crate::assets::asset_import_resolver::AssetImportResolver;
use crate::assets::editor_asset_file_workflow::{AssetFileWorkflowError, EditorAssetFileWorkflow};
use crate::state::editor_reducer::EditorAction;
use crate::state::editor_state::{EditorConsoleSeverity, PlaybackState};
use crate::state::workspace::editor_workbench_state::EditorIssueTarget;

/// One place an asset is referenced from, shown in the asset browser's
/// reference list.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EditorAssetReferenceLocation {
    pub id: String,
    pub label: String,
    pub target: EditorIssueTarget,
}

impl EditorApplication {
    /// Entities using the asset, plus project text files that name its path.
    pub fn asset_references(&self, asset: &EditorAsset) -> Vec<EditorAssetReferenceLocation> {
        let mut locations: Vec<EditorAssetReferenceLocation> = self
            .scene
            .asset_referenced_entity_ids(&asset.id)
            .into_iter()
            .map(|id| {
                let label = self
                    .scene
                    .entity_summary(Some(id))
                    .map(|summary| summary.name)
                    .unwrap_or_else(|| id.to_string());
                EditorAssetReferenceLocation {
                    id: format!("entity:{id}"),
                    label,
                    target: EditorIssueTarget::Entity { id },
                }
            })
            .collect();

        let root = PathBuf::from(&self.project_directory);
        let files = EditorAssetFileWorkflow::reference_files(Path::new(&asset.absolute_path), &root);
        for url in files {
            locations.push(EditorAssetReferenceLocation {
                id: url.to_string_lossy().into_owned(),
                label: EditorAssetFileWorkflow::relative_path(&url, &root),
                target: EditorIssueTarget::File {
                    path: url.to_string_lossy().into_owned(),
                },
            });
        }
        locations
    }

    /// Every source file the scene or the catalog expects that is not on disk.
    pub fn missing_asset_paths(&self) -> Vec<String> {
        let mut paths: BTreeSet<String> = self.scene.missing_asset_paths().into_iter().collect();
        let root = PathBuf::from(&self.project_directory);
        for asset in EditorAssetCatalog::entries() {
            for file in
                AssetImportResolver::resolve(Path::new(&asset.absolute_path), Some(root.as_path()))
            {
                if !file.source.exists() {
                    paths.insert(file.source.to_string_lossy().into_owned());
                }
            }
        }
        paths.into_iter().collect()
    }

    /// Moves the asset inside the project and repoints the scene at it. A
    /// catalog reload that cannot index the moved file undoes the move.
    pub fn relocate_asset(&self, asset: &EditorAsset, relative_path: &str) -> bool {
        if self.store.playback_state() != PlaybackState::Stopped {
            return false;
        }
        let root = PathBuf::from(&self.project_directory);
        let source = PathBuf::from(&asset.absolute_path);
        let destination = root.join(relative_path);
        let has_dirty_reference = self
            .workstation
            .scripts
            .snapshot()
            .documents
            .iter()
            .any(|doc| doc.is_dirty && doc.source.string_value().contains(&asset.relative_path));
        if relative_path.is_empty() || relative_path.starts_with('/') || has_dirty_reference {
            self.log_console(
                "Asset relocation blocked",
                EditorConsoleSeverity::Warning,
                None,
                Some(EditorIssueTarget::Asset { id: asset.id.clone() }),
                Some(
                    "Enter a project-relative path and save scripts referencing this asset before moving it."
                        .to_string(),
                ),
            );
            return false;
        }

        let result = (|| -> Result<EditorAsset, AssetFileWorkflowError> {
            EditorAssetFileWorkflow::relocate(&source, &destination, &root)?;
            let new_id = EditorAssetFileWorkflow::relative_path(&destination, &root);
            AssetRegistry::shared().relocate_asset_path(&asset.id, &new_id);
            let reloaded = EditorAssetCatalog::load_project_default(&self.project_directory)
                .map_err(|error| AssetFileWorkflowError::Failure(error.to_string()))
                .and_then(|assets| {
                    assets
                        .into_iter()
                        .find(|candidate| candidate.id == new_id)
                        .ok_or_else(|| {
                            AssetFileWorkflowError::Failure(
                                "The moved asset could not be indexed.".to_string(),
                            )
                        })
                });
            match reloaded {
                Ok(moved) => Ok(moved),
                Err(error) => {
                    let _ = EditorAssetFileWorkflow::relocate(&destination, &source, &root);
                    AssetRegistry::shared().relocate_asset_path(&new_id, &asset.id);
                    let _ = EditorAssetCatalog::load_project_default(&self.project_directory);
                    Err(error)
                }
            }
        })();

        match result {
            Ok(moved) => {
                self.scene.relocate_asset_references(&asset.id, &moved);
                self.workstation.scripts.refresh_from_disk();
                self.store
                    .dispatch(EditorAction::NavigateToAsset(Some(moved.id.clone())));
                self.store.dispatch(EditorAction::ForceUIRefresh);
                self.log_console(
                    "Asset relocated",
                    EditorConsoleSeverity::Info,
                    Some(format!(
                        "{} → {}",
                        asset.relative_path, moved.relative_path
                    )),
                    Some(EditorIssueTarget::Asset { id: moved.id.clone() }),
                    None,
                );
                true
            }
            Err(error) => {
                self.log_console(
                    "Could not relocate asset",
                    EditorConsoleSeverity::Error,
                    Some(error.to_string()),
                    Some(EditorIssueTarget::Asset { id: asset.id.clone() }),
                    Some(
                        "Check the destination, file permissions and dependencies, then retry."
                            .to_string(),
                    ),
                );
                false
            }
        }
    }

    /// Copies a replacement over a missing file, then reloads the catalog so
    /// the repaired file is indexed.
    pub fn repair_missing_asset(&self, path: &str, from: &Path) -> bool {
        if self.store.playback_state() != PlaybackState::Stopped {
            return false;
        }
        let root = PathBuf::from(&self.project_directory);
        let target = if path.starts_with('/') {
            PathBuf::from(path)
        } else {
            root.join(path)
        };
        let inner = || -> Result<(), AssetFileWorkflowError> {
            EditorAssetFileWorkflow::restore_missing(from, &target, &root, || {
                if self.reload_assets().is_some() {
                    Ok(())
                } else {
                    Err(AssetFileWorkflowError::Failure(
                        "The restored file could not be indexed. Check its dependencies."
                            .to_string(),
                    ))
                }
            })
        };
        match inner() {
            Ok(()) => {
                let relative = EditorAssetFileWorkflow::relative_path(&target, &root);
                self.log_console(
                    "Missing resource repaired",
                    EditorConsoleSeverity::Info,
                    Some(target.to_string_lossy().into_owned()),
                    Some(EditorIssueTarget::Asset { id: relative }),
                    None,
                );
                true
            }
            Err(error) => {
                self.reload_assets();
                self.log_console(
                    "Could not repair missing resource",
                    EditorConsoleSeverity::Error,
                    Some(error.to_string()),
                    Some(EditorIssueTarget::File {
                        path: target.to_string_lossy().into_owned(),
                    }),
                    Some(
                        "Select a valid file of the same format and check its dependencies."
                            .to_string(),
                    ),
                );
                false
            }
        }
    }
}
