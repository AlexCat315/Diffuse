//! `Editor/Sources/EditorCore/Contributions/Themes/ThemeCatalog.swift`.
//!
//! Packages register their themes here; the catalog keeps the last registered
//! generation per package so a reload cannot revoke a newer registration.

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex, OnceLock};

use cove_ui_compose::theme::Theme;
use diffuse_capability::capability_registry::CapabilityRegistry;
use diffuse_capability::support::disposal::Registration;
use diffuse_plugin::Uuid;
use diffuse_plugin::contract::plugin_package::{PluginPackageLoader, ValidatedPluginPackage};
use diffuse_plugin::contribution::registry::ContributionPointRegistry;
use diffuse_plugin::contribution::themes::descriptor::ThemeContributionPoint;

use super::theme_resource::{ThemeResource, ThemeResourceError};
use crate::application::plugins::bundled::BundledPlugins;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EditorThemeDescriptor {
    pub id: String,
    pub title: String,
    pub appearance: String,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ThemeCatalogSnapshot {
    pub revision: u64,
    pub themes: Vec<EditorThemeDescriptor>,
}

#[derive(Debug, thiserror::Error)]
pub enum ThemeCatalogError {
    #[error("{0}")]
    Resource(#[from] ThemeResourceError),
    #[error("{0}")]
    Plugin(#[from] diffuse_plugin::PluginError),
    #[error("{0}")]
    Decode(#[from] serde_json::Error),
}

#[derive(Clone, Debug)]
struct Entry {
    descriptor: EditorThemeDescriptor,
    resource: ThemeResource,
}

#[derive(Clone, Debug)]
struct PackageThemes {
    generation: Uuid,
    entries: Vec<Entry>,
}

#[derive(Debug, Default)]
struct CatalogState {
    packages: BTreeMap<String, PackageThemes>,
    revision: u64,
}

/// Swift declared this as a `final class`; clones share the package table.
#[derive(Clone, Debug, Default)]
pub struct EditorThemeCatalog {
    state: Arc<Mutex<CatalogState>>,
}

impl EditorThemeCatalog {
    pub const DEFAULT_THEME_ID: &'static str = "studio.theme.default";

    pub fn new() -> Self {
        Self::default()
    }

    /// Bundled packages are decoded once; a package that fails to load or
    /// decode contributes no themes rather than blocking the catalog.
    fn bundled() -> &'static [Entry] {
        static BUNDLED: OnceLock<Vec<Entry>> = OnceLock::new();
        BUNDLED.get_or_init(|| {
            let loader = PluginPackageLoader::new(
                CapabilityRegistry::default(),
                None,
                ContributionPointRegistry::standard(),
            );
            BundledPlugins::catalog()
                .iter()
                .flat_map(|plugin| match loader.load(&plugin.package) {
                    Ok(package) => Self::decode(&package).unwrap_or_default(),
                    Err(_) => Vec::new(),
                })
                .collect()
        })
    }

    pub fn validate(package: &ValidatedPluginPackage) -> Result<(), ThemeCatalogError> {
        Self::decode(package).map(|_| ())
    }

    pub fn register(
        &self,
        package: &ValidatedPluginPackage,
    ) -> Result<Registration, ThemeCatalogError> {
        let entries = Self::decode(package)?;
        let id = package.manifest.id.clone();
        let generation = Uuid::new();
        {
            let mut state = self.state.lock().unwrap_or_else(|error| error.into_inner());
            let claimed: std::collections::BTreeSet<String> = state
                .packages
                .values()
                .flat_map(|package| package.entries.iter())
                .map(|entry| entry.descriptor.id.clone())
                .collect();
            if state.packages.contains_key(&id)
                || entries
                    .iter()
                    .any(|entry| claimed.contains(&entry.descriptor.id))
            {
                return Err(ThemeResourceError::InvalidToken(id).into());
            }
            state.packages.insert(
                id.clone(),
                PackageThemes {
                    generation: generation.clone(),
                    entries,
                },
            );
            state.revision = state.revision.wrapping_add(1);
        }
        let weak = Arc::downgrade(&self.state);
        Ok(Registration::new(move || {
            let Some(state) = weak.upgrade() else {
                return;
            };
            let mut state = state.lock().unwrap_or_else(|error| error.into_inner());
            let is_current = state
                .packages
                .get(&id)
                .is_some_and(|package| package.generation == generation);
            if is_current {
                state.packages.remove(&id);
                state.revision = state.revision.wrapping_add(1);
            }
        }))
    }

    pub fn snapshot(&self) -> ThemeCatalogSnapshot {
        let state = self.state.lock().unwrap_or_else(|error| error.into_inner());
        ThemeCatalogSnapshot {
            revision: state.revision,
            themes: Self::entries(&state)
                .into_iter()
                .map(|entry| entry.descriptor.clone())
                .collect(),
        }
    }

    pub fn theme(&self, id: &str, dark: bool) -> Theme {
        let entry = {
            let state = self.state.lock().unwrap_or_else(|error| error.into_inner());
            Self::entries(&state)
                .into_iter()
                .find(|entry| entry.descriptor.id == id)
                .cloned()
        };
        let variant = entry.and_then(|entry| {
            if dark {
                entry.resource.dark
            } else {
                entry.resource.light
            }
        });
        // Before the theme package registers — and when it is switched off —
        // the default palette is already available.
        variant
            .and_then(|variant| variant.make(dark).ok())
            .unwrap_or_else(|| Self::bundled_theme(Self::DEFAULT_THEME_ID, dark))
    }

    pub fn bundled_theme(id: &str, dark: bool) -> Theme {
        let entry = Self::bundled()
            .iter()
            .find(|entry| entry.descriptor.id == id);
        let variant = entry.and_then(|entry| {
            if dark {
                entry.resource.dark.clone()
            } else {
                entry.resource.light.clone()
            }
        });
        variant
            .and_then(|variant| variant.make(dark).ok())
            .unwrap_or_else(|| {
                if dark {
                    Theme::default_dark()
                } else {
                    Theme::default_light()
                }
            })
    }

    fn entries(state: &CatalogState) -> Vec<&Entry> {
        state
            .packages
            .values()
            .flat_map(|package| package.entries.iter())
            .collect()
    }

    fn decode(package: &ValidatedPluginPackage) -> Result<Vec<Entry>, ThemeCatalogError> {
        let mut entries = Vec::new();
        for contribution in package
            .manifest
            .contributes
            .decode::<ThemeContributionPoint>()?
        {
            let data = package.resource(&contribution.path)?;
            let resource: ThemeResource = serde_json::from_slice(&data)?;
            resource.validate(&contribution.appearance)?;
            entries.push(Entry {
                descriptor: EditorThemeDescriptor {
                    id: contribution.id,
                    title: contribution.title,
                    appearance: contribution.appearance,
                },
                resource,
            });
        }
        Ok(entries)
    }
}
