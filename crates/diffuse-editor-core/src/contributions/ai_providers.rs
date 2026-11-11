//! `Editor/Sources/EditorCore/Contributions/AIProviders.swift`.
//!
//! A model a provider exposes. The host owns transport; the descriptor only
//! tells the editor what can be selected.

use diffuse_capability::capability_registry::CapabilityRegistry;
use diffuse_plugin::contract::plugin_package::{PluginPackageLoader, ValidatedPluginPackage};
use diffuse_plugin::contribution::ai::models::AIProviderContribution;
use diffuse_plugin::contribution::ai::provider_point::AIProviderContributionPoint;
use diffuse_plugin::contribution::registry::ContributionPointRegistry;

use crate::application::plugins::bundled::BundledPlugins;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AIModelDescriptor {
    pub id: String,
    pub title: String,
    pub context_window: Option<i64>,
    pub max_output_tokens: Option<i64>,
    pub supports_tools: bool,
}

impl AIModelDescriptor {
    pub fn new(
        id: impl Into<String>,
        title: impl Into<String>,
        context_window: Option<i64>,
        max_output_tokens: Option<i64>,
        supports_tools: bool,
    ) -> Self {
        AIModelDescriptor {
            id: id.into(),
            title: title.into(),
            context_window,
            max_output_tokens,
            supports_tools,
        }
    }

    /// Swift's `contextWindow`/`maxOutputTokens`/`supportsTools` defaults.
    pub fn with_defaults(id: impl Into<String>, title: impl Into<String>) -> Self {
        Self::new(id, title, None, None, true)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AIAuthFieldDescriptor {
    pub id: String,
    pub title: String,
    pub is_secret: bool,
    pub environment_variable: Option<String>,
}

impl AIAuthFieldDescriptor {
    pub fn new(
        id: impl Into<String>,
        title: impl Into<String>,
        is_secret: bool,
        environment_variable: Option<String>,
    ) -> Self {
        AIAuthFieldDescriptor {
            id: id.into(),
            title: title.into(),
            is_secret,
            environment_variable,
        }
    }
}

/// One enabled or bundled AI provider contribution, narrowed to the values the
/// settings UI and session factory need.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AIProviderDescriptor {
    pub plugin_id: String,
    pub id: String,
    pub title: String,
    pub api_format: String,
    pub base_url: Option<String>,
    pub default_model: String,
    pub models: Vec<AIModelDescriptor>,
    pub auth_fields: Vec<AIAuthFieldDescriptor>,
}

impl AIProviderDescriptor {
    /// The field whose value the session sends as the API key.
    pub fn secret_field(&self) -> Option<&AIAuthFieldDescriptor> {
        self.auth_fields.iter().find(|field| field.is_secret)
    }

    pub fn new(plugin_id: impl Into<String>, contribution: &AIProviderContribution) -> Self {
        let models: Vec<AIModelDescriptor> = contribution
            .models
            .iter()
            .map(|model| {
                AIModelDescriptor::new(
                    model.id.clone(),
                    model.title.clone(),
                    model.context_window,
                    model.max_output_tokens,
                    model.supports_tools.unwrap_or(true),
                )
            })
            .collect();
        let default_model = contribution
            .default_model
            .clone()
            .or_else(|| models.first().map(|model| model.id.clone()))
            .unwrap_or_default();
        let auth_fields = contribution
            .auth
            .as_ref()
            .map(|auth| {
                auth.fields
                    .iter()
                    .map(|field| {
                        AIAuthFieldDescriptor::new(
                            field.id.clone(),
                            field.title.clone(),
                            field.secret.unwrap_or(true),
                            field.environment_variable.clone(),
                        )
                    })
                    .collect()
            })
            .unwrap_or_default();
        AIProviderDescriptor {
            plugin_id: plugin_id.into(),
            id: contribution.id.clone(),
            title: contribution.title.clone(),
            api_format: contribution.api_format.clone(),
            base_url: contribution.base_url.clone(),
            default_model,
            models,
            auth_fields,
        }
    }
}

/// Immutable domain snapshot. Every editor session owns its enabled providers.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AIProviderCatalog {
    pub providers: Vec<AIProviderDescriptor>,
}

impl AIProviderCatalog {
    pub fn bundled() -> Self {
        let loader = default_loader();
        let packages: Vec<ValidatedPluginPackage> = BundledPlugins::catalog()
            .iter()
            .filter_map(|plugin| loader.load(&plugin.package).ok())
            .collect();
        Self::new(packages)
    }

    pub fn new(mut packages: Vec<ValidatedPluginPackage>) -> Self {
        packages.sort_by(|left, right| left.manifest.id.cmp(&right.manifest.id));
        let providers = packages
            .into_iter()
            .flat_map(|package| {
                package
                    .manifest
                    .contributes
                    .decode::<AIProviderContributionPoint>()
                    .unwrap_or_default()
                    .into_iter()
                    .map(move |contribution| {
                        AIProviderDescriptor::new(package.manifest.id.clone(), &contribution)
                    })
            })
            .collect();
        AIProviderCatalog { providers }
    }

    /// Swift's `packages: [ValidatedPluginPackage] = []` default.
    pub fn with_default_packages() -> Self {
        Self::new(Vec::new())
    }

    pub fn provider(&self, id: &str) -> Option<&AIProviderDescriptor> {
        self.providers.iter().find(|provider| provider.id == id)
    }

    pub fn model(&self, provider_id: &str, model_id: &str) -> Option<&AIModelDescriptor> {
        self.provider(provider_id)?
            .models
            .iter()
            .find(|model| model.id == model_id)
    }

    pub fn default_model(&self, provider_id: &str) -> Option<&str> {
        self.provider(provider_id)
            .map(|provider| provider.default_model.as_str())
    }
}

/// `PluginPackageLoader()` with its Swift default arguments.
fn default_loader() -> PluginPackageLoader {
    PluginPackageLoader::new(
        CapabilityRegistry::default(),
        None,
        ContributionPointRegistry::standard(),
    )
}
