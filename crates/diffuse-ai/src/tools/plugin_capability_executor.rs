//! Ported from `Engine/Sources/AIRuntime/Tools/PluginCapabilityExecutor.swift`.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;

use diffuse_capability::capability_contract::{
    CapabilityAccess, CapabilityContract, CapabilityExposurePolicy, CapabilityExposureSnapshot,
    PluginCapabilityAuthority, ReleasePhase,
};
use diffuse_capability::capability_registry::CapabilityRegistry;
use diffuse_capability::capsule_schema::validate_capability_input;
use diffuse_capability::drafts::capability_draft_limits::CapabilityDraftLimits;
use diffuse_capability::release::release_phase_gate::ReleasePhaseGate;
use diffuse_intent::CapabilityInvocationPlanner;
use diffuse_intent::invocation::ambiguity_scorer::AmbiguityScorer;
use diffuse_intent::transactions::transaction_ir::{
    CapabilityInvocationRecord, TransactionApprovalPolicy, TransactionBaseRevisions, TransactionIR,
    TransactionProvenance,
};
use diffuse_plugin::PluginError;
use diffuse_plugin::base64_data::Data;
use diffuse_plugin::contract::plugin_manifest::{PluginImportPermission, PluginResourceLimits};
use diffuse_plugin::host::host_capability_call::PluginCompositionValidator;
use diffuse_plugin::host::plugin_host_rpc::{
    PluginCapabilityInvoking, PluginPreparedCapabilityResult, PluginQuerySnapshot,
    PluginQuerySnapshotError,
};
use diffuse_plugin::plugin_authorization::{PluginExecutionBinding, PluginInspection};
use diffuse_scene::scene_runtime::SceneRuntime;

use crate::planning::capability_draft_pipeline::{
    CapabilityDraftError, CapabilityInvocationDraft, SceneCapabilityDraftLowering,
};
use crate::planning::scene_edit_plan_executor::SceneEditPlanExecutor;

/// Swift's asynchronous query-snapshot seam. Hosts run it on their own thread.
pub type PluginQuerySnapshotProvider = Arc<
    dyn Fn(
            &str,
            u64,
        ) -> Result<Option<PluginQuerySnapshot>, Box<dyn std::error::Error + Send + Sync>>
        + Send
        + Sync,
>;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PluginCapabilityExecutorError {
    DuplicatePlugin(String),
    UnknownPlugin(String),
    CapabilityUnavailable(String),
    AuthorityChanged(String),
    StaleSceneRevision {
        expected: u64,
        actual: u64,
    },
    ResultKindMismatch(String),
    InvalidReadResult(String),
    PayloadTooLarge(String),
    InvalidInput {
        capability_id: String,
        reason: String,
    },
}

impl std::fmt::Display for PluginCapabilityExecutorError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PluginCapabilityExecutorError::DuplicatePlugin(id) => {
                write!(
                    formatter,
                    "plugin '{id}' has more than one execution binding"
                )
            }
            PluginCapabilityExecutorError::UnknownPlugin(id) => {
                write!(formatter, "plugin '{id}' is not enabled")
            }
            PluginCapabilityExecutorError::CapabilityUnavailable(id) => {
                write!(formatter, "plugin capability '{id}' is unavailable")
            }
            PluginCapabilityExecutorError::AuthorityChanged(id) => write!(
                formatter,
                "plugin '{id}' changed code, authorisation, or PluginHost generation"
            ),
            PluginCapabilityExecutorError::StaleSceneRevision { expected, actual } => write!(
                formatter,
                "scene revision changed (expected {expected}, actual {actual})"
            ),
            PluginCapabilityExecutorError::ResultKindMismatch(id) => {
                write!(
                    formatter,
                    "plugin capability '{id}' returned the wrong result kind"
                )
            }
            PluginCapabilityExecutorError::InvalidReadResult(id) => {
                write!(formatter, "read capability '{id}' returned invalid JSON")
            }
            PluginCapabilityExecutorError::PayloadTooLarge(id) => {
                write!(
                    formatter,
                    "plugin capability '{id}' exceeded the 1 MiB payload limit"
                )
            }
            PluginCapabilityExecutorError::InvalidInput {
                capability_id,
                reason,
            } => write!(formatter, "invalid input for '{capability_id}': {reason}"),
        }
    }
}

