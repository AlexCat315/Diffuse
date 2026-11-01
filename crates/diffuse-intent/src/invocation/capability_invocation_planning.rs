//! Capability identity, authority and scene-precondition checks before commit.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;

use diffuse_capability::capability_contract::{CapabilityAccess, PluginCapabilityAuthority};
use diffuse_capability::capability_descriptor::CapabilityDescriptor;
use diffuse_capability::capability_registry::CapabilityRegistry;
use diffuse_capability::capability_validator::CapabilityValidator;
use diffuse_capability::drafts::precondition_checker::PreconditionCheckInput;
use diffuse_capability::release::release_phase_gate::ReleasePhaseGate;
use diffuse_scene::entity_id::EntityID;
use diffuse_scene::runtime_world::{Children, Parent, WorldTransform};
use diffuse_scene::scene_bootstrap::{SceneKindComponent, SceneNameComponent};
use diffuse_scene::scene_runtime::SceneRuntime;

use super::ambiguity_scorer::{
    AmbiguityLevel, AmbiguityScore, AmbiguityScorer, AmbiguityScoringContext,
};
use super::capability_invocation::{
    CapabilityInvocationPlannerError, ConfirmationOption, ConfirmationQuestion,
    ConfirmationQuestionKind, ConfirmationSeverity,
};
use crate::capabilities::built_in_typed_capabilities::BuiltInTypedCapabilityCatalog;
use crate::planning::intent_ir::{
    IntentArgumentValue, IntentEvidence, IntentIR, IntentSource, IntentVector3,
};
use crate::transactions::transaction_ir::{
    AssetMutation, CapabilityInvocationRecord, SceneMutation, SequenceMutation,
    TransactionApprovalPolicy, TransactionIR, TransactionOperation,
};

#[derive(Clone, Debug, PartialEq)]
pub struct CapabilityInvocationContext {
    pub selected_entity_id: Option<u64>,
    pub scene_entity_ids: BTreeSet<u64>,
    pub component_types_by_entity_id: BTreeMap<u64, BTreeSet<String>>,
    pub is_scene_editable: bool,
    pub default_source: IntentSource,
    pub default_confidence: f64,
    pub default_evidence: Vec<IntentEvidence>,
}

impl Default for CapabilityInvocationContext {
    fn default() -> Self {
        Self {
            selected_entity_id: None,
            scene_entity_ids: BTreeSet::new(),
            component_types_by_entity_id: BTreeMap::new(),
            is_scene_editable: true,
            default_source: IntentSource::System,
            default_confidence: 1.0,
            default_evidence: Vec::new(),
        }
    }
}

