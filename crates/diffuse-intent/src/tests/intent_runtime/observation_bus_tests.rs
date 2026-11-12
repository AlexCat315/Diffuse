//! Observation-bus and staged-store half of
//! `Engine/Tests/IntentRuntimeTests/IntentRuntimeTests.swift`.

use std::sync::Arc;

use diffuse_math::simd::simd_compat::Float3;
use diffuse_observation::event_envelope::{EventOrigin, EventOriginProcessKind, EventValue};
use diffuse_observation::event_kind_registry::{EventKindId, EventKindRegistry};
use diffuse_observation::publisher::{
    EventFilter, ObservationBus, SubscriptionBufferPolicy, SubscriptionSpec, SubscriptionStartFrom,
};

use super::intent_runtime_tests::{scene, scene_context};
use crate::intent_runtime_coordinator::{
    CapabilityInvocationDisposition, IntentRuntimeCoordinator, validate_confirmation_resolution,
};
use crate::invocation::capability_invocation::{
    ConfirmationAnswer, ConfirmationAnswerOutcome, ConfirmationOption, ConfirmationQuestion,
    ConfirmationQuestionKind, ConfirmationRequestBatch, ConfirmationResolution,
    ConfirmationSeverity,
};
use crate::transactions::staged_transaction_store::StagedTransactionStore;
use crate::transactions::transaction_executor::{TransactionExecutionContext, TransactionExecutor};
use crate::transactions::transaction_ir::{
    SceneMutation, TransactionApprovalPolicy, TransactionBaseRevisions, TransactionIR,
    TransactionOperation, TransactionProvenance,
};

fn editor_origin() -> EventOrigin {
    EventOrigin::new(
        EventOriginProcessKind::Editor,
        "test-host",
        Some("alex".to_string()),
        None,
    )
}

fn temporary_root() -> std::path::PathBuf {
    let root = std::env::temp_dir().join(format!(
        "diffuse-intent-bus-{}",
        diffuse_sequence::sequence_document::new_uuid()
    ));
    std::fs::create_dir_all(&root).expect("create bus root");
    root
}

fn bus(root: &std::path::Path) -> Arc<ObservationBus> {
    Arc::new(
        ObservationBus::new(
            EventKindRegistry::default_registry(),
            Some(root.to_string_lossy().into_owned()),
            256,
        )
        .expect("observation bus"),
    )
}

fn subscription(
    bus: &ObservationBus,
    kinds: Vec<EventKindId>,
    size: usize,
) -> Arc<diffuse_observation::publisher::ObservationSubscription> {
    let mut spec = SubscriptionSpec::generate();
    spec.filter = EventFilter::KindIn(kinds);
    spec.start_from = SubscriptionStartFrom::Latest;
    spec.buffer_policy = SubscriptionBufferPolicy::DropOldest { size };
    bus.subscribe(spec)
}

fn spawn_transaction(mesh_index: i64) -> TransactionIR {
    TransactionIR::new(
        "Spawn imported mesh",
        vec![TransactionOperation::Scene(
            SceneMutation::SpawnImportedMeshEntity {
                label: "Hero".to_string(),
                kind_label: "Static Mesh".to_string(),
                mesh_index,
                position: Float3::new(0.0, 1.0, 0.0),
                parent_id: None,
            },
        )],
        TransactionProvenance::Authored,
    )
}

