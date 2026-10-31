//! `plugin.json` identity, authority and validation.
//!
//! Ported from `Engine/Sources/PluginRuntime/Contract/PluginManifest.swift`.

use std::collections::BTreeSet;
use std::fmt;

use diffuse_capability::capability_contract::{CapabilityAccess, CapabilityContract};
use diffuse_capability::capability_registry::CapabilityRegistry;
use serde::{Deserialize, Serialize};

use crate::contract::activation::PluginActivationEvent;
use crate::contract::host_permissions::PluginHostPermissions;
use crate::contract::requirements::PluginRequirement;
use crate::contract::resources::{PluginResource, PluginRuntimeDeclaration};
use crate::contribution::registry::{ContributionDescriptor, ContributionPointRegistry};
use crate::pattern::{has_whitespace, is_blank, lower_capability, lower_dot};

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub enum PluginImportPermission {
    #[serde(rename = "cove:scene/query")]
    SceneQuery,
    #[serde(rename = "cove:selection/query")]
    SelectionQuery,
    #[serde(rename = "cove:asset/metadata-query")]
    AssetMetadataQuery,
    #[serde(rename = "cove:process/host")]
    Process,
    #[serde(rename = "cove:http/host")]
    Http,
    #[serde(rename = "diffuse:editor/host")]
    Editor,
    #[serde(rename = "cove:service/host")]
    Service,
}

impl PluginImportPermission {
    /// Swift's `CaseIterable` order.
    pub const ALL: [PluginImportPermission; 7] = [
        PluginImportPermission::SceneQuery,
        PluginImportPermission::SelectionQuery,
        PluginImportPermission::AssetMetadataQuery,
        PluginImportPermission::Process,
        PluginImportPermission::Http,
        PluginImportPermission::Editor,
        PluginImportPermission::Service,
    ];

    pub const fn raw_value(self) -> &'static str {
        match self {
            PluginImportPermission::SceneQuery => "cove:scene/query",
            PluginImportPermission::SelectionQuery => "cove:selection/query",
            PluginImportPermission::AssetMetadataQuery => "cove:asset/metadata-query",
            PluginImportPermission::Process => "cove:process/host",
            PluginImportPermission::Http => "cove:http/host",
            PluginImportPermission::Editor => "diffuse:editor/host",
            PluginImportPermission::Service => "cove:service/host",
        }
    }

    pub fn from_raw_value(value: &str) -> Option<PluginImportPermission> {
        Self::ALL
            .into_iter()
            .find(|permission| permission.raw_value() == value)
    }

    pub fn is_snapshot(self) -> bool {
        matches!(
            self,
            PluginImportPermission::SceneQuery
                | PluginImportPermission::SelectionQuery
                | PluginImportPermission::AssetMetadataQuery
        )
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginResourceLimits {
    pub discovery_timeout_milliseconds: u64,
    pub preparation_timeout_milliseconds: u64,
    pub maximum_output_bytes: i64,
    pub maximum_capabilities: i64,
}

impl PluginResourceLimits {
    /// Swift clamped each argument to its ceiling on construction; `min` is kept
    /// here for the same reason.
    pub fn new(
        discovery_timeout_milliseconds: Option<u64>,
        preparation_timeout_milliseconds: Option<u64>,
        maximum_output_bytes: Option<i64>,
        maximum_capabilities: Option<i64>,
    ) -> Self {
        PluginResourceLimits {
            discovery_timeout_milliseconds: discovery_timeout_milliseconds
                .unwrap_or(2_000)
                .min(2_000),
            preparation_timeout_milliseconds: preparation_timeout_milliseconds
                .unwrap_or(5_000)
                .min(5_000),
            maximum_output_bytes: maximum_output_bytes
                .unwrap_or(1_024 * 1_024)
                .min(1_024 * 1_024),
            maximum_capabilities: maximum_capabilities.unwrap_or(64).min(64),
        }
    }

    pub fn secure_default() -> Self {
        Self::new(None, None, None, None)
    }

    /// For `host.processes[].entryPoints`: the editor calls them with whole tool
    /// output, the model never does. Size and fuel bounds are lifted to what the
    /// runtime can hold; the preparation deadline still bounds each call.
    pub fn host_entry_point() -> Self {
        let mut limits = Self::secure_default();
        limits.maximum_output_bytes = 256 * 1_024 * 1_024;
        limits
    }
}

impl Default for PluginResourceLimits {
    fn default() -> Self {
        Self::secure_default()
    }
}

/// `plugin.json` contains package identity and authority only. Capability input
/// types are deliberately absent: `capabilities.wit` owns that contract.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CovePluginManifest {
    pub id: String,
    pub version: i64,
    pub name: String,
    pub description: String,
    pub access: CapabilityAccess,
    pub imports: Vec<PluginImportPermission>,
    #[serde(rename = "composable_host_capabilities")]
    pub composable_host_capabilities: Vec<String>,
    /// Declared dependencies, `[]` when the manifest omits them. Sorted by kind
    /// then id so the value is deterministic for digests and comparisons.
    #[serde(default)]
    pub requires: Vec<PluginRequirement>,
    #[serde(default)]
    pub host: PluginHostPermissions,
    #[serde(default)]
    pub contributes: ContributionDescriptor,
    #[serde(default)]
    pub resources: Vec<PluginResource>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub runtime: Option<PluginRuntimeDeclaration>,
    #[serde(default)]
    pub activation: Vec<String>,
}