impl std::error::Error for PluginCapabilityExecutorError {}

/// Swift's initializer and methods surfaced `PluginError` and
/// `CapabilityDraftError` as well; one wrapper keeps `?` usable.
#[derive(Debug)]
pub enum PluginCapabilityExecutionFailure {
    Executor(PluginCapabilityExecutorError),
    Plugin(PluginError),
    QuerySnapshot(PluginQuerySnapshotError),
    Draft(CapabilityDraftError),
    ScenePlan(crate::planning::scene_edit_plan_executor::SceneEditPlanExecutorError),
}

impl std::fmt::Display for PluginCapabilityExecutionFailure {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PluginCapabilityExecutionFailure::Executor(error) => error.fmt(formatter),
            PluginCapabilityExecutionFailure::Plugin(error) => error.fmt(formatter),
            PluginCapabilityExecutionFailure::QuerySnapshot(error) => error.fmt(formatter),
            PluginCapabilityExecutionFailure::Draft(error) => error.fmt(formatter),
            PluginCapabilityExecutionFailure::ScenePlan(error) => error.fmt(formatter),
        }
    }
}

impl std::error::Error for PluginCapabilityExecutionFailure {}

impl From<PluginCapabilityExecutorError> for PluginCapabilityExecutionFailure {
    fn from(error: PluginCapabilityExecutorError) -> Self {
        PluginCapabilityExecutionFailure::Executor(error)
    }
}

impl From<PluginError> for PluginCapabilityExecutionFailure {
    fn from(error: PluginError) -> Self {
        PluginCapabilityExecutionFailure::Plugin(error)
    }
}

impl From<PluginQuerySnapshotError> for PluginCapabilityExecutionFailure {
    fn from(error: PluginQuerySnapshotError) -> Self {
        PluginCapabilityExecutionFailure::QuerySnapshot(error)
    }
}

impl From<CapabilityDraftError> for PluginCapabilityExecutionFailure {
    fn from(error: CapabilityDraftError) -> Self {
        PluginCapabilityExecutionFailure::Draft(error)
    }
}

impl From<crate::planning::scene_edit_plan_executor::SceneEditPlanExecutorError>
    for PluginCapabilityExecutionFailure
{
    fn from(error: crate::planning::scene_edit_plan_executor::SceneEditPlanExecutorError) -> Self {
        PluginCapabilityExecutionFailure::ScenePlan(error)
    }
}

#[derive(Clone, Debug, PartialEq)]
enum InvocationSegment {
    BuiltIn(usize),
    // Boxed so a built-in segment is not padded to the size of an invocation
    // record.
    Plugin(Box<CapabilityInvocationRecord>, usize),
}

/// Connects authorised plugin Components to the same model Draft and host-owned
/// transaction pipeline as built-in capabilities. A plugin write is expanded
/// only to validated built-in calls; it can never emit TransactionOperation.
#[derive(Clone)]
pub struct PluginCapabilityExecutor {
    pub registry: CapabilityRegistry,
    pub plugin_authorities: BTreeMap<String, PluginCapabilityAuthority>,
    host_registry: CapabilityRegistry,
    bindings: BTreeMap<String, PluginExecutionBinding>,
    invoker: Arc<dyn PluginCapabilityInvoking + Send + Sync>,
}

