//! `Editor/Sources/EditorCore/Scripting/Assets/ScriptAssetRegistry.swift`.
//!
//! Persistent identity map stored with the project at
//! `.cove/script-assets.json`.

use std::collections::BTreeSet;
use std::path::{Component, Path, PathBuf};
use std::sync::{Mutex, MutexGuard};

use cove_system::atomic_file::AtomicFile;
use cove_system::files::Access;
use diffuse_plugin::Uuid;
use serde::{Deserialize, Serialize};

/// Project-stable identity for a Swift script asset.
///
/// File names are presentation. References, build products, and runtime
/// registrations use this identity so renaming `Player.swift` does not break
/// scene bindings or create a second runtime script.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScriptAssetID {
    pub raw_value: Uuid,
}

impl ScriptAssetID {
    /// Swift's `rawValue: UUID = UUID()` default.
    pub fn new() -> Self {
        Self {
            raw_value: Uuid::new(),
        }
    }

    pub fn with_raw_value(raw_value: Uuid) -> Self {
        Self { raw_value }
    }

    pub fn runtime_identifier(&self) -> String {
        format!("scripts.asset.{}", self.raw_value.as_str().to_lowercase())
    }

    pub fn short_description(&self) -> String {
        self.raw_value
            .as_str()
            .to_lowercase()
            .chars()
            .take(8)
            .collect()
    }
}

impl Default for ScriptAssetID {
    fn default() -> Self {
        Self::new()
    }
}

