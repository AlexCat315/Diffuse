//! Package loading: the on-disk `.coveplugin` bundle and its validated view.
//!
//! Ported from `Engine/Sources/PluginRuntime/Contract/PluginPackage.swift`.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use diffuse_capability::capability_registry::CapabilityRegistry;
use diffuse_capability::release::sha256::CapabilityDigest;

use crate::PluginError;
use crate::contract::bun_plugin_contract::BunPluginContract;
use crate::contract::plugin_contract::{PluginContract, PluginContractError};
use crate::contract::plugin_manifest::{
    CovePluginManifest, PluginManifestValidationError, PluginManifestValidator,
};
use crate::contract::resources::{
    PluginPackageResources, last_path_component, path_extension, standardized,
};
use crate::contribution::registry::ContributionPointRegistry;
use crate::contribution::themes::descriptor::ThemeContributionPoint;
use crate::pattern::lower_dot;

#[derive(Clone, Debug, PartialEq)]
pub struct ValidatedPluginPackage {
    pub root_url: PathBuf,
    pub manifest: CovePluginManifest,
    pub runtime: Option<ValidatedPluginRuntime>,
    pub resource_hashes: BTreeMap<String, String>,
}

impl ValidatedPluginPackage {
    /// A package with no runtime, as `ValidatedPluginPackage(rootURL:manifest:runtime:)`
    /// built for declaration-only packages.
    pub fn new(
        root_url: PathBuf,
        manifest: CovePluginManifest,
        runtime: Option<ValidatedPluginRuntime>,
    ) -> Self {
        ValidatedPluginPackage {
            root_url,
            manifest,
            runtime,
            resource_hashes: BTreeMap::new(),
        }
    }

    pub fn require_runtime(&self) -> Result<&ValidatedPluginRuntime, PluginPackageError> {
        self.runtime
            .as_ref()
            .ok_or(PluginPackageError::RuntimeRequired)
    }

