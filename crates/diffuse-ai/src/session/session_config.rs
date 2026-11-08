//! Ported from `Engine/Sources/AIRuntime/Session/SessionConfig.swift`.

use diffuse_capability::contracts::exports::SessionApiFormat;

use crate::session::retry_policy::RetryPolicy;

/// Named assets available in the project, surfaced in the system prompt so the
/// model can use correct clip/mesh names rather than guessing.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct AssetCatalog {
    /// Audio clip names (no file extension). Used by set_audio_source.
    pub audio_clips: Vec<String>,
    /// Animation clip names. Used by set_animation_player.
    pub animation_clips: Vec<String>,
    /// Mesh/model names available for spawning or reference. Optional context only.
    pub mesh_names: Vec<String>,
}

impl AssetCatalog {
    pub fn new(
        audio_clips: Vec<String>,
        animation_clips: Vec<String>,
        mesh_names: Vec<String>,
    ) -> Self {
        Self {
            audio_clips,
            animation_clips,
            mesh_names,
        }
    }

    /// `AssetCatalog()` — every list empty.
    pub fn with_defaults() -> Self {
        Self::default()
    }

    pub fn is_empty(&self) -> bool {
        self.audio_clips.is_empty() && self.animation_clips.is_empty() && self.mesh_names.is_empty()
    }

    /// Compact system-prompt section listing available assets.
    pub(crate) fn system_prompt_section(&self) -> String {
        let mut lines: Vec<String> = Vec::new();
        if !self.audio_clips.is_empty() {
            lines.push(format!(
                "Available audio clips (use exact names for set_audio_source): {}",
                self.audio_clips.join(", ")
            ));
        }
        if !self.animation_clips.is_empty() {
            lines.push(format!(
                "Available animation clips (use exact names for set_animation_player): {}",
                self.animation_clips.join(", ")
            ));
        }
        if !self.mesh_names.is_empty() {
            lines.push(format!("Available meshes: {}", self.mesh_names.join(", ")));
        }
        lines.join("\n")
    }
}

/// Configuration for Session's built-in inference capability.
#[derive(Clone, Debug, PartialEq)]
pub struct SessionConfig {
    pub api_key: String,
    pub model: String,
    pub max_tokens: i64,
    pub timeout_interval: f64,
    pub base_url: String,
    pub api_format: SessionApiFormat,
    /// When `true`, produced Proposals use `.automatic` approval — changes apply
    /// immediately without a confirmation step. Default `false` (requires approval).
    pub auto_approve: bool,
    /// Project asset catalog surfaced in the system prompt.
    pub asset_catalog: AssetCatalog,
    /// Backoff policy for transient inference failures (rate limits, 5xx,
    /// dropped connections).
    pub retry_policy: RetryPolicy,
}

impl SessionConfig {
    pub const DEFAULT_MODEL: &'static str = "claude-sonnet-4-6";
    pub const DEFAULT_ANTHROPIC_MODEL: &'static str = "claude-sonnet-4-6";
    pub const DEFAULT_OPENAI_MODEL: &'static str = "gpt-4o";
    pub const DEFAULT_DEEPSEEK_MODEL: &'static str = "deepseek-chat";

    pub const DEFAULT_MAX_TOKENS: i64 = 2048;
    pub const DEFAULT_TIMEOUT_INTERVAL: f64 = 90.0;