impl CovePluginManifest {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        id: impl Into<String>,
        version: i64,
        name: &str,
        description: &str,
        access: CapabilityAccess,
        imports: Vec<PluginImportPermission>,
        composable_host_capabilities: Vec<String>,
        requires: Vec<PluginRequirement>,
        host: PluginHostPermissions,
        contributes: ContributionDescriptor,
    ) -> Self {
        // Swift de-duplicated imports through a `Set` of raw values and re-sorted
        // by raw value; `BTreeSet` gives the same order.
        let unique_imports: BTreeSet<&'static str> =
            imports.iter().map(|value| value.raw_value()).collect();
        let mut composable: Vec<String> = composable_host_capabilities
            .into_iter()
            .collect::<BTreeSet<String>>()
            .into_iter()
            .collect();
        composable.sort();
        let mut requires = requires;
        requires.sort_by(|left, right| {
            (left.kind.raw_value(), left.id.as_str())
                .cmp(&(right.kind.raw_value(), right.id.as_str()))
        });
        CovePluginManifest {
            id: id.into(),
            version,
            name: CapabilityContract::sanitise_metadata(name, 80),
            description: CapabilityContract::sanitise_metadata(description, 1_024),
            access,
            imports: unique_imports
                .into_iter()
                .filter_map(PluginImportPermission::from_raw_value)
                .collect(),
            composable_host_capabilities: composable,
            requires,
            host,
            contributes,
            resources: Vec::new(),
            runtime: None,
            activation: Vec::new(),
        }
    }

    /// Swift's custom `init(from:)` decoded `requires`, `host` and `contributes`
    /// with `decodeIfPresent` defaults and `resources`/`activation` as empty
    /// lists; the `#[serde(default)]` attributes above carry the same defaults.
    /// The named initialiser still applies the Swift normalisation (sanitised
    /// metadata, de-duplicated imports, sorted requirements), which is why a
    /// decoded manifest goes through `normalised` below.
    pub fn normalised(mut self) -> Self {
        self.name = CapabilityContract::sanitise_metadata(&self.name, 80);
        self.description = CapabilityContract::sanitise_metadata(&self.description, 1_024);
        let unique_imports: BTreeSet<&'static str> =
            self.imports.iter().map(|value| value.raw_value()).collect();
        self.imports = unique_imports
            .into_iter()
            .filter_map(PluginImportPermission::from_raw_value)
            .collect();
        self.composable_host_capabilities.sort();
        self.composable_host_capabilities.dedup();
        self.requires.sort_by(|left, right| {
            (left.kind.raw_value(), left.id.as_str())
                .cmp(&(right.kind.raw_value(), right.id.as_str()))
        });
        self
    }
}

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum PluginManifestValidationError {
    #[error("plugin id must match [a-z][a-z0-9.-]{{2,63}}")]
    InvalidIdentifier,
    #[error("plugin version must be positive")]
    InvalidVersion,
    #[error("plugin name must not be empty")]
    EmptyName,
    #[error("plugin.json must not define '{0}'")]
    ForbiddenMetadataField(String),
    #[error("external side-effect plugins are disabled")]
    ExternalSideEffectsDisabled,
    #[error("unknown composed host capability '{0}'")]
    UnknownHostCapability(String),
    #[error("plugin capability '{0}' cannot be used as a host primitive")]
    PluginCapabilityCannotBeComposed(String),
    #[error("plugin access understates composed capability '{0}'")]
    AccessUnderstatement(String),
    #[error("host capability '{0}' is not an AI-exposed strict write primitive")]
    UnsafeHostPrimitive(String),
    #[error("plugin requirement '{0}' is invalid")]
    InvalidRequirement(String),
    #[error("plugin requirement '{0}' is declared more than once")]
    DuplicateRequirement(String),
    #[error("plugin requirement '{0}' points at the plugin itself")]
    RequirementOnSelf(String),
    #[error("invalid plugin process permissions")]
    InvalidHostPermissions,
    #[error("invalid plugin contribution '{0}'")]
    InvalidContribution(String),
}