    pub fn resource(&self, path: &str) -> Result<Vec<u8>, PluginError> {
        let data = PluginPackageResources::read(path, &self.root_url)?;
        if self.resource_hashes.get(path) != Some(&CapabilityDigest::sha256(&data)) {
            return Err(
                crate::plugin_authorization::PluginAuthorizationError::NoLongerValid.into(),
            );
        }
        Ok(data)
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct ValidatedPluginRuntime {
    pub entry_url: PathBuf,
    pub contract_url: PathBuf,
    pub contract: PluginContract,
    pub code_hash: String,
    pub contract_hash: String,
}

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum PluginPackageError {
    #[error("plugin package must end in .coveplugin")]
    InvalidExtension,
    #[error("plugin package is not a directory")]
    PackageNotDirectory,
    #[error("plugin package is missing {0}")]
    MissingFile(String),
    #[error("symbolic links are not allowed for {0}")]
    SymbolicLinkNotAllowed(String),
    #[error("plugin.js exceeds the package size limit")]
    ComponentTooLarge,
    #[error("plugin.js must contain UTF-8 JavaScript")]
    InvalidComponentHeader,
    #[error("unexpected file in plugin package: {0}")]
    UnexpectedFile(String),
    #[error("plugin.js and capabilities.json must both be present")]
    IncompleteRuntime,
    #[error("this operation requires a plugin runtime")]
    RuntimeRequired,
    #[error("invalid plugin resource: {0}")]
    InvalidResource(String),
}

#[derive(Clone, Debug)]
pub struct PluginPackageLoader {
    pub registry: CapabilityRegistry,
    pub maximum_code_bytes: usize,
    contribution_points: ContributionPointRegistry,
}

impl PluginPackageLoader {
    pub fn new(
        registry: CapabilityRegistry,
        maximum_code_bytes: Option<usize>,
        contribution_points: ContributionPointRegistry,
    ) -> Self {
        PluginPackageLoader {
            registry,
            maximum_code_bytes: maximum_code_bytes
                .unwrap_or(128 * 1_024 * 1_024)
                .min(128 * 1_024 * 1_024),
            contribution_points,
        }
    }

    pub fn load(&self, package_url: &Path) -> Result<ValidatedPluginPackage, PluginError> {
        let root = standardized(package_url);
        if path_extension(&root).as_deref() != Some("coveplugin") {
            return Err(PluginPackageError::InvalidExtension.into());
        }
        if !root.is_dir() {
            return Err(PluginPackageError::PackageNotDirectory.into());
        }
        if is_link(&root) {
            return Err(
                PluginPackageError::SymbolicLinkNotAllowed(last_path_component(&root)).into(),
            );
        }
        let allowed: BTreeSet<&str> =
            ["plugin.json", "plugin.js", "capabilities.json", "resources"]
                .into_iter()
                .collect();
        let children =
            std::fs::read_dir(&root).map_err(|_| PluginPackageError::PackageNotDirectory)?;
        let mut child_names: BTreeSet<String> = BTreeSet::new();
        for child in children {
            let child = child.map_err(|_| PluginPackageError::PackageNotDirectory)?;
            let name = child.file_name().to_string_lossy().into_owned();
            if !allowed.contains(name.as_str()) {
                return Err(PluginPackageError::UnexpectedFile(name).into());
            }
            child_names.insert(name);
        }

        let manifest_url = self.fixed_file("plugin.json", &root)?;
        let manifest_data = std::fs::read(&manifest_url)
            .map_err(|_| PluginPackageError::MissingFile("plugin.json".to_string()))?;
        let manifest = PluginManifestValidator::decode_and_validate(
            &manifest_data,
            &self.registry,
            &self.contribution_points,
        )?;
        let resources = PluginPackageResources::load(&manifest.resources, &root)?;
        for theme in manifest.contributes.decode::<ThemeContributionPoint>()? {
            if !manifest
                .resources
                .iter()
                .any(|resource| resource.path == theme.path && resource.kind == "theme")
            {
                return Err(PluginPackageError::InvalidResource(theme.path).into());
            }
        }
        let has_component = child_names.contains("plugin.js");
        if has_component != child_names.contains("capabilities.json") {
            return Err(PluginPackageError::IncompleteRuntime.into());
        }
        if !has_component {
            if !(manifest.runtime.is_none()
                && manifest.imports.is_empty()
                && manifest.host.processes.is_empty()
                && manifest.composable_host_capabilities.is_empty()
                && manifest.activation.is_empty()
                && manifest.access
                    == diffuse_capability::capability_contract::CapabilityAccess::Read)
            {
                return Err(PluginPackageError::RuntimeRequired.into());
            }
            manifest
                .contributes
                .validate_runtime(None, &self.contribution_points)?;
            return Ok(ValidatedPluginPackage {
                root_url: root,
                manifest,
                runtime: None,
                resource_hashes: resources,
            });
        }
        if manifest.runtime.is_none() {
            return Err(PluginPackageError::RuntimeRequired.into());
        }
        let entry_url = self.fixed_file("plugin.js", &root)?;
        let contract_url = self.fixed_file("capabilities.json", &root)?;
        let component_data = std::fs::read(&entry_url)
            .map_err(|_| PluginPackageError::MissingFile("plugin.js".to_string()))?;
        if component_data.len() > self.maximum_code_bytes {
            return Err(PluginPackageError::ComponentTooLarge.into());
        }
        if component_data.is_empty() || std::str::from_utf8(&component_data).is_err() {
            return Err(PluginPackageError::InvalidComponentHeader.into());
        }
        let wit_data = std::fs::read(&contract_url)
            .map_err(|_| PluginPackageError::MissingFile("capabilities.json".to_string()))?;
        let wit = BunPluginContract::decode(&wit_data, &manifest.imports)?;
        let entry_points = manifest.host.entry_points();
        let declared: BTreeSet<String> = wit
            .capability_inputs
            .iter()
            .map(|input| input.name.clone())
            .collect();
        if !entry_points.is_subset(&declared) {
            return Err(PluginManifestValidationError::InvalidHostPermissions.into());
        }
        manifest
            .contributes
            .validate_runtime(Some(&wit), &self.contribution_points)?;
        for input in &wit.capability_inputs {
            let capability_id = format!("{}.{}", manifest.id, input.name);
            if !lower_dot(&capability_id, 3, 128) {
                return Err(PluginContractError::InvalidCapabilityName(capability_id).into());
            }
        }
        Ok(ValidatedPluginPackage {
            root_url: root,
            manifest,
            runtime: Some(ValidatedPluginRuntime {
                entry_url,
                contract_url,
                contract: wit,
                code_hash: CapabilityDigest::sha256(&component_data),
                contract_hash: CapabilityDigest::sha256(&wit_data),
            }),
            resource_hashes: resources,
        })
    }

    fn fixed_file(&self, name: &str, root: &Path) -> Result<PathBuf, PluginPackageError> {
        let url = standardized(&root.join(name));
        let parent = url.parent().unwrap_or(root);
        // Swift required `PathIdentity.sameLocation(url.deletingLastPathComponent(), root)`.
        if !same_location(parent, root) {
            return Err(PluginPackageError::MissingFile(name.to_string()));
        }
        if is_link(&url) {
            return Err(PluginPackageError::SymbolicLinkNotAllowed(name.to_string()));
        }
        if !url.is_file() {
            return Err(PluginPackageError::MissingFile(name.to_string()));
        }
        Ok(url)
    }
}

fn is_link(path: &Path) -> bool {
    std::fs::symlink_metadata(path).is_ok_and(|metadata| metadata.file_type().is_symlink())
}

/// `PathIdentity.sameLocation`.
fn same_location(lhs: &Path, rhs: &Path) -> bool {
    cove_system::paths::PathIdentity::same_location(lhs, rhs)
}
