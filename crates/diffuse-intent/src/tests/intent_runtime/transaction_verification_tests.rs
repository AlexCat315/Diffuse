//! Ported from `Engine/Tests/IntentRuntimeTests/TransactionVerificationTests.swift`.

use std::collections::BTreeMap;
use std::sync::Arc;

use diffuse_capability::capability_contract::{CapabilityAccess, ReleasePhase};
use diffuse_capability::capability_registry::CapabilityRegistry;
use diffuse_capability::capsule_schema::JsonSchema;
use diffuse_capability::release::release_phase_gate::ReleasePhaseGate;
use diffuse_scene::components::core::registry::ComponentRegistry;
use diffuse_scene::scene_bootstrap::SceneNameComponent;
use diffuse_scene::scene_runtime::SceneRuntime;
use serde::{Deserialize, Serialize};

use crate::capabilities::built_in_typed_capabilities::BuiltInTypedCapabilityCatalog;
use crate::capabilities::cove_capability::{
    AnyCapabilityRegistration, CapabilityPreparationContext, CapabilityPreparationError,
    CapabilityPreview, CoveCapability, CoveCapabilityInput, PreparedCapability,
};
use crate::intent_runtime_coordinator::{
    CapabilityInvocationDisposition, IntentRuntimeCoordinator, IntentRuntimeCoordinatorError,
};
use crate::invocation::ambiguity_scorer::AmbiguityScorer;
use crate::invocation::capability_input_declaration::{
    CapabilitySchemaValue, SceneEntityRef, Vec3, field_schema,
};
use crate::invocation::capability_invocation::{
    CapabilityInvocationPlannerError, ConfirmationAnswer, ConfirmationAnswerOutcome,
    ConfirmationResolution,
};
use crate::invocation::capability_invocation_planning::{
    CapabilityInvocationContext, CapabilityInvocationPlanner,
};
use crate::planning::intent_ir::IntentSource;
use crate::planning::scene_state_verification::SceneStateAssertion;
use crate::transactions::transaction_executor::{
    TransactionExecutionContext, TransactionExecutionError, TransactionExecutor,
};
use crate::transactions::transaction_ir::{
    CapabilityInvocationRecord, SceneMutation, TransactionApprovalPolicy, TransactionBaseRevisions,
    TransactionIR, TransactionOperation, TransactionProvenance, TransactionVerificationAssertion,
};

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
struct RenameInput {
    #[serde(rename = "entity_id")]
    entity_id: u64,
    name: String,
}

