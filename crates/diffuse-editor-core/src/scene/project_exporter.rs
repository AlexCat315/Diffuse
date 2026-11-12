//! `Editor/Sources/EditorCore/Scene/ProjectExporter.swift`.
//!
//! Writes a self-contained, platform-agnostic project export bundle. The layout
//! is exactly what `CovePlayer --project <dir>` expects to load:
//!
//! ```text
//! build.json                       descriptor / metadata
//! assets.json                      referenced asset list
//! Scripts/scripts.json             optional project script aliases and defaults
//! .cove/game-saves/slot-0.json     scene captured as a GameSaveDocument
//! <project-relative paths>         asset files and external model dependencies
//! ```
//!
//! When a player executable is supplied the bundle also contains a runnable
//! player: a macOS application bundle with embedded project data, or a portable
//! `Player/` directory on the other platforms.

use std::collections::{BTreeMap, BTreeSet};
use std::io;
use std::path::{Path, PathBuf};
use std::time::Duration;

use cove_system::atomic_file::AtomicFile;
use cove_system::files::Access;
use cove_system::paths::PathIdentity;
use cove_system::process::{ProcessCommand, ProcessLimits, ProcessSession};
use diffuse_assets::asset_registry::AssetRegistry;
use diffuse_assets::project_resource_walker;
use diffuse_assets::swift_json;
use diffuse_kernel::codable::new_uuid;
use diffuse_script::interop::component_registry_script_codec::scene_document_scripts;
use serde::{Deserialize, Serialize};

use crate::assets::asset_catalog::EditorAsset;
use crate::assets::asset_import_resolver::AssetImportResolver;
use crate::scene::game_save_document::{GameSaveDocument, GameSaveDocumentError};
use crate::scene::manifest::editor_scene_manifest::EditorSceneManifest;
use crate::scene::manifest::node::EditorSceneManifestNode;
use crate::scripting::dynamic::project_compiled_scripts::{
    ProjectCompiledScripts, ProjectCompiledScriptsError, ProjectScriptBuildConfiguration,
};
use crate::scripting::dynamic::project_script_catalog::{
    ProjectScriptCatalog, ProjectScriptCatalogError,
};

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum ProjectExporterError {
    #[error("export asset is missing: {0}")]
    MissingAsset(String),
    #[error("CovePlayer executable is missing or not executable: {0}")]
    MissingPlayerExecutable(String),
    #[error("export asset path escapes the bundle: {0}")]
    UnsafeRelativePath(String),
    #[error("multiple assets target the same export path: {0}")]
    ConflictingAssetDestination(String),
    #[error("multiple assets use export mesh index: {0}")]
    ConflictingMeshIndex(i64),
    #[error("export output cannot contain the source project: {0}")]
    OutputContainsSourceProject(String),
    #[error("Rust scripts require a cargo build configuration before exporting.")]
    MissingScriptBuildConfiguration,
    #[error("Script export is not supported for {0} yet.")]
    UnsupportedScriptExportTarget(String),
    #[error("export has unresolved script bindings: {}", .0.join(", "))]
    UnresolvedScriptBindings(Vec<String>),
    #[error("project preset and script share an identifier: {0}")]
    ConflictingScriptIdentifier(String),
    #[error("exported Player could not load the compiled gameplay: {0}")]
    ScriptPlayerValidationFailed(String),
}

