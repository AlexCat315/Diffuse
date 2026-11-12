//! Translation of `Editor/Sources/EditorCore/Application/Plugins/Installations.swift`.
//!
//! Application-owned installation decisions, separate from project-supplied
//! files.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use cove_system::atomic_file::AtomicFile;
use cove_system::files::Access;
use diffuse_capability::capability_registry::CapabilityRegistry;
use diffuse_capability::support::swift_date::SwiftDate;
use diffuse_plugin::PluginError;
use diffuse_plugin::contract::plugin_package::PluginPackageLoader;
use diffuse_plugin::contribution::registry::ContributionPointRegistry;
use diffuse_plugin::plugin_authorization::{
    PluginAuthorizationRecord, PluginContractDeriver, PluginInspection,
};
use serde::{Deserialize, Serialize};

/// One installed package: its directory under the application root, the
/// authorization captured from the reviewed package and whether it is enabled.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct PluginInstallationRecord {
    pub directory: String,
    pub authorization: PluginAuthorizationRecord,
    #[serde(default)]
    pub enabled: bool,
}

pub struct PluginInstallations {
    root: PathBuf,
}

impl PluginInstallations {
    /// Swift's `.applicationSupportDirectory` mapping for the desktop hosts this
    /// editor runs on; mobile sandboxes are supplied by their host instead.
    pub fn application_root() -> PathBuf {
        #[cfg(target_os = "windows")]
        let base = std::env::var_os("APPDATA")
            .map(PathBuf::from)
            .or_else(|| {
                std::env::var_os("USERPROFILE")
                    .map(|home| PathBuf::from(home).join("AppData").join("Roaming"))
            })
            .unwrap_or_else(|| PathBuf::from("."));
        #[cfg(target_os = "macos")]
        let base = std::env::var_os("HOME")
            .map(|home| {
                PathBuf::from(home)
                    .join("Library")
                    .join("Application Support")
            })
            .unwrap_or_else(|| PathBuf::from("."));
        #[cfg(not(any(target_os = "windows", target_os = "macos")))]
        let base = std::env::var_os("XDG_DATA_HOME")
            .map(PathBuf::from)
            .or_else(|| {
                std::env::var_os("HOME")
                    .map(|home| PathBuf::from(home).join(".local").join("share"))
            })
            .unwrap_or_else(|| PathBuf::from("."));
        base.join("Diffuse").join("InstalledPlugins")
    }

    pub fn new() -> Self {
        Self::with_root(&Self::application_root())
    }