impl PluginCapabilityExecutor {
    pub fn new(
        host_registry: &CapabilityRegistry,
        bindings: Vec<PluginExecutionBinding>,
        enabled_declarations: &[PluginInspection],
        invoker: Arc<dyn PluginCapabilityInvoking + Send + Sync>,
    ) -> Result<Self, PluginCapabilityExecutionFailure> {
        let mut by_id: BTreeMap<String, PluginExecutionBinding> = BTreeMap::new();
        let mut authorities: BTreeMap<String, PluginCapabilityAuthority> = BTreeMap::new();
        for binding in &bindings {
            let plugin_id = binding.plugin_id().to_string();
            if by_id.insert(plugin_id.clone(), binding.clone()).is_some() {
                return Err(PluginCapabilityExecutorError::DuplicatePlugin(plugin_id).into());
            }
            if !invoker.validate(binding) {
                return Err(PluginCapabilityExecutorError::AuthorityChanged(
                    binding.plugin_id().to_string(),
                )
                .into());
            }
            authorities.insert(binding.plugin_id().to_string(), binding.authority());
        }
        let registry =
            diffuse_plugin::plugin_authorization::PluginCapabilityRegistryBuilder::build(
                host_registry,
                &bindings,
                enabled_declarations,
            )?;
        Ok(Self {
            host_registry: host_registry.clone(),
            bindings: by_id,
            invoker,
            plugin_authorities: authorities,
            registry,
        })
    }

    pub fn exposure_policy(&self) -> CapabilityExposurePolicy {
        let mut policy = CapabilityExposurePolicy::new(ReleasePhase::Stable);
        policy.allowed_domains = Some(
            ["scene", "plugin"]
                .into_iter()
                .map(str::to_string)
                .collect::<BTreeSet<String>>(),
        );
        policy.enabled_plugin_ids = self.bindings.keys().cloned().collect();
        policy.maximum_capabilities = 16;
        policy
    }

    pub fn required_imports(
        &self,
        plugin_id: &str,
    ) -> Result<BTreeSet<PluginImportPermission>, PluginCapabilityExecutionFailure> {
        let binding = self
            .bindings
            .get(plugin_id)
            .ok_or_else(|| PluginCapabilityExecutorError::UnknownPlugin(plugin_id.to_string()))?;
        self.ensure_live(binding)?;
        Ok(binding
            .inspection
            .manifest
            .imports
            .iter()
            .copied()
            .collect())
    }

    /// Planner configured for both submit-time checks and the coordinator's
    /// second check immediately before applying a confirmed transaction.
    pub fn make_invocation_planner(
        &self,
        gate: ReleasePhaseGate,
        allow_external_side_effects: bool,
    ) -> CapabilityInvocationPlanner {
        let expected_bindings = self.bindings.clone();
        let live_invoker = self.invoker.clone();
        CapabilityInvocationPlanner::new(
            self.registry.clone(),
            gate,
            AmbiguityScorer::default(),
            allow_external_side_effects,
            self.plugin_authorities.clone(),
            Arc::new(move |authority: &PluginCapabilityAuthority| {
                let Some(binding) = expected_bindings.get(&authority.plugin_id) else {
                    return false;
                };
                if binding.authority() != *authority {
                    return false;
                }
                live_invoker.validate(binding)
            }),
        )
    }

    pub fn make_invocation_planner_with_defaults(&self) -> CapabilityInvocationPlanner {
        self.make_invocation_planner(ReleasePhaseGate::new(ReleasePhase::Stable), false)
    }

