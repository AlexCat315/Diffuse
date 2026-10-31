//! Capability access, source, contract and exposure vocabulary.
//!
//! Swift `@_exported import CoveUIAgentCore` re-exported the portable agent
//! foundation; MIGRATION.md §3 maps that to `cove-agent` (gap G6, now closed).
//! This module is the single place that decides the path.

pub mod agent {
    //! Agent vocabulary re-export (MIGRATION.md §3, gap G6 closed).
    pub use cove_agent::*;
}

use serde::{Deserialize, Serialize};

use crate::capsule_schema::JsonSchema;
use crate::release::sha256::capability_sha256_hex_digest;

/// How invoking a capability may affect state. The host, not a plugin or model,
/// decides the effective access level.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CapabilityAccess {
    Read,
    #[serde(rename = "reversible_write")]
    ReversibleWrite,
    #[serde(rename = "destructive_write")]
    DestructiveWrite,
    #[serde(rename = "external_side_effect")]
    ExternalSideEffect,
}

impl CapabilityAccess {
    /// Swift's `CaseIterable` order.
    pub const ALL: [CapabilityAccess; 4] = [
        CapabilityAccess::Read,
        CapabilityAccess::ReversibleWrite,
        CapabilityAccess::DestructiveWrite,
        CapabilityAccess::ExternalSideEffect,
    ];

    pub const fn raw_value(self) -> &'static str {
        match self {
            CapabilityAccess::Read => "read",
            CapabilityAccess::ReversibleWrite => "reversible_write",
            CapabilityAccess::DestructiveWrite => "destructive_write",
            CapabilityAccess::ExternalSideEffect => "external_side_effect",
        }
    }

    #[inline]
    pub const fn is_write(self) -> bool {
        !matches!(self, CapabilityAccess::Read)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CapabilitySourceKind {
    Builtin,
    Plugin,
}

impl CapabilitySourceKind {
    pub const fn raw_value(self) -> &'static str {
        match self {
            CapabilitySourceKind::Builtin => "builtin",
            CapabilitySourceKind::Plugin => "plugin",
        }
    }
}

/// Swift's `CapabilityReleasePhase`, ordered so `>=` expresses "at least this
/// mature": disabled < experimental < beta < stable.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReleasePhase {
    Disabled,
    Experimental,
    Beta,
    Stable,
}

impl ReleasePhase {
    pub const fn order(self) -> i32 {
        match self {
            ReleasePhase::Disabled => 0,
            ReleasePhase::Experimental => 1,
            ReleasePhase::Beta => 2,
            ReleasePhase::Stable => 3,
        }
    }

    pub const fn raw_value(self) -> &'static str {
        match self {
            ReleasePhase::Disabled => "disabled",
            ReleasePhase::Experimental => "experimental",
            ReleasePhase::Beta => "beta",
            ReleasePhase::Stable => "stable",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CapabilitySource {
    pub kind: CapabilitySourceKind,
    pub plugin_id: Option<String>,
}

impl CapabilitySource {
    #[inline]
    pub fn new(kind: CapabilitySourceKind, plugin_id: Option<String>) -> Self {
        CapabilitySource { kind, plugin_id }
    }

    pub const BUILTIN: CapabilitySource = CapabilitySource {
        kind: CapabilitySourceKind::Builtin,
        plugin_id: None,
    };

    pub fn plugin(id: impl Into<String>) -> Self {
        CapabilitySource {
            kind: CapabilitySourceKind::Plugin,
            plugin_id: Some(id.into()),
        }
    }
}

/// Exact plugin authority captured when a model-facing allow-list is created.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginCapabilityAuthority {
    pub plugin_id: String,
    pub authorization_digest: String,
    pub host_generation: u64,
}

impl PluginCapabilityAuthority {
    #[inline]
    pub fn new(
        plugin_id: impl Into<String>,
        authorization_digest: impl Into<String>,
        host_generation: u64,
    ) -> Self {
        PluginCapabilityAuthority {
            plugin_id: plugin_id.into(),
            authorization_digest: authorization_digest.into(),
            host_generation,
        }
    }
}

/// Provider-neutral, serialisable contract for one AI-visible capability.
/// Provider and MCP tool definitions must be derived from this value.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CapabilityContract {
    pub id: String,
    pub version: i64,
    pub title: String,
    pub description: String,
    pub domain: String,
    pub access: CapabilityAccess,
    pub release_phase: ReleasePhase,
    pub input_schema: JsonSchema,
    pub source: CapabilitySource,
    pub schema_hash: String,
}