pub enum PluginManifestValidator {}

impl PluginManifestValidator {
    const FORBIDDEN_FIELDS: [&'static str; 7] = [
        "schema",
        "inputSchema",
        "input_schema",
        "tools",
        "mutations",
        "transactionOperations",
        "sceneMutations",
    ];
    const ALLOWED_FIELDS: [&'static str; 13] = [
        "id",
        "version",
        "name",
        "description",
        "access",
        "imports",
        "composable_host_capabilities",
        "requires",
        "host",
        "contributes",
        "resources",
        "runtime",
        "activation",
    ];

    pub fn decode_and_validate(
        data: &[u8],
        registry: &CapabilityRegistry,
        contributions: &ContributionPointRegistry,
    ) -> Result<CovePluginManifest, PluginManifestValidationError> {
        let raw: serde_json::Value = serde_json::from_slice(data).map_err(|_| {
            // Swift threw `invalidIdentifier` when `JSONSerialization` did not
            // produce an object.
            PluginManifestValidationError::InvalidIdentifier
        })?;
        let serde_json::Value::Object(object) = raw else {
            return Err(PluginManifestValidationError::InvalidIdentifier);
        };
        if let Some(forbidden) = Self::FORBIDDEN_FIELDS
            .iter()
            .find(|field| object.contains_key(**field))
        {
            return Err(PluginManifestValidationError::ForbiddenMetadataField(
                (*forbidden).to_string(),
            ));
        }
        // Swift took `object.keys.first`, which is unordered; the sorted order
        // here makes the reported field deterministic.
        if let Some(unknown) = object
            .keys()
            .find(|key| !Self::ALLOWED_FIELDS.contains(&key.as_str()))
        {
            return Err(PluginManifestValidationError::ForbiddenMetadataField(
                unknown.clone(),
            ));
        }
        let decoded: CovePluginManifest = serde_json::from_slice(data)
            .map_err(|_| PluginManifestValidationError::InvalidIdentifier)?;
        let decoded = decoded.normalised();
        Self::validate(&decoded, registry, contributions)?;
        Ok(decoded)
    }