    /// Executes a read capability immediately after revalidating its exact
    /// snapshot authority. The returned JSON is untrusted model context only.
    pub fn execute_read(
        &self,
        tool_name: &str,
        input: &[u8],
        snapshot: &CapabilityExposureSnapshot,
        current_scene_revision: u64,
        query_snapshot: Option<&PluginQuerySnapshot>,
    ) -> Result<Data, PluginCapabilityExecutionFailure> {
        if input.len() > CapabilityDraftLimits::MAXIMUM_INPUT_BYTES {
            return Err(
                PluginCapabilityExecutorError::PayloadTooLarge(tool_name.to_string()).into(),
            );
        }
        if let Some(expected) = snapshot.scene_revision
            && expected != current_scene_revision
        {
            return Err(PluginCapabilityExecutorError::StaleSceneRevision {
                expected,
                actual: current_scene_revision,
            }
            .into());
        }
        let (contract, plugin_id) = match snapshot.contract_for_tool_name(tool_name) {
            Some(contract)
                if contract.access == CapabilityAccess::Read
                    && contract.source.plugin_id.is_some() =>
            {
                (
                    contract,
                    contract.source.plugin_id.clone().expect("checked above"),
                )
            }
            _ => {
                return Err(PluginCapabilityExecutorError::CapabilityUnavailable(
                    tool_name.to_string(),
                )
                .into());
            }
        };
        let binding = self.validated_binding(
            &plugin_id,
            contract,
            snapshot,
            snapshot.authority(&plugin_id),
        )?;
        self.validate_input(input, contract)?;
        self.validate_query_snapshot(query_snapshot, binding, current_scene_revision)?;
        let result =
            self.invoker
                .prepare_capability(binding, &contract.id, input, query_snapshot)?;
        self.ensure_live(binding)?;
        let PluginPreparedCapabilityResult::Read(payload) = result else {
            return Err(
                PluginCapabilityExecutorError::ResultKindMismatch(contract.id.clone()).into(),
            );
        };
        if payload.len() as i64 > PluginResourceLimits::secure_default().maximum_output_bytes {
            return Err(PluginCapabilityExecutorError::PayloadTooLarge(contract.id.clone()).into());
        }
        if serde_json::from_slice::<serde_json::Value>(&payload).is_err() {
            return Err(
                PluginCapabilityExecutorError::InvalidReadResult(contract.id.clone()).into(),
            );
        }
        Ok(Data::from_bytes(payload))
    }

    pub fn execute_read_with_defaults(
        &self,
        tool_name: &str,
        input: &[u8],
        snapshot: &CapabilityExposureSnapshot,
        current_scene_revision: u64,
    ) -> Result<Data, PluginCapabilityExecutionFailure> {
        self.execute_read(tool_name, input, snapshot, current_scene_revision, None)
    }

