//! Ported from `Engine/Sources/AIRuntime/Tools/CapabilityToolset.swift`.

use diffuse_capability::capability_contract::{CapabilityContract, CapabilityExposureSnapshot};
use diffuse_capability::capability_registry::CapabilityRegistry;
use diffuse_intent::BuiltInTypedCapabilityCatalog;
use serde_json::{Value, json};

/// Provider adapters for the dynamic capability exposure protocol. All schemas
/// originate from CapabilityRegistry contracts.
pub enum CapabilityToolset {}

impl CapabilityToolset {
    pub const SEARCH_TOOL_NAME: &'static str = "search_capabilities";
    pub const SUBMIT_TOOL_NAME: &'static str = "submit_plan";

    pub fn anthropic_tools_with_default_registry(
        snapshot: &CapabilityExposureSnapshot,
    ) -> Vec<Value> {
        Self::anthropic_tools(snapshot, &BuiltInTypedCapabilityCatalog::registry())
    }

    pub fn anthropic_tools(
        snapshot: &CapabilityExposureSnapshot,
        registry: &CapabilityRegistry,
    ) -> Vec<Value> {
        let mut tools: Vec<Value> = Self::framework_contracts(registry)
            .into_iter()
            .map(|(name, contract)| {
                json!({
                    "name": name,
                    "description": contract.description,
                    "input_schema": contract.input_schema.canonical_json(),
                })
            })
            .collect();
        tools.extend(
            snapshot
                .contracts
                .iter()
                .filter(|contract| !contract.id.starts_with("system."))
                .map(CapabilityContract::anthropic_tool_definition),
        );
        tools
    }

    pub fn open_ai_tools_with_default_registry(
        snapshot: &CapabilityExposureSnapshot,
    ) -> Vec<Value> {
        Self::open_ai_tools(snapshot, &BuiltInTypedCapabilityCatalog::registry())
    }

    pub fn open_ai_tools(
        snapshot: &CapabilityExposureSnapshot,
        registry: &CapabilityRegistry,
    ) -> Vec<Value> {
        let mut tools: Vec<Value> = Self::framework_contracts(registry)
            .into_iter()
            .map(|(name, contract)| {
                json!({
                    "type": "function",
                    "function": {
                        "name": name,
                        "description": contract.description,
                        "parameters": contract.input_schema.canonical_json(),
                    },
                })
            })
            .collect();
        tools.extend(
            snapshot
                .contracts
                .iter()
                .filter(|contract| !contract.id.starts_with("system."))
                .map(CapabilityContract::open_ai_tool_definition),
        );
        tools
    }

    pub fn open_ai_responses_tools_with_default_registry(
        snapshot: &CapabilityExposureSnapshot,
    ) -> Vec<Value> {
        Self::open_ai_responses_tools(snapshot, &BuiltInTypedCapabilityCatalog::registry())
    }

    pub fn open_ai_responses_tools(
        snapshot: &CapabilityExposureSnapshot,
        registry: &CapabilityRegistry,
    ) -> Vec<Value> {
        let mut tools: Vec<Value> = Self::framework_contracts(registry)
            .into_iter()
            .map(|(name, contract)| contract.open_ai_responses_tool_definition(Some(&name)))
            .collect();
        tools.extend(
            snapshot
                .contracts
                .iter()
                .filter(|contract| !contract.id.starts_with("system."))
                .map(|contract| contract.open_ai_responses_tool_definition(None)),
        );
        tools
    }

    pub fn search_result(contracts: &[CapabilityContract]) -> String {
        let entries: Vec<Value> = contracts
            .iter()
            .map(|contract| {
                json!({
                    "id": contract.id,
                    "version": contract.version,
                    "tool_name": contract.tool_name(),
                    "title": contract.title,
                    "description": contract.description,
                    "domain": contract.domain,
                    "access": contract.access.raw_value(),
                    "schema_hash": contract.schema_hash,
                })
            })
            .collect();
        let object = json!({
            "count": entries.len(),
            "capabilities": entries,
        });
        // `serde_json` writes `Value` object keys in sorted order, matching
        // `JSONSerialization` with `.sortedKeys`.
        serde_json::to_string(&object).unwrap_or_else(|_| "{}".to_string())
    }

    fn framework_contracts(registry: &CapabilityRegistry) -> Vec<(String, CapabilityContract)> {
        if !registry.integrity_errors.is_empty() {
            return Vec::new();
        }
        [
            (Self::SEARCH_TOOL_NAME, "system.search_capabilities"),
            (Self::SUBMIT_TOOL_NAME, "system.submit_plan"),
        ]
        .into_iter()
        .filter_map(|(tool_name, capability_id)| {
            registry
                .descriptor(capability_id)
                .map(|descriptor| (tool_name.to_string(), descriptor.contract()))
        })
        .collect()
    }
}
