//! Reserved capability through which a plugin declares the components it owns.
//!
//! The host calls it once, right after the plugin is enabled, and registers the
//! returned descriptions on the scene's component registry. Declarations are data
//! only: the plugin never ships native code for storage or UI.
//!
//! Ported from
//! `Engine/Sources/PluginRuntime/Contract/PluginComponentCapability.swift`.

use diffuse_capability::capability_contract::CapabilityContract;

pub enum PluginComponentCapability {}

impl PluginComponentCapability {
    pub const NAME: &'static str = "components";

    pub fn capability_id(plugin_id: &str) -> String {
        format!("{plugin_id}.{}", Self::NAME)
    }

    /// Input record the host sends. Plugins must declare it exactly:
    ///
    /// ```wit
    /// record components-input { include-all: bool }
    /// components: func(input: components-input) -> string;
    /// ```
    pub fn input() -> &'static [u8] {
        br#"{"include-all":true}"#
    }

    pub fn declares_components(contracts: &[CapabilityContract], plugin_id: &str) -> bool {
        contracts
            .iter()
            .any(|contract| contract.id == Self::capability_id(plugin_id))
    }
}
