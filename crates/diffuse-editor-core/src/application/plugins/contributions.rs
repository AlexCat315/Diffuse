//! `Editor/Sources/EditorCore/Application/Plugins/Contributions.swift`.
//!
//! Registrations belong to the plugin manager; each domain reads its own
//! catalog snapshot.

use std::collections::BTreeSet;
use std::sync::Arc;

use diffuse_plugin::PluginError;
use diffuse_plugin::contract::plugin_manifest::PluginManifestValidationError;
use diffuse_plugin::contract::plugin_package::ValidatedPluginPackage;
use diffuse_plugin::contribution::ai::agent::AgentContributionPoint;
use diffuse_plugin::contribution::ai::context::AIContextContributionPoint;
use diffuse_plugin::contribution::ai::harness::AIHarnessContributionPoint;
use diffuse_plugin::contribution::ai::provider_point::AIProviderContributionPoint;
use diffuse_plugin::contribution::ai::tool::AIToolContributionPoint;
use diffuse_plugin::contribution::catalog::ContributionCatalog;
use diffuse_plugin::contribution::languages::language_point::LanguageContributionPoint;
use diffuse_plugin::contribution::processes::process_points::{
    TaskContributionPoint, VersionControlContributionPoint,
};
use diffuse_plugin::contribution::registrar::ContributionRegistrar;
use diffuse_plugin::contribution::registry::ContributionPointSpec;
use diffuse_plugin::contribution::services::{
    PluginExtensionContributionPoint, PluginExtensionPointContributionPoint,
    PluginServiceContributionPoint,
};
use diffuse_plugin::contribution::themes::descriptor::ThemeContributionPoint;
use diffuse_plugin::contribution::workbench::command::CommandContributionPoint;
use diffuse_plugin::contribution::workbench::document::DocumentViewContributionPoint;
use diffuse_plugin::contribution::workbench::panel::PanelContributionPoint;
use diffuse_plugin::contribution::workbench::placement::{
    MenuContributionPoint, ToolbarContributionPoint,
};
use diffuse_plugin::lifecycle::disposal::Registration;

use diffuse_capability::capability_contract::CapabilityAccess;

use crate::contributions::themes::theme_catalog::{EditorThemeCatalog, ThemeCatalogError};
use crate::contributions::workbench::contributed::ContributedPanel;
use crate::state::workspace::editor_workspace_profile::EditorWorkspaceProfile;

type PackageCatalog = Arc<ContributionCatalog<ValidatedPluginPackage>>;

pub struct PluginContributions {
    pub themes: EditorThemeCatalog,
    pub languages: PackageCatalog,
    pub providers: PackageCatalog,
    pub agents: PackageCatalog,
    pub tasks: PackageCatalog,
    pub version_control: PackageCatalog,
    pub commands: PackageCatalog,
    pub panels: PackageCatalog,
    pub menus: PackageCatalog,
    pub toolbar: PackageCatalog,
    pub document_views: PackageCatalog,
    pub contexts: PackageCatalog,
    pub harnesses: PackageCatalog,
    pub services: PackageCatalog,
    pub extension_points: PackageCatalog,
    pub extensions: PackageCatalog,
}

impl PluginContributions {
    pub fn new() -> Self {
        PluginContributions {
            themes: EditorThemeCatalog::new(),
            languages: Arc::new(ContributionCatalog::new()),
            providers: Arc::new(ContributionCatalog::new()),
            agents: Arc::new(ContributionCatalog::new()),
            tasks: Arc::new(ContributionCatalog::new()),
            version_control: Arc::new(ContributionCatalog::new()),
            commands: Arc::new(ContributionCatalog::new()),
            panels: Arc::new(ContributionCatalog::new()),
            menus: Arc::new(ContributionCatalog::new()),
            toolbar: Arc::new(ContributionCatalog::new()),
            document_views: Arc::new(ContributionCatalog::new()),
            contexts: Arc::new(ContributionCatalog::new()),
            harnesses: Arc::new(ContributionCatalog::new()),
            services: Arc::new(ContributionCatalog::new()),
            extension_points: Arc::new(ContributionCatalog::new()),
            extensions: Arc::new(ContributionCatalog::new()),
        }
    }

    /// Every catalog the workbench reads, in a fixed order.
    pub fn workbench(&self) -> Vec<PackageCatalog> {
        vec![
            self.commands.clone(),
            self.panels.clone(),
            self.menus.clone(),
            self.toolbar.clone(),
            self.document_views.clone(),
        ]
    }

