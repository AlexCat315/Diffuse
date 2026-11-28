//! `Editor/Sources/EditorCore/Application/Plugins/Bundled.swift`.
//!
//! A plugin that ships in the editor's resources. Each is found by listing
//! `Resources/Plugins`; its manifest decides where it runs.
//!
//! The application registers enabled packages and projects their contributed catalogs.

use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use cove_system::atomic_file::AtomicFile;
use cove_system::files::Access;
use diffuse_capability::capability_registry::CapabilityRegistry;
use diffuse_plugin::contract::plugin_manifest::CovePluginManifest;
use diffuse_plugin::contract::plugin_package::PluginPackageLoader;
use diffuse_plugin::contribution::processes::process_points::VersionControlContributionPoint;
use diffuse_plugin::contribution::registry::ContributionPointRegistry;

use crate::contributions::categories::PluginCategory;
use crate::editor_core_resource_bundle::EditorCoreResourceBundle;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum BundledPluginHost {
    /// Loaded into the shared plugin host, beside plugins the user adds.
    Application,
    /// Declarative package with no executable entry: registered in-process.
    Declarative,
    /// Contributes a version control system.
    VersionControl(String),
}

/// A plugin that ships in the editor's resources.
#[derive(Clone, Debug)]
pub struct BundledPlugin {
    pub id: String,
    pub name: String,
    pub description: String,
    pub version: i64,
    pub access: String,
    pub host: BundledPluginHost,
    /// Command-line tools its process permissions run.
    pub commands: Vec<String>,
    pub(crate) package: PathBuf,
    pub(crate) manifest: CovePluginManifest,
}

impl BundledPlugin {
    pub fn categories(&self) -> Vec<PluginCategory> {
        PluginCategory::categories(
            &self.manifest.contributes.point_ids(),
            !matches!(self.host, BundledPluginHost::Declarative),
        )
    }
}

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum BundledPluginsError {
    /// Swift's `throws` rethrew `FileManager` errors; only their description
    /// survives across the boundary, so the variant carries the message.
    #[error("{0}")]
    Io(String),
    #[error("{0}")]
    Decode(String),
}

impl From<std::io::Error> for BundledPluginsError {
    fn from(error: std::io::Error) -> Self {
        BundledPluginsError::Io(error.to_string())
    }
}

impl From<serde_json::Error> for BundledPluginsError {
    fn from(error: serde_json::Error) -> Self {
        BundledPluginsError::Decode(error.to_string())
    }
}

pub struct BundledPlugins;

impl BundledPlugins {
    /// Every package in `Resources/Plugins` whose manifest is valid.
    pub fn catalog() -> &'static [BundledPlugin] {
        static CATALOG: OnceLock<Vec<BundledPlugin>> = OnceLock::new();
        CATALOG.get_or_init(load_catalog)
    }

    pub fn plugin(id: &str) -> Option<&'static BundledPlugin> {
        Self::catalog().iter().find(|plugin| plugin.id == id)
    }

    pub fn disabled(
        project: &Path,
        application_wide: bool,
    ) -> Result<BTreeSet<String>, BundledPluginsError> {
        let url = preferences(project, application_wide);
        if !url.is_file() {
            return Ok(BTreeSet::new());
        }
        let data = fs::read(&url)?;
        Ok(serde_json::from_slice::<BTreeSet<String>>(&data)?)
    }

    /// Swift's `applicationWide: Bool = false` default.
    pub fn disabled_with_default(project: &Path) -> Result<BTreeSet<String>, BundledPluginsError> {
        Self::disabled(project, false)
    }

    pub fn set_enabled(
        enabled: bool,
        id: &str,
        project: &Path,
        application_wide: bool,
    ) -> Result<(), BundledPluginsError> {
        let mut disabled = Self::disabled(project, application_wide)?;
        if enabled {
            disabled.remove(id);
        } else {
            disabled.insert(id.to_string());
        }
        let url = preferences(project, application_wide);
        if let Some(directory) = url.parent() {
            fs::create_dir_all(directory)?;
        }
        let data = serde_json::to_vec(&disabled)?;
        AtomicFile::write(&data, &url, Access::Inherit)?;
        Ok(())
    }

    /// Swift's `applicationWide: Bool = false` default.
    pub fn set_enabled_with_default(
        enabled: bool,
        id: &str,
        project: &Path,
    ) -> Result<(), BundledPluginsError> {
        Self::set_enabled(enabled, id, project, false)
    }
}