/// Failures the export pipeline can raise. Swift rethrew arbitrary errors;
/// Rust names the wrapped error so callers can match `ProjectExporterError`
/// cases exactly as the Swift tests did.
#[derive(Debug, thiserror::Error)]
pub enum ProjectExportError {
    #[error(transparent)]
    Exporter(#[from] ProjectExporterError),
    #[error(transparent)]
    Io(#[from] io::Error),
    #[error(transparent)]
    Encode(#[from] swift_json::SwiftJsonError),
    #[error(transparent)]
    Decode(#[from] serde_json::Error),
    #[error(transparent)]
    Save(#[from] GameSaveDocumentError),
    #[error(transparent)]
    Catalog(#[from] ProjectScriptCatalogError),
    #[error(transparent)]
    Scripts(#[from] ProjectCompiledScriptsError),
    #[error(transparent)]
    Walker(#[from] project_resource_walker::ProjectResourceWalkerError),
}

/// Metadata describing a portable project export bundle.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectExportDescriptor {
    pub schema_version: i64,
    pub app_name: String,
    pub exported_at: String,
    pub entity_count: i64,
    pub asset_count: i64,
    /// Save slot the scene was written to — the slot CovePlayer's project
    /// loader reads.
    pub scene_slot: i64,
}

impl ProjectExportDescriptor {
    pub fn new(
        schema_version: i64,
        app_name: String,
        exported_at: String,
        entity_count: i64,
        asset_count: i64,
        scene_slot: i64,
    ) -> Self {
        ProjectExportDescriptor {
            schema_version,
            app_name,
            exported_at,
            entity_count,
            asset_count,
            scene_slot,
        }
    }
}

/// A referenced asset recorded in the export (paths stay project-relative).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectExportAsset {
    pub id: String,
    pub name: String,
    pub relative_path: String,
    pub kind: String,
    pub mesh_index: i64,
}

impl ProjectExportAsset {
    pub fn new(
        id: String,
        name: String,
        relative_path: String,
        kind: String,
        mesh_index: i64,
    ) -> Self {
        ProjectExportAsset {
            id,
            name,
            relative_path,
            kind,
            mesh_index,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProjectExportAssetList {
    pub assets: Vec<ProjectExportAsset>,
}

impl ProjectExportAssetList {
    pub fn new(assets: Vec<ProjectExportAsset>) -> Self {
        ProjectExportAssetList { assets }
    }
}

pub struct ProjectExporter;

impl ProjectExporter {
    pub const SCHEMA_VERSION: i64 = 1;
    pub const SCENE_SLOT: i64 = 0;

    const AUDIO_EXTENSIONS: [&'static str; 7] = ["wav", "mp3", "m4a", "aiff", "aif", "caf", "ogg"];
    const EXCLUDED_RESOURCE_DIRECTORIES: [&'static str; 7] = [
        ".git",
        ".cove",
        ".build",
        "build",
        "export",
        "node_modules",
        ".gradle",
    ];

    #[allow(clippy::too_many_arguments)]
    pub fn export(
        manifest: &EditorSceneManifest,
        app_name: &str,
        assets: &[EditorAsset],
        source_project_directory: Option<&Path>,
        player_executable_url: Option<&Path>,
        script_build_configuration: Option<&ProjectScriptBuildConfiguration>,
        to: &Path,
    ) -> Result<ProjectExportDescriptor, ProjectExportError> {
        let assets = Self::validated_assets(assets)?;
        let output_url = PathIdentity::canonical_url(to);
        if let Some(source_project_directory) = source_project_directory {
            let source_url = PathIdentity::canonical_url(source_project_directory);
            if PathIdentity::contains(&source_url, &output_url, true) {
                return Err(ProjectExporterError::OutputContainsSourceProject(
                    to.to_string_lossy().into_owned(),
                )
                .into());
            }
        }
        let parent_directory = output_url
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_else(|| PathBuf::from("."));
        std::fs::create_dir_all(&parent_directory)?;
        let output_name = output_url
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::InvalidInput,
                    format!("export output has no file name: {}", to.display()),
                )
            })?;
        let staging_directory =
            parent_directory.join(format!(".{output_name}.staging-{}", new_uuid()));
        let staging_guard = StagingDirectory::new(staging_directory.clone());
        std::fs::create_dir_all(&staging_directory)?;

        // Scene → GameSaveDocument at slot 0: the exact format GameApplication loads.
        let save = GameSaveDocument::new(Self::SCENE_SLOT, manifest.clone());
        save.write(&GameSaveDocument::url(Self::SCENE_SLOT, &staging_directory))?;

        Self::copy_assets(&assets, source_project_directory, &staging_directory)?;
        let mut available_script_identifiers: BTreeSet<String> = ProjectScriptCatalog::built_in()
            .entries
            .iter()
            .map(|entry| entry.identifier.clone())
            .collect();
        let mut has_compiled_scripts = false;
        if let Some(source_project_directory) = source_project_directory {
            available_script_identifiers = ProjectScriptCatalog::load(source_project_directory)?
                .entries
                .iter()
                .map(|entry| entry.identifier.clone())
                .collect();
            Self::copy_audio_resources(
                source_project_directory,
                &staging_directory,
                &[to, staging_directory.as_path()],
            )?;
            Self::copy_project_script_catalog(source_project_directory, &staging_directory)?;
            let compiled_identifiers = ProjectCompiledScripts::build(
                source_project_directory,
                script_build_configuration,
                &staging_directory,
            )?;
            if let Some(conflict) = compiled_identifiers
                .intersection(&available_script_identifiers)
                .next()
            {
                return Err(
                    ProjectExporterError::ConflictingScriptIdentifier(conflict.clone()).into(),
                );
            }
            available_script_identifiers.extend(compiled_identifiers.iter().cloned());
            has_compiled_scripts = !compiled_identifiers.is_empty();
        }
        let mut unresolved_bindings: Vec<String> = Vec::new();
        Self::validate_scripts(
            &manifest.roots,
            &available_script_identifiers,
            &mut unresolved_bindings,
        );
        if !unresolved_bindings.is_empty() {
            return Err(ProjectExporterError::UnresolvedScriptBindings(unresolved_bindings).into());
        }

        let asset_list = ProjectExportAssetList::new(
            assets
                .iter()
                .map(|asset| {
                    ProjectExportAsset::new(
                        asset.id.clone(),
                        asset.name.clone(),
                        asset.relative_path.clone(),
                        asset.kind.raw_value().to_string(),
                        asset.mesh_index,
                    )
                })
                .collect(),
        );
        Self::write_json(&asset_list, &staging_directory.join("assets.json"))?;

        let descriptor = ProjectExportDescriptor::new(
            Self::SCHEMA_VERSION,
            app_name.to_string(),
            iso8601_now(),
            manifest.entity_count,
            assets.len() as i64,
            Self::SCENE_SLOT,
        );
        Self::write_json(&descriptor, &staging_directory.join("build.json"))?;
        if let Some(player_executable_url) = player_executable_url {
            #[cfg(target_os = "macos")]
            Self::create_application_bundle(app_name, player_executable_url, &staging_directory)?;
            #[cfg(not(target_os = "macos"))]
            Self::create_portable_player_bundle(player_executable_url, &staging_directory)?;
            if has_compiled_scripts {
                Self::validate_compiled_player(app_name, &staging_directory)?;
            }
        }
        Self::replace_bundle(&output_url, &staging_directory)?;
        drop(staging_guard);
        Ok(descriptor)
    }

    /// Catch missing host symbols/toolchain mismatches before replacing a working
    /// export. This loads the game with zero simulation frames and opens no window.
    fn validate_compiled_player(
        app_name: &str,
        project_directory: &Path,
    ) -> Result<(), ProjectExportError> {
        let executable = Self::runnable_executable_url(app_name, project_directory);
        let mut command = ProcessCommand::new(&executable)?;
        command.directory = project_directory.to_path_buf();
        command.arguments = vec![
            "--validate-project".into(),
            "--project".into(),
            project_directory.as_os_str().to_os_string(),
        ];
        let limits = ProcessLimits {
            // Swift waited without a bound; the session needs a finite one.
            timeout: Duration::from_secs(600),
            ..ProcessLimits::default()
        };
        let output = ProcessSession::spawn(&command, limits)?.collect()?;
        let mut report = String::from_utf8_lossy(&output.stdout).into_owned();
        report.push_str(&String::from_utf8_lossy(&output.stderr));
        if output.code != 0 || !report.contains("CovePlayer project validation passed") {
            return Err(
                ProjectExporterError::ScriptPlayerValidationFailed(tail(&report, 8192)).into(),
            );
        }
        Ok(())
    }

    /// Reads back a previously written descriptor (used to validate or inspect a bundle).
    pub fn read_descriptor(from: &Path) -> Result<ProjectExportDescriptor, ProjectExportError> {
        let data = std::fs::read(from.join("build.json"))?;
        Ok(serde_json::from_slice(&data)?)
    }

    pub fn application_bundle_url(app_name: &str, in_output_directory: &Path) -> PathBuf {
        in_output_directory.join(format!("{}.app", safe_application_name(app_name)))
    }

    pub fn application_executable_url(app_name: &str, in_output_directory: &Path) -> PathBuf {
        Self::application_bundle_url(app_name, in_output_directory)
            .join("Contents")
            .join("MacOS")
            .join(safe_application_name(app_name))
    }

    /// Executable produced for the host platform by an export with a player.
    pub fn runnable_executable_url(app_name: &str, in_output_directory: &Path) -> PathBuf {
        #[cfg(target_os = "macos")]
        {
            Self::application_executable_url(app_name, in_output_directory)
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = app_name;
            Self::portable_player_executable_url(in_output_directory)
        }
    }

    pub(crate) fn portable_player_executable_url(in_output_directory: &Path) -> PathBuf {
        in_output_directory
            .join("Player")
            .join(player_executable_name())
    }

    fn write_json<T: Serialize>(value: &T, url: &Path) -> Result<(), ProjectExportError> {
        let text = swift_json::to_sorted_pretty(value)?;
        AtomicFile::write(text.as_bytes(), url, Access::Inherit)?;
        Ok(())
    }

    fn validated_assets(assets: &[EditorAsset]) -> Result<Vec<EditorAsset>, ProjectExporterError> {
        let mut relative_paths: BTreeSet<String> = BTreeSet::new();
        let mut mesh_indices: BTreeSet<i64> = BTreeSet::new();
        let mut validated = Vec::with_capacity(assets.len());
        for asset in assets {
            let relative_path = AssetImportResolver::sanitized_relative_path(&asset.relative_path)
                .ok_or_else(|| {
                    ProjectExporterError::UnsafeRelativePath(asset.relative_path.clone())
                })?;
            if !relative_paths.insert(relative_path.clone()) {
                return Err(ProjectExporterError::ConflictingAssetDestination(
                    relative_path,
                ));
            }
            if asset.mesh_index >= AssetRegistry::IMPORTED_MESH_START_INDEX
                && !mesh_indices.insert(asset.mesh_index)
            {
                return Err(ProjectExporterError::ConflictingMeshIndex(asset.mesh_index));
            }
            validated.push(EditorAsset {
                relative_path,
                ..asset.clone()
            });
        }
        Ok(validated)
    }

    #[cfg(target_os = "macos")]
    fn create_application_bundle(
        app_name: &str,
        player_executable_url: &Path,
        project_directory: &Path,
    ) -> Result<(), ProjectExportError> {
        if !is_executable_file(player_executable_url) {
            return Err(ProjectExporterError::MissingPlayerExecutable(
                player_executable_url.to_string_lossy().into_owned(),
            )
            .into());
        }

        // Capture the portable project entries before creating the app inside
        // that same staging directory, avoiding recursive self-copy.
        let project_entries = directory_entries(project_directory, false)?;
        let safe_name = safe_application_name(app_name);
        let app_url = Self::application_bundle_url(app_name, project_directory);
        let contents_url = app_url.join("Contents");
        let macos_url = contents_url.join("MacOS");
        let resources_url = contents_url.join("Resources");
        let bundled_project_url = resources_url.join("CoveProject");
        std::fs::create_dir_all(&macos_url)?;
        std::fs::create_dir_all(&bundled_project_url)?;

        let executable_url = macos_url.join(&safe_name);
        copy_item(player_executable_url, &executable_url)?;
        set_posix_permissions_755(&executable_url)?;

        // Keep resources in the standard signed-app location. Runtime resource
        // lookup supports this layout as well as the adjacent dev layout.
        let player_directory = player_executable_url
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_default();
        for resource in directory_entries(&player_directory, true)? {
            let extension = extension_lower(&resource);
            if extension == "bundle" || extension == "resources" {
                let name = resource
                    .file_name()
                    .map(|name| name.to_os_string())
                    .unwrap_or_default();
                copy_item(&resource, &resources_url.join(name))?;
            } else if extension == "dylib" {
                let name = resource
                    .file_name()
                    .map(|name| name.to_os_string())
                    .unwrap_or_default();
                copy_item(&resource, &macos_url.join(name))?;
            }
        }

        for entry in project_entries {
            if let Some(name) = entry.file_name() {
                copy_item(&entry, &bundled_project_url.join(name))?;
            }
        }

        let identifier = format!("com.cove.export.{}", bundle_identifier_suffix(&safe_name));
        let info = [
            ("CFBundleDisplayName", plist_string(app_name)),
            ("CFBundleExecutable", plist_string(&safe_name)),
            ("CFBundleIdentifier", plist_string(&identifier)),
            ("CFBundleInfoDictionaryVersion", plist_string("6.0")),
            ("CFBundleName", plist_string(app_name)),
            ("CFBundlePackageType", plist_string("APPL")),
            ("CFBundleShortVersionString", plist_string("1.0")),
            ("CFBundleVersion", plist_string("1")),
            ("LSMinimumSystemVersion", plist_string("26.0")),
            ("NSHighResolutionCapable", "<true/>".to_string()),
        ];
        let plist = write_plist(&info);
        AtomicFile::write(
            plist.as_bytes(),
            &contents_url.join("Info.plist"),
            Access::Inherit,
        )?;
        Ok(())
    }

    /// Creates the non-macOS runnable layout. Kept independent of host
    /// selection so the layout can be regression-tested on macOS too.
    #[cfg(not(target_os = "macos"))]
    pub(crate) fn create_portable_player_bundle(
        player_executable_url: &Path,
        project_directory: &Path,
    ) -> Result<(), ProjectExportError> {
        if !is_executable_file(player_executable_url) {
            return Err(ProjectExporterError::MissingPlayerExecutable(
                player_executable_url.to_string_lossy().into_owned(),
            )
            .into());
        }
        let player_directory = project_directory.join("Player");
        std::fs::create_dir_all(&player_directory)?;
        let executable_url = Self::portable_player_executable_url(project_directory);
        copy_item(player_executable_url, &executable_url)?;
        set_posix_permissions_755(&executable_url)?;

        let source_directory = player_executable_url
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_default();
        for sibling in directory_entries(&source_directory, true)? {
            if sibling == player_executable_url {
                continue;
            }
            let metadata = std::fs::symlink_metadata(&sibling)?;
            let extension = extension_lower(&sibling);
            let name_is_lib = sibling
                .file_name()
                .map(|name| name == "Lib")
                .unwrap_or(false);
            let copy_directory = metadata.is_dir()
                && (extension == "bundle" || extension == "resources" || name_is_lib);
            let copy_library =
                metadata.is_file() && matches!(extension.as_str(), "dll" | "so" | "dylib");
            if !copy_directory && !copy_library {
                continue;
            }
            let name = sibling
                .file_name()
                .map(|name| name.to_os_string())
                .unwrap_or_default();
            copy_item(&sibling, &player_directory.join(name))?;
        }
        Ok(())
    }

    fn copy_assets(
        assets: &[EditorAsset],
        project_root: Option<&Path>,
        output_directory: &Path,
    ) -> Result<(), ProjectExportError> {
        let mut copied_destinations: BTreeMap<PathBuf, PathBuf> = BTreeMap::new();
        for asset in assets {
            let source = PathBuf::from(&asset.absolute_path);
            let destination_parent = parent_directory(&asset.relative_path);
            for file in AssetImportResolver::resolve(&source, project_root) {
                if !file.source.exists() {
                    return Err(ProjectExporterError::MissingAsset(
                        file.source.to_string_lossy().into_owned(),
                    )
                    .into());
                }
                let relative_path = if destination_parent.is_empty() || destination_parent == "." {
                    file.relative_path.clone()
                } else {
                    format!("{destination_parent}/{}", file.relative_path)
                };
                let destination = Self::safe_destination(&relative_path, output_directory)?;
                let source_path = PathIdentity::canonical_url(&file.source);
                if let Some(existing_source) = copied_destinations.get(&destination) {
                    if *existing_source != source_path {
                        return Err(ProjectExporterError::ConflictingAssetDestination(
                            relative_path,
                        )
                        .into());
                    }
                    continue;
                }
                copied_destinations.insert(destination.clone(), source_path);
                if let Some(parent) = destination.parent() {
                    std::fs::create_dir_all(parent)?;
                }
                std::fs::copy(&file.source, &destination)?;
            }
        }
        Ok(())
    }

    fn copy_audio_resources(
        source_directory: &Path,
        output_directory: &Path,
        excluding_directories: &[&Path],
    ) -> Result<(), ProjectExportError> {
        let source_root = PathIdentity::canonical_url(source_directory);
        let excluded_urls: Vec<PathBuf> = excluding_directories
            .iter()
            .map(|url| PathIdentity::canonical_url(url))
            .collect();
        let files = project_resource_walker::files(&source_root, false, |directory| {
            let name = directory
                .file_name()
                .map(|name| name.to_string_lossy().to_lowercase())
                .unwrap_or_default();
            Self::EXCLUDED_RESOURCE_DIRECTORIES.contains(&name.as_str())
                || excluded_urls
                    .iter()
                    .any(|root| PathIdentity::contains(directory, root, true))
        })?;
        for source in files {
            if !Self::AUDIO_EXTENSIONS.contains(&extension_lower(&source).as_str()) {
                continue;
            }
            let resolved_source = PathIdentity::canonical_url(&source);
            if !PathIdentity::contains(&resolved_source, &source_root, false) {
                continue;
            }
            let relative_path = PathIdentity::relative_path(&resolved_source, &source_root);
            if relative_path.is_empty() {
                continue;
            }
            let destination = Self::safe_destination(&relative_path, output_directory)?;
            if let Some(parent) = destination.parent() {
                std::fs::create_dir_all(parent)?;
            }
            if !destination.exists() {
                std::fs::copy(&source, &destination)?;
            }
        }
        Ok(())
    }

    fn copy_project_script_catalog(
        source_directory: &Path,
        output_directory: &Path,
    ) -> Result<(), ProjectExportError> {
        let source = source_directory.join(ProjectScriptCatalog::RELATIVE_PATH);
        if !source.exists() {
            return Ok(());
        }
        let destination =
            Self::safe_destination(ProjectScriptCatalog::RELATIVE_PATH, output_directory)?;
        if let Some(parent) = destination.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::copy(&source, &destination)?;
        Ok(())
    }

    fn safe_destination(relative_path: &str, root: &Path) -> Result<PathBuf, ProjectExporterError> {
        let standardized_root = PathIdentity::canonical_url(root);
        let destination = PathIdentity::canonical_url(&standardized_root.join(relative_path));
        if destination == standardized_root
            || !PathIdentity::contains(&destination, &standardized_root, false)
        {
            return Err(ProjectExporterError::UnsafeRelativePath(
                relative_path.to_string(),
            ));
        }
        Ok(destination)
    }

    fn validate_scripts(
        nodes: &[EditorSceneManifestNode],
        available_identifiers: &BTreeSet<String>,
        unresolved_bindings: &mut Vec<String>,
    ) {
        for node in nodes {
            if let Some(bindings) = scene_document_scripts(&node.components) {
                for binding in bindings.iter().filter(|binding| binding.is_enabled) {
                    let identifier = binding.identifier.as_deref();
                    match identifier {
                        Some(identifier) if available_identifiers.contains(identifier) => {}
                        other => unresolved_bindings.push(format!(
                            "{}: {}",
                            node.name,
                            other.unwrap_or("<no identifier>")
                        )),
                    }
                }
            }
            Self::validate_scripts(&node.children, available_identifiers, unresolved_bindings);
        }
    }

    fn replace_bundle(
        output_directory: &Path,
        staging_directory: &Path,
    ) -> Result<(), ProjectExportError> {
        let parent_directory = output_directory
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_else(|| PathBuf::from("."));
        let output_name = output_directory
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_default();
        let backup_directory =
            parent_directory.join(format!(".{output_name}.backup-{}", new_uuid()));
        let had_existing_bundle = output_directory.exists();
        if had_existing_bundle {
            move_item(output_directory, &backup_directory)?;
        }
        match move_item(staging_directory, output_directory) {
            Ok(()) => {
                if had_existing_bundle {
                    let _ = remove_item(&backup_directory);
                }
                Ok(())
            }
            Err(error) => {
                if had_existing_bundle && !output_directory.exists() {
                    let _ = move_item(&backup_directory, output_directory);
                }
                Err(error.into())
            }
        }
    }
}

/// `defer { try? FileManager.default.removeItem(at: stagingDirectory) }`.
struct StagingDirectory {
    url: PathBuf,
}

impl StagingDirectory {
    fn new(url: PathBuf) -> Self {
        StagingDirectory { url }
    }
}

impl Drop for StagingDirectory {
    fn drop(&mut self) {
        let _ = remove_item(&self.url);
    }
}

fn iso8601_now() -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_secs_f64())
        .unwrap_or(0.0);
    cove_logging::iso8601(now.floor()).replace(".000Z", "Z")
}

fn player_executable_name() -> &'static str {
    if cfg!(windows) {
        "CovePlayer.exe"
    } else {
        "CovePlayer"
    }
}

fn safe_application_name(app_name: &str) -> String {
    let sanitized: String = app_name
        .chars()
        .map(|character| {
            if character.is_alphanumeric() || matches!(character, ' ' | '\t' | '-' | '_' | '.') {
                character
            } else {
                '_'
            }
        })
        .collect();
    let trimmed = sanitized.trim().to_string();
    if trimmed.is_empty() {
        "Cove Game".to_string()
    } else {
        trimmed
    }
}

#[cfg(target_os = "macos")]
fn bundle_identifier_suffix(value: &str) -> String {
    let mapped: String = value
        .to_lowercase()
        .chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() {
                character
            } else {
                '-'
            }
        })
        .collect();
    let components: Vec<&str> = mapped
        .split('-')
        .filter(|component| !component.is_empty())
        .collect();
    if components.is_empty() {
        "game".to_string()
    } else {
        components.join("-")
    }
}

fn extension_lower(url: &Path) -> String {
    url.extension()
        .map(|extension| extension.to_string_lossy().to_lowercase())
        .unwrap_or_default()
}

fn parent_directory(relative_path: &str) -> String {
    match relative_path.rfind('/') {
        Some(0) => "/".to_string(),
        Some(index) => relative_path[..index].to_string(),
        None => String::new(),
    }
}

/// Listed directory entries, sorted by name for deterministic bundles.
fn directory_entries(directory: &Path, skip_hidden: bool) -> io::Result<Vec<PathBuf>> {
    let mut entries: Vec<PathBuf> = std::fs::read_dir(directory)?
        .collect::<Result<Vec<_>, _>>()?
        .into_iter()
        .map(|entry| entry.path())
        .filter(|path| {
            if !skip_hidden {
                return true;
            }
            path.file_name()
                .map(|name| !name.to_string_lossy().starts_with('.'))
                .unwrap_or(true)
        })
        .collect();
    entries.sort();
    Ok(entries)
}

fn is_executable_file(url: &Path) -> bool {
    let Ok(metadata) = std::fs::metadata(url) else {
        return false;
    };
    if !metadata.is_file() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        metadata.permissions().mode() & 0o111 != 0
    }
    #[cfg(not(unix))]
    {
        // Foundation on Windows reports a regular file as executable.
        true
    }
}

#[cfg(unix)]
fn set_posix_permissions_755(url: &Path) -> io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(url, std::fs::Permissions::from_mode(0o755))
}

