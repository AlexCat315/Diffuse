//! End-to-end half of `Engine/Tests/IntentRuntimeTests/IntentRuntimeTests.swift`.
//!
//! Swift marked this suite `.serialized`; Rust runs each test with its own bus
//! and temporary directory, so no ordering constraint remains.

use std::sync::Arc;

use diffuse_math::simd::simd_compat::Float3;
use diffuse_observation::event_envelope::{EventOrigin, EventOriginProcessKind};
use diffuse_observation::event_kind_registry::{EventKindId, EventKindRegistry};
use diffuse_observation::publisher::{
    EventFilter, ObservationBus, SubscriptionBufferPolicy, SubscriptionSpec, SubscriptionStartFrom,
};
use diffuse_scene::components::core::value::ComponentValue;
use diffuse_scene::physics::collider::{Collider, ColliderShape};
use diffuse_scene::physics::rigid_body::{RigidBody, RigidBodyMotionType, RigidBodyOptions};
use diffuse_scene::runtime_world::LocalTransform;
use diffuse_scene::scene_bootstrap::SceneNameComponent;

use super::intent_runtime_tests::{scene, scene_context};
use crate::intent_runtime_coordinator::{
    CapabilityInvocationDisposition, IntentRuntimeCoordinator,
};
use crate::planning::intent_ir::{IntentIR, IntentSource};
use crate::transactions::transaction_executor::{TransactionExecutionContext, TransactionExecutor};
use crate::transactions::transaction_ir::{
    SceneMutation, TransactionApprovalPolicy, TransactionBaseRevisions, TransactionIR,
    TransactionOperation, TransactionProvenance,
};