    pub fn validate(
        manifest: &CovePluginManifest,
        registry: &CapabilityRegistry,
        contributions: &ContributionPointRegistry,
    ) -> Result<(), PluginManifestValidationError> {
        manifest.host.validate(&manifest.imports)?;
        manifest
            .contributes
            .validate(contributions, &manifest.host)?;
        let resource_ids: BTreeSet<&String> = manifest
            .resources
            .iter()
            .map(|resource| &resource.id)
            .collect();
        let resource_paths: BTreeSet<&String> = manifest
            .resources
            .iter()
            .map(|resource| &resource.path)
            .collect();
        let runtime_ok = manifest.runtime.as_ref().is_none_or(|runtime| {
            runtime.engine == "bun" && runtime.entry == "plugin.js" && runtime.compatibility == 1
        });
        let activation_set: BTreeSet<&String> = manifest.activation.iter().collect();
        if !(resource_ids.len() == manifest.resources.len()
            && resource_paths.len() == manifest.resources.len()
            && manifest.resources.len() <= 128
            && manifest.resources.iter().all(|resource| {
                !resource.id.is_empty()
                    && !resource.kind.is_empty()
                    && PluginResource::is_valid_path(&resource.path)
            })
            && runtime_ok
            && activation_set.len() == manifest.activation.len()
            && manifest
                .activation
                .iter()
                .all(|event| PluginActivationEvent::is_valid(event)))
        {
            return Err(PluginManifestValidationError::InvalidContribution(
                "package".to_string(),
            ));
        }
        if !lower_dot(&manifest.id, 3, 64) {
            return Err(PluginManifestValidationError::InvalidIdentifier);
        }
        if manifest.version <= 0 {
            return Err(PluginManifestValidationError::InvalidVersion);
        }
        if is_blank(&manifest.name) {
            return Err(PluginManifestValidationError::EmptyName);
        }
        if manifest.access == CapabilityAccess::ExternalSideEffect {
            return Err(PluginManifestValidationError::ExternalSideEffectsDisabled);
        }
        for capability_id in &manifest.composable_host_capabilities {
            let Some(descriptor) = registry.descriptor(capability_id) else {
                return Err(PluginManifestValidationError::UnknownHostCapability(
                    capability_id.clone(),
                ));
            };
            if descriptor.source.kind
                != diffuse_capability::capability_contract::CapabilitySourceKind::Builtin
            {
                return Err(
                    PluginManifestValidationError::PluginCapabilityCannotBeComposed(
                        capability_id.clone(),
                    ),
                );
            }
            if Self::risk_rank(descriptor.access) > Self::risk_rank(manifest.access) {
                return Err(PluginManifestValidationError::AccessUnderstatement(
                    capability_id.clone(),
                ));
            }
            if !(descriptor.is_ai_exposed
                && descriptor.access.is_write()
                && descriptor.input_schema.is_strict_capability_input())
            {
                return Err(PluginManifestValidationError::UnsafeHostPrimitive(
                    capability_id.clone(),
                ));
            }
        }
        let mut seen: BTreeSet<String> = BTreeSet::new();
        for requirement in &manifest.requires {
            Self::validate_requirement(requirement, &manifest.id)?;
            let key = format!("{}:{}", requirement.kind.raw_value(), requirement.id);
            if !seen.insert(key) {
                return Err(PluginManifestValidationError::DuplicateRequirement(
                    requirement.id.clone(),
                ));
            }
        }
        Ok(())
    }

    fn validate_requirement(
        requirement: &PluginRequirement,
        manifest_id: &str,
    ) -> Result<(), PluginManifestValidationError> {
        let minimum_ok = requirement
            .minimum_version
            .is_none_or(|minimum| minimum > 0);
        if !(!requirement.id.is_empty()
            && requirement.id.chars().count() <= 128
            && !has_whitespace(&requirement.id)
            && minimum_ok)
        {
            return Err(PluginManifestValidationError::InvalidRequirement(
                requirement.id.clone(),
            ));
        }
        match requirement.kind {
            crate::contract::requirements::PluginRequirementKind::Plugin => {
                if !lower_dot(&requirement.id, 3, 64) {
                    return Err(PluginManifestValidationError::InvalidRequirement(
                        requirement.id.clone(),
                    ));
                }
                if requirement.id == manifest_id {
                    return Err(PluginManifestValidationError::RequirementOnSelf(
                        requirement.id.clone(),
                    ));
                }
            }
            crate::contract::requirements::PluginRequirementKind::Capability => {
                if !lower_capability(&requirement.id, 1, 128) {
                    return Err(PluginManifestValidationError::InvalidRequirement(
                        requirement.id.clone(),
                    ));
                }
                // A package's own capabilities are `pluginID.capabilityName`; they
                // only exist once this package is mounted, so a self-requirement
                // could never be satisfied and is a manifest bug.
                let prefix = format!("{manifest_id}.");
                let is_own = requirement
                    .id
                    .strip_prefix(&prefix)
                    .is_some_and(|rest| !rest.contains('.'));
                if is_own {
                    return Err(PluginManifestValidationError::RequirementOnSelf(
                        requirement.id.clone(),
                    ));
                }
            }
        }
        Ok(())
    }

    fn risk_rank(access: CapabilityAccess) -> i32 {
        match access {
            CapabilityAccess::Read => 0,
            CapabilityAccess::ReversibleWrite => 1,
            CapabilityAccess::DestructiveWrite => 2,
            CapabilityAccess::ExternalSideEffect => 3,
        }
    }
}

impl fmt::Display for PluginImportPermission {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.raw_value())
    }
}
