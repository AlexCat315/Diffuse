//! Validated model write proposals: the draft store and the compatibility
//! lowering into a `SceneEditPlan`.

use std::collections::BTreeMap;
use std::fmt;
use std::sync::Mutex;

use diffuse_capability::capability_contract::{
    CapabilityAccess, CapabilityContract, CapabilityExposureSnapshot, PluginCapabilityAuthority,
};
use diffuse_capability::capability_registry::CapabilityRegistry;
use diffuse_capability::capsule_schema::validate_capability_input;
use diffuse_capability::drafts::capability_draft_limits::CapabilityDraftLimits;
use diffuse_capability::support::swift_date::SwiftDate;
use diffuse_intent::BuiltInTypedCapabilityCatalog;
use diffuse_plugin::base64_data::Data;
use serde::{Deserialize, Serialize};

use crate::planning::scene_edit_plan::{SceneEditOp, SceneEditPlan, SceneEditStep};

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CapabilityInvocationDraft {
    pub id: String,
    #[serde(rename = "capabilityID")]
    pub capability_id: String,
    pub capability_version: i64,
    pub schema_hash: String,
    #[serde(
        rename = "sourcePluginID",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub source_plugin_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub plugin_authority: Option<PluginCapabilityAuthority>,
    pub validated_input: Data,
    #[serde(rename = "snapshotID")]
    pub snapshot_id: String,
    pub scene_revision: u64,
    pub created_at: SwiftDate,
}

impl CapabilityInvocationDraft {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        id: String,
        capability_id: String,
        capability_version: i64,
        schema_hash: String,
        source_plugin_id: Option<String>,
        plugin_authority: Option<PluginCapabilityAuthority>,
        validated_input: Data,
        snapshot_id: String,
        scene_revision: u64,
        created_at: SwiftDate,
    ) -> Self {
        Self {
            id,
            capability_id,
            capability_version,
            schema_hash,
            source_plugin_id,
            plugin_authority,
            validated_input,
            snapshot_id,
            scene_revision,
            created_at,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CapabilityDraftError {
    UnknownTool(String),
    ReadCapabilityCannotBeDrafted(String),
    ExternalSideEffectDisabled(String),
    StaleSnapshot,
    StaleSceneRevision { expected: u64, actual: u64 },
    ContractChanged(String),
    InvalidInput(String),
    InputTooLarge,
    DraftNotFound(String),
    DraftExpired(String),
    TooManyDrafts,
    DuplicateDraftID(String),
    UnsupportedBuiltInCapability(String),
}

impl fmt::Display for CapabilityDraftError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            CapabilityDraftError::UnknownTool(name) => {
                write!(formatter, "unknown or unexposed capability tool '{name}'")
            }
            CapabilityDraftError::ReadCapabilityCannotBeDrafted(id) => write!(
                formatter,
                "read capability '{id}' cannot create a write draft"
            ),
            CapabilityDraftError::ExternalSideEffectDisabled(id) => {
                write!(
                    formatter,
                    "external side-effect capability '{id}' is disabled"
                )
            }
            CapabilityDraftError::StaleSnapshot => {
                formatter.write_str("capability exposure snapshot is stale")
            }
            CapabilityDraftError::StaleSceneRevision { expected, actual } => write!(
                formatter,
                "scene revision changed (expected {expected}, actual {actual})"
            ),
            CapabilityDraftError::ContractChanged(id) => {
                write!(formatter, "capability contract changed for '{id}'")
            }
            CapabilityDraftError::InvalidInput(reason) => {
                write!(formatter, "invalid capability input: {reason}")
            }
            CapabilityDraftError::InputTooLarge => {
                formatter.write_str("capability input exceeds 1 MiB")
            }
            CapabilityDraftError::DraftNotFound(id) => {
                write!(formatter, "capability draft '{id}' was not found")
            }
            CapabilityDraftError::DraftExpired(id) => {
                write!(formatter, "capability draft '{id}' expired")
            }
            CapabilityDraftError::TooManyDrafts => {
                formatter.write_str("a plan may contain at most 100 capability drafts")
            }
            CapabilityDraftError::DuplicateDraftID(id) => {
                write!(
                    formatter,
                    "capability draft '{id}' cannot be submitted twice"
                )
            }
            CapabilityDraftError::UnsupportedBuiltInCapability(id) => write!(
                formatter,
                "capability '{id}' cannot be lowered by the built-in scene adapter"
            ),
        }
    }
}

impl std::error::Error for CapabilityDraftError {}

/// Serialized access to validated model write proposals. Creating a draft never
/// mutates a scene.
pub struct CapabilityDraftStore {
    registry: CapabilityRegistry,
    ttl: f64,
    drafts: Mutex<BTreeMap<String, CapabilityInvocationDraft>>,
}