    pub fn registrar(&self) -> Result<ContributionRegistrar, PluginManifestValidationError> {
        let mut registrar = ContributionRegistrar::new();

        {
            let themes = self.themes.clone();
            registrar.register::<ThemeContributionPoint, _>(move |_values, package| {
                EditorThemeCatalog::validate(package).map_err(plugin_error_from_theme)?;
                let registration = themes.register(package).map_err(plugin_error_from_theme)?;
                Ok(Arc::new(registration))
            })?;
        }
        {
            let languages = self.languages.clone();
            registrar.register::<LanguageContributionPoint, _>(move |values, package| {
                install::<LanguageContributionPoint>(&languages, package, values, |descriptor| {
                    descriptor.id.clone()
                })
            })?;
        }
        {
            let providers = self.providers.clone();
            registrar.register::<AIProviderContributionPoint, _>(move |values, package| {
                install::<AIProviderContributionPoint>(&providers, package, values, |descriptor| {
                    descriptor.id.clone()
                })
            })?;
        }
        {
            let agents = self.agents.clone();
            registrar.register::<AgentContributionPoint, _>(move |values, package| {
                install::<AgentContributionPoint>(&agents, package, values, |descriptor| {
                    descriptor.id.clone()
                })
            })?;
        }
        {
            let tasks = self.tasks.clone();
            registrar.register::<TaskContributionPoint, _>(move |values, package| {
                install::<TaskContributionPoint>(&tasks, package, values, |descriptor| {
                    descriptor.id.clone()
                })
            })?;
        }
        {
            let version_control = self.version_control.clone();
            registrar.register::<VersionControlContributionPoint, _>(move |values, package| {
                install::<VersionControlContributionPoint>(
                    &version_control,
                    package,
                    values,
                    |descriptor| descriptor.id.clone(),
                )
            })?;
        }
        // The editor shows only read results; a package that writes acts
        // through the approval pipeline, not through a command or panel.
        {
            let commands = self.commands.clone();
            registrar.register::<CommandContributionPoint, _>(move |_values, package| {
                if package.manifest.access != CapabilityAccess::Read {
                    return Err(PluginManifestValidationError::InvalidContribution(
                        CommandContributionPoint::ID.to_string(),
                    )
                    .into());
                }
                commands
                    .register(vec![package.clone()], &package.manifest.id)
                    .map_err(PluginError::from)
            })?;
        }
        {
            let panels = self.panels.clone();
            registrar.register::<PanelContributionPoint, _>(move |values, package| {
                let valid = values.iter().all(|panel| {
                    !EditorWorkspaceProfile::built_in_panel_ids().contains(&panel.id)
                        && ContributedPanel::new(&package.manifest.id, panel).is_some()
                        && (panel.entry_point.is_none()
                            || package.manifest.access == CapabilityAccess::Read)
                });
                if !valid {
                    return Err(PluginManifestValidationError::InvalidContribution(
                        PanelContributionPoint::ID.to_string(),
                    )
                    .into());
                }
                install::<PanelContributionPoint>(&panels, package, values, |descriptor| {
                    descriptor.id.clone()
                })
            })?;
        }
        // Menus and the toolbar only place the package's own commands.
        {
            let menus = self.menus.clone();
            registrar.register::<MenuContributionPoint, _>(move |values, package| {
                require_own_commands(
                    values.iter().map(|value| value.command.as_str()),
                    package,
                    MenuContributionPoint::ID,
                )?;
                menus
                    .register(vec![package.clone()], &package.manifest.id)
                    .map_err(PluginError::from)
            })?;
        }
        {
            let toolbar = self.toolbar.clone();
            registrar.register::<ToolbarContributionPoint, _>(move |values, package| {
                require_own_commands(
                    values.iter().map(|value| value.command.as_str()),
                    package,
                    ToolbarContributionPoint::ID,
                )?;
                toolbar
                    .register(vec![package.clone()], &package.manifest.id)
                    .map_err(PluginError::from)
            })?;
        }
        {
            let document_views = self.document_views.clone();
            registrar.register::<DocumentViewContributionPoint, _>(move |_values, package| {
                if package.manifest.access != CapabilityAccess::Read {
                    return Err(PluginManifestValidationError::InvalidContribution(
                        DocumentViewContributionPoint::ID.to_string(),
                    )
                    .into());
                }
                document_views
                    .register(vec![package.clone()], &package.manifest.id)
                    .map_err(PluginError::from)
            })?;
        }
        // Package context goes to the model provider with the request, so only
        // read packages may supply it.
        {
            let contexts = self.contexts.clone();
            registrar.register::<AIContextContributionPoint, _>(move |values, package| {
                if package.manifest.access != CapabilityAccess::Read {
                    return Err(PluginManifestValidationError::InvalidContribution(
                        AIContextContributionPoint::ID.to_string(),
                    )
                    .into());
                }
                install::<AIContextContributionPoint>(&contexts, package, values, |descriptor| {
                    descriptor.id.clone()
                })
            })?;
        }
        // A harness only decides steps; it needs no write access.
        {
            let harnesses = self.harnesses.clone();
            registrar.register::<AIHarnessContributionPoint, _>(move |values, package| {
                if package.manifest.access != CapabilityAccess::Read {
                    return Err(PluginManifestValidationError::InvalidContribution(
                        AIHarnessContributionPoint::ID.to_string(),
                    )
                    .into());
                }
                install::<AIHarnessContributionPoint>(&harnesses, package, values, |descriptor| {
                    descriptor.id.clone()
                })
            })?;
        }
        // Tools reach the model through the capability registry, which reads them
        // from the manifest; nothing else holds them.
        registrar.register::<AIToolContributionPoint, _>(|_values, _package| {
            Ok(Arc::new(Registration::new(|| {})))
        })?;
        {
            let services = self.services.clone();
            registrar.register::<PluginServiceContributionPoint, _>(move |values, package| {
                install::<PluginServiceContributionPoint>(
                    &services,
                    package,
                    values,
                    |descriptor| descriptor.id.clone(),
                )
            })?;
        }
        {
            let extension_points = self.extension_points.clone();
            registrar.register::<PluginExtensionPointContributionPoint, _>(
                move |values, package| {
                    install::<PluginExtensionPointContributionPoint>(
                        &extension_points,
                        package,
                        values,
                        |descriptor| descriptor.id.clone(),
                    )
                },
            )?;
        }
        {
            let extensions = self.extensions.clone();
            registrar.register::<PluginExtensionContributionPoint, _>(
                move |_values, package| {
                    extensions
                        .register(vec![package.clone()], &package.manifest.id)
                        .map_err(PluginError::from)
                },
            )?;
        }
        Ok(registrar)
    }
}