impl CapabilityInvocationContext {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        selected_entity_id: Option<u64>,
        scene_entity_ids: BTreeSet<u64>,
        component_types_by_entity_id: BTreeMap<u64, BTreeSet<String>>,
        is_scene_editable: bool,
        default_source: IntentSource,
        default_confidence: f64,
        default_evidence: Vec<IntentEvidence>,
    ) -> Self {
        Self {
            selected_entity_id,
            scene_entity_ids,
            component_types_by_entity_id,
            is_scene_editable,
            default_source,
            default_confidence,
            default_evidence,
        }
    }

    pub fn from_scene_runtime(
        scene_runtime: &SceneRuntime,
        selected_entity_id: Option<u64>,
        is_scene_editable: bool,
        default_source: IntentSource,
        default_confidence: f64,
        default_evidence: Vec<IntentEvidence>,
    ) -> Self {
        let entities = scene_runtime.entities();
        let component_types_by_entity_id = entities
            .iter()
            .map(|&entity| {
                (
                    entity.raw_value(),
                    Self::component_type_names(entity, scene_runtime),
                )
            })
            .collect();
        Self::new(
            selected_entity_id,
            entities.iter().map(|e| e.raw_value()).collect(),
            component_types_by_entity_id,
            is_scene_editable,
            default_source,
            default_confidence,
            default_evidence,
        )
    }

    fn component_type_names(entity: EntityID, scene: &SceneRuntime) -> BTreeSet<String> {
        let mut names = BTreeSet::new();
        for (name, present) in [
            (
                "WorldTransform",
                scene.has_component::<WorldTransform>(entity),
            ),
            ("Parent", scene.has_component::<Parent>(entity)),
            ("Children", scene.has_component::<Children>(entity)),
            (
                "SceneNameComponent",
                scene.has_component::<SceneNameComponent>(entity),
            ),
            (
                "SceneKindComponent",
                scene.has_component::<SceneKindComponent>(entity),
            ),
        ] {
            if present {
                names.insert(name.to_string());
            }
        }
        for schema in &scene.component_registry().schemas {
            if scene.has_component_by_type_id(&schema.type_id, entity) {
                // Rust's registry stores a qualified type_name; the contract uses
                // Swift's unqualified runtime type names.
                names.insert(
                    schema
                        .runtime_type_name
                        .rsplit("::")
                        .next()
                        .unwrap_or(&schema.runtime_type_name)
                        .to_string(),
                );
            }
        }
        names
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct CapabilityInvocationPlan {
    pub approval_policy: TransactionApprovalPolicy,
    pub questions: Vec<ConfirmationQuestion>,
    pub warnings: Vec<String>,
}

impl CapabilityInvocationPlan {
    pub fn new(
        approval_policy: TransactionApprovalPolicy,
        questions: Vec<ConfirmationQuestion>,
        warnings: Vec<String>,
    ) -> Self {
        Self {
            approval_policy,
            questions,
            warnings,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CapabilityValidationFailure {
    pub verb: String,
    pub reason: String,
}

impl CapabilityValidationFailure {
    pub fn new(verb: impl Into<String>, reason: impl Into<String>) -> Self {
        Self {
            verb: verb.into(),
            reason: reason.into(),
        }
    }
}

pub type PluginAuthorityValidator = Arc<dyn Fn(&PluginCapabilityAuthority) -> bool + Send + Sync>;

#[derive(Clone)]
pub struct CapabilityInvocationPlanner {
    registry: CapabilityRegistry,
    validator: CapabilityValidator,
    scorer: AmbiguityScorer,
    allow_external_side_effects: bool,
    plugin_authorities: BTreeMap<String, PluginCapabilityAuthority>,
    plugin_authority_validator: PluginAuthorityValidator,
}

impl CapabilityInvocationPlanner {
    pub fn new(
        registry: CapabilityRegistry,
        gate: ReleasePhaseGate,
        scorer: AmbiguityScorer,
        allow_external_side_effects: bool,
        plugin_authorities: BTreeMap<String, PluginCapabilityAuthority>,
        plugin_authority_validator: PluginAuthorityValidator,
    ) -> Self {
        Self {
            validator: CapabilityValidator::new(registry.clone(), gate),
            registry,
            scorer,
            allow_external_side_effects,
            plugin_authorities,
            plugin_authority_validator,
        }
    }

    pub fn plan(
        &self,
        transaction: &TransactionIR,
        context: &CapabilityInvocationContext,
    ) -> Result<CapabilityInvocationPlan, CapabilityInvocationPlannerError> {
        let intents = self.capability_intents(transaction, context);
        if intents.is_empty() {
            return Ok(CapabilityInvocationPlan::new(
                transaction.approval_policy,
                Vec::new(),
                Vec::new(),
            ));
        }
        let mut failures = Vec::new();
        let mut questions = Vec::new();
        let mut warnings = Vec::new();
        let mut approval_policy = transaction.approval_policy;
        for (index, intent) in intents.iter().enumerate() {
            let Some(descriptor) = self.registry.descriptor(&intent.verb) else {
                failures.push(CapabilityValidationFailure::new(
                    &intent.verb,
                    "unknown capability verb",
                ));
                continue;
            };
            if !transaction.capability_invocations.is_empty()
                && let Some(reason) = self.invocation_record_denial_reason(
                    &transaction.capability_invocations[index],
                    &descriptor,
                )
            {
                failures.push(CapabilityValidationFailure::new(&intent.verb, reason));
                continue;
            }
            let (entity_ids, invalid_target) =
                Self::parse_target_entity_ids(&intent.target_object_ids);
            if let Some(invalid) = invalid_target {
                failures.push(CapabilityValidationFailure::new(
                    &intent.verb,
                    format!("invalid target '{invalid}'"),
                ));
                continue;
            }
            let input = PreconditionCheckInput {
                verb: intent.verb.clone(),
                argument_names: intent.arguments.keys().cloned().collect(),
                target_entity_ids: entity_ids,
                selected_entity_id: context.selected_entity_id,
                scene_entity_ids: context.scene_entity_ids.clone(),
                component_types_by_entity_id: context.component_types_by_entity_id.clone(),
                is_scene_editable: context.is_scene_editable,
            };
            if let Err(error) = self.validator.validate(&intent.verb, &input) {
                failures.push(CapabilityValidationFailure::new(
                    &intent.verb,
                    error.to_string(),
                ));
                continue;
            }
            let score = self.scorer.score(
                intent,
                &AmbiguityScoringContext {
                    candidate_entity_ids: context.scene_entity_ids.iter().copied().collect(),
                    selected_entity_id: context.selected_entity_id,
                    requires_target: descriptor.requires_target_entity(),
                    is_verb_destructive: descriptor.is_destructive,
                    required_argument_names: descriptor.required_argument_names(),
                },
            );
            warnings.extend(
                score
                    .signals
                    .iter()
                    .map(|signal| format!("[{}] {}", intent.verb, signal.note)),
            );
            let is_model_or_plugin_write = descriptor.access.is_write()
                && (!transaction.capability_invocations.is_empty()
                    || intent.source == IntentSource::Ai);
            if is_model_or_plugin_write
                || descriptor.requires_confirmation
                || descriptor.is_destructive
                || score.level >= AmbiguityLevel::Low
            {
                approval_policy =
                    escalated_policy(approval_policy, TransactionApprovalPolicy::RequiresApproval);
                questions.push(
                    self.scorer
                        .make_question(intent, &score, Vec::new())
                        .unwrap_or_else(|| {
                            Self::make_confirmation_question(intent, &descriptor, &score)
                        }),
                );
            }
        }
        if !failures.is_empty() {
            return Err(CapabilityInvocationPlannerError::CapabilityDenied(failures));
        }
        Ok(CapabilityInvocationPlan::new(
            approval_policy,
            questions,
            warnings,
        ))
    }

    fn capability_intents(
        &self,
        transaction: &TransactionIR,
        context: &CapabilityInvocationContext,
    ) -> Vec<IntentIR> {
        if !transaction.capability_invocations.is_empty() {
            return transaction
                .capability_invocations
                .iter()
                .enumerate()
                .map(|(index, record)| IntentIR {
                    id: format!("{}:invocation:{index}", transaction.id),
                    verb: record.capability_id.clone(),
                    summary: transaction.summary.clone(),
                    target_object_ids: record.target_references.clone(),
                    arguments: record
                        .argument_names
                        .iter()
                        .map(|name| {
                            (
                                name.clone(),
                                IntentArgumentValue::String("<validated>".to_string()),
                            )
                        })
                        .collect(),
                    confidence: context.default_confidence,
                    evidence: context.default_evidence.clone(),
                    source: context.default_source,
                    created_at: transaction.created_at,
                })
                .collect();
        }
        if let Some(intent) = &transaction.intent {
            return vec![intent.clone()];
        }
        transaction
            .operations
            .iter()
            .enumerate()
            .map(|(index, operation)| {
                let projection = CapabilityOperationProjection::new(operation);
                IntentIR {
                    id: format!("{}:capability:{index}", transaction.id),
                    summary: if transaction.summary.is_empty() {
                        projection.verb.to_string()
                    } else {
                        transaction.summary.clone()
                    },
                    verb: projection.verb.to_string(),
                    target_object_ids: projection
                        .target_entity_id
                        .map(|id| vec![format!("scene:{id}")])
                        .unwrap_or_default(),
                    arguments: projection.arguments,
                    confidence: context.default_confidence,
                    evidence: context.default_evidence.clone(),
                    source: context.default_source,
                    created_at: transaction.created_at,
                }
            })
            .collect()
    }

    fn invocation_record_denial_reason(
        &self,
        record: &CapabilityInvocationRecord,
        descriptor: &CapabilityDescriptor,
    ) -> Option<String> {
        let contract = descriptor.contract();
        let reason = if !descriptor.is_ai_exposed {
            "capability is not approved for AI exposure"
        } else if contract.access.is_write() && !contract.input_schema.is_strict_capability_input()
        {
            "write capability schema contains an open or unsupported type"
        } else if record.capability_version != contract.version {
            return Some(format!(
                "capability version mismatch (expected {}, got {})",
                contract.version, record.capability_version
            ));
        } else if record.schema_hash != contract.schema_hash {
            "capability schema hash mismatch"
        } else if record.access != contract.access {
            "capability access level mismatch"
        } else if record.source_plugin_id != contract.source.plugin_id {
            "capability source mismatch"
        } else {
            if let Some(plugin_id) = &contract.source.plugin_id {
                let valid = record.plugin_authority.as_ref().is_some_and(|authority| {
                    self.plugin_authorities.get(plugin_id) == Some(authority)
                        && (self.plugin_authority_validator)(authority)
                });
                if !valid {
                    return Some(
                        "plugin authorisation or PluginHost generation changed".to_string(),
                    );
                }
            } else if record.plugin_authority.is_some() {
                return Some("built-in capability carried forged plugin authority".to_string());
            }
            if contract.access == CapabilityAccess::ExternalSideEffect
                && !self.allow_external_side_effects
            {
                return Some("external side-effect capabilities are disabled".to_string());
            }
            return None;
        };
        Some(reason.to_string())
    }

    fn make_confirmation_question(
        intent: &IntentIR,
        descriptor: &CapabilityDescriptor,
        score: &AmbiguityScore,
    ) -> ConfirmationQuestion {
        let mut question = ConfirmationQuestion::new(
            format!("capability:{}", intent.id),
            if descriptor.is_destructive {
                ConfirmationQuestionKind::ApproveDestructive
            } else {
                ConfirmationQuestionKind::ChooseOne
            },
            if intent.summary.is_empty() {
                format!("Confirm: {}", intent.verb)
            } else {
                intent.summary.clone()
            },
            if descriptor.is_destructive {
                ConfirmationSeverity::Destructive
            } else {
                ConfirmationSeverity::Warn
            },
            true,
            score.score,
        );
        question.prompt_detail = Some(format!("Capability: {}", intent.verb));
        let mut confirm = ConfirmationOption::new("confirm", "Apply");
        confirm.label_detail = Some(format!("Proceed with '{}'", intent.verb));
        let mut skip = ConfirmationOption::new("skip", "Discard");
        skip.label_detail = Some("Discard this intent".to_string());
        question.options = vec![confirm, skip];
        question.default_option_id = Some("confirm".to_string());
        question.source_proposal_ids = vec![intent.id.clone()];
        question
    }

    fn parse_target_entity_ids(targets: &[String]) -> (Vec<u64>, Option<String>) {
        let mut entity_ids = Vec::with_capacity(targets.len());
        for target in targets {
            let raw = target.strip_prefix("scene:").unwrap_or(target);
            let Ok(id) = raw.parse::<u64>() else {
                return (entity_ids, Some(target.clone()));
            };
            entity_ids.push(id);
        }
        (entity_ids, None)
    }
}

impl Default for CapabilityInvocationPlanner {
    fn default() -> Self {
        Self::new(
            BuiltInTypedCapabilityCatalog::registry(),
            ReleasePhaseGate::default(),
            AmbiguityScorer::default(),
            false,
            BTreeMap::new(),
            Arc::new(|_| true),
        )
    }
}

struct CapabilityOperationProjection {
    verb: &'static str,
    target_entity_id: Option<u64>,
    arguments: BTreeMap<String, IntentArgumentValue>,
}

impl CapabilityOperationProjection {
    fn new(operation: &TransactionOperation) -> Self {
        match operation {
            TransactionOperation::Scene(mutation) => Self::from_scene(mutation),
            TransactionOperation::Sequence(SequenceMutation::ReplaceDocument(_)) => Self {
                verb: "sequence.replace_document",
                target_entity_id: None,
                arguments: BTreeMap::new(),
            },
            TransactionOperation::Asset(AssetMutation::ScanProject { root_path }) => Self {
                verb: "asset.scan_project",
                target_entity_id: None,
                arguments: BTreeMap::from([(
                    "root_path".to_string(),
                    IntentArgumentValue::String(root_path.clone()),
                )]),
            },
        }
    }

    fn from_scene(mutation: &SceneMutation) -> Self {
        use IntentArgumentValue::{Integer, StableId, String as Text, Vec3};
        let mut arguments = BTreeMap::new();
        let verb = match mutation {
            SceneMutation::SpawnImportedMeshEntity {
                label, position, ..
            }
            | SceneMutation::SpawnEmptyEntity {
                label, position, ..
            } => {
                arguments.insert("label".to_string(), Text(label.clone()));
                arguments.insert(
                    "position".to_string(),
                    Vec3(IntentVector3::from_simd(*position)),
                );
                "scene.spawn_entity"
            }
            SceneMutation::SpawnLightEntity {
                label, position, ..
            } => {
                arguments.insert("label".to_string(), Text(label.clone()));
                arguments.insert(
                    "position".to_string(),
                    Vec3(IntentVector3::from_simd(*position)),
                );
                "scene.spawn_light"
            }
            SceneMutation::SpawnCameraEntity {
                label, position, ..
            } => {
                arguments.insert("label".to_string(), Text(label.clone()));
                arguments.insert(
                    "position".to_string(),
                    Vec3(IntentVector3::from_simd(*position)),
                );
                "scene.spawn_camera"
            }
            SceneMutation::DeleteEntity { .. } => "scene.delete_entity",
            SceneMutation::DuplicateEntity { .. } => "scene.duplicate_entity",
            SceneMutation::DuplicateEntityWithOffset {
                position_offset, ..
            } => {
                arguments.insert(
                    "offset".to_string(),
                    Vec3(IntentVector3::from_simd(*position_offset)),
                );
                "scene.duplicate_entity_offset"
            }
            SceneMutation::MoveEntity {
                parent_id, index, ..
            } => {
                if let Some(id) = parent_id {
                    arguments.insert("parent_id".to_string(), StableId(*id));
                }
                arguments.insert("index".to_string(), Integer(*index));
                "scene.reparent_entity"
            }
            SceneMutation::SetLocalTransform { transform, .. } => {
                arguments.insert(
                    "translation".to_string(),
                    Vec3(IntentVector3::from_simd(transform.translation())),
                );
                "scene.set_transform"
            }
            SceneMutation::SetSceneName { value, .. } => {
                arguments.insert("name".to_string(), Text(value.clone()));
                "scene.set_name"
            }
            SceneMutation::SetComponentData { type_id, .. } => {
                arguments.insert("type_id".to_string(), Text(type_id.clone()));
                "scene.set_component_data"
            }
            SceneMutation::AddComponent { type_id, .. } => {
                arguments.insert("type_id".to_string(), Text(type_id.clone()));
                "scene.add_component"
            }
            SceneMutation::RemoveComponentData { type_id, .. } => {
                arguments.insert("type_id".to_string(), Text(type_id.clone()));
                "scene.remove_component_data"
            }
        };
        Self {
            verb,
            target_entity_id: mutation.entity_id(),
            arguments,
        }
    }
}

fn escalated_policy(
    current: TransactionApprovalPolicy,
    other: TransactionApprovalPolicy,
) -> TransactionApprovalPolicy {
    use TransactionApprovalPolicy::{Automatic, Forbidden, RequiresApproval};
    if current == Forbidden || other == Forbidden {
        Forbidden
    } else if current == RequiresApproval || other == RequiresApproval {
        RequiresApproval
    } else {
        Automatic
    }
}
