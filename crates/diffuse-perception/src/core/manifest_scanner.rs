//! `ManifestScanner.swift` — recursive perception manifest discovery.

use std::path::{Path, PathBuf};

use crate::core::perception_contracts::PerceptionModelManifest;
use crate::core::perception_schema_validator::PerceptionSchemaValidator;

pub struct ManifestScanError {
    pub url: PathBuf,
    pub error: String,
}

pub struct ScanResult {
    pub manifests: Vec<PerceptionModelManifest>,
    pub errors: Vec<ManifestScanError>,
}

impl ScanResult {
    pub fn new(manifests: Vec<PerceptionModelManifest>, errors: Vec<ManifestScanError>) -> Self {
        ScanResult { manifests, errors }
    }
}

pub struct ManifestScanner;

impl ManifestScanner {
    /// Scans `directory` recursively for files named `manifest.json` or ending in
    /// `.perception.json`. Files that fail decoding or schema validation are
    /// collected in `errors`.
    pub fn scan(directory: &Path) -> ScanResult {
        let mut manifests = Vec::new();
        let mut errors = Vec::new();
        let mut files = Vec::new();
        collect_files(directory, &mut files);

        for file_url in files {
            let Some(name) = file_url.file_name().and_then(|name| name.to_str()) else {
                continue;
            };
            if name != "manifest.json" && !name.ends_with(".perception.json") {
                continue;
            }
            let parsed = std::fs::read(&file_url)
                .map_err(|error| error.to_string())
                .and_then(|data| {
                    serde_json::from_slice::<PerceptionModelManifest>(&data)
                        .map_err(|error| error.to_string())
                })
                .and_then(|manifest| {
                    PerceptionSchemaValidator::validate_manifest(&manifest)
                        .map(|()| manifest)
                        .map_err(|error| error.to_string())
                });
            match parsed {
                Ok(manifest) => manifests.push(manifest),
                Err(error) => errors.push(ManifestScanError {
                    url: file_url,
                    error,
                }),
            }
        }

        ScanResult::new(manifests, errors)
    }
}

/// Mirrors `FileManager.enumerator(options: .skipsHiddenFiles)`: hidden entries
/// are skipped at every depth. Directory order is sorted so scan output is stable.
fn collect_files(directory: &Path, files: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(directory) else {
        return;
    };
    let mut entries: Vec<_> = entries.filter_map(Result::ok).collect();
    entries.sort_by_key(|entry| entry.file_name());
    for entry in entries {
        if entry.file_name().to_string_lossy().starts_with('.') {
            continue;
        }
        let path = entry.path();
        let is_directory = entry
            .file_type()
            .map(|file_type| file_type.is_dir())
            .unwrap_or(false);
        if is_directory {
            collect_files(&path, files);
        } else {
            files.push(path);
        }
    }
}