    /// Expands write Drafts in order, prepares all built-in operations against
    /// one shadow scene, and returns a transaction that records both the outer
    /// plugin invocation and every host primitive it composed.
    #[allow(clippy::too_many_arguments)]
    pub fn build_transaction(
        &self,
        summary: &str,
        reasoning: Option<&str>,
        drafts: &[CapabilityInvocationDraft],
        snapshot: &CapabilityExposureSnapshot,
        scene: &SceneRuntime,
        current_scene_revision: u64,
        query_snapshots: &BTreeMap<String, PluginQuerySnapshot>,
        approval_policy: TransactionApprovalPolicy,
    ) -> Result<TransactionIR, PluginCapabilityExecutionFailure> {
        if drafts.len() > CapabilityDraftLimits::MAXIMUM_DRAFTS_PER_PLAN {
            return Err(CapabilityDraftError::TooManyDrafts.into());
        }
        let mut seen_ids: BTreeSet<&str> = BTreeSet::new();
        if let Some(duplicate) = drafts
            .iter()
            .map(|draft| draft.id.as_str())
            .find(|id| !seen_ids.insert(id))
        {
            return Err(CapabilityDraftError::DuplicateDraftID(duplicate.to_string()).into());
        }
        if let Some(expected) = snapshot.scene_revision
            && expected != current_scene_revision
        {
            return Err(PluginCapabilityExecutorError::StaleSceneRevision {
                expected,
                actual: current_scene_revision,
            }
            .into());
        }

        let mut primitive_drafts: Vec<CapabilityInvocationDraft> = Vec::new();
        let mut segments: Vec<InvocationSegment> = Vec::new();

        for draft in drafts {
            if draft.snapshot_id != snapshot.id {
                return Err(PluginCapabilityExecutorError::CapabilityUnavailable(
                    draft.capability_id.clone(),
                )
                .into());
            }
            if draft.scene_revision != current_scene_revision {
                return Err(PluginCapabilityExecutorError::StaleSceneRevision {
                    expected: draft.scene_revision,
                    actual: current_scene_revision,
                }
                .into());
            }
            let exposed = snapshot
                .contract(&draft.capability_id)
                .filter(|exposed| {
                    exposed.version == draft.capability_version
                        && exposed.schema_hash == draft.schema_hash
                        && exposed.source.plugin_id == draft.source_plugin_id
                })
                .ok_or_else(|| {
                    PluginCapabilityExecutorError::CapabilityUnavailable(
                        draft.capability_id.clone(),
                    )
                })?;
            self.validate_input(draft.validated_input.as_slice(), exposed)?;

            let Some(plugin_id) = exposed.source.plugin_id.clone() else {
                if draft.plugin_authority.is_some() {
                    return Err(PluginCapabilityExecutorError::AuthorityChanged(
                        draft.capability_id.clone(),
                    )
                    .into());
                }
                primitive_drafts.push(draft.clone());
                segments.push(InvocationSegment::BuiltIn(1));
                continue;
            };
            if !exposed.access.is_write() {
                return Err(
                    PluginCapabilityExecutorError::ResultKindMismatch(exposed.id.clone()).into(),
                );
            }
            let binding = self.validated_binding(
                &plugin_id,
                exposed,
                snapshot,
                draft.plugin_authority.as_ref(),
            )?;
            let query_snapshot = query_snapshots.get(&plugin_id);
            self.validate_query_snapshot(query_snapshot, binding, current_scene_revision)?;
            let result = self.invoker.prepare_capability(
                binding,
                &exposed.id,
                draft.validated_input.as_slice(),
                query_snapshot,
            )?;
            self.ensure_live(binding)?;
            let PluginPreparedCapabilityResult::HostCalls(raw_calls) = result else {
                return Err(
                    PluginCapabilityExecutorError::ResultKindMismatch(exposed.id.clone()).into(),
                );
            };
            let calls = PluginCompositionValidator::validate(
                &raw_calls,
                &binding.inspection.manifest,
                &self.host_registry,
                &PluginResourceLimits::secure_default(),
            )?;
            let outer_record = CapabilityInvocationRecord {
                capability_id: exposed.id.clone(),
                capability_version: exposed.version,
                schema_hash: exposed.schema_hash.clone(),
                source_plugin_id: Some(plugin_id.clone()),
                plugin_authority: Some(binding.authority()),
                input_digest: exposed.input_digest(draft.validated_input.as_slice()),
                argument_names: top_level_argument_names(draft.validated_input.as_slice()),
                target_references: scene_references(draft.validated_input.as_slice()),
                access: exposed.access,
                exposure_snapshot_id: snapshot.id.clone(),
            };
            segments.push(InvocationSegment::Plugin(
                Box::new(outer_record),
                calls.len(),
            ));
            for call in &calls {
                let primitive = self
                    .host_registry
                    .descriptor(&call.capability_id)
                    .map(|descriptor| descriptor.contract())
                    .ok_or_else(|| {
                        PluginCapabilityExecutorError::CapabilityUnavailable(
                            call.capability_id.clone(),
                        )
                    })?;
                let canonical_arguments =
                    canonical_object(call.arguments.as_slice(), &call.capability_id)?;
                primitive_drafts.push(CapabilityInvocationDraft::new(
                    diffuse_kernel::codable::new_uuid(),
                    primitive.id.clone(),
                    primitive.version,
                    primitive.schema_hash.clone(),
                    None,
                    None,
                    Data::from_bytes(canonical_arguments),
                    snapshot.id.clone(),
                    current_scene_revision,
                    draft.created_at,
                ));
            }
        }

        if primitive_drafts.is_empty() {
            let mut transaction =
                TransactionIR::new(summary, Vec::new(), TransactionProvenance::Proposal);
            transaction.base_revisions = TransactionBaseRevisions {
                scene_revision: Some(current_scene_revision),
                ..TransactionBaseRevisions::new()
            };
            transaction.approval_policy = approval_policy;
            return Ok(transaction);
        }

        let plan = SceneCapabilityDraftLowering::plan(summary, reasoning, &primitive_drafts)?;
        let mut primitive_contracts_by_id: BTreeMap<String, CapabilityContract> = BTreeMap::new();
        for draft in &primitive_drafts {
            if let Some(contract) = self
                .host_registry
                .descriptor(&draft.capability_id)
                .map(|descriptor| descriptor.contract())
            {
                primitive_contracts_by_id.insert(draft.capability_id.clone(), contract);
            }
        }
        let primitive_contracts: Vec<CapabilityContract> =
            primitive_contracts_by_id.into_values().collect();
        let primitive_snapshot = CapabilityExposureSnapshot::new(
            snapshot.id.clone(),
            snapshot.generation,
            Some(current_scene_revision),
            primitive_contracts,
            snapshot.created_at,
            BTreeMap::new(),
        );
        let mut transaction = SceneEditPlanExecutor::new().build_transaction(
            &plan,
            scene,
            Some(current_scene_revision),
            approval_policy,
            Some(&primitive_snapshot),
            &self.host_registry,
        )?;

        let mut primitive_index = 0usize;
        let mut invocation_records: Vec<CapabilityInvocationRecord> = Vec::new();
        for segment in &segments {
            let count = match segment {
                InvocationSegment::BuiltIn(value) => *value,
                InvocationSegment::Plugin(outer, value) => {
                    invocation_records.push((**outer).clone());
                    *value
                }
            };
            let end = primitive_index + count;
            if end > transaction.capability_invocations.len() {
                return Err(PluginCapabilityExecutorError::CapabilityUnavailable(
                    "host preparation records".to_string(),
                )
                .into());
            }
            invocation_records.extend(
                transaction.capability_invocations[primitive_index..end]
                    .iter()
                    .cloned(),
            );
            primitive_index = end;
        }
        if primitive_index != transaction.capability_invocations.len() {
            return Err(PluginCapabilityExecutorError::CapabilityUnavailable(
                "host preparation records".to_string(),
            )
            .into());
        }
        transaction.capability_invocations = invocation_records;
        Ok(transaction)
    }

