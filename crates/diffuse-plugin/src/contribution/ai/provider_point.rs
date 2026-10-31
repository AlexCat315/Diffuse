//! AI provider contribution validation.
//!
//! Ported from `Engine/Sources/PluginRuntime/Contribution/AI/ProviderPoint.swift`.

use std::collections::BTreeSet;

use crate::contract::host_permissions::PluginHostPermissions;
use crate::contract::plugin_manifest::PluginManifestValidationError;
use crate::contribution::ai::models::{
    AIAuthContribution, AIModelContribution, AIProviderContribution,
};
use crate::contribution::registry::{ContributionPointSpec, ContributionValidation};
use crate::pattern::upper_environment_variable;

pub enum AIProviderContributionPoint {}

impl AIProviderContributionPoint {
    fn valid_auth(auth: &AIAuthContribution) -> bool {
        let ids: BTreeSet<&String> = auth.fields.iter().map(|field| &field.id).collect();
        auth.r#type == "apiKey"
            && !auth.fields.is_empty()
            && auth.fields.len() <= 8
            && ids.len() == auth.fields.len()
            && auth.fields.iter().all(|field| {
                ContributionValidation::identifier(&field.id)
                    && ContributionValidation::title(&field.title)
                    && field
                        .environment_variable
                        .as_ref()
                        .is_none_or(|variable| upper_environment_variable(variable))
            })
    }

    fn valid_models(models: &[AIModelContribution], default_model: Option<&str>) -> bool {
        let ids: BTreeSet<&String> = models.iter().map(|model| &model.id).collect();
        if models.is_empty() || models.len() > 64 || ids.len() != models.len() {
            return false;
        }
        if let Some(default_model) = default_model
            && !models.iter().any(|model| model.id == default_model)
        {
            return false;
        }
        models.iter().all(|model| {
            !model.id.is_empty()
                && model.id.chars().count() <= 80
                && ContributionValidation::title(&model.title)
                && model.context_window.is_none_or(|window| window > 0)
                && model.max_output_tokens.is_none_or(|tokens| tokens > 0)
        })
    }

    /// `URL(string:)` with an `https`/`http` scheme, a host, and no user or
    /// password component.
    fn valid_url(value: &str) -> bool {
        let Some((scheme, rest)) = value.split_once("://") else {
            return false;
        };
        let scheme = scheme.to_lowercase();
        if scheme != "https" && scheme != "http" {
            return false;
        }
        // Strip a path, query or fragment, then an optional port.
        let authority = rest.split(['/', '?', '#']).next().unwrap_or_default();
        if authority.is_empty() {
            return false;
        }
        let host = authority.split('@').next_back().unwrap_or_default();
        let host = host.split(':').next().unwrap_or_default();
        !host.is_empty() && !authority.contains('@')
    }
}

impl ContributionPointSpec for AIProviderContributionPoint {
    type Descriptor = AIProviderContribution;

    const ID: &'static str = "cove.ai.provider/v1";

    fn validate(
        provider: &AIProviderContribution,
        _host: &PluginHostPermissions,
    ) -> Result<(), PluginManifestValidationError> {
        let url_ok = provider
            .base_url
            .as_deref()
            .is_none_or(AIProviderContributionPoint::valid_url);
        if !(ContributionValidation::identifier(&provider.id)
            && ContributionValidation::title(&provider.title)
            && ["anthropic", "openai-responses", "openai-compatible"]
                .contains(&provider.api_format.as_str())
            && url_ok
            && AIProviderContributionPoint::valid_models(
                &provider.models,
                provider.default_model.as_deref(),
            )
            && provider
                .auth
                .as_ref()
                .is_none_or(AIProviderContributionPoint::valid_auth))
        {
            return Err(PluginManifestValidationError::InvalidContribution(
                Self::ID.to_string(),
            ));
        }
        Ok(())
    }
}