fn load_catalog() -> Vec<BundledPlugin> {
    let Some(bundle) = EditorCoreResourceBundle::bundle_if_available() else {
        return Vec::new();
    };
    let root = bundle.root().join("Plugins");
    let Ok(entries) = fs::read_dir(&root) else {
        return Vec::new();
    };
    let mut packages: Vec<PathBuf> = entries
        .flatten()
        .map(|entry| entry.path())
        .filter(|package| {
            package.extension().and_then(|value| value.to_str()) == Some("coveplugin")
        })
        .collect();
    packages.sort_by(|left, right| {
        left.file_name()
            .unwrap_or_default()
            .cmp(right.file_name().unwrap_or_default())
    });
    let loader = PluginPackageLoader::new(
        CapabilityRegistry::default(),
        None,
        ContributionPointRegistry::standard(),
    );
    packages
        .into_iter()
        .filter_map(|package| {
            let validated = loader.load(&package).ok()?;
            let manifest = &validated.manifest;
            let host = match manifest
                .contributes
                .decode::<VersionControlContributionPoint>()
                .unwrap_or_default()
                .into_iter()
                .next()
            {
                Some(contribution) => {
                    BundledPluginHost::VersionControl(version_control_system(&contribution.id)?)
                }
                None if validated.runtime.is_none() => BundledPluginHost::Declarative,
                None => BundledPluginHost::Application,
            };
            Some(BundledPlugin {
                id: manifest.id.clone(),
                name: manifest.name.clone(),
                description: manifest.description.clone(),
                version: manifest.version,
                access: manifest.access.raw_value().to_string(),
                host,
                commands: manifest
                    .host
                    .processes
                    .iter()
                    .map(|process| process.command.clone())
                    .collect(),
                package,
                manifest: manifest.clone(),
            })
        })
        .collect()
}

/// `VersionControlSystem(rawValue:)`'s `^[a-z][a-z0-9-]{0,31}$` check, kept
/// here until `version_control/model.rs` supplies the typed value.
fn version_control_system(value: &str) -> Option<String> {
    let mut characters = value.chars();
    let first = characters.next()?;
    if !first.is_ascii_lowercase() {
        return None;
    }
    let mut length = 1;
    for character in characters {
        if !(character.is_ascii_lowercase() || character.is_ascii_digit() || character == '-') {
            return None;
        }
        length += 1;
        if length > 32 {
            return None;
        }
    }
    Some(value.to_string())
}

fn preferences(project: &Path, application_wide: bool) -> PathBuf {
    if !application_wide {
        return project.join(".cove").join("disabled_bundled_plugins.json");
    }
    application_support_directory()
        .join("Diffuse")
        .join("disabled_bundled_plugins.json")
}

/// `FileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]`.
fn application_support_directory() -> PathBuf {
    #[cfg(target_os = "macos")]
    {
        std::env::var_os("HOME")
            .map(PathBuf::from)
            .unwrap_or_else(std::env::temp_dir)
            .join("Library")
            .join("Application Support")
    }
    #[cfg(target_os = "windows")]
    {
        std::env::var_os("APPDATA")
            .map(PathBuf::from)
            .unwrap_or_else(std::env::temp_dir)
    }
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    {
        std::env::var_os("XDG_DATA_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| {
                std::env::var_os("HOME")
                    .map(PathBuf::from)
                    .unwrap_or_else(std::env::temp_dir)
                    .join(".local")
                    .join("share")
            })
    }
}

