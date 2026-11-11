//! `Editor/Sources/EditorCore/AI/Chat/EditorAISettings.swift`.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use cove_system::atomic_file::AtomicFile;
use cove_system::files::Access;
use cove_system::permissions::FilePermissions;
use diffuse_capability::capability_contract::ReleasePhase;
use serde::{Deserialize, Serialize};

use crate::contributions::ai_providers::AIAuthFieldDescriptor;

// MARK: - Settings

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct EditorAISettings {
    /// The plugin-contributed provider id; empty disables the assistant.
    #[serde(rename = "provider_id", default)]
    pub provider_id: String,
    #[serde(default)]
    pub model: String,
    /// The contributed agent id; empty picks the first enabled agent.
    #[serde(rename = "agent_id", default)]
    pub agent_id: String,
    /// Compatibility preference for read-only/legacy flows. Capability-backed
    /// AI writes always escalate to the required preview confirmation policy.
    #[serde(rename = "autoApprove", default)]
    pub auto_approve: bool,
}

impl EditorAISettings {
    pub fn is_enabled(&self) -> bool {
        !self.provider_id.is_empty()
    }

    pub fn new(
        provider_id: impl Into<String>,
        model: impl Into<String>,
        agent_id: impl Into<String>,
        auto_approve: bool,
    ) -> Self {
        EditorAISettings {
            provider_id: provider_id.into(),
            model: model.into(),
            agent_id: agent_id.into(),
            auto_approve,
        }
    }

    /// Swift's default arguments (`""`, `""`, `""`, `false`).
    pub fn with_defaults() -> Self {
        Self::new("", "", "", false)
    }
}

impl Default for EditorAISettings {
    /// Swift's `static let default`.
    fn default() -> Self {
        Self::with_defaults()
    }
}

// MARK: - Capability Settings

#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum EditorCapabilityReleasePhase {
    Stable,
    Beta,
    Experimental,
}

impl EditorCapabilityReleasePhase {
    /// Swift's `CaseIterable` order.
    pub const ALL: [EditorCapabilityReleasePhase; 3] = [
        EditorCapabilityReleasePhase::Stable,
        EditorCapabilityReleasePhase::Beta,
        EditorCapabilityReleasePhase::Experimental,
    ];

