//! Capability-planning half of
//! `Engine/Tests/IntentRuntimeTests/IntentRuntimeTests.swift`.

use std::collections::BTreeMap;
use std::sync::Arc;

use diffuse_capability::capability_contract::ReleasePhase;
use diffuse_capability::release::release_phase_gate::ReleasePhaseGate;
use diffuse_math::simd::simd_compat::Float3;
use diffuse_scene::components::core::value::ComponentValue;
use diffuse_scene::physics::rigid_body::{RigidBody, RigidBodyOptions};

use super::intent_runtime_tests::{capability_context, scene, scene_context};
use crate::capabilities::built_in_typed_capabilities::BuiltInTypedCapabilityCatalog;
use crate::intent_runtime_coordinator::{
    CapabilityInvocationDisposition, IntentRuntimeCoordinator,
};
use crate::invocation::ambiguity_scorer::AmbiguityScorer;
use crate::invocation::capability_invocation::{
    CapabilityInvocationPlannerError, ConfirmationAnswer, ConfirmationAnswerOutcome,
    ConfirmationResolution, ConfirmationSeverity,
};
use crate::invocation::capability_invocation_planning::CapabilityInvocationPlanner;
use crate::pipeline::commit_pipeline::{CommitEntry, CommitHandlerError};
use crate::planning::intent_ir::{IntentArgumentValue, IntentIR, IntentSource};
use crate::transactions::transaction_ir::{
    SceneMutation, TransactionApprovalPolicy, TransactionIR, TransactionOperation,
    TransactionProvenance,
};

fn planner_error(error: &CommitHandlerError) -> Option<&CapabilityInvocationPlannerError> {
    error.downcast_ref::<CapabilityInvocationPlannerError>()
}

fn beta_planner() -> CapabilityInvocationPlanner {
    CapabilityInvocationPlanner::new(
        BuiltInTypedCapabilityCatalog::registry(),
        ReleasePhaseGate::new(ReleasePhase::Beta),
        AmbiguityScorer::default(),
        false,
        BTreeMap::new(),
        Arc::new(|_| true),
    )
}

/// Capability planning escalates automatic destructive transactions to
/// confirmation.
#[test]
fn capability_planning_escalates_destructive_transactions() {
    let coordinator = IntentRuntimeCoordinator::default();
    let mut scene = scene();
    let entity = scene.create_entity();
    let mut transaction = TransactionIR::new(
        "Delete selected entity",
        vec![TransactionOperation::Scene(SceneMutation::DeleteEntity {
            entity_id: entity.raw_value(),
        })],
        TransactionProvenance::Authored,
    );
    transaction.intent = Some(IntentIR {
        target_object_ids: vec![format!("scene:{}", entity.raw_value())],
        ..IntentIR::new(
            "scene.delete_entity",
            "Delete selected entity",
            IntentSource::Human,
        )
    });
    transaction.approval_policy = TransactionApprovalPolicy::Automatic;
    let mut execution_context = scene_context(scene);
    let context = capability_context(
        execution_context.scene_runtime.as_ref().expect("scene"),
        IntentSource::Human,
        1.0,
    );

    let result = coordinator
        .submit_plan(
            &transaction,
            &mut execution_context,
            Some(context),
            CommitEntry::Ui,
        )
        .expect("submitted");

    assert_eq!(
        result.disposition,
        CapabilityInvocationDisposition::ConfirmationRequested
    );
    assert_eq!(
        result
            .confirmation_request
            .as_ref()
            .and_then(|request| request.questions.first())
            .map(|question| question.severity),
        Some(ConfirmationSeverity::Destructive)
    );
    assert_eq!(
        execution_context
            .scene_runtime
            .as_ref()
            .map(|scene| scene.snapshot().entity_count),
        Some(1)
    );
}

/// Capability planning blocks operations when required components are absent.
#[test]
fn capability_planning_blocks_missing_components() {
    let coordinator = IntentRuntimeCoordinator::default();
    let mut scene = scene();
    let entity = scene.create_entity();
    let mut transaction = TransactionIR::new(
        "Set light color",
        vec![TransactionOperation::Scene(
            SceneMutation::component_fields(
                entity.raw_value(),
                "light",
                vec![(
                    "color".to_string(),
                    Some(ComponentValue::Array(vec![
                        ComponentValue::Number(1.0),
                        ComponentValue::Number(0.0),
                        ComponentValue::Number(0.0),
                    ])),
                )],
            ),
        )],
        TransactionProvenance::Proposal,
    );
    transaction.approval_policy = TransactionApprovalPolicy::Automatic;
    let mut execution_context = scene_context(scene);
    let context = capability_context(
        execution_context.scene_runtime.as_ref().expect("scene"),
        IntentSource::Ai,
        0.9,
    );

    let error = coordinator
        .submit_plan(
            &transaction,
            &mut execution_context,
            Some(context),
            CommitEntry::Ui,
        )
        .expect_err("component is absent");
    match planner_error(&error).expect("planner error") {
        CapabilityInvocationPlannerError::CapabilityDenied(failures) => {
            assert_eq!(failures.len(), 1);
            assert_eq!(failures[0].verb, "scene.set_component_data");
            assert!(failures[0].reason.contains("unknown capability"));
        }
        other => panic!("expected capabilityDenied, got {other:?}"),
    }
}