impl Default for PluginContributions {
    fn default() -> Self {
        Self::new()
    }
}

/// Swift's `ContributionCatalog where Value == ValidatedPluginPackage.install`.
fn install<Point: ContributionPointSpec>(
    catalog: &PackageCatalog,
    package: &ValidatedPluginPackage,
    values: &[Point::Descriptor],
    id: impl Fn(&Point::Descriptor) -> String,
) -> Result<Arc<Registration>, PluginError> {
    let claimed: BTreeSet<String> = catalog
        .snapshot()
        .values
        .iter()
        .flat_map(|contributed| {
            contributed
                .value
                .manifest
                .contributes
                .decode::<Point>()
                .unwrap_or_default()
        })
        .map(|descriptor| id(&descriptor))
        .collect();
    if values.iter().any(|value| claimed.contains(&id(value))) {
        return Err(
            PluginManifestValidationError::InvalidContribution(Point::ID.to_string()).into(),
        );
    }
    catalog
        .register(vec![package.clone()], &package.manifest.id)
        .map_err(PluginError::from)
}

fn require_own_commands<'a>(
    names: impl Iterator<Item = &'a str>,
    package: &ValidatedPluginPackage,
    point: &str,
) -> Result<(), PluginError> {
    let commands: BTreeSet<String> = package
        .manifest
        .contributes
        .decode::<CommandContributionPoint>()?
        .into_iter()
        .map(|descriptor| descriptor.id)
        .collect();
    if names.into_iter().all(|name| commands.contains(name)) {
        Ok(())
    } else {
        Err(PluginManifestValidationError::InvalidContribution(point.to_string()).into())
    }
}

/// Swift's registrar threw the theme's own error through a `throws` installer;
/// Rust's installer channel is `PluginError`, so a theme failure keeps its text
/// in an invalid-data I/O error when it is not already a plugin error.
fn plugin_error_from_theme(error: ThemeCatalogError) -> PluginError {
    match error {
        ThemeCatalogError::Plugin(error) => error,
        other => PluginError::Io(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            other.to_string(),
        )),
    }
}