    pub fn with_root(root: &Path) -> Self {
        PluginInstallations {
            root: standardized(root),
        }
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    fn registry_path(&self) -> PathBuf {
        self.root.join("registry.json")
    }

    pub fn records(&self) -> Result<Vec<PluginInstallationRecord>, PluginError> {
        let file = self.registry_path();
        if !file.is_file() {
            return Ok(Vec::new());
        }
        let bytes = std::fs::read(&file)?;
        let values: Vec<PluginInstallationRecord> = serde_json::from_slice(&bytes)?;
        let mut ids: BTreeSet<String> = BTreeSet::new();
        for record in &values {
            let directory = &record.directory;
            if !ids.insert(record.authorization.plugin_id.clone())
                || !directory.ends_with(".coveplugin")
                || directory.contains('/')
                || directory.contains('\\')
                || directory.starts_with('.')
            {
                return Err(
                    diffuse_plugin::plugin_authorization::PluginAuthorizationError::NoLongerValid
                        .into(),
                );
            }
        }
        Ok(values)
    }

    pub fn package(&self, record: &PluginInstallationRecord) -> PathBuf {
        self.root.join(&record.directory)
    }

    /// Copy first, then compare the copied bytes to the reviewed inspection.
    pub fn stage(
        &self,
        source: &Path,
        inspection: &PluginInspection,
    ) -> Result<PluginInstallationRecord, PluginError> {
        let authorization =
            PluginAuthorizationRecord::from_inspection(inspection, SwiftDate::now())?;
        std::fs::create_dir_all(&self.root)?;
        let record = PluginInstallationRecord {
            directory: format!("{}.coveplugin", diffuse_kernel::codable::new_uuid()),
            authorization,
            enabled: false,
        };
        let destination = self.package(&record);
        let result = (|| -> Result<(), PluginError> {
            copy_directory(source, &destination)?;
            let loader = PluginPackageLoader::new(
                CapabilityRegistry::default_registry(),
                None,
                ContributionPointRegistry::standard(),
            );
            let validated = loader.load(&destination)?;
            let copied = PluginInspection::from_package(
                &validated,
                PluginContractDeriver::contracts(&validated),
            );
            if !record.authorization.is_still_valid(&copied) {
                return Err(
                    diffuse_plugin::plugin_authorization::PluginAuthorizationError::NoLongerValid
                        .into(),
                );
            }
            Ok(())
        })();
        match result {
            Ok(()) => Ok(record),
            Err(error) => {
                let _ = std::fs::remove_dir_all(&destination);
                Err(error)
            }
        }
    }

    pub fn save(&self, record: &PluginInstallationRecord) -> Result<(), PluginError> {
        let mut values = self.records()?;
        let previous: Vec<PluginInstallationRecord> = values
            .iter()
            .filter(|value| {
                value.authorization.plugin_id == record.authorization.plugin_id
                    && value.directory != record.directory
            })
            .cloned()
            .collect();
        values.retain(|value| value.authorization.plugin_id != record.authorization.plugin_id);
        values.push(record.clone());
        self.persist(&values)?;
        for old in previous {
            let _ = std::fs::remove_dir_all(self.package(&old));
        }
        Ok(())
    }

    pub fn set_enabled(&self, enabled: bool, ids: &BTreeSet<String>) -> Result<(), PluginError> {
        let mut values = self.records()?;
        let mut changed = false;
        for value in &mut values {
            if ids.contains(&value.authorization.plugin_id) && value.enabled != enabled {
                value.enabled = enabled;
                changed = true;
            }
        }
        if changed {
            self.persist(&values)?;
        }
        Ok(())
    }

    pub fn remove(&self, id: &str) -> Result<(), PluginError> {
        let values = self.records()?;
        let remaining: Vec<PluginInstallationRecord> = values
            .iter()
            .filter(|value| value.authorization.plugin_id != id)
            .cloned()
            .collect();
        self.persist(&remaining)?;
        // Keep package bytes until no running project can reference them.
        for record in values
            .iter()
            .filter(|value| value.authorization.plugin_id == id)
        {
            let _ = std::fs::remove_dir_all(self.package(record));
        }
        Ok(())
    }

    fn persist(&self, values: &[PluginInstallationRecord]) -> Result<(), PluginError> {
        std::fs::create_dir_all(&self.root)?;
        // `serde_json::Value` maps are ordered, so this is the Swift
        // `.sortedKeys` layout with pretty printing.
        let value = serde_json::to_value(values)?;
        let bytes = serde_json::to_vec_pretty(&value)?;
        AtomicFile::write(&bytes, &self.registry_path(), Access::Inherit)?;
        Ok(())
    }
}

impl Default for PluginInstallations {
    fn default() -> Self {
        Self::new()
    }
}

fn standardized(path: &Path) -> PathBuf {
    path.canonicalize().unwrap_or_else(|_| path.to_path_buf())
}

/// Recursive copy used by `stage`; plugin packages contain regular files and
/// directories only (the package loader rejects symbolic links).
fn copy_directory(source: &Path, destination: &Path) -> Result<(), PluginError> {
    std::fs::create_dir_all(destination)?;
    for entry in std::fs::read_dir(source)? {
        let entry = entry?;
        let target = destination.join(entry.file_name());
        let file_type = entry.file_type()?;
        if file_type.is_dir() {
            copy_directory(&entry.path(), &target)?;
        } else {
            std::fs::copy(entry.path(), &target)?;
        }
    }
    Ok(())
}
