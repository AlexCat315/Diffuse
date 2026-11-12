//! `Editor/Sources/EditorCore/Scripting/Dynamic/ScriptProjectTrust.swift`.
//!
//! User-owned workspace trust. The decision is deliberately stored outside the
//! project so a downloaded repository cannot mark itself as trusted.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Component, Path, PathBuf};
use std::sync::{Mutex, MutexGuard};

use cove_system::atomic_file::AtomicFile;
use cove_system::files::Access;
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ScriptProjectTrustState {
    Untrusted,
    Trusted,
}

impl ScriptProjectTrustState {
    pub fn allows_execution(self) -> bool {
        matches!(self, ScriptProjectTrustState::Trusted)
    }
}

/// Persisted as Swift `Codable` would: `version`, `trustedProjectPaths`.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct TrustDocument {
    version: i64,
    trusted_project_paths: Vec<String>,
}

const LOAD_WARNING: &str = "Script workspace trust could not be read; execution remains blocked.";

/// Swift's `Document.version` for the only format this store writes.
const DOCUMENT_VERSION: i64 = 1;

pub struct ScriptProjectTrustStore {
    storage_url: PathBuf,
    trusted_paths: Mutex<BTreeSet<String>>,
    load_warning: Option<String>,
}

impl ScriptProjectTrustStore {
    /// Swift's `init(storageURL: nil, environment: ProcessInfo.processInfo.environment)`.
    pub fn new() -> Self {
        let environment: BTreeMap<String, String> = std::env::vars().collect();
        Self::with_storage_url(default_storage_url(&environment))
    }

    /// Swift's `init(environment:)` with an explicit environment instead of
    /// `ProcessInfo.processInfo.environment`.
    pub fn with_environment(environment: &BTreeMap<String, String>) -> Self {
        Self::with_storage_url(default_storage_url(environment))
    }

    /// Swift's `init(storageURL:environment:)` with an explicit file.
    pub fn with_storage_url(storage_url: PathBuf) -> Self {
        let (trusted_paths, load_warning) = match std::fs::read(&storage_url) {
            Ok(data) => match serde_json::from_slice::<TrustDocument>(&data) {
                Ok(document) if document.version == DOCUMENT_VERSION => {
                    (document.trusted_project_paths.into_iter().collect(), None)
                }
                _ => (BTreeSet::new(), Some(LOAD_WARNING.to_string())),
            },
            Err(_) if storage_url.exists() => (BTreeSet::new(), Some(LOAD_WARNING.to_string())),
            Err(_) => (BTreeSet::new(), None),
        };
        Self {
            storage_url,
            trusted_paths: Mutex::new(trusted_paths),
            load_warning,
        }
    }

    pub fn load_warning(&self) -> Option<&str> {
        self.load_warning.as_deref()
    }

    pub fn state(&self, project_directory: &str) -> ScriptProjectTrustState {
        let trusted_paths = self.lock();
        if trusted_paths.contains(&project_key(project_directory)) {
            ScriptProjectTrustState::Trusted
        } else {
            ScriptProjectTrustState::Untrusted
        }
    }

    pub fn set_trusted(&self, trusted: bool, project_directory: &str) -> std::io::Result<()> {
        let mut trusted_paths = self.lock();
        let key = project_key(project_directory);
        if trusted {
            trusted_paths.insert(key);
        } else {
            trusted_paths.remove(&key);
        }
        self.save(&trusted_paths)
    }

    fn save(&self, trusted_paths: &BTreeSet<String>) -> std::io::Result<()> {
        if let Some(directory) = self.storage_url.parent() {
            std::fs::create_dir_all(directory)?;
        }
        let document = TrustDocument {
            version: DOCUMENT_VERSION,
            trusted_project_paths: trusted_paths.iter().cloned().collect(),
        };
        let encoded = diffuse_assets::swift_json::to_sorted_pretty(&document)
            .map_err(std::io::Error::other)?;
        AtomicFile::write(encoded.as_bytes(), &self.storage_url, Access::Inherit)
    }

    fn lock(&self) -> MutexGuard<'_, BTreeSet<String>> {
        self.trusted_paths
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

impl Default for ScriptProjectTrustStore {
    fn default() -> Self {
        Self::new()
    }
}

/// `URL(fileURLWithPath:isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path`.
fn project_key(project_directory: &str) -> String {
    standardized_path(Path::new(project_directory))
        .to_string_lossy()
        .into_owned()
}

/// `COVE_EDITOR_STATE_DIRECTORY` wins; otherwise Application Support.
fn default_storage_url(environment: &BTreeMap<String, String>) -> PathBuf {
    if let Some(override_directory) = environment
        .get("COVE_EDITOR_STATE_DIRECTORY")
        .filter(|value| !value.is_empty())
    {
        return Path::new(override_directory).join("script-workspace-trust.json");
    }
    let base = application_support_directory()
        .or_else(|| home_directory().map(|home| home.join(".cove")))
        .unwrap_or_else(std::env::temp_dir);
    base.join("DiffuseEditor")
        .join("script-workspace-trust.json")
}

/// Canonical form when the path exists, otherwise an absolute lexically
/// normalized path — matching `standardizedFileURL`.
fn standardized_path(path: &Path) -> PathBuf {
    if let Ok(canonical) = std::fs::canonicalize(path) {
        return canonical;
    }
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()
            .map(|cwd| cwd.join(path))
            .unwrap_or_else(|_| path.to_path_buf())
    };
    let mut normalized = PathBuf::new();
    for component in absolute.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                normalized.pop();
            }
            other => normalized.push(other.as_os_str()),
        }
    }
    normalized
}

fn application_support_directory() -> Option<PathBuf> {
    #[cfg(target_os = "macos")]
    {
        home_directory().map(|home| home.join("Library").join("Application Support"))
    }
    #[cfg(target_os = "windows")]
    {
        std::env::var_os("APPDATA").map(PathBuf::from)
    }
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    {
        std::env::var_os("XDG_DATA_HOME").map(PathBuf::from)
    }
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

#[derive(Clone, Copy, Debug, PartialEq, Eq, thiserror::Error)]
pub enum ScriptProjectTrustError {
    #[error("Swift script execution is blocked until this project is explicitly trusted.")]
    ExecutionBlocked,
}

impl ScriptProjectTrustError {
    pub fn error_description(&self) -> &'static str {
        match self {
            ScriptProjectTrustError::ExecutionBlocked => {
                "Swift script execution is blocked until this project is explicitly trusted."
            }
        }
    }
}