impl Default for CapabilityDraftStore {
    fn default() -> Self {
        // Swift's `init(registry: CapabilityRegistry = .aiDefault)`.
        Self::new(BuiltInTypedCapabilityCatalog::registry())
    }
}

impl CapabilityDraftStore {
    pub const DEFAULT_TTL: f64 = CapabilityDraftLimits::TIME_TO_LIVE_SECONDS;
    pub const MAXIMUM_INPUT_BYTES: usize = CapabilityDraftLimits::MAXIMUM_INPUT_BYTES;
    pub const MAXIMUM_DRAFTS_PER_PLAN: usize = CapabilityDraftLimits::MAXIMUM_DRAFTS_PER_PLAN;

    pub fn new(registry: CapabilityRegistry) -> Self {
        Self::with_ttl(registry, Self::DEFAULT_TTL)
    }

    pub fn with_ttl(registry: CapabilityRegistry, ttl: f64) -> Self {
        Self {
            registry,
            ttl: ttl.max(1.0),
            drafts: Mutex::new(BTreeMap::new()),
        }
    }

    pub fn create_draft(
        &self,
        tool_name: &str,
        input: &[u8],
        snapshot: &CapabilityExposureSnapshot,
        current_scene_revision: u64,
        now: SwiftDate,
    ) -> Result<CapabilityInvocationDraft, CapabilityDraftError> {
        self.create_draft_with_registry(
            tool_name,
            input,
            snapshot,
            current_scene_revision,
            now,
            &self.registry,
        )
    }

    // A retained exposure session may expand against a newer registry while
    // keeping its existing drafts. Validate against the caller's atomic catalog
    // snapshot without mutating this store's registry.
    pub(crate) fn create_draft_with_registry(
        &self,
        tool_name: &str,
        input: &[u8],
        snapshot: &CapabilityExposureSnapshot,
        current_scene_revision: u64,
        now: SwiftDate,
        registry: &CapabilityRegistry,
    ) -> Result<CapabilityInvocationDraft, CapabilityDraftError> {
        if input.len() > Self::MAXIMUM_INPUT_BYTES {
            return Err(CapabilityDraftError::InputTooLarge);
        }
        let snapshot_age = now.0 - snapshot.created_at.0;
        if !(snapshot_age >= 0.0 && snapshot_age <= self.ttl) {
            return Err(CapabilityDraftError::StaleSnapshot);
        }
        if let Some(expected) = snapshot.scene_revision
            && expected != current_scene_revision
        {
            return Err(CapabilityDraftError::StaleSceneRevision {
                expected,
                actual: current_scene_revision,
            });
        }
        let Some(exposed) = snapshot.contract_for_tool_name(tool_name) else {
            return Err(CapabilityDraftError::UnknownTool(tool_name.to_string()));
        };
        if !exposed.access.is_write() {
            return Err(CapabilityDraftError::ReadCapabilityCannotBeDrafted(
                exposed.id.clone(),
            ));
        }
        if exposed.access == CapabilityAccess::ExternalSideEffect {
            return Err(CapabilityDraftError::ExternalSideEffectDisabled(
                exposed.id.clone(),
            ));
        }
        let Some(current) = registry
            .descriptor(&exposed.id)
            .map(|descriptor| descriptor.contract())
        else {
            return Err(CapabilityDraftError::ContractChanged(exposed.id.clone()));
        };
        if current.version != exposed.version
            || current.schema_hash != exposed.schema_hash
            || current.access != exposed.access
            || current.source != exposed.source
        {
            return Err(CapabilityDraftError::ContractChanged(exposed.id.clone()));
        }
        let canonical = canonicalise(input)?;
        let value: serde_json::Value = serde_json::from_slice(&canonical)
            .map_err(|error| CapabilityDraftError::InvalidInput(error.to_string()))?;
        validate_capability_input(&value, &exposed.input_schema)
            .map_err(|error| CapabilityDraftError::InvalidInput(error.to_string()))?;
        let plugin_authority = plugin_authority(exposed, snapshot)?;
        let mut drafts = self.lock_drafts();
        purge_expired(&mut drafts, self.ttl, now);
        let draft = CapabilityInvocationDraft::new(
            diffuse_kernel::codable::new_uuid(),
            exposed.id.clone(),
            exposed.version,
            exposed.schema_hash.clone(),
            exposed.source.plugin_id.clone(),
            plugin_authority,
            Data::from_bytes(canonical),
            snapshot.id.clone(),
            current_scene_revision,
            now,
        );
        drafts.insert(draft.id.clone(), draft.clone());
        Ok(draft)
    }