fn temporary_root() -> std::path::PathBuf {
    let root = std::env::temp_dir().join(format!(
        "diffuse-intent-e2e-{}",
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

fn origin() -> EventOrigin {
    EventOrigin::new(
        EventOriginProcessKind::Editor,
        "test",
        Some("e2e".to_string()),
        None,
    )
}

fn spawn_transaction(label: &str, mesh_index: i64, position: Float3) -> TransactionIR {
    TransactionIR::new(
        "Spawn",
        vec![TransactionOperation::Scene(
            SceneMutation::SpawnImportedMeshEntity {
                label: label.to_string(),
                kind_label: "Static Mesh".to_string(),
                mesh_index,
                position,
                parent_id: None,
            },
        )],
        TransactionProvenance::Authored,
    )
}

/// `ObservationBus → IntentIR → TransactionIR → SceneRuntime` full pipeline.
#[test]
fn full_pipeline_spawn_entity() {
    let root = temporary_root();
    let bus = bus(&root);
    let tx_stream = subscription(&bus, vec![EventKindId::TransactionApplied], 8);
    let scene_stream = subscription(&bus, vec![EventKindId::SceneChanged], 8);

    let mut transaction = spawn_transaction("Hero", 7, Float3::new(2.0, 0.0, -3.0));
    transaction.intent = Some(IntentIR::new(
        "scene.spawn_entity",
        "Spawn a hero mesh at the origin",
        IntentSource::Human,
    ));
    transaction.base_revisions = TransactionBaseRevisions {
        scene_revision: Some(0),
        ..TransactionBaseRevisions::default()
    };
    let mut context = TransactionExecutionContext {
        scene_runtime: Some(scene()),
        observation_bus: Some(bus.clone()),
        event_origin: origin(),
        scene_stream_id: "scene:e2e".to_string(),
        ..TransactionExecutionContext::default()
    };

    let result = TransactionExecutor::new()
        .apply(&transaction, &mut context)
        .expect("apply");
    let scene = context.scene_runtime.as_ref().expect("scene");
    assert_eq!(scene.snapshot().entity_count, 1);
    assert_eq!(result.created_entity_ids.len(), 1);
    let entity = diffuse_scene::entity_id::EntityID::from_raw_value(result.created_entity_ids[0]);
    assert_eq!(
        scene
            .component::<SceneNameComponent>(entity)
            .map(|name| name.value),
        Some("Hero".to_string())
    );
    assert_eq!(
        scene
            .local_transform(entity)
            .map(|transform| transform.translation()),
        Some(Float3::new(2.0, 0.0, -3.0))
    );

    assert_eq!(
        tx_stream
            .drain()
            .iter()
            .map(|event| event.kind)
            .collect::<Vec<_>>(),
        vec![EventKindId::TransactionApplied]
    );
    assert_eq!(
        scene_stream
            .drain()
            .iter()
            .map(|event| event.kind)
            .collect::<Vec<_>>(),
        vec![EventKindId::SceneChanged]
    );

    let replayed = bus.replay("scene:e2e", 1, None).expect("replay");
    assert!(!replayed.is_empty());
    assert!(
        replayed
            .iter()
            .any(|event| event.kind == EventKindId::SceneChanged)
    );
    let _ = std::fs::remove_dir_all(&root);
}

/// Multi-step pipeline: spawn → `setLocalTransform` → verify via cold-log replay.
#[test]
fn multi_step_spawn_and_transform() {
    let root = temporary_root();
    let bus = bus(&root);
    let executor = TransactionExecutor::new();
    let origin = origin();

    let mut context = TransactionExecutionContext {
        scene_runtime: Some(scene()),
        observation_bus: Some(bus.clone()),
        event_origin: origin.clone(),
        scene_stream_id: "scene:e2e".to_string(),
        ..TransactionExecutionContext::default()
    };
    let spawn = spawn_transaction("Cube", 2, Float3::new(1.0, 2.0, 3.0));
    let spawn_result = executor.apply(&spawn, &mut context).expect("spawn");
    let entity =
        diffuse_scene::entity_id::EntityID::from_raw_value(spawn_result.created_entity_ids[0]);
    let revision1 = context
        .scene_runtime
        .as_ref()
        .expect("scene")
        .snapshot()
        .revision;
    assert_eq!(
        context
            .scene_runtime
            .as_ref()
            .and_then(|scene| scene.local_transform(entity))
            .map(|transform| transform.translation()),
        Some(Float3::new(1.0, 2.0, 3.0))
    );

    let scene = context.scene_runtime.take().expect("scene");
    let mut context2 = TransactionExecutionContext {
        scene_runtime: Some(scene),
        observation_bus: Some(bus.clone()),
        event_origin: origin,
        scene_stream_id: "scene:e2e".to_string(),
        ..TransactionExecutionContext::default()
    };
    let mut move_tx = TransactionIR::new(
        "Move cube",
        vec![TransactionOperation::Scene(
            SceneMutation::SetLocalTransform {
                entity_id: entity.raw_value(),
                transform: LocalTransform::from_translation(Float3::new(10.0, 20.0, 30.0)),
            },
        )],
        TransactionProvenance::Authored,
    );
    move_tx.base_revisions = TransactionBaseRevisions {
        scene_revision: Some(revision1),
        ..TransactionBaseRevisions::default()
    };
    let move_result = executor.apply(&move_tx, &mut context2).expect("move");
    assert_eq!(
        move_result.changed_domains,
        vec![crate::transactions::transaction_ir::TransactionDomain::Scene]
    );
    assert_eq!(
        context2
            .scene_runtime
            .as_ref()
            .and_then(|scene| scene.local_transform(entity))
            .map(|transform| transform.translation()),
        Some(Float3::new(10.0, 20.0, 30.0))
    );
    assert!(
        context2
            .scene_runtime
            .as_ref()
            .expect("scene")
            .snapshot()
            .revision
            > revision1
    );

    let replayed = bus.replay("scene:e2e", 1, None).expect("replay");
    let scene_changes: Vec<_> = replayed
        .into_iter()
        .filter(|event| event.kind == EventKindId::SceneChanged)
        .collect();
    assert!(scene_changes.len() >= 2);
    assert!(scene_changes[0].seq < scene_changes[1].seq);
    let _ = std::fs::remove_dir_all(&root);
}

/// Spawn an entity, set a rigid body through the direct API, then update it
/// through a transaction.
#[test]
fn spawn_entity_with_physics_via_direct_api_then_transaction() {
    let executor = TransactionExecutor::new();
    let mut scene = scene();
    let entity = scene.create_entity();
    scene.set_local_transform(
        LocalTransform::from_translation(Float3::new(0.0, 5.0, 0.0)),
        entity,
    );
    scene.set_component(
        RigidBody::new(RigidBodyOptions {
            motion_type: RigidBodyMotionType::Static,
            ..RigidBodyOptions::default()
        }),
        entity,
    );
    assert_eq!(scene.snapshot().entity_count, 1);

    let mut context = scene_context(scene);
    let raw_id = entity.raw_value();
    let mut collider = Collider::with_shape(ColliderShape::Box {
        half_extents: Float3::splat(1.0),
        center: Float3::ZERO,
    });
    collider.layer_id = 0;
    let registry = context
        .scene_runtime
        .as_ref()
        .expect("scene")
        .component_registry()
        .clone();
    let mut transaction = TransactionIR::new(
        "Add physics components",
        vec![
            TransactionOperation::Scene(SceneMutation::component_fields(
                raw_id,
                "rigidbody",
                vec![(
                    "motionType".to_string(),
                    Some(ComponentValue::String(
                        RigidBodyMotionType::Dynamic.raw_value().to_string(),
                    )),
                )],
            )),
            TransactionOperation::Scene(SceneMutation::component_fields(
                raw_id,
                "rigidbody",
                vec![("mass".to_string(), Some(ComponentValue::Number(2.0)))],
            )),
            TransactionOperation::Scene(SceneMutation::component_fields(
                raw_id,
                "rigidbody",
                vec![(
                    "gravityScale".to_string(),
                    Some(ComponentValue::Number(1.0)),
                )],
            )),
            TransactionOperation::Scene(SceneMutation::component_data(
                raw_id, "collider", collider, registry,
            )),
        ],
        TransactionProvenance::Authored,
    );
    transaction.base_revisions = TransactionBaseRevisions {
        scene_revision: context
            .scene_runtime
            .as_ref()
            .map(|scene| scene.snapshot().revision),
        ..TransactionBaseRevisions::default()
    };
    executor.apply(&transaction, &mut context).expect("apply");

    let body = context
        .scene_runtime
        .as_ref()
        .and_then(|scene| scene.component::<RigidBody>(entity))
        .expect("rigid body");
    assert_eq!(body.motion_type, RigidBodyMotionType::Dynamic);
    assert_eq!(body.mass, 2.0);
    let collider = context
        .scene_runtime
        .as_ref()
        .and_then(|scene| scene.component::<Collider>(entity))
        .expect("collider");
    assert!(matches!(collider.shape(), ColliderShape::Box { .. }));

    let scene = context.scene_runtime.as_mut().expect("scene");
    assert!(scene.apply_force(Float3::new(0.0, 9.8, 0.0), entity, true));
    assert_eq!(
        scene
            .component::<RigidBody>(entity)
            .map(|body| body.accumulated_force),
        Some(Float3::new(0.0, 9.8, 0.0))
    );
}

/// Observable state hydration: bus events match scene mutations across the
/// coordinator.
#[test]
fn coordinator_pipeline_emits_consistent_events() {
    let root = temporary_root();
    let bus = bus(&root);
    let coordinator = IntentRuntimeCoordinator::default();
    let stream = subscription(
        &bus,
        vec![EventKindId::TransactionApplied, EventKindId::SceneChanged],
        16,
    );
    let mut context = TransactionExecutionContext {
        scene_runtime: Some(scene()),
        observation_bus: Some(bus.clone()),
        event_origin: origin(),
        scene_stream_id: "scene:coordinator".to_string(),
        ..TransactionExecutionContext::default()
    };
    let mut transaction = spawn_transaction("CoordEntity", 5, Float3::ZERO);
    transaction.intent = Some(IntentIR::new(
        "scene.spawn_entity",
        "Coordinator spawn",
        IntentSource::Human,
    ));
    transaction.approval_policy = TransactionApprovalPolicy::Automatic;

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
        context
            .scene_runtime
            .as_ref()
            .map(|scene| scene.snapshot().entity_count),
        Some(1)
    );
    let events = stream.drain();
    assert_eq!(events.len(), 2);
    assert_eq!(
        events.iter().map(|event| event.kind).collect::<Vec<_>>(),
        vec![EventKindId::TransactionApplied, EventKindId::SceneChanged]
    );
    let _ = std::fs::remove_dir_all(&root);
}