/// Capability planning escalates low-confidence AI plans.
#[test]
fn capability_planning_escalates_low_confidence_ai_plans() {
    let coordinator = IntentRuntimeCoordinator::default();
    let mut transaction = TransactionIR::new(
        "Spawn entity",
        vec![TransactionOperation::Scene(
            SceneMutation::SpawnImportedMeshEntity {
                label: "AI Entity".to_string(),
                kind_label: "Static Mesh".to_string(),
                mesh_index: 0,
                position: Float3::ZERO,
                parent_id: None,
            },
        )],
        TransactionProvenance::Proposal,
    );
    transaction.approval_policy = TransactionApprovalPolicy::Automatic;
    let mut execution_context = scene_context(scene());
    let context = capability_context(
        execution_context.scene_runtime.as_ref().expect("scene"),
        IntentSource::Ai,
        0.4,
    );

    let result = coordinator
        .submit_plan(
            &transaction,
            &mut execution_context,
            Some(context),
            CommitEntry::Ui,
        )
        .expect("submitted");

    assert_eq!(
        result.disposition,
        CapabilityInvocationDisposition::ConfirmationRequested
    );
    assert!(
        result
            .confirmation_request
            .as_ref()
            .and_then(|request| request.questions.first())
            .is_some_and(|question| question.ambiguity_score > 0.0)
    );
    assert!(
        result
            .warnings
            .iter()
            .any(|warning| warning.contains("AI confidence"))
    );
}

/// Beta write capabilities remain gated by confirmation after release
/// enablement.
#[test]
fn capability_planning_can_be_reconfigured_for_beta_capabilities() {
    let coordinator = IntentRuntimeCoordinator::default();
    let mut scene = scene();
    let entity = scene.create_entity();
    scene.set_component(
        RigidBody::new(RigidBodyOptions {
            mass: 1.0,
            ..RigidBodyOptions::default()
        }),
        entity,
    );
    let mut transaction = TransactionIR::new(
        "Update rigid body mass",
        vec![TransactionOperation::Scene(
            SceneMutation::component_fields(
                entity.raw_value(),
                "rigidbody",
                vec![("mass".to_string(), Some(ComponentValue::Number(12.0)))],
            ),
        )],
        TransactionProvenance::Authored,
    );
    transaction.intent = Some(IntentIR {
        target_object_ids: vec![format!("scene:{}", entity.raw_value())],
        arguments: [("mass".to_string(), IntentArgumentValue::Number(12.0))]
            .into_iter()
            .collect(),
        ..IntentIR::new(
            "scene.set_rigid_body_mass",
            "Update rigid body mass",
            IntentSource::Human,
        )
    });
    transaction.approval_policy = TransactionApprovalPolicy::Automatic;
    let context = capability_context(&scene.clone(), IntentSource::Human, 1.0);
    let mut stable_context = scene_context(scene.clone());

    let error = coordinator
        .submit_plan(
            &transaction,
            &mut stable_context,
            Some(context.clone()),
            CommitEntry::Ui,
        )
        .expect_err("beta capability is gated");
    match planner_error(&error).expect("planner error") {
        CapabilityInvocationPlannerError::CapabilityDenied(failures) => {
            assert!(
                failures
                    .first()
                    .is_some_and(|failure| failure.reason.contains("beta"))
            );
        }
        other => panic!("expected capabilityDenied, got {other:?}"),
    }

    coordinator.configure_capability_planner(beta_planner());
    let mut beta_context = scene_context(scene);

    let result = coordinator
        .submit_plan(
            &transaction,
            &mut beta_context,
            Some(context),
            CommitEntry::Ui,
        )
        .expect("submitted");
    let request = result.confirmation_request.clone().expect("request");
    assert_eq!(
        result.disposition,
        CapabilityInvocationDisposition::ConfirmationRequested
    );
    assert_eq!(
        beta_context
            .scene_runtime
            .as_ref()
            .and_then(|scene| scene.component::<RigidBody>(entity))
            .map(|body| body.mass),
        Some(1.0)
    );

    let resolution = ConfirmationResolution::new(
        request.batch_id.clone(),
        request.correlation_id.clone(),
        vec![{
            let mut answer = ConfirmationAnswer::new(
                request.questions[0].id.clone(),
                ConfirmationAnswerOutcome::Accepted,
            );
            answer.picked_option_id = Some("confirm".to_string());
            answer
        }],
        false,
    );
    let applied = coordinator
        .resolve_plan_confirmation(&resolution, &mut beta_context)
        .expect("applied");
    assert_eq!(
        applied.disposition,
        CapabilityInvocationDisposition::Applied
    );
    assert_eq!(
        beta_context
            .scene_runtime
            .as_ref()
            .and_then(|scene| scene.component::<RigidBody>(entity))
            .map(|body| body.mass),
        Some(12.0)
    );
}
