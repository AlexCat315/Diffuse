//! Declared dependencies between packages and capabilities.
//!
//! Ported from `Engine/Sources/PluginRuntime/Contract/Requirements.swift`.
//!
//! Requirements express capability needs only. They grant no authority: every
//! plugin still needs its own authorization, and an unmet requirement fails the
//! enable closed instead of auto-enabling a dependency.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;

use serde::{Deserialize, Serialize};

use crate::contract::plugin_manifest::CovePluginManifest;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PluginRequirementKind {
    Plugin,
    Capability,
}

impl PluginRequirementKind {
    pub const fn raw_value(self) -> &'static str {
        match self {
            PluginRequirementKind::Plugin => "plugin",
            PluginRequirementKind::Capability => "capability",
        }
    }
}

/// One declared dependency of a package.
///
/// `plugin.json` carries them as structured entries so the contract stays
/// machine-checkable:
///
/// ```json
/// "requires": [
///   { "kind": "plugin", "id": "studio.core", "minimum_version": 2 },
///   { "kind": "capability", "id": "studio.core.draw" }
/// ]
/// ```
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct PluginRequirement {
    pub kind: PluginRequirementKind,
    pub id: String,
    /// Optional minimum version of the depended plugin or capability contract.
    #[serde(default, rename = "minimum_version")]
    pub minimum_version: Option<i64>,
}

impl PluginRequirement {
    pub fn new(kind: PluginRequirementKind, id: impl Into<String>) -> Self {
        PluginRequirement {
            kind,
            id: id.into(),
            minimum_version: None,
        }
    }

    pub fn with_minimum_version(
        kind: PluginRequirementKind,
        id: impl Into<String>,
        minimum_version: i64,
    ) -> Self {
        PluginRequirement {
            kind,
            id: id.into(),
            minimum_version: Some(minimum_version),
        }
    }
}

impl fmt::Display for PluginRequirement {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self.minimum_version {
            Some(minimum) => write!(
                formatter,
                "{}:{}@{minimum}+",
                self.kind.raw_value(),
                self.id
            ),
            None => write!(formatter, "{}:{}", self.kind.raw_value(), self.id),
        }
    }
}

/// One unmet requirement, reported by `PluginRequirementResolver::unmet`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PluginRequirementViolation {
    MissingPlugin {
        id: String,
        required_by: String,
        minimum_version: Option<i64>,
    },
    PluginVersionTooLow {
        id: String,
        required_by: String,
        minimum_version: i64,
        actual: i64,
    },
    MissingCapability {
        id: String,
        required_by: String,
        minimum_version: Option<i64>,
    },
    CapabilityVersionTooLow {
        id: String,
        required_by: String,
        minimum_version: i64,
        actual: i64,
    },
}

impl fmt::Display for PluginRequirementViolation {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            PluginRequirementViolation::MissingPlugin {
                id,
                required_by,
                minimum_version,
            } => {
                let version = minimum_version
                    .map(|minimum| format!(" (minimum version {minimum})"))
                    .unwrap_or_default();
                write!(
                    formatter,
                    "'{required_by}' requires plugin '{id}'{version}, which is not enabled"
                )
            }
            PluginRequirementViolation::PluginVersionTooLow {
                id,
                required_by,
                minimum_version,
                actual,
            } => write!(
                formatter,
                "'{required_by}' requires plugin '{id}' version {minimum_version} or newer; enabled version is {actual}"
            ),
            PluginRequirementViolation::MissingCapability {
                id,
                required_by,
                minimum_version,
            } => {
                let version = minimum_version
                    .map(|minimum| format!(" (minimum version {minimum})"))
                    .unwrap_or_default();
                write!(
                    formatter,
                    "'{required_by}' requires capability '{id}'{version}, which is not available"
                )
            }
            PluginRequirementViolation::CapabilityVersionTooLow {
                id,
                required_by,
                minimum_version,
                actual,
            } => write!(
                formatter,
                "'{required_by}' requires capability '{id}' version {minimum_version} or newer; available version is {actual}"
            ),
        }
    }
}