    pub fn build_transaction_with_defaults(
        &self,
        summary: &str,
        drafts: &[CapabilityInvocationDraft],
        snapshot: &CapabilityExposureSnapshot,
        scene: &SceneRuntime,
        current_scene_revision: u64,
    ) -> Result<TransactionIR, PluginCapabilityExecutionFailure> {
        self.build_transaction(
            summary,
            None,
            drafts,
            snapshot,
            scene,
            current_scene_revision,
            &BTreeMap::new(),
            TransactionApprovalPolicy::RequiresApproval,
        )
    }

    fn validated_binding<'a>(
        &'a self,
        plugin_id: &str,
        contract: &CapabilityContract,
        snapshot: &CapabilityExposureSnapshot,
        draft_authority: Option<&PluginCapabilityAuthority>,
    ) -> Result<&'a PluginExecutionBinding, PluginCapabilityExecutionFailure> {
        let binding = self
            .bindings
            .get(plugin_id)
            .ok_or_else(|| PluginCapabilityExecutorError::UnknownPlugin(plugin_id.to_string()))?;
        let exposed = self
            .registry
            .descriptor(&contract.id)
            .filter(|descriptor| descriptor.is_ai_exposed);
        let authority = binding.authority();
        let valid = exposed.is_some_and(|descriptor| {
            descriptor.contract() == *contract
                && binding.inspection.contracts.contains(contract)
                && snapshot.authority(plugin_id) == Some(&authority)
                && draft_authority == Some(&authority)
        });
        if !valid {
            return Err(
                PluginCapabilityExecutorError::AuthorityChanged(plugin_id.to_string()).into(),
            );
        }
        if !self.invoker.validate(binding) {
            return Err(
                PluginCapabilityExecutorError::AuthorityChanged(plugin_id.to_string()).into(),
            );
        }
        Ok(binding)
    }

    fn validate_input(
        &self,
        input: &[u8],
        contract: &CapabilityContract,
    ) -> Result<(), PluginCapabilityExecutionFailure> {
        if input.len() > CapabilityDraftLimits::MAXIMUM_INPUT_BYTES {
            return Err(PluginCapabilityExecutorError::PayloadTooLarge(contract.id.clone()).into());
        }
        let value: serde_json::Value = serde_json::from_slice(input).map_err(|error| {
            PluginCapabilityExecutorError::InvalidInput {
                capability_id: contract.id.clone(),
                reason: error.to_string(),
            }
        })?;
        validate_capability_input(&value, &contract.input_schema).map_err(|error| {
            PluginCapabilityExecutorError::InvalidInput {
                capability_id: contract.id.clone(),
                reason: error.to_string(),
            }
        })?;
        Ok(())
    }

    fn ensure_live(
        &self,
        binding: &PluginExecutionBinding,
    ) -> Result<(), PluginCapabilityExecutionFailure> {
        if self.invoker.validate(binding) {
            Ok(())
        } else {
            Err(
                PluginCapabilityExecutorError::AuthorityChanged(binding.plugin_id().to_string())
                    .into(),
            )
        }
    }

    fn validate_query_snapshot(
        &self,
        query_snapshot: Option<&PluginQuerySnapshot>,
        binding: &PluginExecutionBinding,
        scene_revision: u64,
    ) -> Result<(), PluginCapabilityExecutionFailure> {
        let imports: BTreeSet<PluginImportPermission> = binding
            .inspection
            .manifest
            .imports
            .iter()
            .copied()
            .filter(|permission| permission.is_snapshot())
            .collect();
        match query_snapshot {
            Some(query_snapshot) => {
                if query_snapshot.scene_revision != scene_revision {
                    return Err(PluginCapabilityExecutorError::StaleSceneRevision {
                        expected: query_snapshot.scene_revision,
                        actual: scene_revision,
                    }
                    .into());
                }
                query_snapshot.validate(&imports)?;
                Ok(())
            }
            None => {
                if imports.is_empty() {
                    return Ok(());
                }
                let mut sorted: Vec<PluginImportPermission> = imports.into_iter().collect();
                sorted.sort_by(|left, right| left.raw_value().cmp(right.raw_value()));
                Err(PluginQuerySnapshotError::MissingPayload(sorted[0]).into())
            }
        }
    }
}

