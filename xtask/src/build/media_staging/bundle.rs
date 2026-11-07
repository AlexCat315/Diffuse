//! `Bundle.swift` — the SwiftPM artifact bundle manifest written under
//! `FFmpeg.artifactbundle/info.json`, plus per-variant provenance.

use std::collections::BTreeMap;
use std::path::Path;

use serde::{Deserialize, Serialize};

use super::stage_operation::StageOperation;
use crate::support::files;
use crate::support::terminal::ToolError;

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StaticLibraryMetadata {
    pub header_paths: Vec<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ArtifactBundleVariant {
    pub path: String,
    pub supported_triples: Vec<String>,
    pub static_library_metadata: StaticLibraryMetadata,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ArtifactBundleArtifact {
    #[serde(rename = "type")]
    pub type_name: String,
    pub version: String,
    pub variants: Vec<ArtifactBundleVariant>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ArtifactBundle {
    pub schema_version: String,
    pub artifacts: BTreeMap<String, ArtifactBundleArtifact>,
}

/// Per-variant provenance recorded next to the staged files so integrity can
/// be re-checked without network access.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Provenance {
    pub version: String,
    #[serde(rename = "source_sha256")]
    pub source_sha256: String,
    pub license: String,
    /// Variant-relative path to SHA-256, excluding the stamp itself.
    pub files: BTreeMap<String, String>,
}

fn io_error(error: std::io::Error) -> ToolError {
    ToolError::message(error.to_string())
}

impl StageOperation {
    /// `shutil.copytree(source, destination, dirs_exist_ok=True)`: copies a tree
    /// over an existing destination, replacing files but leaving unrelated
    /// entries in place.
    pub(super) fn merge(source: &Path, destination: &Path) -> Result<(), ToolError> {
        for entry in files::files_in(source, true).map_err(io_error)? {
            let target = destination.join(files::relative_path(&entry, source));
            if entry.is_dir() {
                files::directory(&target).map_err(io_error)?;
            } else {
                files::copy(&entry, &target).map_err(io_error)?;
            }
        }
        Ok(())
    }
}