/// Every unmet requirement of one package, thrown when enabling would mount a
/// plugin whose declared dependencies are absent.
#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
#[error("Plugin '{plugin_id}' declares unmet requirements: {}", violations.iter().map(ToString::to_string).collect::<Vec<_>>().join("; "))]
pub struct UnmetPluginRequirements {
    pub plugin_id: String,
    pub violations: Vec<PluginRequirementViolation>,
}

impl UnmetPluginRequirements {
    pub fn new(plugin_id: impl Into<String>, violations: Vec<PluginRequirementViolation>) -> Self {
        UnmetPluginRequirements {
            plugin_id: plugin_id.into(),
            violations,
        }
    }
}

/// A disable request refused because other enabled plugins require the target.
#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub struct RequiredPluginStillNeeded {
    pub plugin_id: String,
    pub dependents: Vec<String>,
}

impl RequiredPluginStillNeeded {
    pub fn new(plugin_id: impl Into<String>, dependents: Vec<String>) -> Self {
        RequiredPluginStillNeeded {
            plugin_id: plugin_id.into(),
            dependents,
        }
    }
}

impl fmt::Display for RequiredPluginStillNeeded {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let mut sorted = self.dependents.clone();
        sorted.sort();
        let list = sorted
            .iter()
            .map(|dependent| format!("'{dependent}'"))
            .collect::<Vec<_>>()
            .join(", ");
        write!(
            formatter,
            "'{}' is required by {list}; disable those plugins first.",
            self.plugin_id
        )
    }
}

/// Resolves declared requirements against what is already mounted.
///
/// Enabling is incremental: a package may only be enabled while every
/// requirement is already satisfied, which keeps the enable order topological
/// (dependencies always precede dependents) and makes requirement cycles
/// impossible to create.
pub enum PluginRequirementResolver {}

impl PluginRequirementResolver {
    /// Every unmet requirement, in declaration order.
    pub fn unmet(
        requirements: &[PluginRequirement],
        required_by: &str,
        enabled_plugins: &BTreeMap<String, i64>,
        provided_capabilities: &BTreeMap<String, i64>,
    ) -> Vec<PluginRequirementViolation> {
        let mut violations = Vec::new();
        for requirement in requirements {
            match requirement.kind {
                PluginRequirementKind::Plugin => {
                    let Some(actual) = enabled_plugins.get(&requirement.id).copied() else {
                        violations.push(PluginRequirementViolation::MissingPlugin {
                            id: requirement.id.clone(),
                            required_by: required_by.to_string(),
                            minimum_version: requirement.minimum_version,
                        });
                        continue;
                    };
                    if let Some(minimum) = requirement.minimum_version
                        && actual < minimum
                    {
                        violations.push(PluginRequirementViolation::PluginVersionTooLow {
                            id: requirement.id.clone(),
                            required_by: required_by.to_string(),
                            minimum_version: minimum,
                            actual,
                        });
                    }
                }
                PluginRequirementKind::Capability => {
                    let Some(actual) = provided_capabilities.get(&requirement.id).copied() else {
                        violations.push(PluginRequirementViolation::MissingCapability {
                            id: requirement.id.clone(),
                            required_by: required_by.to_string(),
                            minimum_version: requirement.minimum_version,
                        });
                        continue;
                    };
                    if let Some(minimum) = requirement.minimum_version
                        && actual < minimum
                    {
                        violations.push(PluginRequirementViolation::CapabilityVersionTooLow {
                            id: requirement.id.clone(),
                            required_by: required_by.to_string(),
                            minimum_version: minimum,
                            actual,
                        });
                    }
                }
            }
        }
        violations
    }

    /// Enabled plugins that require this plugin or one of its exact contracts.
    pub fn dependents(
        of: &str,
        capability_ids: &BTreeSet<String>,
        manifests: &BTreeMap<String, CovePluginManifest>,
    ) -> Vec<String> {
        let mut dependents: Vec<String> = manifests
            .iter()
            .filter(|(id, manifest)| {
                id.as_str() != of
                    && manifest
                        .requires
                        .iter()
                        .any(|requirement| match requirement.kind {
                            PluginRequirementKind::Plugin => requirement.id == of,
                            PluginRequirementKind::Capability => {
                                capability_ids.contains(&requirement.id)
                            }
                        })
            })
            .map(|(id, _)| id.clone())
            .collect();
        dependents.sort();
        dependents
    }
}
