//! Which capability an editor calls, which one the model may call, and the
//! limits each gets.
//!
//! Ported from `Engine/Sources/PluginRuntime/Contract/EntryPoints.swift`.

use diffuse_capability::capsule_schema::JsonSchema;

use crate::contract::plugin_contract::PluginEntryContract;
use crate::contract::plugin_manifest::{CovePluginManifest, PluginResourceLimits};
use crate::contract::plugin_package::ValidatedPluginPackage;
use crate::contribution::ai::harness::{AIHarnessContribution, AIHarnessContributionPoint};
use crate::contribution::ai::tool::{AIToolContribution, AIToolContributionPoint};

impl CovePluginManifest {
    /// Only capabilities a `cove.ai.tool/v1` names reach the model; everything
    /// else a package exports is called by the editor alone.
    pub fn exposes_to_ai(&self, entry_point: &str) -> bool {
        self.ai_tool(entry_point).is_some()
    }

    pub fn ai_tool(&self, entry_point: &str) -> Option<AIToolContribution> {
        // Swift used `(try? decode(…)) ?? []`: a contribution list that does not
        // decode is treated as absent rather than fatal.
        let harnesses: Vec<AIHarnessContribution> = self
            .contributes
            .decode::<AIHarnessContributionPoint>()
            .unwrap_or_default();
        if entry_point == "components"
            || self.host.entry_points().contains(entry_point)
            || harnesses
                .iter()
                .any(|harness| harness.entry_point == entry_point)
        {
            return None;
        }
        self.contributes
            .decode::<AIToolContributionPoint>()
            .unwrap_or_default()
            .into_iter()
            .find(|tool| tool.entry_point == entry_point)
    }
}

/// Capabilities named by `host.processes[].entryPoints` are called by the editor
/// with whole tool output and never by the model, and so are harness entry
/// points, which get whole turns. Their inputs are checked for shape but not
/// length, under `PluginResourceLimits::host_entry_point`.
impl ValidatedPluginPackage {
    pub fn is_host_entry_point(&self, capability: &str) -> bool {
        // Swift compared against `Set<String>` from `host.entryPoints`.
        self.manifest.host.entry_points().contains(capability)
            || self
                .manifest
                .contributes
                .decode::<AIHarnessContributionPoint>()
                .unwrap_or_default()
                .iter()
                .any(|harness| harness.entry_point == capability)
    }

    pub fn input_schema(&self, capability: &PluginEntryContract) -> JsonSchema {
        if self.is_host_entry_point(&capability.name) {
            without_size_limits(&capability.input_schema)
        } else {
            capability.input_schema.clone()
        }
    }

    pub fn limits(&self, capability: &str, default: &PluginResourceLimits) -> PluginResourceLimits {
        if self.is_host_entry_point(capability) {
            PluginResourceLimits::host_entry_point()
        } else {
            default.clone()
        }
    }
}

/// `JSONSchema.withoutSizeLimits`: drop `maximumLength` and `maximumItems`
/// everywhere, including nested properties, items and alternatives.
pub fn without_size_limits(schema: &JsonSchema) -> JsonSchema {
    let mut result = schema.clone();
    result.maximum_length = None;
    result.maximum_items = None;
    result.properties = result
        .properties
        .iter()
        .map(|(key, value)| (key.clone(), without_size_limits(value)))
        .collect();
    result.items = result
        .items
        .as_ref()
        .map(|items| Box::new(without_size_limits(items)));
    result.one_of = result.one_of.iter().map(without_size_limits).collect();
    result
}

/// `(try? manifest.contributes.decode(Point.self)) ?? []`.
///
/// Swift swallowed a decode failure at every one of these sites — an activation
/// scan must not fail because one declaration family is malformed; manifest
/// validation reports that separately.
pub fn decode_or_default<Spec: crate::contribution::registry::ContributionPointSpec>(
    manifest: &CovePluginManifest,
) -> Vec<Spec::Descriptor> {
    manifest.contributes.decode_lossy::<Spec>()
}
