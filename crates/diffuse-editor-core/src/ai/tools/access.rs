//! `Editor/Sources/EditorCore/AI/Tools/Access.swift` — tool enforcement and
//! exposure state share the same host policy for the entire Editor lifetime,
//! including replacement assistant sessions.

use std::collections::BTreeMap;

use diffuse_ai::planning::capability_draft_pipeline::CapabilityDraftStore;
use diffuse_ai::tools::capability_exposure_session_store::CapabilityExposureSessionStore;
use diffuse_ai::tools::tool_policy::ToolPolicy;
use diffuse_capability::capability_contract::CapabilityExposurePolicy;
use diffuse_intent::BuiltInTypedCapabilityCatalog;

pub(crate) struct EditorToolAccess {
    pub(crate) policy: ToolPolicy,
    pub(crate) capability_sessions: CapabilityExposureSessionStore,
}

impl EditorToolAccess {
    pub(crate) fn new(policy: ToolPolicy) -> Self {
        // `CapabilityExposureSessionStore(toolPolicy:)`: the Swift initializer
        // defaults exactly like `CapabilityRegistry.aiDefault` plus
        // `allowedDomains: ["scene"]`.
        let exposure_policy = CapabilityExposurePolicy {
            allowed_domains: Some(std::iter::once("scene".to_string()).collect()),
            ..CapabilityExposurePolicy::default()
        };
        let capability_sessions = CapabilityExposureSessionStore::with_configuration(
            BuiltInTypedCapabilityCatalog::registry(),
            CapabilityDraftStore::DEFAULT_TTL,
            exposure_policy,
            BTreeMap::new(),
            Some(policy.clone()),
        );
        EditorToolAccess {
            policy,
            capability_sessions,
        }
    }
}
