//! `Editor/Sources/EditorCore/Projects/EditorProjectLifecycle.swift`.
//!
//! Project creation, adoption, validation and recoverable deletion. Every
//! creation writes into a staging folder and renames it only after validation,
//! so a failure never leaves a half-project behind.

use std::fmt;
use std::io;
use std::path::{Path, PathBuf};

use diffuse_assets::swift_json;
use serde::{Deserialize, Serialize};

use crate::editor_core_resource_bundle::EditorCoreResourceBundle;
use crate::localization::localized;
use crate::scene::manifest::editor_scene_manifest::EditorSceneManifest;
use crate::scene::manifest::node::EditorSceneManifestNode;

use super::editor_scratch_workspace::application_support_directory;
use super::standardized_path;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum EditorProjectTemplate {
    #[default]
    #[serde(rename = "blank")]
    Blank,
    #[serde(rename = "crystalRush")]
    CrystalRush,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EditorProjectDescriptor {
    pub schema_version: i64,
    pub id: String,
    pub name: String,
    pub template: EditorProjectTemplate,
    pub created_at: String,
}

impl EditorProjectDescriptor {
    /// `init(name:template:)` — a fresh v4 UUID and second-precision timestamp.
    pub fn new(name: impl Into<String>, template: EditorProjectTemplate) -> Self {
        EditorProjectDescriptor {
            schema_version: 1,
            id: diffuse_kernel::codable::new_uuid(),
            name: name.into(),
            template,
            created_at: iso8601_now(),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EditorProjectLocation {
    pub directory: PathBuf,
    pub descriptor: Option<EditorProjectDescriptor>,
}

impl EditorProjectLocation {
    pub fn name(&self) -> String {
        self.descriptor
            .as_ref()
            .map(|descriptor| descriptor.name.clone())
            .unwrap_or_else(|| {
                self.directory
                    .file_name()
                    .map(|name| name.to_string_lossy().into_owned())
                    .unwrap_or_default()
            })
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EditorProjectLifecycleError {
    pub message: String,
}

impl EditorProjectLifecycleError {
    fn new(message: impl Into<String>) -> Self {
        EditorProjectLifecycleError {
            message: message.into(),
        }
    }
}

impl fmt::Display for EditorProjectLifecycleError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&localized(&self.message))
    }
}

impl std::error::Error for EditorProjectLifecycleError {}

impl From<io::Error> for EditorProjectLifecycleError {
    fn from(error: io::Error) -> Self {
        EditorProjectLifecycleError::new(error.to_string())
    }
}

impl From<serde_json::Error> for EditorProjectLifecycleError {
    fn from(error: serde_json::Error) -> Self {
        EditorProjectLifecycleError::new(error.to_string())
    }
}

impl From<swift_json::SwiftJsonError> for EditorProjectLifecycleError {
    fn from(error: swift_json::SwiftJsonError) -> Self {
        EditorProjectLifecycleError::new(error.to_string())
    }
}

pub enum EditorProjectLifecycle {}

impl EditorProjectLifecycle {
    pub const DESCRIPTOR_PATH: &'static str = ".cove/project.json";
    pub const SCENE_PATH: &'static str = ".cove/editor-scene-manifest.json";

    /// Creates a new child of the chosen parent. Existing directories are never
    /// adopted or overwritten.
    pub fn create(
        name: &str,
        parent: &Path,
        template: EditorProjectTemplate,
    ) -> Result<EditorProjectLocation, EditorProjectLifecycleError> {
        let name = Self::validated_name(name)?;
        let parent = standardized_path(parent);
        let is_directory = |path: &Path| std::fs::metadata(path).is_ok_and(|meta| meta.is_dir());
        if !is_directory(&parent) {
            return Err(EditorProjectLifecycleError::new(
                "The project location must be an existing folder.",
            ));
        }
        let destination = parent.join(&name);
        if destination.exists() {
            return Err(EditorProjectLifecycleError::new(
                "A file or folder with this project name already exists.",
            ));
        }

        let staging = parent.join(format!(
            ".cove-create-{}",
            diffuse_kernel::codable::new_uuid()
        ));
        std::fs::create_dir(&staging)?;
        struct RemoveStaging(PathBuf);
        impl Drop for RemoveStaging {
            fn drop(&mut self) {
                let _ = std::fs::remove_dir_all(&self.0);
            }
        }
        let _cleanup = RemoveStaging(staging.clone());

        for folder in [".cove", "Assets", "Scripts"] {
            std::fs::create_dir(staging.join(folder))?;
        }
        let descriptor = EditorProjectDescriptor::new(&name, template);
        write_json(&descriptor, &staging.join(Self::DESCRIPTOR_PATH))?;
        match template {
            EditorProjectTemplate::Blank => {
                let scene = EditorSceneManifest::new(0, 0, Vec::new());
                write_json(&scene, &staging.join(Self::SCENE_PATH))?;
            }
            EditorProjectTemplate::CrystalRush => {
                Self::copy_template(
                    "crystal-rush.swift",
                    "txt",
                    &staging.join("Scripts/CrystalRush.swift"),
                )?;
                Self::copy_template(
                    "crystal-rush.scene",
                    "json",
                    &staging.join(Self::SCENE_PATH),
                )?;
                Self::copy_template(
                    "crystal-rush.script-assets",
                    "json",
                    &staging.join(".cove/script-assets.json"),
                )?;
                Self::copy_template("crystal-rush.readme", "txt", &staging.join("README.md"))?;
            }
        }
        // Rename only after every file has been written and validated. A
        // collision at this point also fails safely.
        let _ = Self::inspect(&staging, true)?;
        std::fs::rename(&staging, &destination)?;
        Ok(EditorProjectLocation {
            directory: destination,
            descriptor: Some(descriptor),
        })
    }

    /// Opens any folder as a project. A folder without `.cove` gains only a
    /// project descriptor; its own files are left as they are.
    pub fn adopt(directory: &Path) -> Result<EditorProjectLocation, EditorProjectLifecycleError> {
        let directory = standardized_path(directory);
        if !directory.is_dir() {
            return Err(EditorProjectLifecycleError::new(
                "The project folder no longer exists.",
            ));
        }
        let cove = directory.join(".cove");
        if !cove.exists() {
            std::fs::create_dir(&cove)?;
            let name = directory
                .file_name()
                .and_then(|name| name.to_str())
                .and_then(|name| Self::validated_name(name).ok())
                .unwrap_or_else(|| "Project".to_string());
            let descriptor = EditorProjectDescriptor::new(name, EditorProjectTemplate::Blank);
            write_json(&descriptor, &directory.join(Self::DESCRIPTOR_PATH))?;
        }
        Self::inspect(&directory, true)
    }

    /// Read-only validation before the application creates caches, history or
    /// script services. Older projects with a `.cove` directory remain
    /// supported, including empty legacy projects.
    pub fn inspect(
        directory: &Path,
        validate_scene: bool,
    ) -> Result<EditorProjectLocation, EditorProjectLifecycleError> {
        let directory = standardized_path(directory);
        if !directory.is_dir() {
            return Err(EditorProjectLifecycleError::new(
                "The project folder no longer exists.",
            ));
        }
        let cove = directory.join(".cove");
        if !cove.is_dir() {
            return Err(EditorProjectLifecycleError::new(
                "This folder is not a Cove project. Choose its project root or create a new project.",
            ));
        }
        if std::fs::symlink_metadata(&cove).is_ok_and(|meta| meta.file_type().is_symlink()) {
            return Err(EditorProjectLifecycleError::new(
                "The project's .cove folder must not be a symbolic link.",
            ));
        }

        let mut descriptor = None;
        let descriptor_url = directory.join(Self::DESCRIPTOR_PATH);
        if descriptor_url.exists() {
            let data = std::fs::read(&descriptor_url)?;
            let decoded: EditorProjectDescriptor = serde_json::from_slice(&data)?;
            if decoded.schema_version != 1 {
                return Err(EditorProjectLifecycleError::new(
                    "This project uses an unsupported project format.",
                ));
            }
            descriptor = Some(decoded);
        }

        let scene_url = directory.join(Self::SCENE_PATH);
        if validate_scene && scene_url.exists() {
            let data = std::fs::read(&scene_url)?;
            let scene: EditorSceneManifest = serde_json::from_slice(&data)?;
            if scene.schema_version != EditorSceneManifest::CURRENT_SCHEMA_VERSION {
                return Err(EditorProjectLifecycleError::new(
                    "This project uses an unsupported scene format.",
                ));
            }
            let mut ids = std::collections::BTreeSet::new();
            let mut stack: Vec<&EditorSceneManifestNode> = scene.roots.iter().collect();
            while let Some(node) = stack.pop() {
                if !ids.insert(node.id) {
                    return Err(EditorProjectLifecycleError::new(
                        "The saved scene contains duplicate entity IDs.",
                    ));
                }
                stack.extend(node.children.iter());
            }
            if ids.len() as i64 != scene.entity_count {
                return Err(EditorProjectLifecycleError::new(
                    "The saved scene has an invalid entity count.",
                ));
            }
        }

        Ok(EditorProjectLocation {
            directory,
            descriptor,
        })
    }

    /// Recoverable deletion. Never recursively delete an arbitrary recent-list
    /// path.
    pub fn move_to_trash(directory: &Path) -> Result<PathBuf, EditorProjectLifecycleError> {
        // Trash must remain available even if a managed project has a corrupt
        // scene.
        let location = Self::inspect(directory, false)?;
        let root = &location.directory;
        let mut protected = vec![standardized_path(Path::new("/"))];
        if let Some(home) = home_directory() {
            protected.push(standardized_path(&home));
        }
        protected.push(standardized_path(&std::env::temp_dir()));
        if protected.iter().any(|path| path == root) {
            return Err(EditorProjectLifecycleError::new(
                "This folder cannot be deleted as a project.",
            ));
        }
        if location.descriptor.is_none() {
            return Err(EditorProjectLifecycleError::new(
                "Legacy projects can only be removed from Recents. Manage their files in the file manager.",
            ));
        }
        let recovery = application_support_directory()
            .join("Cove")
            .join("DeletedProjects");
        Ok(cove_system::trash::FileTrash::r#move(root, &recovery)?)
    }

    pub fn validated_name(proposed: &str) -> Result<String, EditorProjectLifecycleError> {
        let name = proposed.trim();
        let invalid = name.chars().any(|character| {
            character.is_control()
                || matches!(
                    character,
                    '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|'
                )
        });
        if name.is_empty()
            || name == "."
            || name == ".."
            || name.starts_with('.')
            || name.chars().count() > 100
            || name.ends_with('.')
            || invalid
        {
            return Err(EditorProjectLifecycleError::new(
                "Enter a valid project name (no path separators or special characters).",
            ));
        }
        Ok(name.to_string())
    }

    fn copy_template(
        name: &str,
        extension: &str,
        destination: &Path,
    ) -> Result<(), EditorProjectLifecycleError> {
        let source = EditorCoreResourceBundle::bundle()
            .root()
            .join(format!("{name}.{extension}"));
        if !source.is_file() {
            return Err(EditorProjectLifecycleError::new(
                "The bundled example project is missing. Reinstall the editor.",
            ));
        }
        std::fs::copy(&source, destination)?;
        Ok(())
    }
}

fn write_json<T: Serialize + ?Sized>(
    value: &T,
    destination: &Path,
) -> Result<(), EditorProjectLifecycleError> {
    let encoded = swift_json::to_sorted_pretty(value)?;
    if let Some(parent) = destination.parent() {
        std::fs::create_dir_all(parent)?;
    }
    cove_system::files::atomic_write(
        destination,
        encoded.as_bytes(),
        cove_system::files::Access::Inherit,
    )?;
    Ok(())
}

/// `ISO8601DateFormatter().string(from: Date())`: UTC, second precision.
fn iso8601_now() -> String {
    let seconds = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_secs_f64())
        .unwrap_or_default();
    cove_logging::iso8601(seconds.floor()).replace(".000Z", "Z")
}

fn home_directory() -> Option<PathBuf> {
    #[cfg(windows)]
    {
        std::env::var_os("USERPROFILE").map(PathBuf::from)
    }
    #[cfg(not(windows))]
    {
        std::env::var_os("HOME").map(PathBuf::from)
    }
}