impl std::fmt::Display for ScriptAssetID {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.runtime_identifier())
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ResolvedScriptAsset {
    pub id: ScriptAssetID,
    pub url: PathBuf,
    pub legacy_identifiers: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct AssetRecord {
    id: ScriptAssetID,
    relative_path: String,
    content_fingerprint: String,
    file_system_identity: Option<String>,
    legacy_identifiers: Vec<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct AssetDocument {
    version: i64,
    assets: Vec<AssetRecord>,
}

/// A content fingerprint is only a rename-reconciliation hint. Identity never
/// derives from the fingerprint: ambiguous matches receive a new UUID instead
/// of risking that two equal files exchange identities.
pub struct ScriptAssetRegistry {
    scripts_directory_url: PathBuf,
    storage_url: PathBuf,
    records: Mutex<Option<Vec<AssetRecord>>>,
}

impl ScriptAssetRegistry {
    pub fn new(project_directory: &str) -> Self {
        let project_url = Path::new(project_directory);
        Self {
            scripts_directory_url: project_url.join("Scripts"),
            storage_url: project_url.join(".cove").join("script-assets.json"),
            records: Mutex::new(None),
        }
    }

    pub fn resolve(
        &self,
        urls: Vec<PathBuf>,
    ) -> Result<Vec<ResolvedScriptAsset>, ScriptAssetRegistryError> {
        let mut guard = self.lock();
        let mut current = match guard.take() {
            Some(records) => records,
            None => Self::read_records(&self.storage_url)?,
        };
        let relative_paths: BTreeSet<String> =
            urls.iter().map(|url| self.relative_path(url)).collect();
        let mut claimed_ids: BTreeSet<ScriptAssetID> = BTreeSet::new();
        let mut did_change = false;
        let mut resolved: Vec<ResolvedScriptAsset> = Vec::new();

        let mut sorted_urls = urls;
        sorted_urls.sort_by(|left, right| file_name_lower(left).cmp(&file_name_lower(right)));

        for url in sorted_urls {
            let path = self.relative_path(&url);
            let fingerprint = Self::fingerprint(&url)?;
            let file_system_identity = file_system_identity(&url);
            let legacy_identifier = legacy_identifier_for_file_stem(
                &url.file_stem()
                    .map(|stem| stem.to_string_lossy().into_owned())
                    .unwrap_or_default(),
            );

            let mut index = current
                .iter()
                .position(|record| record.relative_path == path);
            if index.is_none() {
                let identity_candidates: Vec<usize> = current
                    .iter()
                    .enumerate()
                    .filter(|(_, record)| {
                        !claimed_ids.contains(&record.id)
                            && !relative_paths.contains(&record.relative_path)
                            && file_system_identity.is_some()
                            && record.file_system_identity == file_system_identity
                    })
                    .map(|(index, _)| index)
                    .collect();
                if identity_candidates.len() == 1 {
                    index = Some(identity_candidates[0]);
                } else {
                    let fingerprint_candidates: Vec<usize> = current
                        .iter()
                        .enumerate()
                        .filter(|(_, record)| {
                            !claimed_ids.contains(&record.id)
                                && !relative_paths.contains(&record.relative_path)
                                && record.content_fingerprint == fingerprint
                        })
                        .map(|(index, _)| index)
                        .collect();
                    if fingerprint_candidates.len() == 1 {
                        index = Some(fingerprint_candidates[0]);
                    }
                }
            }

            match index {
                Some(index) => {
                    claimed_ids.insert(current[index].id.clone());
                    if current[index].relative_path != path {
                        current[index].relative_path = path;
                        did_change = true;
                    }
                    if current[index].content_fingerprint != fingerprint {
                        current[index].content_fingerprint = fingerprint;
                        did_change = true;
                    }
                    if current[index].file_system_identity != file_system_identity {
                        current[index].file_system_identity = file_system_identity;
                        did_change = true;
                    }
                    if !current[index]
                        .legacy_identifiers
                        .contains(&legacy_identifier)
                    {
                        current[index].legacy_identifiers.push(legacy_identifier);
                        current[index].legacy_identifiers.sort();
                        did_change = true;
                    }
                    resolved.push(ResolvedScriptAsset {
                        id: current[index].id.clone(),
                        url,
                        legacy_identifiers: current[index].legacy_identifiers.clone(),
                    });
                }
                None => {
                    let record = AssetRecord {
                        id: ScriptAssetID::new(),
                        relative_path: path,
                        content_fingerprint: fingerprint,
                        file_system_identity,
                        legacy_identifiers: vec![legacy_identifier],
                    };
                    claimed_ids.insert(record.id.clone());
                    resolved.push(ResolvedScriptAsset {
                        id: record.id.clone(),
                        url,
                        legacy_identifiers: record.legacy_identifiers.clone(),
                    });
                    current.push(record);
                    did_change = true;
                }
            }
        }

        current.sort_by(|left, right| {
            left.relative_path
                .to_lowercase()
                .cmp(&right.relative_path.to_lowercase())
        });
        *guard = Some(current);
        if did_change {
            let records = guard.as_ref().expect("records cached above");
            self.save(records)?;
        }
        Ok(resolved)
    }

    pub fn remove(&self, asset_id: &ScriptAssetID) -> Result<(), ScriptAssetRegistryError> {
        let mut guard = self.lock();
        let mut current = match guard.take() {
            Some(records) => records,
            None => Self::read_records(&self.storage_url)?,
        };
        let previous_count = current.len();
        current.retain(|record| record.id != *asset_id);
        if current.len() == previous_count {
            *guard = Some(current);
            return Ok(());
        }
        *guard = Some(current);
        let records = guard.as_ref().expect("records cached above");
        self.save(records)
    }

    fn read_records(storage_url: &Path) -> Result<Vec<AssetRecord>, ScriptAssetRegistryError> {
        if !storage_url.exists() {
            return Ok(Vec::new());
        }
        let data = std::fs::read(storage_url)?;
        let document: AssetDocument = serde_json::from_slice(&data)
            .map_err(|error| ScriptAssetRegistryError::InvalidRegistry(error.to_string()))?;
        if document.version != 1 {
            return Err(ScriptAssetRegistryError::UnsupportedVersion(
                document.version,
            ));
        }
        Ok(document.assets)
    }

    fn save(&self, records: &[AssetRecord]) -> Result<(), ScriptAssetRegistryError> {
        let Some(directory) = self.storage_url.parent() else {
            return Ok(());
        };
        std::fs::create_dir_all(directory)?;
        let document = AssetDocument {
            version: 1,
            assets: records.to_vec(),
        };
        let data = diffuse_assets::swift_json::to_sorted_pretty(&document)?;
        AtomicFile::write(data.as_bytes(), &self.storage_url, Access::Inherit)?;
        Ok(())
    }

    fn relative_path(&self, url: &Path) -> String {
        let base = standardized_path(&self.scripts_directory_url)
            .to_string_lossy()
            .replace('\\', "/");
        let path = standardized_path(url).to_string_lossy().replace('\\', "/");
        let prefix = if base.ends_with('/') {
            base
        } else {
            format!("{base}/")
        };
        match path.strip_prefix(&prefix) {
            Some(relative) => relative.to_string(),
            None => url
                .file_name()
                .map(|name| name.to_string_lossy().into_owned())
                .unwrap_or_default(),
        }
    }

    fn fingerprint(url: &Path) -> Result<String, ScriptAssetRegistryError> {
        let bytes = std::fs::read(url)?;
        let mut first: u64 = 0xcbf2_9ce4_8422_2325;
        let mut second: u64 = 0x8422_2325_cbf2_9ce4;
        for byte in bytes {
            first = (first ^ u64::from(byte)).wrapping_mul(0x0000_0100_0000_01b3);
            second =
                (second ^ u64::from(byte.wrapping_add(0x9d))).wrapping_mul(0x0000_0100_0000_01b3);
        }
        Ok(format!("{first:016x}{second:016x}"))
    }

    fn lock(&self) -> MutexGuard<'_, Option<Vec<AssetRecord>>> {
        self.records
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

/// `DynamicScriptManager.legacyIdentifier(forFileStem:)`, kept here until the
/// manager itself is migrated.
fn legacy_identifier_for_file_stem(stem: &str) -> String {
    format!("scripts.{}", stem.to_lowercase().replace(' ', "-"))
}

fn file_name_lower(path: &Path) -> String {
    path.file_name()
        .map(|name| name.to_string_lossy().to_lowercase())
        .unwrap_or_default()
}

#[cfg(unix)]
fn file_system_identity(url: &Path) -> Option<String> {
    use std::os::unix::fs::MetadataExt;
    let metadata = std::fs::metadata(url).ok()?;
    Some(format!("{}:{}", metadata.dev(), metadata.ino()))
}

#[cfg(windows)]
fn file_system_identity(url: &Path) -> Option<String> {
    use std::os::windows::io::AsRawHandle;

    #[repr(C)]
    struct ByHandleFileInformation {
        file_attributes: u32,
        creation_time_low: u32,
        creation_time_high: u32,
        last_access_time_low: u32,
        last_access_time_high: u32,
        last_write_time_low: u32,
        last_write_time_high: u32,
        volume_serial_number: u32,
        file_size_high: u32,
        file_size_low: u32,
        number_of_links: u32,
        file_index_high: u32,
        file_index_low: u32,
    }

    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn GetFileInformationByHandle(
            file: *mut core::ffi::c_void,
            information: *mut ByHandleFileInformation,
        ) -> i32;
    }

    // `FileManager.attributesOfItem` reports the volume and file numbers, which
    // the stable `std` metadata extension does not expose on Windows.
    let file = std::fs::File::open(url).ok()?;
    let mut information = std::mem::MaybeUninit::<ByHandleFileInformation>::uninit();
    let success =
        unsafe { GetFileInformationByHandle(file.as_raw_handle(), information.as_mut_ptr()) };
    if success == 0 {
        return None;
    }
    let information = unsafe { information.assume_init() };
    let file_index =
        (u64::from(information.file_index_high) << 32) | u64::from(information.file_index_low);
    Some(format!("{}:{file_index}", information.volume_serial_number))
}

#[cfg(not(any(unix, windows)))]
fn file_system_identity(_url: &Path) -> Option<String> {
    None
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

#[derive(Debug, thiserror::Error)]
pub enum ScriptAssetRegistryError {
    #[error("Unsupported script asset registry version {0}.")]
    UnsupportedVersion(i64),
    #[error("The script asset registry is unreadable: {0}")]
    InvalidRegistry(String),
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error(transparent)]
    Encode(#[from] diffuse_assets::swift_json::SwiftJsonError),
}