    /// Swift's `init(apiKey:model:baseURL:apiFormat:)` with its defaults.
    pub fn new_with_defaults(
        api_key: impl Into<String>,
        model: &str,
        base_url: impl Into<String>,
        api_format: SessionApiFormat,
    ) -> Self {
        Self::new(
            api_key.into(),
            model.to_string(),
            Self::DEFAULT_MAX_TOKENS,
            Self::DEFAULT_TIMEOUT_INTERVAL,
            base_url.into(),
            api_format,
            false,
            AssetCatalog::with_defaults(),
            RetryPolicy::with_defaults(),
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub fn new(
        api_key: String,
        model: String,
        max_tokens: i64,
        timeout_interval: f64,
        base_url: String,
        api_format: SessionApiFormat,
        auto_approve: bool,
        asset_catalog: AssetCatalog,
        retry_policy: RetryPolicy,
    ) -> Self {
        Self {
            api_key,
            model,
            max_tokens,
            timeout_interval,
            base_url,
            api_format,
            auto_approve,
            asset_catalog,
            retry_policy,
        }
    }

    pub fn anthropic(api_key: impl Into<String>) -> Self {
        Self::anthropic_with_options(
            api_key,
            Self::DEFAULT_ANTHROPIC_MODEL,
            Self::DEFAULT_MAX_TOKENS,
            Self::DEFAULT_TIMEOUT_INTERVAL,
            false,
            AssetCatalog::with_defaults(),
            RetryPolicy::with_defaults(),
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub fn anthropic_with_options(
        api_key: impl Into<String>,
        model: &str,
        max_tokens: i64,
        timeout_interval: f64,
        auto_approve: bool,
        asset_catalog: AssetCatalog,
        retry_policy: RetryPolicy,
    ) -> Self {
        Self::new(
            api_key.into(),
            model.to_string(),
            max_tokens,
            timeout_interval,
            "https://api.anthropic.com".to_string(),
            SessionApiFormat::Anthropic,
            auto_approve,
            asset_catalog,
            retry_policy,
        )
    }

    pub fn open_ai(api_key: impl Into<String>) -> Self {
        Self::open_ai_with_options(
            api_key,
            Self::DEFAULT_OPENAI_MODEL,
            Self::DEFAULT_MAX_TOKENS,
            Self::DEFAULT_TIMEOUT_INTERVAL,
            false,
            AssetCatalog::with_defaults(),
            RetryPolicy::with_defaults(),
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub fn open_ai_with_options(
        api_key: impl Into<String>,
        model: &str,
        max_tokens: i64,
        timeout_interval: f64,
        auto_approve: bool,
        asset_catalog: AssetCatalog,
        retry_policy: RetryPolicy,
    ) -> Self {
        Self::new(
            api_key.into(),
            model.to_string(),
            max_tokens,
            timeout_interval,
            "https://api.openai.com".to_string(),
            SessionApiFormat::OpenAiCompatible,
            auto_approve,
            asset_catalog,
            retry_policy,
        )
    }

    pub fn open_ai_responses(api_key: impl Into<String>) -> Self {
        Self::open_ai_responses_with_options(
            api_key,
            Self::DEFAULT_OPENAI_MODEL,
            Self::DEFAULT_MAX_TOKENS,
            Self::DEFAULT_TIMEOUT_INTERVAL,
            false,
            AssetCatalog::with_defaults(),
            RetryPolicy::with_defaults(),
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub fn open_ai_responses_with_options(
        api_key: impl Into<String>,
        model: &str,
        max_tokens: i64,
        timeout_interval: f64,
        auto_approve: bool,
        asset_catalog: AssetCatalog,
        retry_policy: RetryPolicy,
    ) -> Self {
        Self::new(
            api_key.into(),
            model.to_string(),
            max_tokens,
            timeout_interval,
            "https://api.openai.com".to_string(),
            SessionApiFormat::OpenAiResponses,
            auto_approve,
            asset_catalog,
            retry_policy,
        )
    }

    pub fn open_ai_compatible(
        api_key: impl Into<String>,
        model: &str,
        base_url: impl Into<String>,
    ) -> Self {
        Self::open_ai_compatible_with_options(
            api_key,
            model,
            base_url,
            Self::DEFAULT_MAX_TOKENS,
            Self::DEFAULT_TIMEOUT_INTERVAL,
            false,
            AssetCatalog::with_defaults(),
            RetryPolicy::with_defaults(),
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub fn open_ai_compatible_with_options(
        api_key: impl Into<String>,
        model: &str,
        base_url: impl Into<String>,
        max_tokens: i64,
        timeout_interval: f64,
        auto_approve: bool,
        asset_catalog: AssetCatalog,
        retry_policy: RetryPolicy,
    ) -> Self {
        Self::new(
            api_key.into(),
            model.to_string(),
            max_tokens,
            timeout_interval,
            base_url.into(),
            SessionApiFormat::OpenAiCompatible,
            auto_approve,
            asset_catalog,
            retry_policy,
        )
    }

    pub fn deep_seek(api_key: impl Into<String>) -> Self {
        Self::deep_seek_with_options(
            api_key,
            Self::DEFAULT_DEEPSEEK_MODEL,
            Self::DEFAULT_MAX_TOKENS,
            Self::DEFAULT_TIMEOUT_INTERVAL,
            false,
            AssetCatalog::with_defaults(),
            RetryPolicy::with_defaults(),
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub fn deep_seek_with_options(
        api_key: impl Into<String>,
        model: &str,
        max_tokens: i64,
        timeout_interval: f64,
        auto_approve: bool,
        asset_catalog: AssetCatalog,
        retry_policy: RetryPolicy,
    ) -> Self {
        Self::new(
            api_key.into(),
            model.to_string(),
            max_tokens,
            timeout_interval,
            "https://api.deepseek.com".to_string(),
            SessionApiFormat::OpenAiCompatible,
            auto_approve,
            asset_catalog,
            retry_policy,
        )
    }
}
