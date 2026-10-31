//! Plugin authorization, inspection and the registry binding.
//!
//! Ported from `Engine/Sources/PluginRuntime/PluginAuthorization.swift`.
//!
//! Every digest in this file is a `.sortedKeys` encoding. Swift's plain
//! `JSONEncoder` writes keys in a per-process random order
//! (MIGRATION.md §10), while `.sortedKeys` is alphabetical and stable, so
//! `serde_json` over an ordered map reproduces the bytes. Numbers go through
//! `diffuse_kernel::codable::serialize_double` because Swift writes `100` where
//! serde_json writes `100.0` (§5.4).

use std::collections::{BTreeMap, BTreeSet};

use diffuse_capability::capability_contract::{
    CapabilityAccess, CapabilityContract, PluginCapabilityAuthority, ReleasePhase,
};
use diffuse_capability::capability_descriptor::CapabilityDescriptor;
use diffuse_capability::capability_registry::CapabilityRegistry;
use diffuse_capability::release::sha256::CapabilityDigest;
use diffuse_capability::support::swift_date::SwiftDate;
use serde::{Deserialize, Serialize};

use crate::contract::host_permissions::PluginHostPermissions;
use crate::contract::plugin_manifest::CovePluginManifest;
use crate::contract::plugin_package::ValidatedPluginPackage;
use crate::contract::requirements::{
    PluginRequirement, PluginRequirementResolver, UnmetPluginRequirements,
};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PluginCapabilityDiscovery {
    #[serde(rename = "capability_ids")]
    pub capability_ids: Vec<String>,
}

impl PluginCapabilityDiscovery {
    pub fn new(capability_ids: Vec<String>) -> Self {
        let mut capability_ids = capability_ids;
        capability_ids.sort();
        PluginCapabilityDiscovery { capability_ids }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum PluginCapabilityValidationError {
    #[error("plugin capability '{0}' is absent from its validated static contract")]
    UnknownCapability(String),
}

/// Builds the complete model-facing contract from package identity/authority and
/// statically derived input types. Runtime Component output is never consulted.
pub enum PluginContractDeriver {}

impl PluginContractDeriver {
    pub fn contracts(package: &ValidatedPluginPackage) -> Vec<CapabilityContract> {
        let inputs = package
            .runtime
            .as_ref()
            .map(|runtime| runtime.contract.capability_inputs.clone())
            .unwrap_or_default();
        let mut contracts: Vec<CapabilityContract> = inputs
            .iter()
            .map(|input| {
                // A tool declaration is what the model reads; static contract
                // metadata describe the rest.
                let tool = package.manifest.ai_tool(&input.name);
                let title = tool
                    .as_ref()
                    .map(|tool| tool.title.clone())
                    .unwrap_or_else(|| input.title.clone());
                let description = tool
                    .as_ref()
                    .map(|tool| tool.description.clone())
                    .unwrap_or_else(|| {
                        if input.description.is_empty() {
                            package.manifest.description.clone()
                        } else {
                            input.description.clone()
                        }
                    });
                CapabilityContract::new(
                    format!("{}.{}", package.manifest.id, input.name),
                    package.manifest.version,
                    title,
                    description,
                    "plugin",
                    package.manifest.access,
                    ReleasePhase::Stable,
                    input.input_schema.clone(),
                    diffuse_capability::capability_contract::CapabilitySource::plugin(
                        package.manifest.id.clone(),
                    ),
                    None,
                )
            })
            .collect();
        contracts.sort_by(|left, right| left.id.cmp(&right.id));
        contracts
    }
}

/// Immutable result shown to the user before enabling a plugin. It binds the
/// exact code, contract boundary, manifest authority, and AI-visible contracts.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginInspection {
    pub manifest: CovePluginManifest,
    #[serde(default)]
    pub code_hash: Option<String>,
    #[serde(default)]
    pub contract_hash: Option<String>,
    #[serde(default)]
    pub resource_hashes: BTreeMap<String, String>,
    pub contracts: Vec<CapabilityContract>,
}

impl PluginInspection {
    pub fn from_package(
        package: &ValidatedPluginPackage,
        contracts: Vec<CapabilityContract>,
    ) -> Self {
        let mut contracts = contracts;
        contracts.sort_by(|left, right| left.id.cmp(&right.id));
        PluginInspection {
            manifest: package.manifest.clone(),
            code_hash: package
                .runtime
                .as_ref()
                .map(|runtime| runtime.code_hash.clone()),
            contract_hash: package
                .runtime
                .as_ref()
                .map(|runtime| runtime.contract_hash.clone()),
            resource_hashes: package.resource_hashes.clone(),
            contracts,
        }
    }