#[cfg(not(unix))]
fn set_posix_permissions_755(_url: &Path) -> io::Result<()> {
    Ok(())
}

fn copy_item(source: &Path, destination: &Path) -> io::Result<()> {
    let metadata = std::fs::symlink_metadata(source)?;
    if metadata.is_dir() {
        std::fs::create_dir_all(destination)?;
        for entry in directory_entries(source, false)? {
            let Some(name) = entry.file_name() else {
                continue;
            };
            copy_item(&entry, &destination.join(name))?;
        }
        return Ok(());
    }
    if let Some(parent) = destination.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::copy(source, destination).map(|_| ())
}

/// `FileManager.moveItem`, which also moves across volumes.
fn move_item(source: &Path, destination: &Path) -> io::Result<()> {
    match std::fs::rename(source, destination) {
        Ok(()) => Ok(()),
        Err(_) => {
            copy_item(source, destination)?;
            remove_item(source)
        }
    }
}

fn remove_item(url: &Path) -> io::Result<()> {
    match std::fs::symlink_metadata(url) {
        Ok(metadata) if metadata.is_dir() => std::fs::remove_dir_all(url),
        Ok(_) => std::fs::remove_file(url),
        Err(error) => Err(error),
    }
}

/// Swift's `String(report.suffix(8192))`.
fn tail(text: &str, limit: usize) -> String {
    let characters: Vec<char> = text.chars().collect();
    if characters.len() <= limit {
        return text.to_string();
    }
    characters[characters.len() - limit..].iter().collect()
}

#[cfg(target_os = "macos")]
fn plist_string(value: &str) -> String {
    let mut escaped = String::with_capacity(value.len() + 16);
    escaped.push_str("<string>");
    for character in value.chars() {
        match character {
            '&' => escaped.push_str("&amp;"),
            '<' => escaped.push_str("&lt;"),
            '>' => escaped.push_str("&gt;"),
            other => escaped.push(other),
        }
    }
    escaped.push_str("</string>");
    escaped
}

/// `PropertyListSerialization.data(fromPropertyList:format:.xml)`: keys sorted
/// so the generated bundle does not depend on hash order.
#[cfg(target_os = "macos")]
fn write_plist(entries: &[(&str, String)]) -> String {
    let mut sorted: Vec<(&str, &String)> =
        entries.iter().map(|(key, value)| (*key, value)).collect();
    sorted.sort_by(|left, right| left.0.cmp(right.0));
    let mut text = String::from(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\
         <!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n\
         <plist version=\"1.0\">\n<dict>\n",
    );
    for (key, value) in sorted {
        text.push_str(&format!("\t<key>{key}</key>\n\t{value}\n"));
    }
    text.push_str("</dict>\n</plist>\n");
    text
}