/// Scene apply emits transaction and scene bus events.
#[test]
fn scene_apply_emits_bus_events() {
    let root = temporary_root();
    let bus = bus(&root);
    let executor = TransactionExecutor::new();
    let transaction_stream = subscription(&bus, vec![EventKindId::TransactionApplied], 4);
    let scene_stream = subscription(&bus, vec![EventKindId::SceneChanged], 4);
    let mut transaction = spawn_transaction(9);
    transaction.intent = Some(crate::planning::intent_ir::IntentIR::new(
        "scene.spawn_entity",
        "Spawn imported mesh",
        crate::planning::intent_ir::IntentSource::Human,
    ));
    let mut context = TransactionExecutionContext {
        scene_runtime: Some(scene()),
        observation_bus: Some(bus.clone()),
        event_origin: editor_origin(),
        scene_stream_id: "scene:test".to_string(),
        ..TransactionExecutionContext::default()
    };

    let result = executor.apply(&transaction, &mut context).expect("apply");
    let transaction_events = transaction_stream.drain();
    let scene_events = scene_stream.drain();

    assert_eq!(
        result.changed_domains,
        vec![crate::transactions::transaction_ir::TransactionDomain::Scene]
    );
    assert_eq!(
        transaction_events
            .iter()
            .map(|event| event.kind)
            .collect::<Vec<_>>(),
        vec![EventKindId::TransactionApplied]
    );
    assert_eq!(
        scene_events
            .iter()
            .map(|event| event.kind)
            .collect::<Vec<_>>(),
        vec![EventKindId::SceneChanged]
    );
    assert_eq!(
        bus.replay("transaction", 1, None)
            .expect("replay")
            .iter()
            .map(|event| event.kind)
            .collect::<Vec<_>>(),
        vec![EventKindId::TransactionApplied]
    );
    let _ = std::fs::remove_dir_all(&root);
}

/// The staged transaction store emits staged and applied events while deferring
/// mutation until apply.
#[test]
fn staged_transaction_store_emits_staged_and_applied_events() {
    let root = temporary_root();
    let bus = bus(&root);
    let store = StagedTransactionStore::new(TransactionExecutor::new());
    let transaction_stream = subscription(
        &bus,
        vec![
            EventKindId::TransactionStaged,
            EventKindId::TransactionApplied,
        ],
        8,
    );
    let scene_stream = subscription(&bus, vec![EventKindId::SceneChanged], 8);
    let transaction = spawn_transaction(7);
    let mut context = TransactionExecutionContext {
        scene_runtime: Some(scene()),
        observation_bus: Some(bus.clone()),
        event_origin: editor_origin(),
        scene_stream_id: "scene:test".to_string(),
        ..TransactionExecutionContext::default()
    };

    let staged = store.stage(&transaction, &context).expect("staged");
    let stage_events = transaction_stream.drain();

    assert_eq!(staged.transaction_id, transaction.id);
    assert_eq!(
        context
            .scene_runtime
            .as_ref()
            .map(|scene| scene.snapshot().entity_count),
        Some(0)
    );
    assert_eq!(
        stage_events
            .iter()
            .map(|event| event.kind)
            .collect::<Vec<_>>(),
        vec![EventKindId::TransactionStaged]
    );

    let applied = store
        .apply_staged_transaction(&mut context)
        .expect("applied");
    let applied_transaction_events = transaction_stream.drain();
    let applied_scene_events = scene_stream.drain();

    assert!(applied.had_transaction);
    assert_eq!(
        context
            .scene_runtime
            .as_ref()
            .map(|scene| scene.snapshot().entity_count),
        Some(1)
    );
    assert_eq!(
        applied_transaction_events
            .iter()
            .map(|event| event.kind)
            .collect::<Vec<_>>(),
        vec![EventKindId::TransactionApplied]
    );
    assert_eq!(
        applied_scene_events
            .iter()
            .map(|event| event.kind)
            .collect::<Vec<_>>(),
        vec![EventKindId::SceneChanged]
    );
    let _ = std::fs::remove_dir_all(&root);
}

/// Discarding a staged transaction emits the discarded event and leaves the
/// scene untouched.
#[test]
fn discard_staged_transaction_emits_discarded_event() {
    let root = temporary_root();
    let bus = bus(&root);
    let store = StagedTransactionStore::new(TransactionExecutor::new());
    let stream = subscription(
        &bus,
        vec![
            EventKindId::TransactionStaged,
            EventKindId::TransactionDiscarded,
        ],
        8,
    );
    let transaction = spawn_transaction(7);
    let context = TransactionExecutionContext {
        scene_runtime: Some(scene()),
        observation_bus: Some(bus.clone()),
        event_origin: editor_origin(),
        scene_stream_id: "scene:test".to_string(),
        ..TransactionExecutionContext::default()
    };

    store.stage(&transaction, &context).expect("staged");
    stream.drain();
    let discarded = store
        .discard_staged_transaction(Some(&context))
        .expect("discarded");
    let discarded_events = stream.drain();

    assert!(discarded.had_transaction);
    assert_eq!(
        discarded_events
            .iter()
            .map(|event| event.kind)
            .collect::<Vec<_>>(),
        vec![EventKindId::TransactionDiscarded]
    );
    let _ = std::fs::remove_dir_all(&root);
}