    pub fn display_name(self) -> &'static str {
        match self {
            EditorCapabilityReleasePhase::Stable => "Stable",
            EditorCapabilityReleasePhase::Beta => "Beta",
            EditorCapabilityReleasePhase::Experimental => "Experimental",
        }
    }

    pub fn runtime_phase(self) -> ReleasePhase {
        match self {
            EditorCapabilityReleasePhase::Stable => ReleasePhase::Stable,
            EditorCapabilityReleasePhase::Beta => ReleasePhase::Beta,
            EditorCapabilityReleasePhase::Experimental => ReleasePhase::Experimental,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct EditorCapabilitySettings {
    #[serde(rename = "releasePhase", default = "default_release_phase")]
    pub release_phase: EditorCapabilityReleasePhase,
}

fn default_release_phase() -> EditorCapabilityReleasePhase {
    EditorCapabilityReleasePhase::Stable
}

impl EditorCapabilitySettings {
    pub fn new(release_phase: EditorCapabilityReleasePhase) -> Self {
        EditorCapabilitySettings { release_phase }
    }

    /// Swift's `releasePhase: EditorCapabilityReleasePhase = .stable` default.
    pub fn with_defaults() -> Self {
        Self::new(EditorCapabilityReleasePhase::Stable)
    }
}

impl Default for EditorCapabilitySettings {
    /// Swift's `static let default`.
    fn default() -> Self {
        Self::with_defaults()
    }
}

// MARK: - Key store

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum AICredentialStoreError {
    #[error("The credential could not be saved: {0}")]
    WriteFailed(String),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AICredentialSource {
    CredentialFile,
    Environment { variable: String },
}

/// Provider credentials in one file only the user can read
/// (`~/Library/Application Support/Diffuse/Credentials/ai-providers.json`,
/// mode 0600 inside a 0700 folder), one value per auth field the provider
/// declares. Values are never written to project files, settings JSON,
/// prompts, logs, or plugins; a field's environment variable fills in a value
/// the file does not hold.
pub struct AICredentialStore;

/// Provider ID → auth field ID → value.
pub(crate) type Values = BTreeMap<String, BTreeMap<String, String>>;

impl AICredentialStore {
    pub fn file_url() -> PathBuf {
        let base = application_support_directory()
            .or_else(|| home_directory().map(|home| home.join(".local").join("share")))
            .unwrap_or_else(std::env::temp_dir);
        base.join("Diffuse")
            .join("Credentials")
            .join("ai-providers.json")
    }

    /// Stores the given fields' values; an empty value removes that field.
    pub fn save(
        values: &BTreeMap<String, String>,
        provider_id: &str,
    ) -> Result<(), AICredentialStoreError> {
        Self::save_at(values, provider_id, &Self::file_url())
    }

    pub(crate) fn save_at(
        values: &BTreeMap<String, String>,
        provider_id: &str,
        url: &Path,
    ) -> Result<(), AICredentialStoreError> {
        let mut stored = Self::stored(url);
        let mut fields = stored.remove(provider_id).unwrap_or_default();
        for (field, value) in values {
            if value.is_empty() {
                fields.remove(field);
            } else {
                fields.insert(field.clone(), value.clone());
            }
        }
        if !fields.is_empty() {
            stored.insert(provider_id.to_string(), fields);
        }
        let data = serde_json::to_vec(&stored)
            .map_err(|error| AICredentialStoreError::WriteFailed(error.to_string()))?;
        let directory = url.parent().unwrap_or(Path::new("."));
        FilePermissions::create_private_directory(directory, true)
            .and_then(|()| AtomicFile::write(&data, url, Access::OwnerOnly))
            .map_err(|error| AICredentialStoreError::WriteFailed(error.to_string()))
    }

    pub fn load(field: &AIAuthFieldDescriptor, provider_id: &str) -> Option<String> {
        Self::stored(&Self::file_url())
            .get(provider_id)
            .and_then(|fields| fields.get(&field.id))
            .cloned()
            .or_else(|| {
                environment_credential(field.environment_variable.as_deref(), &environment())
                    .map(|credential| credential.key)
            })
    }

    pub fn credential_source(
        field: &AIAuthFieldDescriptor,
        provider_id: &str,
    ) -> Option<AICredentialSource> {
        if Self::stored(&Self::file_url())
            .get(provider_id)
            .and_then(|fields| fields.get(&field.id))
            .is_some()
        {
            return Some(AICredentialSource::CredentialFile);
        }
        environment_credential(field.environment_variable.as_deref(), &environment()).map(
            |credential| AICredentialSource::Environment {
                variable: credential.variable,
            },
        )
    }

    /// Removes every stored field of the provider.
    pub fn delete(provider_id: &str) -> Result<(), AICredentialStoreError> {
        let fields = Self::stored(&Self::file_url())
            .remove(provider_id)
            .unwrap_or_default();
        let empty: BTreeMap<String, String> = fields
            .keys()
            .map(|field| (field.clone(), String::new()))
            .collect();
        Self::save(&empty, provider_id)
    }

    pub(crate) fn stored(url: &Path) -> Values {
        let Ok(data) = std::fs::read(url) else {
            return Values::new();
        };
        let Ok(values) = serde_json::from_slice::<Values>(&data) else {
            return Values::new();
        };
        values
            .into_iter()
            .map(|(provider, fields)| {
                (
                    provider,
                    fields
                        .into_iter()
                        .filter(|(_, value)| !value.is_empty())
                        .collect::<BTreeMap<String, String>>(),
                )
            })
            .filter(|(_, fields)| !fields.is_empty())
            .collect()
    }
}

pub(crate) fn environment_credential(
    variable: Option<&str>,
    environment: &BTreeMap<String, String>,
) -> Option<Credential> {
    let variable = variable?;
    let value = environment.get(variable)?.trim();
    if value.is_empty() {
        return None;
    }
    Some(Credential {
        variable: variable.to_string(),
        key: value.to_string(),
    })
}

pub(crate) struct Credential {
    pub variable: String,
    pub key: String,
}

/// `ProcessInfo.processInfo.environment`.
pub(crate) fn environment() -> BTreeMap<String, String> {
    std::env::vars().collect()
}

/// `FileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)`
/// first entry: nil on platforms whose location cannot be resolved.
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

/// `FileManager.default.homeDirectoryForCurrentUser`.
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
