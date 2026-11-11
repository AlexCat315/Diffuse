//! `Editor/Sources/EditorCore/Scripting/Dynamic/ProjectScriptCatalog.swift`.
//!
//! The project's `Scripts/scripts.json` catalog: built-in presets first, then
//! whatever the manifest declares, with per-entry diagnostics instead of a hard
//! failure so one bad row cannot hide the rest.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard};
use std::time::SystemTime;

use diffuse_script::ScriptPresetKind;
use serde::{Deserialize, Serialize};

#[derive(Debug, thiserror::Error)]
pub enum ProjectScriptCatalogError {
    #[error("Unsupported project script catalog schema version: {0}")]
    UnsupportedSchemaVersion(i64),
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error(transparent)]
    Decode(#[from] serde_json::Error),
    #[error(transparent)]
    Encode(#[from] diffuse_assets::swift_json::SwiftJsonError),
}

/// JSON value preserving the manifest's shape, decoded the way Swift's
/// hand-written `Codable` conformance folds unknown numeric forms.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum ProjectScriptJsonValue {
    Null,
    Bool(bool),
    Number(f64),
    String(String),
    Array(Vec<ProjectScriptJsonValue>),
    Object(BTreeMap<String, ProjectScriptJsonValue>),
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectScriptDefinition {
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub display_name: Option<String>,
    pub preset: String,
    #[serde(default)]
    pub default_parameters: BTreeMap<String, ProjectScriptJsonValue>,
}

impl ProjectScriptDefinition {
    pub fn new(
        id: String,
        display_name: Option<String>,
        preset: String,
        default_parameters: BTreeMap<String, ProjectScriptJsonValue>,
    ) -> Self {
        Self {
            id,
            display_name,
            preset,
            default_parameters,
        }
    }

    /// Swift's `displayName: nil` and `defaultParameters: [:]` defaults.
    pub fn with_defaults(id: String, preset: String) -> Self {
        Self::new(id, None, preset, BTreeMap::new())
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectScriptManifest {
    pub schema_version: i64,
    pub scripts: Vec<ProjectScriptDefinition>,
}

impl ProjectScriptManifest {
    pub fn new() -> Self {
        Self {
            schema_version: 1,
            scripts: Vec::new(),
        }
    }
}

impl Default for ProjectScriptManifest {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProjectScriptCatalogEntry {
    pub identifier: String,
    pub display_name: String,
    pub preset: ScriptPresetKind,
    pub default_parameters_json: String,
    pub is_built_in: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProjectScriptCatalogDiagnostic {
    pub severity: ProjectScriptCatalogDiagnosticSeverity,
    pub message: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProjectScriptCatalogDiagnosticSeverity {
    Warning,
    Error,
}

impl ProjectScriptCatalogDiagnosticSeverity {
    pub const fn raw_value(self) -> &'static str {
        match self {
            Self::Warning => "warning",
            Self::Error => "error",
        }
    }

    pub fn from_raw_value(value: &str) -> Option<Self> {
        match value {
            "warning" => Some(Self::Warning),
            "error" => Some(Self::Error),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProjectScriptCatalog {
    pub entries: Vec<ProjectScriptCatalogEntry>,
    pub diagnostics: Vec<ProjectScriptCatalogDiagnostic>,
    pub source_url: Option<PathBuf>,
}

impl ProjectScriptCatalog {
    /// Swift's `static let relativePath`.
    pub const RELATIVE_PATH: &'static str = "Scripts/scripts.json";

    /// Swift's `static var builtIn`.
    pub fn built_in() -> Self {
        Self {
            entries: built_in_entries(),
            diagnostics: Vec::new(),
            source_url: None,
        }
    }

    pub fn load(project_directory: &Path) -> Result<Self, ProjectScriptCatalogError> {
        let url = project_directory.join(Self::RELATIVE_PATH);
        let mut entries = built_in_entries();
        if !url.exists() {
            return Ok(Self {
                entries,
                diagnostics: Vec::new(),
                source_url: None,
            });
        }

        let data = std::fs::read(&url)?;
        let manifest: ProjectScriptManifest = serde_json::from_slice(&data)?;
        if manifest.schema_version != 1 {
            return Err(ProjectScriptCatalogError::UnsupportedSchemaVersion(
                manifest.schema_version,
            ));
        }

        let mut diagnostics: Vec<ProjectScriptCatalogDiagnostic> = Vec::new();
        let mut identifiers: BTreeSet<String> = entries
            .iter()
            .map(|entry| entry.identifier.clone())
            .collect();
        for definition in manifest.scripts {
            let identifier = definition.id.trim().to_string();
            if !is_valid_identifier(&identifier) {
                diagnostics.push(ProjectScriptCatalogDiagnostic {
                    severity: ProjectScriptCatalogDiagnosticSeverity::Error,
                    message: format!(
                        "Invalid script id '{}'; use letters, numbers, '.', '_' or '-'.",
                        definition.id
                    ),
                });
                continue;
            }
            if !identifiers.insert(identifier.clone()) {
                diagnostics.push(ProjectScriptCatalogDiagnostic {
                    severity: ProjectScriptCatalogDiagnosticSeverity::Error,
                    message: format!("Duplicate script id '{identifier}'."),
                });
                continue;
            }
            let Some(preset) = ScriptPresetKind::from_raw_value(&definition.preset) else {
                diagnostics.push(ProjectScriptCatalogDiagnostic {
                    severity: ProjectScriptCatalogDiagnosticSeverity::Error,
                    message: format!(
                        "Script '{identifier}' uses unknown preset '{}'.",
                        definition.preset
                    ),
                });
                continue;
            };
            let parameters = encode_parameters(&definition.default_parameters)?;
            let display_name = definition
                .display_name
                .as_deref()
                .map(str::trim)
                .filter(|name| !name.is_empty())
                .unwrap_or(&identifier)
                .to_string();
            entries.push(ProjectScriptCatalogEntry {
                identifier,
                display_name,
                preset,
                default_parameters_json: parameters,
                is_built_in: false,
            });
        }
        Ok(Self {
            entries,
            diagnostics,
            source_url: Some(url),
        })
    }
}

fn encode_parameters(
    parameters: &BTreeMap<String, ProjectScriptJsonValue>,
) -> Result<String, ProjectScriptCatalogError> {
    // `JSONEncoder().outputFormatting = [.sortedKeys]` — compact, key-sorted.
    Ok(diffuse_assets::swift_json::to_compact(parameters)?)
}

fn is_valid_identifier(identifier: &str) -> bool {
    !identifier.is_empty()
        && identifier
            .chars()
            .all(|character| character.is_alphanumeric() || matches!(character, '.' | '_' | '-'))
}

fn built_in_entries() -> Vec<ProjectScriptCatalogEntry> {
    fn entry(
        identifier: &str,
        display_name: &str,
        preset: ScriptPresetKind,
        default_parameters_json: &str,
    ) -> ProjectScriptCatalogEntry {
        ProjectScriptCatalogEntry {
            identifier: identifier.to_string(),
            display_name: display_name.to_string(),
            preset,
            default_parameters_json: default_parameters_json.to_string(),
            is_built_in: true,
        }
    }
    vec![
        entry(
            "cove.rotator",
            "Rotator",
            ScriptPresetKind::Rotator,
            r#"{"speed":[0,1.57,0]}"#,
        ),
        entry(
            "cove.oscillator",
            "Oscillator",
            ScriptPresetKind::Oscillator,
            r#"{"axis":[0,1,0],"amplitude":1,"frequency":1}"#,
        ),
        entry(
            "cove.mover",
            "Mover",
            ScriptPresetKind::Mover,
            r#"{"velocity":[0,0,0]}"#,
        ),
        entry(
            "cove.destroy-after",
            "Destroy After",
            ScriptPresetKind::DestroyAfter,
            r#"{"seconds":1}"#,
        ),
        entry(
            "cove.follower",
            "Follower",
            ScriptPresetKind::Follower,
            r#"{"targetEntityName":"","speed":5,"arrivalRadius":0.1}"#,
        ),
        entry(
            "cove.look-at",
            "Look At",
            ScriptPresetKind::LookAt,
            r#"{"targetEntityName":""}"#,
        ),
        entry(
            "cove.character-controller",
            "Character Controller Input",
            ScriptPresetKind::CharacterController,
            r#"{"moveSpeed":5,"jumpSpeed":8,"crouchAction":"crouch"}"#,
        ),
        entry(
            "cove.first-person-camera",
            "First Person Camera",
            ScriptPresetKind::FirstPersonCamera,
            r#"{"moveSpeed":5,"lookSensitivity":0.002}"#,
        ),
        entry(
            "cove.orbit-camera",
            "Orbit Camera",
            ScriptPresetKind::OrbitCamera,
            r#"{"target":[0,0,0],"distance":10,"orbitSpeed":0.005,"zoomSpeed":1,"minDistance":1,"maxDistance":100}"#,
        ),
    ]
}

/// Cheap file-signature monitor shared by Editor and standalone Player.
pub struct ProjectScriptCatalogMonitor {
    project_directory: String,
    last_signature: Mutex<Option<Signature>>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct Signature {
    exists: bool,
    modified_at: Option<SystemTime>,
    file_size: Option<u64>,
    contents: Option<Vec<u8>>,
}

impl ProjectScriptCatalogMonitor {
    pub fn new(project_directory: String) -> Self {
        Self {
            project_directory,
            last_signature: Mutex::new(None),
        }
    }

    /// Swift's `loadIfChanged()` — the `force: false` default.
    pub fn load_if_changed_with_default(
        &self,
    ) -> Result<Option<ProjectScriptCatalog>, ProjectScriptCatalogError> {
        self.load_if_changed(false)
    }

    pub fn load_if_changed(
        &self,
        force: bool,
    ) -> Result<Option<ProjectScriptCatalog>, ProjectScriptCatalogError> {
        let url = Path::new(&self.project_directory).join(ProjectScriptCatalog::RELATIVE_PATH);
        let metadata = std::fs::metadata(&url).ok();
        let signature = Signature {
            exists: url.exists(),
            modified_at: metadata.as_ref().and_then(|value| value.modified().ok()),
            file_size: metadata.as_ref().map(|value| value.len()),
            contents: std::fs::read(&url).ok(),
        };
        {
            let mut last_signature = self.lock();
            if !force && last_signature.as_ref() == Some(&signature) {
                return Ok(None);
            }
            *last_signature = Some(signature);
        }
        ProjectScriptCatalog::load(Path::new(&self.project_directory)).map(Some)
    }

    fn lock(&self) -> MutexGuard<'_, Option<Signature>> {
        self.last_signature
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}