    /// Revalidates every authority-bearing field. Drafts remain available until
    /// the caller explicitly consumes them after a transaction is staged.
    pub fn validated_drafts(
        &self,
        ids: &[String],
        snapshot: &CapabilityExposureSnapshot,
        current_scene_revision: u64,
        now: SwiftDate,
    ) -> Result<Vec<CapabilityInvocationDraft>, CapabilityDraftError> {
        self.validated_drafts_with_registry(
            ids,
            snapshot,
            current_scene_revision,
            now,
            &self.registry,
        )
    }

    pub(crate) fn validated_drafts_with_registry(
        &self,
        ids: &[String],
        snapshot: &CapabilityExposureSnapshot,
        current_scene_revision: u64,
        now: SwiftDate,
        registry: &CapabilityRegistry,
    ) -> Result<Vec<CapabilityInvocationDraft>, CapabilityDraftError> {
        if ids.len() > Self::MAXIMUM_DRAFTS_PER_PLAN {
            return Err(CapabilityDraftError::TooManyDrafts);
        }
        let mut seen = std::collections::BTreeSet::new();
        if let Some(duplicate) = ids.iter().find(|id| !seen.insert((*id).clone())) {
            return Err(CapabilityDraftError::DuplicateDraftID(duplicate.clone()));
        }
        let snapshot_age = now.0 - snapshot.created_at.0;
        if !(snapshot_age >= 0.0 && snapshot_age <= self.ttl) {
            return Err(CapabilityDraftError::StaleSnapshot);
        }
        let mut drafts = self.lock_drafts();
        purge_expired(&mut drafts, self.ttl, now);
        let mut validated = Vec::with_capacity(ids.len());
        for id in ids {
            let Some(draft) = drafts.get(id).cloned() else {
                return Err(CapabilityDraftError::DraftNotFound(id.clone()));
            };
            if now.0 - draft.created_at.0 > self.ttl {
                drafts.remove(id);
                return Err(CapabilityDraftError::DraftExpired(id.clone()));
            }
            if draft.snapshot_id != snapshot.id {
                return Err(CapabilityDraftError::StaleSnapshot);
            }
            if draft.scene_revision != current_scene_revision {
                return Err(CapabilityDraftError::StaleSceneRevision {
                    expected: draft.scene_revision,
                    actual: current_scene_revision,
                });
            }
            let Some(exposed) = snapshot.contract(&draft.capability_id) else {
                return Err(CapabilityDraftError::ContractChanged(
                    draft.capability_id.clone(),
                ));
            };
            let Some(current) = registry
                .descriptor(&draft.capability_id)
                .map(|descriptor| descriptor.contract())
            else {
                return Err(CapabilityDraftError::ContractChanged(
                    draft.capability_id.clone(),
                ));
            };
            if exposed.version != draft.capability_version
                || exposed.schema_hash != draft.schema_hash
                || exposed.access != current.access
                || exposed.source.plugin_id != draft.source_plugin_id
                || exposed.source != current.source
                || current.version != draft.capability_version
                || current.schema_hash != draft.schema_hash
                || plugin_authority(exposed, snapshot)? != draft.plugin_authority
            {
                return Err(CapabilityDraftError::ContractChanged(
                    draft.capability_id.clone(),
                ));
            }
            let value: serde_json::Value = serde_json::from_slice(draft.validated_input.as_slice())
                .map_err(|error| CapabilityDraftError::InvalidInput(error.to_string()))?;
            validate_capability_input(&value, &current.input_schema)
                .map_err(|error| CapabilityDraftError::InvalidInput(error.to_string()))?;
            validated.push(draft);
        }
        Ok(validated)
    }

    pub fn consume(&self, ids: &[String]) {
        let mut drafts = self.lock_drafts();
        for id in ids {
            drafts.remove(id);
        }
    }

    pub fn has_pending_drafts(&self) -> bool {
        !self.lock_drafts().is_empty()
    }

    pub fn remove_all(&self) {
        self.lock_drafts().clear();
    }

    fn lock_drafts(
        &self,
    ) -> std::sync::MutexGuard<'_, BTreeMap<String, CapabilityInvocationDraft>> {
        match self.drafts.lock() {
            Ok(drafts) => drafts,
            Err(poisoned) => poisoned.into_inner(),
        }
    }
}

fn purge_expired(
    drafts: &mut BTreeMap<String, CapabilityInvocationDraft>,
    ttl: f64,
    now: SwiftDate,
) {
    drafts.retain(|_, draft| now.0 - draft.created_at.0 <= ttl);
}

fn canonicalise(data: &[u8]) -> Result<Vec<u8>, CapabilityDraftError> {
    let value: serde_json::Value = serde_json::from_slice(data)
        .map_err(|_| CapabilityDraftError::InvalidInput("invalid JSON".to_string()))?;
    if !value.is_object() {
        return Err(CapabilityDraftError::InvalidInput(
            "input must be a JSON object".to_string(),
        ));
    }
    serde_json::to_vec(&value)
        .map_err(|error| CapabilityDraftError::InvalidInput(error.to_string()))
}

