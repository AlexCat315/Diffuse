//! Declared package resources and the on-disk resource reader.
//!
//! Ported from `Engine/Sources/PluginRuntime/Contract/Resources.swift`.

use std::collections::BTreeMap;
use std::io::Read;
use std::path::{Path, PathBuf};

use diffuse_capability::release::sha256::CapabilityDigest;
use serde::{Deserialize, Serialize};

use crate::contract::plugin_package::PluginPackageError;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginResource {
    pub id: String,
    pub path: String,
    pub kind: String,
}

impl PluginResource {
    pub fn new(id: impl Into<String>, path: impl Into<String>, kind: impl Into<String>) -> Self {
        PluginResource {
            id: id.into(),
            path: path.into(),
            kind: kind.into(),
        }
    }

    pub fn is_valid_path(path: &str) -> bool {
        // Swift split on "/" keeping empty subsequences.
        let parts: Vec<&str> = path.split('/').collect();
        parts.len() >= 2
            && parts.first() == Some(&"resources")
            && path.len() <= 512
            && !path.contains('\\')
            && !path.contains(':')
            && !path.contains('\0')
            && parts
                .iter()
                .all(|part| !part.is_empty() && *part != "." && *part != "..")
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginRuntimeDeclaration {
    #[serde(default = "default_engine")]
    pub engine: String,
    #[serde(default = "default_entry")]
    pub entry: String,
    #[serde(default = "default_compatibility")]
    pub compatibility: i64,
}

fn default_engine() -> String {
    "bun".to_string()
}

fn default_entry() -> String {
    "plugin.js".to_string()
}

fn default_compatibility() -> i64 {
    1
}

impl PluginRuntimeDeclaration {
    /// Swift's `init()` set the three defaults; the decoder then overrode
    /// `engine` and `entry` from the document and defaulted `compatibility`
    /// only. The derived `Deserialize` above expresses the same contract for a
    /// document that omits any of the three.
    pub fn new() -> Self {
        PluginRuntimeDeclaration {
            engine: default_engine(),
            entry: default_entry(),
            compatibility: default_compatibility(),
        }
    }
}

impl Default for PluginRuntimeDeclaration {
    fn default() -> Self {
        Self::new()
    }
}

pub enum PluginPackageResources {}

impl PluginPackageResources {
    pub const MAXIMUM_BYTES: usize = 16 * 1_024 * 1_024;

    pub fn load(
        resources: &[PluginResource],
        root: &Path,
    ) -> Result<BTreeMap<String, String>, PluginPackageError> {
        let mut hashes: BTreeMap<String, String> = BTreeMap::new();
        let mut size = 0usize;
        for resource in resources {
            let data = Self::read(&resource.path, root)?;
            size += data.len();
            if size > Self::MAXIMUM_BYTES {
                return Err(PluginPackageError::InvalidResource(resource.path.clone()));
            }
            hashes.insert(resource.path.clone(), CapabilityDigest::sha256(&data));
        }
        let resource_root = root.join("resources");
        if resource_root.exists() {
            Self::check_directory(
                &resource_root,
                "resources",
                &hashes.keys().cloned().collect(),
            )?;
        }
        Ok(hashes)
    }

    pub fn read(path: &str, root: &Path) -> Result<Vec<u8>, PluginPackageError> {
        if !PluginResource::is_valid_path(path) {
            return Err(PluginPackageError::InvalidResource(path.to_string()));
        }
        let mut url = root.to_path_buf();
        for part in path.split('/') {
            url.push(part);
            if is_symbolic_link(&url)? {
                return Err(PluginPackageError::SymbolicLinkNotAllowed(path.to_string()));
            }
        }
        let metadata = std::fs::symlink_metadata(&url);
        let Ok(metadata) = metadata else {
            return Err(PluginPackageError::InvalidResource(path.to_string()));
        };
        if !metadata.is_file() || metadata.len() as usize > Self::MAXIMUM_BYTES {
            return Err(PluginPackageError::InvalidResource(path.to_string()));
        }
        let data = std::fs::read(&url)
            .map_err(|_| PluginPackageError::InvalidResource(path.to_string()))?;
        if data.len() > Self::MAXIMUM_BYTES {
            return Err(PluginPackageError::InvalidResource(path.to_string()));
        }
        Ok(data)
    }

    fn check_directory(
        directory: &Path,
        prefix: &str,
        declared: &std::collections::BTreeSet<String>,
    ) -> Result<(), PluginPackageError> {
        let name = directory
            .file_name()
            .map(|value| value.to_string_lossy().into_owned())
            .unwrap_or_default();
        if is_symbolic_link(directory)? {
            return Err(PluginPackageError::SymbolicLinkNotAllowed(name));
        }
        if !directory.is_dir() {
            return Err(PluginPackageError::InvalidResource(name));
        }
        let entries = std::fs::read_dir(directory)
            .map_err(|_| PluginPackageError::InvalidResource(name.clone()))?;
        for entry in entries {
            let entry = entry.map_err(|_| PluginPackageError::InvalidResource(name.clone()))?;
            let child = entry.path();
            let last = entry.file_name().to_string_lossy().into_owned();
            let path = format!("{prefix}/{last}");
            if is_symbolic_link(&child)? {
                return Err(PluginPackageError::SymbolicLinkNotAllowed(last));
            }
            if child.is_dir() {
                Self::check_directory(&child, &path, declared)?;
            } else if !declared.contains(&path) {
                return Err(PluginPackageError::InvalidResource(path));
            }
        }
        Ok(())
    }
}

/// `URLResourceValues.isSymbolicLink`.
pub fn is_symbolic_link(path: &Path) -> Result<bool, PluginPackageError> {
    match std::fs::symlink_metadata(path) {
        Ok(metadata) => Ok(metadata.file_type().is_symlink()),
        // Foundation's `resourceValues(forKeys:)` threw for a missing path; the
        // readers above treat that as a package error at their own call site.
        Err(_) => Ok(false),
    }
}

/// `URL.pathExtension == "coveplugin"` in a case-sensitive comparison.
pub fn path_extension(path: &Path) -> Option<String> {
    path.extension()
        .map(|extension| extension.to_string_lossy().into_owned())
}

/// `URL.lastPathComponent`.
pub fn last_path_component(path: &Path) -> String {
    path.file_name()
        .map(|value| value.to_string_lossy().into_owned())
        .unwrap_or_default()
}

/// Standardises a path without touching the filesystem, matching
/// `URL.standardizedFileURL` for the absolute paths this crate is handed.
pub fn standardized(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for component in path.components() {
        match component {
            std::path::Component::CurDir => {}
            std::path::Component::ParentDir => {
                if !out.pop() {
                    out.push("..");
                }
            }
            other => out.push(other.as_os_str()),
        }
    }
    out
}

/// Reads a whole file, reporting the same failure the Swift `Data(contentsOf:)`
/// surfaced as a package error.
pub fn read_file(path: &Path) -> Result<Vec<u8>, PluginPackageError> {
    let mut file = std::fs::File::open(path)
        .map_err(|_| PluginPackageError::MissingFile(last_path_component(path)))?;
    let mut data = Vec::new();
    file.read_to_end(&mut data)
        .map_err(|_| PluginPackageError::MissingFile(last_path_component(path)))?;
    Ok(data)
}
