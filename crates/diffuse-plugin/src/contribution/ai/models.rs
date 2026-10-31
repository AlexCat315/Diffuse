//! Model provider declarations.
//!
//! Ported from `Engine/Sources/PluginRuntime/Contribution/AI/Models.swift`.
//! Transport remains in the host: the contribution names a supported API
//! format, base URL and models, and the host owns credentials, HTTP, streaming
//! and auditing.

use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AIProviderContribution {
    pub id: String,
    pub title: String,
    /// `anthropic`, `openai-responses` or `openai-compatible`.
    pub api_format: String,
    #[serde(default)]
    pub base_url: Option<String>,
    #[serde(default)]
    pub default_model: Option<String>,
    pub models: Vec<AIModelContribution>,
    #[serde(default)]
    pub auth: Option<AIAuthContribution>,
}

impl AIProviderContribution {
    pub fn new(
        id: impl Into<String>,
        title: impl Into<String>,
        api_format: impl Into<String>,
        models: Vec<AIModelContribution>,
    ) -> Self {
        AIProviderContribution {
            id: id.into(),
            title: title.into(),
            api_format: api_format.into(),
            base_url: None,
            default_model: None,
            models,
            auth: None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AIModelContribution {
    pub id: String,
    pub title: String,
    #[serde(default)]
    pub context_window: Option<i64>,
    #[serde(default)]
    pub max_output_tokens: Option<i64>,
    #[serde(default)]
    pub supports_tools: Option<bool>,
}

impl AIModelContribution {
    pub fn new(id: impl Into<String>, title: impl Into<String>) -> Self {
        AIModelContribution {
            id: id.into(),
            title: title.into(),
            context_window: None,
            max_output_tokens: None,
            supports_tools: None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AIAuthContribution {
    /// Only `apiKey` is supported for host-mediated providers.
    #[serde(default = "default_auth_type")]
    pub r#type: String,
    pub fields: Vec<AIAuthFieldContribution>,
}

fn default_auth_type() -> String {
    "apiKey".to_string()
}

impl AIAuthContribution {
    pub fn new(fields: Vec<AIAuthFieldContribution>) -> Self {
        AIAuthContribution {
            r#type: default_auth_type(),
            fields,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AIAuthFieldContribution {
    pub id: String,
    pub title: String,
    #[serde(default)]
    pub secret: Option<bool>,
    /// Host-only fallback when the credential file has no value.
    #[serde(default)]
    pub environment_variable: Option<String>,
}

impl AIAuthFieldContribution {
    pub fn new(id: impl Into<String>, title: impl Into<String>) -> Self {
        AIAuthFieldContribution {
            id: id.into(),
            title: title.into(),
            secret: None,
            environment_variable: None,
        }
    }
}
