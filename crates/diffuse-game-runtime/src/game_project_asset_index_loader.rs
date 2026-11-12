//! Translation of `Editor/Sources/GameRuntime/GameProjectAssetIndexLoader.swift`.
//!
//! Loads the stable mesh-slot mapping recorded by `ProjectExporter`. A missing
//! asset list is valid for a development project, but an existing corrupt list
//! must not silently remap meshes and render the wrong scene.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;
use std::io;
use std::path::Path;

use diffuse_assets::asset_registry::AssetRegistry;
use diffuse_editor_core::assets::asset_import_resolver::AssetImportResolver;
use diffuse_editor_core::scene::project_exporter::{ProjectExportError, ProjectExporter};
use diffuse_script::core::script_definition::{JsonValue, ScriptDefinition};

/// Swift's `GameProjectAssetIndexError`.
#[derive(Debug)]
pub enum GameProjectAssetIndexError {
    MissingExportAssetList,
    AssetCountMismatch {
        expected: i64,
        actual: i64,
    },
    UnsafeRelativePath(String),
    DuplicateRelativePath(String),
    DuplicateMeshIndex(i64),
    /// Swift rethrew the descriptor errors; Rust names the wrapped error.
    Export(ProjectExportError),
    Io(io::Error),
    Decode(String),
}

impl fmt::Display for GameProjectAssetIndexError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::MissingExportAssetList => {
                formatter.write_str("project export is missing assets.json")
            }
            Self::AssetCountMismatch { expected, actual } => write!(
                formatter,
                "project asset count mismatch (expected {expected}, found {actual})"
            ),
            Self::UnsafeRelativePath(path) => write!(
                formatter,
                "export asset list contains an unsafe relative path: {path}"
            ),
            Self::DuplicateRelativePath(path) => write!(
                formatter,
                "export asset list contains a duplicate relative path: {path}"
            ),
            Self::DuplicateMeshIndex(index) => write!(
                formatter,
                "export asset list assigns mesh index {index} more than once"
            ),
            Self::Export(error) => error.fmt(formatter),
            Self::Io(error) => error.fmt(formatter),
            Self::Decode(message) => formatter.write_str(message),
        }
    }
}

impl std::error::Error for GameProjectAssetIndexError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Export(error) => Some(error),
            Self::Io(error) => Some(error),
            _ => None,
        }
    }
}

impl From<ProjectExportError> for GameProjectAssetIndexError {
    fn from(error: ProjectExportError) -> Self {
        Self::Export(error)
    }
}

impl From<io::Error> for GameProjectAssetIndexError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

pub struct GameProjectAssetIndexLoader;

impl GameProjectAssetIndexLoader {
    pub fn load(
        project_directory: &Path,
    ) -> Result<BTreeMap<String, i64>, GameProjectAssetIndexError> {
        let asset_list_url = project_directory.join("assets.json");
        let descriptor_url = project_directory.join("build.json");
        let descriptor = if descriptor_url.exists() {
            Some(ProjectExporter::read_descriptor(project_directory)?)
        } else {
            None
        };
        if !asset_list_url.exists() {
            if descriptor.is_some() {
                return Err(GameProjectAssetIndexError::MissingExportAssetList);
            }
            return Ok(BTreeMap::new());
        }

        let data = std::fs::read_to_string(&asset_list_url)?;
        let asset_list = decode_asset_list(&data)?;
        if let Some(descriptor) = descriptor.as_ref() {
            let actual = i64::try_from(asset_list.len()).unwrap_or(i64::MAX);
            if descriptor.asset_count != actual {
                return Err(GameProjectAssetIndexError::AssetCountMismatch {
                    expected: descriptor.asset_count,
                    actual,
                });
            }
        }

        let mut result: BTreeMap<String, i64> = BTreeMap::new();
        let mut seen_relative_paths: BTreeSet<String> = BTreeSet::new();
        let mut used_mesh_indices: BTreeSet<i64> = BTreeSet::new();
        for asset in asset_list {
            let Some(relative_path) =
                AssetImportResolver::sanitized_relative_path(&asset.relative_path)
            else {
                return Err(GameProjectAssetIndexError::UnsafeRelativePath(
                    asset.relative_path,
                ));
            };
            if !seen_relative_paths.insert(relative_path.clone()) {
                return Err(GameProjectAssetIndexError::DuplicateRelativePath(
                    relative_path,
                ));
            }
            // Texture entries use slot 0 and do not participate in the mesh map.
            if asset.mesh_index < AssetRegistry::IMPORTED_MESH_START_INDEX {
                continue;
            }
            if !used_mesh_indices.insert(asset.mesh_index) {
                return Err(GameProjectAssetIndexError::DuplicateMeshIndex(
                    asset.mesh_index,
                ));
            }
            result.insert(relative_path, asset.mesh_index);
        }
        Ok(result)
    }
}

struct AssetEntry {
    relative_path: String,
    mesh_index: i64,
}

/// `serde_json` is not a dependency of this crate; the std-only parser behind
/// `ScriptDefinition::decode_parameters` is the only public JSON reader here.
/// It reports malformed input as an empty object, so every required field is
/// checked explicitly and a missing one fails decoding.
fn decode_asset_list(text: &str) -> Result<Vec<AssetEntry>, GameProjectAssetIndexError> {
    let document = ScriptDefinition::decode_parameters(text);
    let assets = document
        .get("assets")
        .and_then(JsonValue::as_array)
        .ok_or_else(|| decode_error("project export asset list is missing its assets array"))?;
    let mut entries = Vec::with_capacity(assets.len());
    for asset in assets {
        let object = asset
            .as_object()
            .ok_or_else(|| decode_error("project export asset list contains a non-object entry"))?;
        let relative_path = required_string(object, "relativePath")?;
        for key in ["id", "name", "kind"] {
            let _ = required_string(object, key)?;
        }
        let mesh_index = required_i64(object, "meshIndex")?;
        entries.push(AssetEntry {
            relative_path,
            mesh_index,
        });
    }
    Ok(entries)
}

fn required_string(
    object: &BTreeMap<String, JsonValue>,
    key: &str,
) -> Result<String, GameProjectAssetIndexError> {
    object
        .get(key)
        .and_then(JsonValue::as_str)
        .map(str::to_owned)
        .ok_or_else(|| {
            decode_error(format!(
                "project export asset is missing string field {key}"
            ))
        })
}

fn required_i64(
    object: &BTreeMap<String, JsonValue>,
    key: &str,
) -> Result<i64, GameProjectAssetIndexError> {
    object.get(key).and_then(integer_value).ok_or_else(|| {
        decode_error(format!(
            "project export asset is missing integer field {key}"
        ))
    })
}

fn integer_value(value: &JsonValue) -> Option<i64> {
    match value {
        JsonValue::Integer(value) => Some(*value),
        JsonValue::Unsigned(value) => i64::try_from(*value).ok(),
        JsonValue::Number(value)
            if value.is_finite()
                && value.fract() == 0.0
                && *value >= i64::MIN as f64
                && *value <= i64::MAX as f64 =>
        {
            Some(*value as i64)
        }
        JsonValue::Float(value) if value.is_finite() && value.fract() == 0.0 => Some(*value as i64),
        _ => None,
    }
}

fn decode_error(message: impl Into<String>) -> GameProjectAssetIndexError {
    GameProjectAssetIndexError::Decode(message.into())
}