impl CapabilityContract {
    /// Swift defaults: version 1, builtin source, fingerprint computed when no
    /// schema hash is supplied.
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        id: impl Into<String>,
        version: i64,
        title: impl Into<String>,
        description: impl Into<String>,
        domain: impl Into<String>,
        access: CapabilityAccess,
        release_phase: ReleasePhase,
        input_schema: JsonSchema,
        source: CapabilitySource,
        schema_hash: Option<String>,
    ) -> Self {
        let id = id.into();
        let title = Self::sanitise_metadata(&title.into(), 80);
        let description = Self::sanitise_metadata(&description.into(), 1_024);
        let domain = domain.into();
        let schema_hash = match schema_hash {
            Some(hash) => hash,
            None => Self::fingerprint(
                &id,
                version,
                &title,
                &description,
                &domain,
                access,
                release_phase,
                &input_schema,
                &source,
            ),
        };
        CapabilityContract {
            id,
            version,
            title,
            description,
            domain,
            access,
            release_phase,
            input_schema,
            source,
            schema_hash,
        }
    }

    /// A collision-resistant provider tool name.
    pub fn tool_name(&self) -> String {
        let readable: String = self
            .id
            .to_lowercase()
            .chars()
            .map(|character| {
                if character.is_alphanumeric() {
                    character
                } else {
                    '_'
                }
            })
            .collect();
        let collapsed = readable.replace("__", "_");
        let prefix: String = collapsed.chars().take(44).collect();
        let prefix = prefix.trim_matches('_');
        let hash_prefix: String = self.schema_hash.chars().take(8).collect();
        format!("cap_{prefix}_v{}_", self.version) + &hash_prefix
    }

    fn tool_descriptor(&self, name: Option<&str>) -> crate::capability_contract::agent::AgentTool {
        let name = name.map(str::to_string).unwrap_or_else(|| self.tool_name());
        crate::capability_contract::agent::AgentTool::new(
            name,
            self.description.clone(),
            self.input_schema.clone(),
            self.access == CapabilityAccess::Read,
        )
    }

    pub fn anthropic_tool_definition(&self) -> serde_json::Value {
        self.tool_descriptor(None)
            .provider_definition(crate::capability_contract::agent::SessionApiFormat::Anthropic)
    }

    pub fn open_ai_tool_definition(&self) -> serde_json::Value {
        self.tool_descriptor(None).provider_definition(
            crate::capability_contract::agent::SessionApiFormat::OpenAiCompatible,
        )
    }

    pub fn open_ai_responses_tool_definition(&self, name: Option<&str>) -> serde_json::Value {
        self.tool_descriptor(name).provider_definition(
            crate::capability_contract::agent::SessionApiFormat::OpenAiResponses,
        )
    }

    pub fn mcp_tool_definition(&self) -> serde_json::Value {
        self.tool_descriptor(None).mcp_definition()
    }

    /// Digest of the already validated canonical capability input.
    #[inline]
    pub fn input_digest(&self, data: &[u8]) -> String {
        capability_sha256_hex_digest(data)
    }

    #[allow(clippy::too_many_arguments)]
    fn fingerprint(
        id: &str,
        version: i64,
        title: &str,
        description: &str,
        domain: &str,
        access: CapabilityAccess,
        release_phase: ReleasePhase,
        input_schema: &JsonSchema,
        source: &CapabilitySource,
    ) -> String {
        let mut source_object = serde_json::Map::new();
        source_object.insert(
            "kind".to_string(),
            serde_json::Value::String(source.kind.raw_value().to_string()),
        );
        if let Some(plugin_id) = &source.plugin_id {
            source_object.insert(
                "plugin_id".to_string(),
                serde_json::Value::String(plugin_id.clone()),
            );
        }
        let mut object = serde_json::Map::new();
        object.insert("id".to_string(), serde_json::Value::String(id.to_string()));
        object.insert(
            "version".to_string(),
            serde_json::Value::Number(version.into()),
        );
        object.insert(
            "title".to_string(),
            serde_json::Value::String(title.to_string()),
        );
        object.insert(
            "description".to_string(),
            serde_json::Value::String(description.to_string()),
        );
        object.insert(
            "domain".to_string(),
            serde_json::Value::String(domain.to_string()),
        );
        object.insert(
            "access".to_string(),
            serde_json::Value::String(access.raw_value().to_string()),
        );
        object.insert(
            "release_phase".to_string(),
            serde_json::Value::String(release_phase.raw_value().to_string()),
        );
        object.insert("input_schema".to_string(), input_schema.canonical_json());
        object.insert(
            "source".to_string(),
            serde_json::Value::Object(source_object),
        );
        // Swift used JSONSerialization with `.sortedKeys`; serde_json's BTreeMap
        // ordering yields the same sorted member order.
        let data = serde_json::to_vec(&serde_json::Value::Object(object)).unwrap_or_default();
        capability_sha256_hex_digest(&data)
    }

    /// Tool descriptions supplied by plugins are untrusted prompt content: keep
    /// them plain, bounded, and free of control characters.
    pub fn sanitise_metadata(value: &str, maximum_length: usize) -> String {
        let scalars = value.chars().filter(|character| {
            // Swift filtered the `control`, `format`, `lineSeparator` and
            // `paragraphSeparator` general categories.
            !matches!(
                unicode_general_category::get_general_category(*character),
                unicode_general_category::GeneralCategory::Control
                    | unicode_general_category::GeneralCategory::Format
                    | unicode_general_category::GeneralCategory::LineSeparator
                    | unicode_general_category::GeneralCategory::ParagraphSeparator
            )
        });
        scalars.take(maximum_length).collect()
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct CapabilityExposurePolicy {
    pub active_release_phase: ReleasePhase,
    pub allowed_domains: Option<std::collections::BTreeSet<String>>,
    pub allowed_capability_ids: Option<std::collections::BTreeSet<String>>,
    pub enabled_plugin_ids: std::collections::BTreeSet<String>,
    pub allow_external_side_effects: bool,
    pub maximum_capabilities: usize,
}

impl CapabilityExposurePolicy {
    /// Swift defaults: stable, no domain/id filters, no plugins, external effects
    /// denied, 16 capabilities.
    pub fn new(active_release_phase: ReleasePhase) -> Self {
        CapabilityExposurePolicy {
            active_release_phase,
            allowed_domains: None,
            allowed_capability_ids: None,
            enabled_plugin_ids: std::collections::BTreeSet::new(),
            allow_external_side_effects: false,
            maximum_capabilities: 16,
        }
    }
}

impl Default for CapabilityExposurePolicy {
    fn default() -> Self {
        Self::new(ReleasePhase::Stable)
    }
}

/// Immutable allow-list captured for one inference turn.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CapabilityExposureSnapshot {
    pub id: String,
    pub generation: u64,
    pub scene_revision: Option<u64>,
    pub contracts: Vec<CapabilityContract>,
    pub created_at: crate::support::swift_date::SwiftDate,
    /// Optional so snapshots written before plugin authority binding still decode.
    pub plugin_authorities: Option<std::collections::BTreeMap<String, PluginCapabilityAuthority>>,
}

