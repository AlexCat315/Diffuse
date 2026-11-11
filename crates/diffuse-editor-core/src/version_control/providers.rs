//! `Editor/Sources/EditorCore/VersionControl/Providers.swift`.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use cove_system::paths::PathIdentity;
use diffuse_capability::capability_registry::CapabilityRegistry;
use diffuse_plugin::contract::host_permissions::PluginProcessPermission;
use diffuse_plugin::contract::plugin_manifest::CovePluginManifest;
use diffuse_plugin::contract::plugin_package::{PluginPackageLoader, ValidatedPluginPackage};
use diffuse_plugin::contribution::processes::process_points::VersionControlContributionPoint;
use diffuse_plugin::contribution::processes::systems::VersionControlContribution;
use diffuse_plugin::contribution::registry::ContributionPointRegistry;

use crate::application::plugins::bundled::{BundledPluginHost, BundledPlugins};
use crate::contributions::host::{StepError, StepPlugins, StepProvider};
use crate::contributions::tool::ContributionTool;
use crate::version_control::backend::{VersionControlBackend, VersionControlError};
use crate::version_control::model::{VersionControlRepository, VersionControlSystem};
use crate::version_control::operations::PluginBackend;

/// A bundled version control plugin and what its manifest contributes: the
/// system, the marker that finds its working trees and the command it runs.
#[derive(Clone, Debug)]
pub struct VersionControlProvider {
    pub system: VersionControlSystem,
    pub manifest: CovePluginManifest,
    pub contribution: VersionControlContribution,
    pub package: PathBuf,
    pub process: PluginProcessPermission,
}

impl VersionControlProvider {
    pub fn plugin_id(&self) -> &str {
        &self.manifest.id
    }

    /// In detection order: when one folder holds several markers, the higher
    /// `priority` wins (Lore over Git: it is the deliberate choice for assets).
    pub fn bundled() -> &'static [VersionControlProvider] {
        static BUNDLED: OnceLock<Vec<VersionControlProvider>> = OnceLock::new();
        BUNDLED.get_or_init(|| {
            let loader = PluginPackageLoader::new(
                CapabilityRegistry::default(),
                None,
                ContributionPointRegistry::standard(),
            );
            let mut providers: Vec<VersionControlProvider> = BundledPlugins::catalog()
                .iter()
                .filter_map(|plugin| {
                    let BundledPluginHost::VersionControl(system) = &plugin.host else {
                        return None;
                    };
                    let system = VersionControlSystem::new(system.clone())?;
                    let package = loader.load(&plugin.package).ok()?;
                    let contribution = package
                        .manifest
                        .contributes
                        .decode_lossy::<VersionControlContributionPoint>()
                        .into_iter()
                        .next()?;
                    let process = package.manifest.host.processes.first()?.clone();
                    Some(VersionControlProvider {
                        system,
                        manifest: package.manifest.clone(),
                        contribution,
                        package: package.root_url,
                        process,
                    })
                })
                .collect();
            providers.sort_by(|lhs, rhs| {
                rhs.contribution
                    .priority
                    .unwrap_or(0)
                    .cmp(&lhs.contribution.priority.unwrap_or(0))
            });
            providers
        })
    }

    pub fn registered(packages: &[ValidatedPluginPackage]) -> Vec<VersionControlProvider> {
        let mut providers: Vec<VersionControlProvider> = packages
            .iter()
            .flat_map(|package| {
                package
                    .manifest
                    .contributes
                    .decode_lossy::<VersionControlContributionPoint>()
                    .into_iter()
                    .filter_map(|contribution| {
                        let system = VersionControlSystem::new(contribution.id.clone())?;
                        let process = package.manifest.host.processes.first()?.clone();
                        Some(VersionControlProvider {
                            system,
                            manifest: package.manifest.clone(),
                            contribution,
                            package: package.root_url.clone(),
                            process,
                        })
                    })
                    .collect::<Vec<_>>()
            })
            .collect();
        providers.sort_by(|lhs, rhs| {
            rhs.contribution
                .priority
                .unwrap_or(0)
                .cmp(&lhs.contribution.priority.unwrap_or(0))
        });
        providers
    }

    pub fn provider_for(system: &VersionControlSystem) -> Option<VersionControlProvider> {
        Self::bundled()
            .iter()
            .find(|provider| &provider.system == system)
            .cloned()
    }

    pub fn step(&self) -> StepProvider {
        StepProvider {
            plugin_id: self.plugin_id().to_string(),
            title: self.contribution.title.clone(),
            package: self.package.clone(),
            entry_point: VersionControlContribution::ENTRY_POINT.to_string(),
            activation_event: format!("onCommand:{}", self.contribution.id),
            process: self.process.clone(),
        }
    }

    /// The nearest working tree containing `directory` of a system not
    /// `excluding`; `among` defaults to the bundled providers.
    pub fn repository_containing(
        directory: &Path,
        disabled: &BTreeSet<VersionControlSystem>,
        available: Option<&[VersionControlProvider]>,
    ) -> Option<VersionControlRepository> {
        let bundled = Self::bundled();
        let available = available.unwrap_or(bundled);
        let providers: Vec<&VersionControlProvider> = available
            .iter()
            .filter(|provider| !disabled.contains(&provider.system))
            .collect();
        let current = PathIdentity::canonical_url(directory);
        for ancestor in PathIdentity::ancestors(&current) {
            // `.git` is a file inside worktrees and submodules.
            for provider in &providers {
                if ancestor.join(&provider.contribution.marker).exists() {
                    return Some(VersionControlRepository::new(
                        provider.system.clone(),
                        ancestor.clone(),
                    ));
                }
            }
        }
        None
    }

    /// The all-default form of [`Self::repository_containing`].
    pub fn repository_containing_default(directory: &Path) -> Option<VersionControlRepository> {
        Self::repository_containing(directory, &BTreeSet::new(), None)
    }
}

impl StepPlugins {
    /// Systems whose command-line tool is installed.
    pub fn installed_systems(&self) -> BTreeSet<VersionControlSystem> {
        self.runtime
            .version_control_providers()
            .iter()
            .filter(|provider| {
                ContributionTool::locate_with_process_environment(&provider.process.command)
                    .is_some()
            })
            .map(|provider| provider.system.clone())
            .collect()
    }

    pub fn backend(
        &self,
        repository: &VersionControlRepository,
    ) -> Result<Box<dyn VersionControlBackend>, VersionControlError> {
        let plugin = self.plugin_for(&repository.system, &repository.root)?;
        Ok(Box::new(PluginBackend {
            repository: repository.clone(),
            plugin,
        }))
    }

    /// The plugin for `system`, running its commands in `workspace`.
    pub fn plugin_for(
        &self,
        system: &VersionControlSystem,
        workspace: &Path,
    ) -> Result<crate::contributions::host::StepPlugin, VersionControlError> {
        let Some(provider) = self
            .runtime
            .version_control_providers()
            .into_iter()
            .find(|provider| &provider.system == system)
        else {
            return Err(VersionControlError::Unsupported(format!(
                "The {} plugin is missing from this build.",
                system.raw_value()
            )));
        };
        match self.plugin(&provider.step(), workspace) {
            Ok(plugin) => Ok(plugin),
            Err(StepError::ToolMissing(_)) => Err(VersionControlError::ToolMissing(system.clone())),
            Err(error) => Err(error.into()),
        }
    }
}