/// `submitPlan` applies automatic transactions immediately.
#[test]
fn submit_plan_applies_automatic_transactions_immediately() {
    let coordinator = IntentRuntimeCoordinator::default();
    let mut transaction = spawn_transaction(9);
    transaction.base_revisions = TransactionBaseRevisions {
        scene_revision: Some(0),
        ..TransactionBaseRevisions::default()
    };
    transaction.approval_policy = TransactionApprovalPolicy::Automatic;
    let mut context = scene_context(scene());

    let result = coordinator
        .submit_plan(
            &transaction,
            &mut context,
            None,
            crate::pipeline::commit_pipeline::CommitEntry::Ui,
        )
        .expect("submitted");

    assert_eq!(result.disposition, CapabilityInvocationDisposition::Applied);
    assert_eq!(
        result
            .apply_result
            .as_ref()
            .map(|applied| applied.created_entity_ids.len()),
        Some(1)
    );
    assert_eq!(
        context
            .scene_runtime
            .as_ref()
            .map(|scene| scene.snapshot().entity_count),
        Some(1)
    );
}

/// `submitPlan` stages requiresApproval transactions and emits confirmation
/// requests.
#[test]
fn submit_plan_stages_requires_approval_transactions() {
    let root = temporary_root();
    let bus = bus(&root);
    let coordinator = IntentRuntimeCoordinator::default();
    let mut scene = scene();
    let entity = scene.create_entity();
    let transaction_stream = subscription(&bus, vec![EventKindId::TransactionStaged], 4);
    let confirmation_stream = subscription(&bus, vec![EventKindId::ConfirmationRequested], 4);
    let mut transaction = TransactionIR::new(
        "Delete selected entity",
        vec![TransactionOperation::Scene(SceneMutation::DeleteEntity {
            entity_id: entity.raw_value(),
        })],
        TransactionProvenance::Authored,
    );
    transaction.base_revisions = TransactionBaseRevisions {
        scene_revision: Some(scene.snapshot().revision),
        ..TransactionBaseRevisions::default()
    };
    transaction.approval_policy = TransactionApprovalPolicy::RequiresApproval;
    let mut context = TransactionExecutionContext {
        scene_runtime: Some(scene),
        observation_bus: Some(bus.clone()),
        event_origin: editor_origin(),
        ..TransactionExecutionContext::default()
    };

    let result = coordinator
        .submit_plan(
            &transaction,
            &mut context,
            None,
            crate::pipeline::commit_pipeline::CommitEntry::Ui,
        )
        .expect("submitted");
    let staged_events = transaction_stream.drain();
    let confirmation_events = confirmation_stream.drain();

    assert_eq!(
        result.disposition,
        CapabilityInvocationDisposition::ConfirmationRequested
    );
    assert_eq!(
        result
            .staged_result
            .as_ref()
            .map(|staged| staged.transaction_id.clone()),
        Some(transaction.id.clone())
    );
    assert_eq!(
        context
            .scene_runtime
            .as_ref()
            .map(|scene| scene.snapshot().entity_count),
        Some(1)
    );
    assert_eq!(
        staged_events
            .iter()
            .map(|event| event.kind)
            .collect::<Vec<_>>(),
        vec![EventKindId::TransactionStaged]
    );
    assert_eq!(
        confirmation_events
            .iter()
            .map(|event| event.kind)
            .collect::<Vec<_>>(),
        vec![EventKindId::ConfirmationRequested]
    );
    let payload = confirmation_events[0]
        .payload_ref
        .inline_record()
        .expect("payload");
    assert_eq!(
        payload.get("batch_id"),
        Some(&EventValue::String(format!("cfm:{}", transaction.id)))
    );
    let _ = std::fs::remove_dir_all(&root);
}