impl CoveCapabilityInput for RenameInput {
    fn input_schema() -> JsonSchema {
        JsonSchema::object(
            BTreeMap::from([
                (
                    "entity_id".to_string(),
                    JsonSchema::integer(Some(0.0), None),
                ),
                ("name".to_string(), JsonSchema::string(Some(1), Some(128))),
            ]),
            vec!["entity_id".to_string(), "name".to_string()],
        )
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct RenameCapability;

impl CoveCapability for RenameCapability {
    type Input = RenameInput;
    type Error = CapabilityPreparationError;

    const ID: &'static str = "test.rename";
    const TITLE: &'static str = "Rename";
    const DESCRIPTION: &'static str = "Rename an entity";
    const DOMAIN: &'static str = "scene";
    const ACCESS: CapabilityAccess = CapabilityAccess::ReversibleWrite;
    const RELEASE_PHASE: ReleasePhase = ReleasePhase::Stable;

    fn prepare(
        input: RenameInput,
        _context: &CapabilityPreparationContext,
    ) -> Result<PreparedCapability, Self::Error> {
        Ok(PreparedCapability::new(
            vec![TransactionOperation::Scene(SceneMutation::SetSceneName {
                entity_id: input.entity_id,
                value: input.name.clone(),
            })],
            CapabilityPreview::new("Rename", vec![format!("scene:{}", input.entity_id)]),
            vec![TransactionVerificationAssertion::EntityExists(
                input.entity_id,
            )],
        ))
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
struct UnsafeInput {
    payload: String,
}

impl CoveCapabilityInput for UnsafeInput {
    fn input_schema() -> JsonSchema {
        JsonSchema::object(
            BTreeMap::from([("payload".to_string(), JsonSchema::any())]),
            vec!["payload".to_string()],
        )
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct UnsafeCapability;

impl CoveCapability for UnsafeCapability {
    type Input = UnsafeInput;
    type Error = CapabilityPreparationError;

    const ID: &'static str = "test.unsafe";
    const TITLE: &'static str = "Unsafe";
    const DESCRIPTION: &'static str = "Contains an open value";
    const DOMAIN: &'static str = "scene";
    const ACCESS: CapabilityAccess = CapabilityAccess::ReversibleWrite;
    const RELEASE_PHASE: ReleasePhase = ReleasePhase::Stable;

    fn prepare(
        input: UnsafeInput,
        _context: &CapabilityPreparationContext,
    ) -> Result<PreparedCapability, Self::Error> {
        Ok(PreparedCapability::new(
            vec![TransactionOperation::Scene(SceneMutation::SetSceneName {
                entity_id: 1,
                value: input.payload,
            })],
            CapabilityPreview::new("Unsafe", Vec::new()),
            vec![TransactionVerificationAssertion::EntityExists(1)],
        ))
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
struct DeclaredTransformInput {
    entity: SceneEntityRef,
    position: Option<Vec3>,
    scale: Option<Vec3>,
}

impl CoveCapabilityInput for DeclaredTransformInput {
    fn input_schema() -> JsonSchema {
        JsonSchema::object(
            BTreeMap::from([
                ("entity".to_string(), SceneEntityRef::capability_schema()),
                (
                    "position".to_string(),
                    field_schema::<Option<Vec3>>(
                        Some("New world position"),
                        None,
                        None,
                        None,
                        None,
                        None,
                    ),
                ),
                (
                    "scale".to_string(),
                    field_schema::<Option<Vec3>>(
                        None,
                        Some(0.001),
                        Some(1_000.0),
                        None,
                        None,
                        None,
                    ),
                ),
            ]),
            vec!["entity".to_string()],
        )
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct DeclaredTransformCapability;

impl CoveCapability for DeclaredTransformCapability {
    type Input = DeclaredTransformInput;
    type Error = CapabilityPreparationError;

    const ID: &'static str = "test.declared_transform";
    const TITLE: &'static str = "Declared transform";
    const DESCRIPTION: &'static str = "Exercises generated input metadata";
    const DOMAIN: &'static str = "scene";
    const ACCESS: CapabilityAccess = CapabilityAccess::ReversibleWrite;
    const RELEASE_PHASE: ReleasePhase = ReleasePhase::Stable;

    fn prepare(
        input: DeclaredTransformInput,
        _context: &CapabilityPreparationContext,
    ) -> Result<PreparedCapability, Self::Error> {
        let raw_id = input.entity.entity_id();
        Ok(PreparedCapability::new(
            vec![TransactionOperation::Scene(SceneMutation::SetSceneName {
                entity_id: raw_id,
                value: "Declared".to_string(),
            })],
            CapabilityPreview::new("Declared input", vec![input.entity.as_str().to_string()]),
            vec![TransactionVerificationAssertion::EntityExists(raw_id)],
        ))
    }
}

fn scene() -> SceneRuntime {
    SceneRuntime::new(ComponentRegistry::built_in())
}

fn context(scene: SceneRuntime) -> TransactionExecutionContext {
    TransactionExecutionContext {
        scene_runtime: Some(scene),
        ..TransactionExecutionContext::default()
    }
}

/// Typed registration derives contract decoder and prepared transaction.
#[test]
fn typed_registration_uses_one_contract() {
    let registration = AnyCapabilityRegistration::new::<RenameCapability>().expect("registration");
    let prepared = registration
        .prepare(
            br#"{"entity_id":42,"name":"Renamed"}"#,
            &CapabilityPreparationContext::new(7, Vec::new()),
        )
        .expect("prepared");
    assert_eq!(registration.contract.id, "test.rename");
    assert_eq!(
        registration.descriptor().contract().schema_hash,
        registration.contract.schema_hash
    );
    assert_eq!(
        prepared.operations,
        vec![TransactionOperation::Scene(SceneMutation::SetSceneName {
            entity_id: 42,
            value: "Renamed".to_string(),
        })]
    );
    assert_eq!(
        prepared.assertions,
        vec![
            TransactionVerificationAssertion::EntityExists(42),
            TransactionVerificationAssertion::SceneState(SceneStateAssertion::SceneName {
                entity_id: 42,
                value: "Renamed".to_string(),
            }),
        ]
    );

    let error = match AnyCapabilityRegistration::new::<UnsafeCapability>() {
        Ok(_) => panic!("open schema must be rejected"),
        Err(error) => error,
    };
    assert_eq!(
        error,
        crate::capabilities::cove_capability::CapabilityRegistrationError::WriteSchemaContainsUnsupportedType(
            "test.unsafe".to_string()
        )
    );
}

/// Field declarations generate a strict schema and the matching decoder.
#[test]
fn declared_input_generates_schema_and_decoder() {
    let registration =
        AnyCapabilityRegistration::new::<DeclaredTransformCapability>().expect("registration");
    let schema = &registration.contract.input_schema;
    assert_eq!(schema.additional_properties, Some(false));
    assert_eq!(schema.required, vec!["entity".to_string()]);
    assert!(schema.properties["position"].description.is_none());
    let position_alternatives = &schema.properties["position"].one_of;
    assert!(
        position_alternatives
            .iter()
            .any(|alternative| alternative.description.as_deref() == Some("New world position"))
    );
    let scale_alternatives = &schema.properties["scale"].one_of;
    let scale_schema = scale_alternatives
        .iter()
        .find(|alternative| {
            alternative.r#type == Some(diffuse_capability::capsule_schema::JsonSchemaType::Array)
        })
        .expect("array alternative");
    let items = scale_schema.items.as_ref().expect("items");
    assert_eq!(items.minimum, Some(0.001));
    assert_eq!(items.maximum, Some(1_000.0));

    let prepared = registration
        .prepare(
            br#"{"entity":"scene:42","position":[1,2,3]}"#,
            &CapabilityPreparationContext::new(1, Vec::new()),
        )
        .expect("prepared");
    assert_eq!(
        prepared.preview.target_references,
        vec!["scene:42".to_string()]
    );
    assert_eq!(
        prepared.assertions,
        vec![
            TransactionVerificationAssertion::EntityExists(42),
            TransactionVerificationAssertion::SceneState(SceneStateAssertion::SceneName {
                entity_id: 42,
                value: "Declared".to_string(),
            }),
        ]
    );

    assert!(
        registration
            .prepare(
                br#"{"entity":"not-a-scene-ref"}"#,
                &CapabilityPreparationContext::new(1, Vec::new()),
            )
            .is_err()
    );
}

/// A failed post-apply assertion restores the scene snapshot.
#[test]
fn assertion_failure_rolls_back() {
    let mut scene = scene();
    let entity = scene.create_entity();
    scene.set_component(SceneNameComponent::new("Original"), entity);
    let original_revision = scene.snapshot().revision;
    let mut transaction = TransactionIR::new(
        "Rename with a deliberately failing assertion",
        vec![TransactionOperation::Scene(SceneMutation::SetSceneName {
            entity_id: entity.raw_value(),
            value: "Changed".to_string(),
        })],
        TransactionProvenance::Proposal,
    );
    transaction.verification_assertions = vec![TransactionVerificationAssertion::EntityIsAbsent(
        entity.raw_value(),
    )];
    transaction.base_revisions = TransactionBaseRevisions {
        scene_revision: Some(original_revision),
        ..TransactionBaseRevisions::default()
    };
    let mut context = context(scene);

    let error = TransactionExecutor::new()
        .apply(&transaction, &mut context)
        .expect_err("assertion fails");
    assert!(matches!(error, TransactionExecutionError::Executor(_)));
    let restored = context.scene_runtime.as_ref().expect("scene");
    assert_eq!(restored.snapshot().revision, original_revision);
    assert_eq!(
        restored
            .component::<SceneNameComponent>(entity)
            .map(|name| name.value),
        Some("Original".to_string())
    );
}

/// An exact scene-state mismatch restores the scene snapshot.
#[test]
fn exact_scene_state_failure_rolls_back() {
    let mut scene = scene();
    let entity = scene.create_entity();
    scene.set_component(SceneNameComponent::new("Original"), entity);
    let original_revision = scene.snapshot().revision;
    let mut transaction = TransactionIR::new(
        "Rename with an incorrect exact postcondition",
        vec![TransactionOperation::Scene(SceneMutation::SetSceneName {
            entity_id: entity.raw_value(),
            value: "Changed".to_string(),
        })],
        TransactionProvenance::Proposal,
    );
    transaction.verification_assertions = vec![TransactionVerificationAssertion::SceneState(
        SceneStateAssertion::SceneName {
            entity_id: entity.raw_value(),
            value: "Unexpected".to_string(),
        },
    )];
    transaction.base_revisions = TransactionBaseRevisions {
        scene_revision: Some(original_revision),
        ..TransactionBaseRevisions::default()
    };
    let mut context = context(scene);

    let error = TransactionExecutor::new()
        .apply(&transaction, &mut context)
        .expect_err("exact verification fails");
    assert!(!format!("{error:?}").contains("Unexpected"));
    let restored = context.scene_runtime.as_ref().expect("scene");
    assert_eq!(restored.snapshot().revision, original_revision);
    assert_eq!(
        restored
            .component::<SceneNameComponent>(entity)
            .map(|name| name.value),
        Some("Original".to_string())
    );
}

/// The final exact assertion wins when a field is written more than once.
#[test]
fn repeated_field_uses_final_postcondition() {
    let mut scene = scene();
    let entity = scene.create_entity();
    scene.set_component(SceneNameComponent::new("Original"), entity);
    let mut transaction = TransactionIR::new(
        "Rename twice",
        vec![
            TransactionOperation::Scene(SceneMutation::SetSceneName {
                entity_id: entity.raw_value(),
                value: "Intermediate".to_string(),
            }),
            TransactionOperation::Scene(SceneMutation::SetSceneName {
                entity_id: entity.raw_value(),
                value: "Final".to_string(),
            }),
        ],
        TransactionProvenance::Proposal,
    );
    transaction.verification_assertions = vec![
        TransactionVerificationAssertion::SceneState(SceneStateAssertion::SceneName {
            entity_id: entity.raw_value(),
            value: "Intermediate".to_string(),
        }),
        TransactionVerificationAssertion::SceneState(SceneStateAssertion::SceneName {
            entity_id: entity.raw_value(),
            value: "Final".to_string(),
        }),
    ];
    transaction.base_revisions = TransactionBaseRevisions {
        scene_revision: Some(scene.snapshot().revision),
        ..TransactionBaseRevisions::default()
    };
    let mut context = context(scene);

    TransactionExecutor::new()
        .apply(&transaction, &mut context)
        .expect("transaction applies");
    assert_eq!(
        context
            .scene_runtime
            .as_ref()
            .and_then(|scene| scene.component::<SceneNameComponent>(entity))
            .map(|name| name.value),
        Some("Final".to_string())
    );
}

/// Exact scene assertions preserve their Codable contract.
#[test]
fn exact_scene_assertion_codable_round_trip() {
    let assertion = TransactionVerificationAssertion::SceneState(SceneStateAssertion::Material {
        entity_id: 42,
        base_color: vec![0.1, 0.2, 0.3, 1.0],
        metallic: 0.4,
        roughness: 0.5,
        emissive: vec![0.6, 0.7, 0.8],
    });
    let encoded = serde_json::to_string(&assertion).expect("encode");
    let decoded: TransactionVerificationAssertion = serde_json::from_str(&encoded).expect("decode");
    assert_eq!(decoded, assertion);
}

fn accept(
    request: &crate::invocation::capability_invocation::ConfirmationRequestBatch,
) -> ConfirmationResolution {
    ConfirmationResolution::new(
        request.batch_id.clone(),
        request.correlation_id.clone(),
        request
            .questions
            .iter()
            .map(|question| {
                let mut answer = ConfirmationAnswer::new(
                    question.id.clone(),
                    ConfirmationAnswerOutcome::Accepted,
                );
                answer.picked_option_id = Some("confirm".to_string());
                answer
            })
            .collect(),
        false,
    )
}

fn ai_context(scene: &SceneRuntime) -> CapabilityInvocationContext {
    CapabilityInvocationContext::from_scene_runtime(
        scene,
        None,
        true,
        IntentSource::Ai,
        1.0,
        Vec::new(),
    )
}

/// Explicit destructive AI invocation requires plan and destructive
/// confirmations.
#[test]
fn destructive_ai_uses_two_rounds() {
    let mut scene = scene();
    let entity = scene.create_entity();
    let descriptor = BuiltInTypedCapabilityCatalog::registry()
        .descriptor("scene.delete_entity")
        .expect("descriptor");
    let contract = descriptor.contract();
    let mut transaction = TransactionIR::new(
        "Delete entity",
        vec![TransactionOperation::Scene(SceneMutation::DeleteEntity {
            entity_id: entity.raw_value(),
        })],
        TransactionProvenance::Proposal,
    );
    transaction.capability_invocations = vec![CapabilityInvocationRecord {
        argument_names: vec!["entity_id".to_string()],
        target_references: vec![format!("scene:{}", entity.raw_value())],
        ..CapabilityInvocationRecord::new(
            descriptor.verb.clone(),
            descriptor.version,
            contract.schema_hash.clone(),
            contract.input_digest(b"{}"),
            CapabilityAccess::DestructiveWrite,
        )
    }];
    transaction.verification_assertions = vec![
        TransactionVerificationAssertion::DeletedEntity(entity.raw_value()),
        TransactionVerificationAssertion::EntityIsAbsent(entity.raw_value()),
    ];
    transaction.base_revisions = TransactionBaseRevisions {
        scene_revision: Some(scene.snapshot().revision),
        ..TransactionBaseRevisions::default()
    };
    transaction.approval_policy = TransactionApprovalPolicy::Automatic;

    let coordinator = IntentRuntimeCoordinator::default();
    let mut context = context(scene);
    let capability_context = ai_context(context.scene_runtime.as_ref().expect("scene"));

    let first = coordinator
        .submit_plan(
            &transaction,
            &mut context,
            Some(capability_context),
            crate::pipeline::commit_pipeline::CommitEntry::Ui,
        )
        .expect("submitted");
    let first_request = first.confirmation_request.clone().expect("first request");
    assert_eq!(
        first_request.questions[0].severity,
        crate::invocation::capability_invocation::ConfirmationSeverity::Warn
    );
    assert_eq!(
        first
            .staged_result
            .as_ref()
            .map(|result| result.preview.mutation_summaries.clone()),
        Some(vec![format!("scene:delete:{}", entity.raw_value())])
    );
    let second = coordinator
        .resolve_plan_confirmation(&accept(&first_request), &mut context)
        .expect("second round");
    let second_request = second.confirmation_request.clone().expect("second request");
    assert_eq!(
        second.disposition,
        CapabilityInvocationDisposition::ConfirmationRequested
    );
    assert_eq!(
        second_request.questions[0].severity,
        crate::invocation::capability_invocation::ConfirmationSeverity::Destructive
    );
    assert!(
        context
            .scene_runtime
            .as_ref()
            .is_some_and(|scene| scene.contains(entity))
    );

    let applied = coordinator
        .resolve_plan_confirmation(&accept(&second_request), &mut context)
        .expect("applied");
    assert_eq!(
        applied.disposition,
        CapabilityInvocationDisposition::Applied
    );
    assert!(
        !context
            .scene_runtime
            .as_ref()
            .is_some_and(|scene| scene.contains(entity))
    );
}

/// AI capability authority is checked again after confirmation.
#[test]
fn permission_revocation_before_apply_fails_closed() {
    let mut scene = scene();
    let entity = scene.create_entity();
    scene.set_component(SceneNameComponent::new("Original"), entity);
    let descriptor = BuiltInTypedCapabilityCatalog::registry()
        .descriptor("scene.set_name")
        .expect("descriptor");
    let contract = descriptor.contract();
    let mut transaction = TransactionIR::new(
        "Rename entity",
        vec![TransactionOperation::Scene(SceneMutation::SetSceneName {
            entity_id: entity.raw_value(),
            value: "Changed".to_string(),
        })],
        TransactionProvenance::Proposal,
    );
    transaction.capability_invocations = vec![CapabilityInvocationRecord {
        argument_names: vec!["entity_id".to_string(), "name".to_string()],
        target_references: vec![format!("scene:{}", entity.raw_value())],
        ..CapabilityInvocationRecord::new(
            descriptor.verb.clone(),
            descriptor.version,
            contract.schema_hash.clone(),
            contract.input_digest(b"{}"),
            CapabilityAccess::ReversibleWrite,
        )
    }];
    transaction.verification_assertions = vec![TransactionVerificationAssertion::EntityExists(
        entity.raw_value(),
    )];
    transaction.base_revisions = TransactionBaseRevisions {
        scene_revision: Some(scene.snapshot().revision),
        ..TransactionBaseRevisions::default()
    };
    transaction.approval_policy = TransactionApprovalPolicy::Automatic;

    let coordinator = IntentRuntimeCoordinator::default();
    let mut context = context(scene);
    let capability_context = ai_context(context.scene_runtime.as_ref().expect("scene"));
    let submitted = coordinator
        .submit_plan(
            &transaction,
            &mut context,
            Some(capability_context),
            crate::pipeline::commit_pipeline::CommitEntry::Ui,
        )
        .expect("submitted");
    let request = submitted.confirmation_request.clone().expect("request");

    let mut revoked = descriptor.clone();
    revoked.is_ai_exposed = false;
    coordinator.configure_capability_planner(CapabilityInvocationPlanner::new(
        CapabilityRegistry::new(vec![revoked]),
        ReleasePhaseGate::default(),
        AmbiguityScorer::default(),
        false,
        BTreeMap::new(),
        Arc::new(|_| true),
    ));

    let error = coordinator
        .resolve_plan_confirmation(&accept(&request), &mut context)
        .expect_err("revoked authority fails closed");
    assert!(error.is::<CapabilityInvocationPlannerError>());
    assert_eq!(
        context
            .scene_runtime
            .as_ref()
            .and_then(|scene| scene.component::<SceneNameComponent>(entity))
            .map(|name| name.value),
        Some("Original".to_string())
    );
    assert!(coordinator.pending_confirmation_request().is_none());
}

/// Explicit AI authority cannot bypass the capability planner.
#[test]
fn missing_capability_context_fails_closed() {
    let descriptor = BuiltInTypedCapabilityCatalog::registry()
        .descriptor("scene.set_name")
        .expect("descriptor");
    let contract = descriptor.contract();
    let mut transaction = TransactionIR::new(
        "Forged direct invocation",
        Vec::new(),
        TransactionProvenance::Proposal,
    );
    transaction.capability_invocations = vec![CapabilityInvocationRecord::new(
        descriptor.verb.clone(),
        descriptor.version,
        contract.schema_hash.clone(),
        contract.input_digest(b"{}"),
        descriptor.access,
    )];
    transaction.approval_policy = TransactionApprovalPolicy::Automatic;
    let mut context = context(scene());

    let error = IntentRuntimeCoordinator::default()
        .submit_plan(
            &transaction,
            &mut context,
            None,
            crate::pipeline::commit_pipeline::CommitEntry::Ui,
        )
        .expect_err("missing context");
    assert!(error.is::<IntentRuntimeCoordinatorError>());
}