fn canonical_object(
    input: &[u8],
    capability_id: &str,
) -> Result<Vec<u8>, PluginCapabilityExecutionFailure> {
    let value: serde_json::Value = serde_json::from_slice(input).map_err(|error| {
        PluginCapabilityExecutorError::InvalidInput {
            capability_id: capability_id.to_string(),
            reason: error.to_string(),
        }
    })?;
    if !value.is_object() {
        return Err(PluginCapabilityExecutorError::InvalidInput {
            capability_id: capability_id.to_string(),
            reason: "arguments must be an object".to_string(),
        }
        .into());
    }
    // `serde_json` writes object keys in sorted order, matching
    // `JSONSerialization` with `.sortedKeys`.
    let encoded = serde_json::to_vec(&value).map_err(|error| {
        PluginCapabilityExecutorError::InvalidInput {
            capability_id: capability_id.to_string(),
            reason: error.to_string(),
        }
    })?;
    Ok(encoded)
}

fn top_level_argument_names(input: &[u8]) -> Vec<String> {
    serde_json::from_slice::<serde_json::Value>(input)
        .ok()
        .and_then(|value| {
            value
                .as_object()
                .map(|object| object.keys().cloned().collect())
        })
        .unwrap_or_default()
}

fn scene_references(input: &[u8]) -> Vec<String> {
    let Ok(value) = serde_json::from_slice::<serde_json::Value>(input) else {
        return Vec::new();
    };
    let mut references: BTreeSet<String> = BTreeSet::new();
    fn visit(value: &serde_json::Value, references: &mut BTreeSet<String>) {
        match value {
            serde_json::Value::String(string) => {
                if let Some(rest) = string.strip_prefix("scene:")
                    && rest.parse::<u64>().is_ok()
                {
                    references.insert(string.clone());
                }
            }
            serde_json::Value::Array(array) => {
                for item in array {
                    visit(item, references);
                }
            }
            serde_json::Value::Object(object) => {
                for item in object.values() {
                    visit(item, references);
                }
            }
            _ => {}
        }
    }
    visit(&value, &mut references);
    references.into_iter().collect()
}