/// Confirmation resolution applies staged transactions and publishes the UI
/// resolution.
#[test]
fn confirmation_resolution_applies_staged_transactions() {
    let root = temporary_root();
    let bus = bus(&root);
    let coordinator = IntentRuntimeCoordinator::default();
    let mut scene = scene();
    let entity = scene.create_entity();
    let resolved_stream = subscription(&bus, vec![EventKindId::ConfirmationResolved], 4);
    let scene_stream = subscription(&bus, vec![EventKindId::SceneChanged], 4);
    let mut transaction = TransactionIR::new(
        "Delete selected entity",
        vec![TransactionOperation::Scene(SceneMutation::DeleteEntity {
            entity_id: entity.raw_value(),
        })],
        TransactionProvenance::Authored,
    );
    transaction.base_revisions = TransactionBaseRevisions {
        scene_revision: Some(scene.snapshot().revision),
        ..TransactionBaseRevisions::default()
    };
    transaction.approval_policy = TransactionApprovalPolicy::RequiresApproval;
    let mut context = TransactionExecutionContext {
        scene_runtime: Some(scene),
        observation_bus: Some(bus.clone()),
        event_origin: editor_origin(),
        ..TransactionExecutionContext::default()
    };

    let staged = coordinator
        .submit_plan(
            &transaction,
            &mut context,
            None,
            crate::pipeline::commit_pipeline::CommitEntry::Ui,
        )
        .expect("submitted");
    let request = staged.confirmation_request.clone().expect("request");
    let mut resolution = ConfirmationResolution::new(
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
    );
    resolution.user_id = Some("alex".to_string());

    let applied = coordinator
        .resolve_plan_confirmation(&resolution, &mut context)
        .expect("applied");
    let confirmation_events = resolved_stream.drain();
    let scene_events = scene_stream.drain();

    assert_eq!(
        applied.disposition,
        CapabilityInvocationDisposition::Applied
    );
    assert_eq!(
        context
            .scene_runtime
            .as_ref()
            .map(|scene| scene.snapshot().entity_count),
        Some(0)
    );
    assert_eq!(
        confirmation_events
            .iter()
            .map(|event| event.kind)
            .collect::<Vec<_>>(),
        vec![EventKindId::ConfirmationResolved]
    );
    assert_eq!(
        scene_events
            .iter()
            .map(|event| event.kind)
            .collect::<Vec<_>>(),
        vec![EventKindId::SceneChanged]
    );
    let _ = std::fs::remove_dir_all(&root);
}

/// Confirmation resolution requires one valid answer for every displayed
/// question.
#[test]
fn confirmation_resolution_validates_complete_batch() {
    let options = vec![
        ConfirmationOption::new("confirm", "Apply"),
        ConfirmationOption::new("skip", "Discard"),
    ];
    let questions: Vec<ConfirmationQuestion> = ["first", "second"]
        .into_iter()
        .map(|id| {
            let mut question = ConfirmationQuestion::new(
                id,
                ConfirmationQuestionKind::ChooseOne,
                id,
                ConfirmationSeverity::Warn,
                true,
                0.0,
            );
            question.options = options.clone();
            question.default_option_id = Some("confirm".to_string());
            question
        })
        .collect();
    let request = ConfirmationRequestBatch::new("batch", "test", "correlation", questions.clone());
    let incomplete = ConfirmationResolution::new(
        request.batch_id.clone(),
        request.correlation_id.clone(),
        vec![{
            let mut answer = ConfirmationAnswer::new("first", ConfirmationAnswerOutcome::Accepted);
            answer.picked_option_id = Some("confirm".to_string());
            answer
        }],
        false,
    );
    assert!(validate_confirmation_resolution(&incomplete, &request).is_err());

    let invalid_option = ConfirmationResolution::new(
        request.batch_id.clone(),
        request.correlation_id.clone(),
        questions
            .iter()
            .map(|question| {
                let mut answer = ConfirmationAnswer::new(
                    question.id.clone(),
                    ConfirmationAnswerOutcome::Accepted,
                );
                answer.picked_option_id = Some(if question.id == "second" {
                    "foreign".to_string()
                } else {
                    "confirm".to_string()
                });
                answer
            })
            .collect(),
        false,
    );
    assert!(validate_confirmation_resolution(&invalid_option, &request).is_err());

    let complete = ConfirmationResolution::new(
        request.batch_id.clone(),
        request.correlation_id.clone(),
        questions
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
    );
    validate_confirmation_resolution(&complete, &request).expect("complete batch");
}