fn plugin_authority(
    contract: &CapabilityContract,
    snapshot: &CapabilityExposureSnapshot,
) -> Result<Option<PluginCapabilityAuthority>, CapabilityDraftError> {
    let Some(plugin_id) = &contract.source.plugin_id else {
        return Ok(None);
    };
    match snapshot.authority(plugin_id) {
        Some(authority) if &authority.plugin_id == plugin_id => Ok(Some(authority.clone())),
        _ => Err(CapabilityDraftError::ContractChanged(contract.id.clone())),
    }
}

/// Compatibility lowering used while the old SceneEditStep wire format remains.
/// Plugin composition also lowers to these same host-owned primitive calls.
pub struct SceneCapabilityDraftLowering;

impl SceneCapabilityDraftLowering {
    pub fn plan(
        summary: &str,
        reasoning: Option<&str>,
        drafts: &[CapabilityInvocationDraft],
    ) -> Result<SceneEditPlan, CapabilityDraftError> {
        let steps = drafts
            .iter()
            .map(|draft| -> Result<SceneEditStep, CapabilityDraftError> {
                let Some(operation) = SceneEditOp::from_capability_id(&draft.capability_id) else {
                    return Err(CapabilityDraftError::UnsupportedBuiltInCapability(
                        draft.capability_id.clone(),
                    ));
                };
                let mut input: serde_json::Map<String, serde_json::Value> =
                    serde_json::from_slice(draft.validated_input.as_slice()).map_err(|_| {
                        CapabilityDraftError::InvalidInput(
                            "draft input is not an object".to_string(),
                        )
                    })?;
                input.insert(
                    "op".to_string(),
                    serde_json::Value::String(operation.raw_value().to_string()),
                );
                let data = serde_json::to_vec(&serde_json::Value::Object(input))
                    .map_err(|error| CapabilityDraftError::InvalidInput(error.to_string()))?;
                serde_json::from_slice(&data)
                    .map_err(|error| CapabilityDraftError::InvalidInput(error.to_string()))
            })
            .collect::<Result<Vec<SceneEditStep>, CapabilityDraftError>>()?;
        Ok(SceneEditPlan::new(
            summary.to_string(),
            reasoning.map(str::to_string),
            steps,
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::{CapabilityDraftError, SceneCapabilityDraftLowering};
    use crate::planning::capability_draft_pipeline::CapabilityInvocationDraft;
    use crate::planning::scene_edit_plan::SceneEditOp;
    use diffuse_capability::support::swift_date::SwiftDate;
    use diffuse_plugin::base64_data::Data;

    fn draft(capability_id: &str, input: &str) -> CapabilityInvocationDraft {
        CapabilityInvocationDraft::new(
            "draft".to_string(),
            capability_id.to_string(),
            1,
            "hash".to_string(),
            None,
            None,
            Data::from_bytes(input.as_bytes()),
            "snapshot".to_string(),
            1,
            SwiftDate(0.0),
        )
    }

    #[test]
    fn lowering_injects_the_legacy_operation_name() {
        let plan = SceneCapabilityDraftLowering::plan(
            "move it",
            None,
            &[draft(
                "scene.set_transform",
                r#"{"entity_id":"scene:1","position":[1,2,3]}"#,
            )],
        )
        .expect("lowering succeeds");
        assert_eq!(plan.summary, "move it");
        assert_eq!(plan.steps.len(), 1);
        assert_eq!(plan.steps[0].op, SceneEditOp::SetTransform);
        assert_eq!(plan.steps[0].entity_ref.as_deref(), Some("scene:1"));
        assert_eq!(plan.steps[0].position, Some(vec![1.0, 2.0, 3.0]));
    }

    #[test]
    fn lowering_rejects_capabilities_without_a_legacy_operation() {
        let error =
            SceneCapabilityDraftLowering::plan("s", None, &[draft("plugin.custom_thing", r#"{}"#)])
                .expect_err("unsupported capability");
        assert_eq!(
            error,
            CapabilityDraftError::UnsupportedBuiltInCapability("plugin.custom_thing".to_string())
        );
    }

    #[test]
    fn error_descriptions_match_swift() {
        assert_eq!(
            CapabilityDraftError::StaleSceneRevision {
                expected: 4,
                actual: 5
            }
            .to_string(),
            "scene revision changed (expected 4, actual 5)"
        );
        assert_eq!(
            CapabilityDraftError::InputTooLarge.to_string(),
            "capability input exceeds 1 MiB"
        );
    }
}