    pub fn new(
        manifest: CovePluginManifest,
        code_hash: Option<String>,
        contract_hash: Option<String>,
        contracts: Vec<CapabilityContract>,
    ) -> Self {
        let mut contracts = contracts;
        contracts.sort_by(|left, right| left.id.cmp(&right.id));
        PluginInspection {
            manifest,
            code_hash,
            contract_hash,
            resource_hashes: BTreeMap::new(),
            contracts,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum PluginAuthorizationError {
    #[error("plugin must be explicitly authorised before loading")]
    Missing,
    #[error(
        "plugin code, static, permissions, or capability schemas changed; reauthorisation is required"
    )]
    NoLongerValid,
    #[error("plugin authorisation contains duplicate capability '{0}'")]
    DuplicateCapability(String),
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginAuthorizationRecord {
    // Swift's synthesized `CodingKeys` used the property spelling, so the
    // persisted key is `pluginID`, not `pluginId`.
    #[serde(rename = "pluginID")]
    pub plugin_id: String,
    #[serde(rename = "pluginVersion")]
    pub plugin_version: i64,
    #[serde(default)]
    pub code_hash: Option<String>,
    #[serde(default)]
    pub contract_hash: Option<String>,
    pub imports: Vec<crate::contract::plugin_manifest::PluginImportPermission>,
    pub access: CapabilityAccess,
    pub composable_host_capabilities: Vec<String>,
    /// Declared dependencies, bound into the authorization like every other
    /// authority field: changing `requires` invalidates the stored record.
    pub requires: Vec<PluginRequirement>,
    pub capability_schema_hashes: BTreeMap<String, String>,
    pub manifest_hash: String,
    pub resource_hashes: BTreeMap<String, String>,
    pub authorised_at: SwiftDate,
    pub host: PluginHostPermissions,
}

impl PluginAuthorizationRecord {
    pub fn from_inspection(
        inspection: &PluginInspection,
        authorised_at: SwiftDate,
    ) -> Result<Self, crate::PluginError> {
        let hashes = Self::schema_hashes(&inspection.contracts)?;
        Ok(PluginAuthorizationRecord {
            manifest_hash: Self::digest(&inspection.manifest),
            resource_hashes: inspection.resource_hashes.clone(),
            plugin_id: inspection.manifest.id.clone(),
            plugin_version: inspection.manifest.version,
            code_hash: inspection.code_hash.clone(),
            contract_hash: inspection.contract_hash.clone(),
            imports: inspection.manifest.imports.clone(),
            access: inspection.manifest.access,
            composable_host_capabilities: inspection.manifest.composable_host_capabilities.clone(),
            requires: inspection.manifest.requires.clone(),
            host: inspection.manifest.host.clone(),
            capability_schema_hashes: hashes,
            authorised_at,
        })
    }

    pub fn from_package(
        package: &ValidatedPluginPackage,
        contracts: Vec<CapabilityContract>,
        authorised_at: SwiftDate,
    ) -> Result<Self, crate::PluginError> {
        Self::from_inspection(
            &PluginInspection::from_package(package, contracts),
            authorised_at,
        )
    }

    pub fn is_still_valid(&self, inspection: &PluginInspection) -> bool {
        let Ok(hashes) = Self::schema_hashes(&inspection.contracts) else {
            return false;
        };
        self.manifest_hash == Self::digest(&inspection.manifest)
            && self.resource_hashes == inspection.resource_hashes
            && self.plugin_id == inspection.manifest.id
            && self.plugin_version == inspection.manifest.version
            && self.code_hash == inspection.code_hash
            && self.contract_hash == inspection.contract_hash
            && self.imports == inspection.manifest.imports
            && self.access == inspection.manifest.access
            && self.composable_host_capabilities == inspection.manifest.composable_host_capabilities
            && self.requires == inspection.manifest.requires
            && self.host == inspection.manifest.host
            && self.capability_schema_hashes == hashes
    }

    pub fn is_still_valid_for_package(
        &self,
        package: &ValidatedPluginPackage,
        contracts: Vec<CapabilityContract>,
    ) -> bool {
        self.is_still_valid(&PluginInspection::from_package(package, contracts))
    }

    /// Stable executable-authority fingerprint. `authorised_at` is deliberately
    /// excluded: the authority is the exact code/contracts/permissions/schema
    /// tuple, not when a UI happened to persist the user's decision.
    pub fn authority_digest(&self) -> String {
        // Swift built a `[String: Any]` and serialised it with `.sortedKeys`;
        // a `BTreeMap<String, serde_json::Value>` is the same object with the
        // same ordering.
        let mut object: BTreeMap<String, serde_json::Value> = BTreeMap::new();
        object.insert(
            "plugin_id".to_string(),
            serde_json::Value::String(self.plugin_id.clone()),
        );
        object.insert("plugin_version".to_string(), integer(self.plugin_version));
        object.insert(
            "component_hash".to_string(),
            self.code_hash
                .clone()
                .map(serde_json::Value::String)
                .unwrap_or(serde_json::Value::Null),
        );
        object.insert(
            "manifest_hash".to_string(),
            serde_json::Value::String(self.manifest_hash.clone()),
        );
        object.insert(
            "resource_hashes".to_string(),
            string_map(&self.resource_hashes),
        );
        object.insert(
            "wit_hash".to_string(),
            self.contract_hash
                .clone()
                .map(serde_json::Value::String)
                .unwrap_or(serde_json::Value::Null),
        );
        let mut imports: Vec<&str> = self.imports.iter().map(|value| value.raw_value()).collect();
        imports.sort_unstable();
        object.insert(
            "imports".to_string(),
            serde_json::Value::Array(
                imports
                    .into_iter()
                    .map(|value| serde_json::Value::String(value.to_string()))
                    .collect(),
            ),
        );
        object.insert(
            "access".to_string(),
            serde_json::Value::String(self.access.raw_value().to_string()),
        );
        object.insert(
            "host".to_string(),
            serde_json::to_value(&self.host).unwrap_or(serde_json::Value::Null),
        );
        let mut composable = self.composable_host_capabilities.clone();
        composable.sort();
        object.insert(
            "composable_host_capabilities".to_string(),
            serde_json::Value::Array(
                composable
                    .into_iter()
                    .map(serde_json::Value::String)
                    .collect(),
            ),
        );
        object.insert(
            "requires".to_string(),
            serde_json::Value::Array(
                self.requires
                    .iter()
                    .map(|requirement| {
                        let mut entry: BTreeMap<String, serde_json::Value> = BTreeMap::new();
                        entry.insert(
                            "kind".to_string(),
                            serde_json::Value::String(requirement.kind.raw_value().to_string()),
                        );
                        entry.insert(
                            "id".to_string(),
                            serde_json::Value::String(requirement.id.clone()),
                        );
                        if let Some(minimum) = requirement.minimum_version {
                            entry.insert("minimum_version".to_string(), integer(minimum));
                        }
                        serde_json::Value::Object(entry.into_iter().collect())
                    })
                    .collect(),
            ),
        );
        object.insert(
            "capability_schema_hashes".to_string(),
            string_map(&self.capability_schema_hashes),
        );
        // `.sortedKeys`: the object is alphabetical by key, which is what a
        // `BTreeMap` iteration and serde_json's `Value::Object` (a BTreeMap)
        // both give.
        let data = serde_json::to_vec(&serde_json::Value::Object(object.into_iter().collect()))
            .unwrap_or_default();
        CapabilityDigest::sha256(&data)
    }

    /// `JSONEncoder` with `.sortedKeys` over the manifest.
    fn digest(manifest: &CovePluginManifest) -> String {
        let data = crate::swift_manifest_json::encode_sorted(manifest).unwrap_or_default();
        CapabilityDigest::sha256(&data)
    }

    fn schema_hashes(
        contracts: &[CapabilityContract],
    ) -> Result<BTreeMap<String, String>, PluginAuthorizationError> {
        let mut result: BTreeMap<String, String> = BTreeMap::new();
        for contract in contracts {
            if result
                .insert(contract.id.clone(), contract.schema_hash.clone())
                .is_some()
            {
                return Err(PluginAuthorizationError::DuplicateCapability(
                    contract.id.clone(),
                ));
            }
        }
        Ok(result)
    }
}

fn integer(value: i64) -> serde_json::Value {
    serde_json::Value::Number(value.into())
}

fn string_map(values: &BTreeMap<String, String>) -> serde_json::Value {
    serde_json::Value::Object(
        values
            .iter()
            .map(|(key, value)| (key.clone(), serde_json::Value::String(value.clone())))
            .collect(),
    )
}

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum PluginCapabilityRegistryError {
    #[error("plugin capability contract '{0}' does not match its authorised manifest")]
    InvalidContract(String),
    #[error("plugin '{0}' was enabled more than once")]
    DuplicatePlugin(String),
}

/// Editor-side immutable binding for one package that has been inspected,
/// authorised, and loaded into a particular PluginHost generation.
#[derive(Clone, Debug, PartialEq)]
pub struct PluginExecutionBinding {
    pub plugin_path: String,
    pub inspection: PluginInspection,
    pub authorization: PluginAuthorizationRecord,
    pub host_generation: u64,
}

impl PluginExecutionBinding {
    pub fn new(
        plugin_path: impl Into<String>,
        inspection: PluginInspection,
        authorization: PluginAuthorizationRecord,
        host_generation: u64,
    ) -> Result<Self, PluginAuthorizationError> {
        let plugin_path = plugin_path.into();
        if plugin_path.is_empty() || !authorization.is_still_valid(&inspection) {
            return Err(PluginAuthorizationError::NoLongerValid);
        }
        Ok(PluginExecutionBinding {
            plugin_path,
            inspection,
            authorization,
            host_generation,
        })
    }

    pub fn plugin_id(&self) -> &str {
        &self.inspection.manifest.id
    }

    pub fn authority(&self) -> PluginCapabilityAuthority {
        PluginCapabilityAuthority::new(
            self.plugin_id().to_string(),
            self.authorization.authority_digest(),
            self.host_generation,
        )
    }

    pub fn validate(&self, current_generation: u64) -> Result<(), PluginAuthorizationError> {
        if current_generation == self.host_generation
            && self.authorization.is_still_valid(&self.inspection)
        {
            Ok(())
        } else {
            Err(PluginAuthorizationError::NoLongerValid)
        }
    }
}

/// Converts authorised statically derived contracts into metadata-only Registry
/// descriptors. Plugin code never supplies an executable closure or mutation.
pub enum PluginCapabilityRegistryBuilder {}

impl PluginCapabilityRegistryBuilder {
    pub fn build(
        base: &CapabilityRegistry,
        bindings: &[PluginExecutionBinding],
        enabled_declarations: &[PluginInspection],
    ) -> Result<CapabilityRegistry, crate::PluginError> {
        let mut plugin_ids: BTreeSet<String> = BTreeSet::new();
        let mut descriptors: Vec<CapabilityDescriptor> = Vec::new();
        for binding in bindings {
            if !plugin_ids.insert(binding.plugin_id().to_string()) {
                return Err(PluginCapabilityRegistryError::DuplicatePlugin(
                    binding.plugin_id().to_string(),
                )
                .into());
            }
            binding.validate(binding.host_generation)?;
            let manifest = &binding.inspection.manifest;
            let prefix = format!("{}.", manifest.id);
            for contract in &binding.inspection.contracts {
                let id_ok = contract.id.starts_with(&prefix) && contract.id.len() > prefix.len();
                if !(id_ok
                    && contract.version == manifest.version
                    && contract.access == manifest.access
                    && contract.domain == "plugin"
                    && contract.release_phase == ReleasePhase::Stable
                    && contract.source
                        == diffuse_capability::capability_contract::CapabilitySource::plugin(
                            manifest.id.clone(),
                        )
                    && (!contract.access.is_write()
                        || contract.input_schema.is_strict_capability_input()))
                {
                    return Err(PluginCapabilityRegistryError::InvalidContract(
                        contract.id.clone(),
                    )
                    .into());
                }
                let mut descriptor = CapabilityDescriptor::new(contract.id.clone());
                descriptor.release_phase = contract.release_phase;
                descriptor.requires_confirmation = contract.access.is_write();
                descriptor.is_destructive = contract.access == CapabilityAccess::DestructiveWrite;
                descriptor.domain = contract.domain.clone();
                descriptor.version = contract.version;
                descriptor.title = contract.title.clone();
                descriptor.capability_description = contract.description.clone();
                descriptor.access = contract.access;
                descriptor.input_schema = contract.input_schema.clone();
                descriptor.source = contract.source.clone();
                descriptor.is_ai_exposed = manifest.exposes_to_ai(&contract.id[prefix.len()..]);
                descriptors.push(descriptor);
            }
        }
        let result = base.appending(&descriptors);
        result.validate_integrity()?;
        Self::validate_requirements(bindings, enabled_declarations, base)?;
        Ok(result)
    }

    /// Resolve in dependency order even when bindings arrive in another order. No
    /// progress means a missing/versioned dependency or a cycle: either way the
    /// entire registry is rejected before any executor is published.
    fn validate_requirements(
        bindings: &[PluginExecutionBinding],
        declarations: &[PluginInspection],
        base: &CapabilityRegistry,
    ) -> Result<(), crate::PluginError> {
        let mut remaining = bindings.to_vec();
        remaining.sort_by(|left, right| left.plugin_id().cmp(right.plugin_id()));
        // Runtime dependencies are activated first by PluginManager. Pure
        // declarations can satisfy package requirements without a binding.
        let mut plugins: BTreeMap<String, i64> = declarations
            .iter()
            .filter(|inspection| inspection.code_hash.is_none())
            .map(|inspection| (inspection.manifest.id.clone(), inspection.manifest.version))
            .collect();
        let mut capabilities: BTreeMap<String, i64> = base
            .all_verbs()
            .into_iter()
            .filter_map(|id| {
                base.descriptor(&id)
                    .map(|descriptor| (id.clone(), descriptor.version))
            })
            .collect();
        while !remaining.is_empty() {
            let index = remaining.iter().position(|binding| {
                PluginRequirementResolver::unmet(
                    &binding.inspection.manifest.requires,
                    binding.plugin_id(),
                    &plugins,
                    &capabilities,
                )
                .is_empty()
            });
            let Some(index) = index else {
                let binding = remaining[0].clone();
                return Err(UnmetPluginRequirements::new(
                    binding.plugin_id().to_string(),
                    PluginRequirementResolver::unmet(
                        &binding.inspection.manifest.requires,
                        binding.plugin_id(),
                        &plugins,
                        &capabilities,
                    ),
                )
                .into());
            };
            let binding = remaining.remove(index);
            plugins.insert(
                binding.plugin_id().to_string(),
                binding.inspection.manifest.version,
            );
            for contract in &binding.inspection.contracts {
                capabilities.insert(contract.id.clone(), contract.version);
            }
        }
        Ok(())
    }
}