impl crate::application::editor_application::EditorApplication {
    pub(super) fn refresh_contribution_snapshots(&self) {
        use crate::contributions::agents::AgentCatalog;
        use crate::contributions::ai_providers::AIProviderCatalog;
        use crate::contributions::languages::LanguageCatalog;
        use crate::state::editor_reducer::EditorAction;

        let contributions = &self.plugin_session.contributions;
        let themes = contributions.themes.snapshot();
        let providers = contributions.providers.snapshot();
        let languages = contributions.languages.snapshot();
        let agents = contributions.agents.snapshot();
        let mut state = self.plugin_session.state();
        let themes_changed = state.theme_revision != Some(themes.revision);
        state.theme_revision = Some(themes.revision);
        if state.provider_revision != Some(providers.revision) {
            state.providers = AIProviderCatalog::new(
                providers
                    .values
                    .into_iter()
                    .map(|item| item.value)
                    .collect(),
            );
            state.provider_revision = Some(providers.revision);
        }
        if state.language_revision != Some(languages.revision) {
            state.languages = LanguageCatalog::from_packages(
                languages
                    .values
                    .into_iter()
                    .map(|item| item.value)
                    .collect(),
            );
            state.language_revision = Some(languages.revision);
        }
        if state.agent_revision != Some(agents.revision) {
            state.agents = AgentCatalog::from_packages(
                agents.values.into_iter().map(|item| item.value).collect(),
            );
            state.agent_revision = Some(agents.revision);
        }
        drop(state);
        if themes_changed {
            self.store.dispatch(EditorAction::ThemeCatalogChanged);
        }
        let snapshots = contributions
            .workbench()
            .iter()
            .map(|catalog| catalog.snapshot())
            .collect::<Vec<_>>();
        self.plugin_session.editor.workbench.update(&snapshots);
        self.request_display_refresh();
    }
}

impl crate::application::editor_application::EditorApplication {
    pub fn bundled_plugins(&self) -> &'static [BundledPlugin] {
        BundledPlugins::catalog()
    }

    pub fn is_bundled_plugin_enabled(&self, plugin: &BundledPlugin) -> bool {
        self.enabled_plugin_manifests().contains_key(&plugin.id)
    }

    /// Registers declarative packages and mounts runtime packages on startup.
    pub fn enable_bundled_plugins(self: &std::rc::Rc<Self>) {
        use crate::state::editor_state::EditorConsoleSeverity;
        use diffuse_capability::support::swift_date::SwiftDate;
        use diffuse_plugin::plugin_authorization::{
            PluginAuthorizationRecord, PluginContractDeriver,
        };

        let mut state = self.plugin_session.state();
        if state.bundled_started || !self.is_active() {
            return;
        }
        state.bundled_started = true;
        drop(state);

        let application_wide = self.plugin_session.editor.peers.borrow().is_some();
        let disabled =
            BundledPlugins::disabled(Path::new(&self.project_directory), application_wide)
                .unwrap_or_default();
        let loader = PluginPackageLoader::new(
            CapabilityRegistry::default(),
            None,
            ContributionPointRegistry::standard(),
        );
        for plugin in BundledPlugins::catalog()
            .iter()
            .filter(|plugin| !disabled.contains(&plugin.id))
        {
            let enable = || -> Result<(), super::plugins::PluginLifecycleError> {
                if self.is_bundled_plugin_enabled(plugin) {
                    return Ok(());
                }
                let package = loader.load(&plugin.package)?;
                if package.manifest.id != plugin.id {
                    return Err(diffuse_plugin::plugin_authorization::PluginAuthorizationError::NoLongerValid.into());
                }
                let authorization = PluginAuthorizationRecord::from_package(
                    &package,
                    PluginContractDeriver::contracts(&package),
                    SwiftDate::now(),
                )?;
                self.enable_plugin(&plugin.package, &authorization)?;
                Ok(())
            };
            if let Err(error) = enable() {
                self.log_console(
                    &format!("{} could not start", plugin.name),
                    EditorConsoleSeverity::Warning,
                    Some(error.to_string()),
                    None,
                    None,
                );
            }
        }
        if let Err(error) = self.activate_plugins("onStartup") {
            self.log_console(
                "Plugin startup failed",
                EditorConsoleSeverity::Warning,
                Some(error.to_string()),
                None,
                None,
            );
        }
        self.workstation.version_control.refresh();
        self.workstation.tasks.refresh();
    }
}