impl CapabilityExposureSnapshot {
    pub fn new(
        id: String,
        generation: u64,
        scene_revision: Option<u64>,
        mut contracts: Vec<CapabilityContract>,
        created_at: crate::support::swift_date::SwiftDate,
        plugin_authorities: std::collections::BTreeMap<String, PluginCapabilityAuthority>,
    ) -> Self {
        contracts.sort_by(|left, right| left.id.cmp(&right.id));
        CapabilityExposureSnapshot {
            id,
            generation,
            scene_revision,
            contracts,
            created_at,
            plugin_authorities: if plugin_authorities.is_empty() {
                None
            } else {
                Some(plugin_authorities)
            },
        }
    }

    pub fn contract_for_tool_name(&self, name: &str) -> Option<&CapabilityContract> {
        self.contracts
            .iter()
            .find(|contract| contract.tool_name() == name)
    }

    pub fn contract(&self, id: &str) -> Option<&CapabilityContract> {
        self.contracts.iter().find(|contract| contract.id == id)
    }

    pub fn authority(&self, plugin_id: &str) -> Option<&PluginCapabilityAuthority> {
        self.plugin_authorities
            .as_ref()
            .and_then(|authorities| authorities.get(plugin_id))
    }
}

/// A random v4 UUID formatted exactly as Swift's `UUID().uuidString`: 36
/// characters, groups of 8-4-4-4-12. `diffuse-kernel::codable::new_uuid` is the
/// canonical implementation; keep this one byte-identical to it.
pub fn new_uuid() -> String {
    use std::sync::atomic::{AtomicU64, Ordering};

    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_nanos() as u64)
        .unwrap_or(0);
    let counter = COUNTER.fetch_add(1, Ordering::Relaxed);
    let mixed = nanos ^ counter.wrapping_mul(0x9E37_79B9_7F4A_7C15);
    let time_low = (mixed & 0xFFFF_FFFF) as u32;
    let time_mid = ((mixed >> 32) & 0xFFFF) as u16;
    let time_hi = (((mixed >> 48) & 0x0FFF) as u16) | 0x4000;
    let clock = ((counter & 0x3FFF) as u16) | 0x8000;
    let node: u64 = (mixed >> 8) & 0x0000_FFFF_FFFF_FFFF;
    format!("{time_low:08X}-{time_mid:04X}-{time_hi:04X}-{clock:04X}-{node:012X}")
}

#[cfg(test)]
mod uuid_shape_tests {
    use super::new_uuid;

    /// Swift's `UUID().uuidString` is 36 characters, groups 8-4-4-4-12. A previous
    /// version of this function produced 34 characters because the node was
    /// formatted as two short fields.
    #[test]
    fn uuid_is_thirty_six_characters_with_five_groups() {
        for _ in 0..256 {
            let value = new_uuid();
            assert_eq!(value.len(), 36, "wrong length: {value}");
            let groups: Vec<usize> = value.split('-').map(str::len).collect();
            assert_eq!(groups, vec![8, 4, 4, 4, 12], "wrong grouping: {value}");
            assert_eq!(value, value.to_uppercase());
        }
    }
}
