//! `Editor/Sources/EditorCore/AI/Plugins/EditorPluginAuthorizationStore.swift`.
//!
//! Project-scoped record of explicit user decisions. Records are not an
//! enable-list: opening a project never loads a plugin from this file. The UI
//! may reuse a record only after `is_still_valid` binds it to the current
//! inspection, and `EditorApplication.enable_plugin` still asks PluginHost to
//! validate the package again before exposure.

use std::collections::BTreeMap;
use std::fmt;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard};

use diffuse_kernel::codable::new_uuid;
use diffuse_plugin::plugin_authorization::{PluginAuthorizationRecord, PluginInspection};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum EditorPluginAuthorizationStoreError {
    #[error("Plugin authorization storage contains duplicate plugin '{0}'.")]
    DuplicatePlugin(String),
    #[error("Plugin authorization storage uses unsupported format version {0}.")]
    UnsupportedFormatVersion(i64),
    #[error("Plugin authorization storage could not be encoded.")]
    CouldNotEncode,
    /// `throws` rethrows FileManager failures in Swift; only their description
    /// survives, so the variant carries the message rather than an `io::Error`.
    #[error("{0}")]
    Io(String),
}

/// The persisted shape: `{"format_version": 1, "records": [...]}`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
struct Document {
    #[serde(rename = "format_version")]
    format_version: i64,
    records: Vec<PluginAuthorizationRecord>,
}

pub struct EditorPluginAuthorizationStore {
    pub storage_url: PathBuf,
    pub load_warning: Option<String>,
    records_by_plugin_id: Mutex<BTreeMap<String, PluginAuthorizationRecord>>,
}

impl EditorPluginAuthorizationStore {
    pub fn new(project_directory: impl AsRef<Path>) -> Self {
        let storage_url = project_directory
            .as_ref()
            .join(".cove")
            .join("plugin_authorizations.json");
        let (records_by_plugin_id, load_warning) = match Self::load(&storage_url) {
            Ok(records) => (records, None),
            Err(error) => {
                let original_description = error.to_string();
                let quarantine_url = quarantine_url(&storage_url);
                let quarantine_name = quarantine_url
                    .file_name()
                    .map(|name| name.to_string_lossy().into_owned())
                    .unwrap_or_default();
                let warning = match fs::rename(&storage_url, &quarantine_url) {
                    Ok(()) => format!(
                        "The invalid authorization file was moved to {quarantine_name}: \
                         {original_description}"
                    ),
                    Err(move_error) => format!(
                        "Plugin authorizations were rejected, but the invalid file could not \
                         be quarantined: {move_error}; original error: {original_description}"
                    ),
                };
                (BTreeMap::new(), Some(warning))
            }
        };
        EditorPluginAuthorizationStore {
            storage_url,
            load_warning,
            records_by_plugin_id: Mutex::new(records_by_plugin_id),
        }
    }

    pub fn authorization(
        &self,
        inspection: &PluginInspection,
    ) -> Option<PluginAuthorizationRecord> {
        let records = self.lock();
        let record = records.get(&inspection.manifest.id)?;
        if record.is_still_valid(inspection) {
            Some(record.clone())
        } else {
            None
        }
    }

    pub fn record(
        &self,
        authorization: &PluginAuthorizationRecord,
    ) -> Result<(), EditorPluginAuthorizationStoreError> {
        let mut records = self.lock();
        let mut next = records.clone();
        next.insert(authorization.plugin_id.clone(), authorization.clone());
        self.persist(&next)?;
        *records = next;
        Ok(())
    }

    pub fn remove(&self, plugin_id: &str) -> Result<(), EditorPluginAuthorizationStoreError> {
        let mut records = self.lock();
        let mut next = records.clone();
        next.remove(plugin_id);
        self.persist(&next)?;
        *records = next;
        Ok(())
    }

    pub fn all_records(&self) -> Vec<PluginAuthorizationRecord> {
        let records = self.lock();
        let mut all: Vec<PluginAuthorizationRecord> = records.values().cloned().collect();
        all.sort_by(|left, right| left.plugin_id.cmp(&right.plugin_id));
        all
    }

    fn lock(&self) -> MutexGuard<'_, BTreeMap<String, PluginAuthorizationRecord>> {
        self.records_by_plugin_id
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn load(storage_url: &Path) -> Result<BTreeMap<String, PluginAuthorizationRecord>, LoadError> {
        if !storage_url.exists() {
            return Ok(BTreeMap::new());
        }
        let document: Document = serde_json::from_slice(&fs::read(storage_url)?)?;
        if document.format_version != 1 {
            return Err(LoadError::Invalid(
                EditorPluginAuthorizationStoreError::UnsupportedFormatVersion(
                    document.format_version,
                ),
            ));
        }
        let mut result: BTreeMap<String, PluginAuthorizationRecord> = BTreeMap::new();
        for record in document.records {
            let plugin_id = record.plugin_id.clone();
            if result.insert(plugin_id.clone(), record).is_some() {
                return Err(LoadError::Invalid(
                    EditorPluginAuthorizationStoreError::DuplicatePlugin(plugin_id),
                ));
            }
        }
        Ok(result)
    }

    fn persist(
        &self,
        records: &BTreeMap<String, PluginAuthorizationRecord>,
    ) -> Result<(), EditorPluginAuthorizationStoreError> {
        let mut ordered: Vec<PluginAuthorizationRecord> = records.values().cloned().collect();
        ordered.sort_by(|left, right| left.plugin_id.cmp(&right.plugin_id));
        let document = Document {
            format_version: 1,
            records: ordered,
        };
        let encoded = diffuse_assets::swift_json::to_sorted_pretty(&document)
            .map_err(|_| EditorPluginAuthorizationStoreError::CouldNotEncode)?;
        if let Some(directory) = self.storage_url.parent() {
            fs::create_dir_all(directory)
                .map_err(|error| EditorPluginAuthorizationStoreError::Io(error.to_string()))?;
        }
        cove_system::files::atomic_write(
            &self.storage_url,
            encoded.as_bytes(),
            cove_system::files::Access::OwnerOnly,
        )
        .map_err(|error| EditorPluginAuthorizationStoreError::Io(error.to_string()))?;
        Ok(())
    }
}

/// `plugin_authorizations.corrupt-<uuid>.json` beside the rejected file.
fn quarantine_url(storage_url: &Path) -> PathBuf {
    let stem = storage_url
        .file_stem()
        .map(|stem| stem.to_string_lossy().into_owned())
        .unwrap_or_else(|| "plugin_authorizations".to_string());
    storage_url.with_file_name(format!("{stem}.corrupt-{}.json", new_uuid()))
}

/// Errors surfaced by the initial load; `new` only renders their description.
enum LoadError {
    Io(std::io::Error),
    Decode(serde_json::Error),
    Invalid(EditorPluginAuthorizationStoreError),
}

impl From<std::io::Error> for LoadError {
    fn from(error: std::io::Error) -> Self {
        LoadError::Io(error)
    }
}

impl From<serde_json::Error> for LoadError {
    fn from(error: serde_json::Error) -> Self {
        LoadError::Decode(error)
    }
}

impl fmt::Display for LoadError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            LoadError::Io(error) => write!(formatter, "{error}"),
            LoadError::Decode(error) => write!(formatter, "{error}"),
            LoadError::Invalid(error) => write!(formatter, "{error}"),
        }
    }
}
