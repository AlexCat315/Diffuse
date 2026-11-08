//! Ported from `Engine/Tests/AIRuntimeTests/AIRuntimeTests.swift`.
//!
//! Swift's `@testable import AIRuntime` becomes `pub(crate)` access on the few
//! private helpers these tests reach (`Session::compact_dict`,
//! `Session::find_entities_result`, `Session::update_issue_memory`). The actor
//! methods are synchronous in Rust (MIGRATION.md §5.5), so `async` tests become
//! plain `#[test]` functions. `URLProtocol` mocking becomes the loopback
//! `FixtureHttpServer`.

use std::collections::BTreeMap;
use std::path::Path;
use std::sync::Arc;

use diffuse_context_memory::context_entry::EntryKind;
use diffuse_context_memory::context_memory_store::ContextMemoryStore;
use diffuse_intent::transactions::transaction_ir::{
    SceneMutation, TransactionApprovalPolicy, TransactionIR, TransactionOperation,
};
use diffuse_intent::transactions::world_event::{WorldEvent, WorldPropertyValue};
use diffuse_math::simd::simd_compat::{Float3, Float4, Float4x4};
use diffuse_observation::publisher::SnapshotProvider;
use diffuse_perception::core::perception_contracts::{
    ClassificationObservation, PerceptionLicenseMetadata, PerceptionModelManifest,
    PerceptionObservation, PerceptionProvenance, PerceptionResult, PerceptionRuntimeConfig,
    PerceptionSemanticCandidate, PerceptionTask, PerceptionTimingInfo,
};
use diffuse_perception::core::perception_service::PerceptionService;
use diffuse_perception::worker::perception_worker::{PerceptionRuntimeError, PerceptionWorker};
use diffuse_scene::components::core::registry::ComponentRegistry;
use diffuse_scene::components::core::value::ComponentValue;
use diffuse_scene::entity_id::EntityID;
use diffuse_scene::media::animation::AnimationPlayer;
use diffuse_scene::media::audio::AudioSource;
use diffuse_scene::physics::collider::{
    Collider, ColliderShape, ColliderShapeInstance, PhysicsMaterial,
};
use diffuse_scene::physics::destruction::{
    Destructible, DestructibleAsset, DestructibleAssetResource, DestructibleConnectionAsset,
    DestructibleFragmentAsset,
};
use diffuse_scene::physics::joints::physics_joint::Constraint;
use diffuse_scene::physics::joints::physics_joint_configuration::PhysicsJointConfiguration;
use diffuse_scene::physics::queries::spatial_queries::{
    MeshColliderGeometry, MeshColliderGeometryResource,
};
use diffuse_scene::physics::rigid_body::{RigidBody, RigidBodyMotionType};
use diffuse_scene::physics::soft_bodies::cloth::{Cloth, ClothBendType};
use diffuse_scene::physics::soft_bodies::soft_body::{SoftBody, SoftBodyMesh};
use diffuse_scene::physics::vehicles::vehicle::Vehicle;
use diffuse_scene::physics::vehicles::vehicle_powertrain::{
    VehicleEngineConfiguration, VehicleTransmissionConfiguration,
};
use diffuse_scene::physics::vehicles::vehicle_wheel_configuration::VehicleTransmissionMode;
use diffuse_scene::rendering::render_extraction::{
    CameraComponent, LightComponent, LightType, RenderMaterialComponent, RenderMeshComponent,
};
use diffuse_scene::runtime_world::LocalTransform;
use diffuse_scene::scene_runtime::SceneRuntime;
use diffuse_script::core::script_component::{
    ScriptBinding, ScriptBindingID, ScriptComponent, ScriptHandle,
};
use serde_json::{Map, Value, json};

use crate::context::ai_world_context::AIWorldContext;
use crate::context::workflow_context::{
    FilmNarrativePhase, FilmWorkflowContext, GameKnownConstraints, GameLevelPhase,
    GameWorkflowContext, GameplayIntent, ScriptParameterDescriptor, ScriptSchema, WorkflowContext,
};
use crate::context::world_view::{WorldEntityRecord, WorldView};
use crate::planning::scene_edit_plan::{JSONValue, SceneEditOp, SceneEditPlan, SceneEditStep};
use crate::planning::scene_edit_plan_executor::{
    SceneEditPlanExecutor, SceneEditPlanExecutorError,
};
use crate::semantic::scene_semantic_encoder::SceneSemanticEncoder;
use crate::semantic::scene_semantic_snapshot::{
    SceneSemanticSnapshot, SceneSemanticSnapshotEntity, SceneSemanticSnapshotScriptBindingRecord,
};
use crate::session::conversation_turn::{ConversationTurn, ConversationTurnKind};
use crate::session::retry_policy::RetryPolicy;
use crate::session::session::{Session, SessionError};
use crate::session::session_config::{AssetCatalog, SessionConfig};
use crate::session::signal::Signal;
use crate::tests::ai_runtime::component_mutation_test_support::DecodedComponent;
use crate::tests::ai_runtime::fixture_http::{FixtureHttpServer, FixtureResponse};

// MARK: - Helpers

/// Swift's `SceneSemanticSnapshot.Entity` memberwise initializer defaults every
/// optional field to `nil`. Decoding the six required fields reproduces that
/// default record; tests override fields with struct-update syntax.
fn entity(id: &str, name: &str, kind: &str) -> SceneSemanticSnapshotEntity {
    serde_json::from_value(json!({
        "id": id, "name": name, "kind": kind,
        "childRefs": [], "components": [], "isSelected": false
    }))
    .expect("default snapshot entity")
}

fn snapshot(revision: u64, entities: Vec<SceneSemanticSnapshotEntity>) -> SceneSemanticSnapshot {
    let count = entities.len() as i64;
    SceneSemanticSnapshot::new(revision, count, entities)
}

fn step(value: Value) -> SceneEditStep {
    serde_json::from_value(value).expect("decode edit step")
}

fn decode_step(json: &str) -> SceneEditStep {
    serde_json::from_str(json).expect("decode edit step")
}

fn added(ref_: &str, name: &str, kind: &str) -> WorldEvent {
    WorldEvent::EntityAdded {
        ref_: ref_.to_string(),
        name: name.to_string(),
        kind: Some(kind.to_string()),
    }
}

fn authored(ref_: &str, property: &str, value: WorldPropertyValue) -> WorldEvent {
    WorldEvent::EntityAuthoredChanged {
        ref_: ref_.to_string(),
        property: property.to_string(),
        value,
    }
}

fn vec3_value(x: f32, y: f32, z: f32) -> WorldPropertyValue {
    WorldPropertyValue::Vec3(x, y, z)
}

fn vec4_value(x: f32, y: f32, z: f32, w: f32) -> WorldPropertyValue {
    WorldPropertyValue::Vec4(x, y, z, w)
}

fn float_value(value: f32) -> WorldPropertyValue {
    WorldPropertyValue::Float(value)
}

fn string_value(value: &str) -> WorldPropertyValue {
    WorldPropertyValue::String(value.to_string())
}

fn bool_value(value: bool) -> WorldPropertyValue {
    WorldPropertyValue::Bool(value)
}

fn assert_close(actual: f64, expected: f64, accuracy: f64) {
    assert!(
        (actual - expected).abs() <= accuracy,
        "{actual} != {expected} (accuracy {accuracy})"
    );
}

/// Swift's `makeTestConfig()` = `.anthropic(apiKey: "test")`.
fn make_test_config() -> SessionConfig {
    SessionConfig::anthropic("test")
}

/// Swift's `Session(id:config:)` convenience initializer.
fn make_session(id: &str) -> Session {
    Session::new(
        Some(id.to_string()),
        make_test_config(),
        None,
        None,
        None,
        None,
        None,
        None,
        None,
    )
}

/// Swift's `Session(id:config:initialWorldView:)` (and `urlSession:` variants,
/// where the mock transport becomes a `base_url` pointing at the fixture server).
fn session_with_world_view(id: &str, config: SessionConfig, world_view: WorldView) -> Session {
    Session::new(
        Some(id.to_string()),
        config,
        None,
        None,
        Some(world_view),
        None,
        None,
        None,
        None,
    )
}

/// Swift's `scaledMatrix(_:_:_:)` — identity with the diagonal scale written in.
fn scaled_matrix(sx: f32, sy: f32, sz: f32) -> Float4x4 {
    let mut matrix = Float4x4::from_scalar(1.0);
    matrix.set_column(0, Float4::new(sx, 0.0, 0.0, 0.0));
    matrix.set_column(1, Float4::new(0.0, sy, 0.0, 0.0));
    matrix.set_column(2, Float4::new(0.0, 0.0, sz, 0.0));
    matrix
}

// MARK: - Executor helpers

/// Decodes a plan JSON document and builds its transaction against `scene`.
fn build_plan(json: &str, scene: &SceneRuntime) -> TransactionIR {
    let plan: SceneEditPlan = serde_json::from_str(json).expect("decode plan");
    SceneEditPlanExecutor::new()
        .build_transaction_with_defaults(&plan, scene)
        .expect("build transaction")
}

/// Builds a transaction from already-decoded steps (the common executor-test
/// shape: `SceneEditPlan(summary:steps:)` → `buildTransaction`).
fn execute_plan(summary: &str, steps: Vec<SceneEditStep>, scene: &SceneRuntime) -> TransactionIR {
    let plan = SceneEditPlan::new(summary.to_string(), None, steps);
    SceneEditPlanExecutor::new()
        .build_transaction_with_defaults(&plan, scene)
        .expect("build transaction")
}

/// Builds a transaction expected to fail, returning the executor error.
fn executor_error(
    summary: &str,
    steps: Vec<SceneEditStep>,
    scene: &SceneRuntime,
) -> SceneEditPlanExecutorError {
    let plan = SceneEditPlan::new(summary.to_string(), None, steps);
    SceneEditPlanExecutor::new()
        .build_transaction_with_defaults(&plan, scene)
        .expect_err("expected executor error")
}

/// Swift's `transaction.operations.compactMap { if case let .scene(m) = $0 ... }`.
fn scene_ops(transaction: &TransactionIR) -> Vec<&SceneMutation> {
    transaction
        .operations
        .iter()
        .filter_map(|operation| match operation {
            TransactionOperation::Scene(mutation) => Some(mutation),
            TransactionOperation::Sequence(_) | TransactionOperation::Asset(_) => None,
        })
        .collect()
}

fn entity_ref(entity: EntityID) -> String {
    format!("scene:{}", entity.raw_value())
}

/// Swift's `SceneSemanticEncoder().encode(scene, selectedEntityID: nil,
/// workspaceMode: nil, localeIdentifier: nil)`.
fn encode(scene: &SceneRuntime) -> SceneSemanticSnapshot {
    SceneSemanticEncoder::new().encode_with_defaults(scene)
}

fn snapshot_entity<'a>(
    snapshot: &'a SceneSemanticSnapshot,
    reference: &str,
) -> &'a SceneSemanticSnapshotEntity {
    snapshot
        .entities
        .iter()
        .find(|entity| entity.id == reference)
        .expect("entity in snapshot")
}

/// Swift's `JSONValue.asFloat` on a compact-dict entry (stored as `f64`).
fn dict_float(dict: &Map<String, Value>, key: &str) -> Option<f32> {
    dict.get(key)
        .and_then(Value::as_f64)
        .map(|value| value as f32)
}

/// Swift's `JSONValue.asFloatArray` on a compact-dict entry.
fn dict_float_array(dict: &Map<String, Value>, key: &str) -> Option<Vec<f32>> {
    dict.get(key).and_then(Value::as_array).map(|array| {
        array
            .iter()
            .map(|value| value.as_f64().expect("float array element") as f32)
            .collect()
    })
}

/// Swift's `Optional<Any>.asFloat` extension (AIRuntimeTests.swift:4978) applied
/// to a `find_entities` JSON entry. Values round-trip through `f32`→`f64`, so
/// casting back recovers the authored `Float` exactly on every platform.
fn value_as_float(value: &Value) -> Option<f32> {
    value.as_f64().map(|number| number as f32)
}

/// Swift's `Optional<Any>.asFloatArray` extension applied to a JSON entry.
fn value_as_float_array(value: &Value) -> Option<Vec<f32>> {
    value.as_array().map(|array| {
        array
            .iter()
            .map(|element| element.as_f64().expect("float array element") as f32)
            .collect()
    })
}

// MARK: - WorldView / WorldEntityRecord

#[test]
fn world_view_stores_inferred_source_from_world_event() {
    let mut world_view = WorldView::new();
    world_view.apply_event(added("scene:1", "Hero", "mesh"));
    world_view.apply_event(WorldEvent::EntityInferredUpdated {
        ref_: "scene:1".to_string(),
        property: "object_category".to_string(),
        value: string_value("chair"),
        confidence: 0.91,
        source: Some("perception:fixture_classifier".to_string()),
    });

    let record = world_view.entity_record("scene:1").expect("record");
    let inferred = record.inferred.get("object_category").expect("inferred");
    assert_eq!(inferred.display_value, "chair");
    assert_eq!(inferred.confidence, 0.91);
    assert_eq!(
        inferred.source.as_deref(),
        Some("perception:fixture_classifier")
    );
}

#[test]
fn ai_world_context_stores_inferred_events_without_remote_session() {
    let context = AIWorldContext::default();
    context.observe_events(vec![
        added("scene:1", "Hero", "mesh"),
        WorldEvent::EntityInferredUpdated {
            ref_: "scene:1".to_string(),
            property: "object_category".to_string(),
            value: string_value("trashcan"),
            confidence: 0.84,
            source: Some("perception:apple_vision_classify_image_v1".to_string()),
        },
    ]);

    let record = context.entity_record("scene:1").expect("record");
    assert_eq!(record.name, "Hero");
    let inferred = record.inferred.get("object_category").expect("inferred");
    assert_eq!(inferred.display_value, "trashcan");
    assert_eq!(
        inferred.source.as_deref(),
        Some("perception:apple_vision_classify_image_v1")
    );
}

#[test]
fn snapshot_euler_degrees_copied_to_entity_record() {
    let record = SceneSemanticSnapshotEntity {
        position: Some(vec![0.0, 0.0, 0.0]),
        euler_degrees: Some(vec![45.0, 0.0, 30.0]),
        components: vec!["transform".to_string(), "mesh".to_string()],
        ..entity("scene:9", "TiltedBox", "mesh")
    };
    let mut world_view = WorldView::new();
    world_view.apply_snapshot(&snapshot(1, vec![record]));

    assert_eq!(
        world_view.entity_record("scene:9").unwrap().euler_degrees,
        Some(vec![45.0, 0.0, 30.0])
    );
}

#[test]
fn snapshot_scale_copied_to_entity_record() {
    let record = SceneSemanticSnapshotEntity {
        position: Some(vec![0.0, 0.0, 0.0]),
        scale: Some(vec![2.0, 3.0, 0.5]),
        components: vec!["transform".to_string(), "mesh".to_string()],
        ..entity("scene:7", "BigBox", "mesh")
    };
    let mut world_view = WorldView::new();
    world_view.apply_snapshot(&snapshot(1, vec![record]));

    assert_eq!(
        world_view.entity_record("scene:7").unwrap().scale,
        Some(vec![2.0, 3.0, 0.5])
    );
}

#[test]
fn entity_authored_scale_event_populates_record() {
    let mut world_view = WorldView::new();
    world_view.apply_event(added("scene:8", "Crate", "mesh"));
    world_view.apply_event(authored("scene:8", "scale", vec3_value(2.0, 2.0, 2.0)));

    assert_eq!(
        world_view.entity_record("scene:8").unwrap().scale,
        Some(vec![2.0, 2.0, 2.0])
    );
}

#[test]
fn snapshot_world_position_populates_evaluated_dict() {
    let record = SceneSemanticSnapshotEntity {
        position: Some(vec![0.0, 0.0, 0.0]),
        world_position: Some(vec![3.0, 4.0, 5.0]),
        components: vec!["transform".to_string(), "mesh".to_string()],
        ..entity("scene:1", "Hero", "mesh")
    };
    let mut world_view = WorldView::new();
    world_view.apply_snapshot(&snapshot(1, vec![record]));

    assert_eq!(
        world_view
            .entity_record("scene:1")
            .unwrap()
            .evaluated
            .get("worldPosition"),
        Some(&vec3_value(3.0, 4.0, 5.0))
    );
}

#[test]
fn snapshot_without_world_position_leaves_evaluated_empty() {
    let record = SceneSemanticSnapshotEntity {
        position: Some(vec![1.0, 2.0, 3.0]),
        world_position: None,
        components: vec!["transform".to_string()],
        ..entity("scene:2", "Root", "group")
    };
    let mut world_view = WorldView::new();
    world_view.apply_snapshot(&snapshot(1, vec![record]));

    assert!(
        !world_view
            .entity_record("scene:2")
            .unwrap()
            .evaluated
            .contains_key("worldPosition")
    );
}

#[test]
fn snapshot_physics_collider_audio_fields_copied_to_entity_record() {
    let record = SceneSemanticSnapshotEntity {
        position: Some(vec![0.0, 0.0, 0.0]),
        components: vec![
            "transform".to_string(),
            "mesh".to_string(),
            "rigidbody".to_string(),
            "collider".to_string(),
            "audio_source".to_string(),
        ],
        rigid_body_motion_type: Some("dynamic".to_string()),
        rigid_body_mass: Some(12.5),
        rigid_body_gravity_scale: Some(0.8),
        rigid_body_allow_sleep: Some(true),
        collider_shape: Some("capsule".to_string()),
        collider_is_trigger: Some(false),
        collider_friction: Some(0.6),
        collider_restitution: Some(0.2),
        collider_density: Some(1.1),
        audio_clip: Some("barrel_roll".to_string()),
        audio_volume: Some(0.75),
        audio_loop: Some(false),
        audio_play_on_awake: Some(true),
        ..entity("scene:10", "Barrel", "mesh")
    };
    let mut world_view = WorldView::new();
    world_view.apply_snapshot(&snapshot(1, vec![record]));

    let r = world_view.entity_record("scene:10").unwrap();
    assert_eq!(r.rigid_body_motion_type.as_deref(), Some("dynamic"));
    assert_eq!(r.rigid_body_mass, Some(12.5));
    assert_eq!(r.rigid_body_gravity_scale, Some(0.8));
    assert_eq!(r.rigid_body_allow_sleep, Some(true));
    assert_eq!(r.collider_shape.as_deref(), Some("capsule"));
    assert_eq!(r.collider_is_trigger, Some(false));
    assert_eq!(r.collider_friction, Some(0.6));
    assert_eq!(r.collider_restitution, Some(0.2));
    assert_eq!(r.collider_density, Some(1.1));
    assert_eq!(r.audio_clip.as_deref(), Some("barrel_roll"));
    assert_eq!(r.audio_volume, Some(0.75));
    assert_eq!(r.audio_loop, Some(false));
    assert_eq!(r.audio_play_on_awake, Some(true));
}

#[test]
fn world_entity_record_apply_physics_from_events() {
    let mut world_view = WorldView::new();
    world_view.apply_event(added("scene:5", "Crate", "mesh"));
    world_view.apply_event(authored("scene:5", "rigidBodyMass", float_value(8.0)));
    world_view.apply_event(authored(
        "scene:5",
        "rigidBodyGravityScale",
        float_value(0.5),
    ));
    world_view.apply_event(authored(
        "scene:5",
        "rigidBodyAllowSleep",
        bool_value(false),
    ));
    world_view.apply_event(authored("scene:5", "colliderShape", string_value("box")));
    world_view.apply_event(authored("scene:5", "colliderFriction", float_value(0.4)));
    world_view.apply_event(authored("scene:5", "audioClip", string_value("thud")));
    world_view.apply_event(authored("scene:5", "audioLoop", bool_value(true)));

    let r = world_view.entity_record("scene:5").unwrap();
    assert_eq!(r.rigid_body_mass, Some(8.0));
    assert_eq!(r.rigid_body_gravity_scale, Some(0.5));
    assert_eq!(r.rigid_body_allow_sleep, Some(false));
    assert_eq!(r.collider_shape.as_deref(), Some("box"));
    assert_eq!(r.collider_friction, Some(0.4));
    assert_eq!(r.audio_clip.as_deref(), Some("thud"));
    assert_eq!(r.audio_loop, Some(true));
}

#[test]
fn snapshot_world_euler_degrees_copied_to_evaluated_dict() {
    let record = SceneSemanticSnapshotEntity {
        position: Some(vec![0.0, 0.0, 0.0]),
        world_euler_degrees: Some(vec![30.0, 45.0, 0.0]),
        components: vec!["transform".to_string(), "mesh".to_string()],
        ..entity("scene:30", "TiltedChild", "mesh")
    };
    let mut world_view = WorldView::new();
    world_view.apply_snapshot(&snapshot(1, vec![record]));

    assert_eq!(
        world_view
            .entity_record("scene:30")
            .unwrap()
            .evaluated
            .get("worldEulerDegrees"),
        Some(&vec3_value(30.0, 45.0, 0.0))
    );
}

#[test]
fn snapshot_without_world_euler_degrees_leaves_evaluated_empty() {
    let record = SceneSemanticSnapshotEntity {
        position: Some(vec![0.0, 0.0, 0.0]),
        world_euler_degrees: None,
        components: vec!["transform".to_string(), "mesh".to_string()],
        ..entity("scene:31", "Upright", "mesh")
    };
    let mut world_view = WorldView::new();
    world_view.apply_snapshot(&snapshot(1, vec![record]));

    assert!(
        !world_view
            .entity_record("scene:31")
            .unwrap()
            .evaluated
            .contains_key("worldEulerDegrees")
    );
}

#[test]
fn snapshot_world_scale_copied_to_evaluated_dict() {
    let record = SceneSemanticSnapshotEntity {
        position: Some(vec![0.0, 0.0, 0.0]),
        world_scale: Some(vec![2.0, 3.0, 4.0]),
        components: vec!["transform".to_string(), "mesh".to_string()],
        ..entity("scene:32", "BigBox", "mesh")
    };
    let mut world_view = WorldView::new();
    world_view.apply_snapshot(&snapshot(1, vec![record]));

    assert_eq!(
        world_view
            .entity_record("scene:32")
            .unwrap()
            .evaluated
            .get("worldScale"),
        Some(&vec3_value(2.0, 3.0, 4.0))
    );
}

#[test]
fn snapshot_without_world_scale_leaves_evaluated_empty() {
    let record = SceneSemanticSnapshotEntity {
        position: Some(vec![0.0, 0.0, 0.0]),
        world_scale: None,
        components: vec!["transform".to_string(), "mesh".to_string()],
        ..entity("scene:33", "Unit", "mesh")
    };
    let mut world_view = WorldView::new();
    world_view.apply_snapshot(&snapshot(1, vec![record]));

    assert!(
        !world_view
            .entity_record("scene:33")
            .unwrap()
            .evaluated
            .contains_key("worldScale")
    );
}

#[test]
fn snapshot_script_bindings_copied_to_entity_record() {
    let binding = SceneSemanticSnapshotScriptBindingRecord::new(
        42,
        Some("project.runner".to_string()),
        true,
        "{\"speed\":5}".to_string(),
    );
    let record = SceneSemanticSnapshotEntity {
        position: Some(vec![0.0, 0.0, 0.0]),
        components: vec!["transform".to_string(), "script".to_string()],
        script_bindings: Some(vec![binding]),
        ..entity("scene:20", "Runner", "mesh")
    };
    let mut world_view = WorldView::new();
    world_view.apply_snapshot(&snapshot(1, vec![record]));

    let r = world_view.entity_record("scene:20").unwrap();
    let bindings = r.script_bindings.as_ref().expect("bindings");
    assert_eq!(bindings.len(), 1);
    assert_eq!(bindings[0].handle, 42);
    assert_eq!(bindings[0].identifier.as_deref(), Some("project.runner"));
    assert!(bindings[0].is_enabled);
    assert_eq!(bindings[0].parameters_json, "{\"speed\":5}");
}

#[test]
fn world_entity_record_apply_light_properties_from_events() {
    let mut world_view = WorldView::new();
    world_view.apply_event(added("scene:L", "Sun", "light"));
    world_view.apply_event(authored(
        "scene:L",
        "lightType",
        string_value("directional"),
    ));
    world_view.apply_event(authored("scene:L", "lightIntensity", float_value(1200.0)));
    world_view.apply_event(authored(
        "scene:L",
        "lightColor",
        vec3_value(1.0, 0.95, 0.8),
    ));
    world_view.apply_event(authored("scene:L", "lightRange", float_value(50.0)));
    world_view.apply_event(authored("scene:L", "lightSpotInner", float_value(15.0)));
    world_view.apply_event(authored("scene:L", "lightSpotOuter", float_value(30.0)));
    world_view.apply_event(authored("scene:L", "lightCastShadows", bool_value(true)));

    let r = world_view.entity_record("scene:L").unwrap();
    assert_eq!(r.light_type.as_deref(), Some("directional"));
    assert_eq!(r.light_intensity, Some(1200.0));
    assert_eq!(r.light_color, Some(vec![1.0, 0.95, 0.8]));
    assert_eq!(r.light_range, Some(50.0));
    assert_eq!(r.light_spot_inner, Some(15.0));
    assert_eq!(r.light_spot_outer, Some(30.0));
    assert_eq!(r.light_cast_shadows, Some(true));
}

#[test]
fn world_entity_record_apply_collider_granular_fields_from_events() {
    let mut world_view = WorldView::new();
    world_view.apply_event(added("scene:C", "Box", "mesh"));
    world_view.apply_event(authored("scene:C", "colliderIsTrigger", bool_value(true)));
    world_view.apply_event(authored("scene:C", "colliderRestitution", float_value(0.7)));
    world_view.apply_event(authored("scene:C", "colliderDensity", float_value(2.5)));
    world_view.apply_event(authored("scene:C", "colliderLayerID", float_value(4.0)));
    world_view.apply_event(authored("scene:C", "colliderLayerMask", float_value(255.0)));

    let r = world_view.entity_record("scene:C").unwrap();
    assert_eq!(r.collider_is_trigger, Some(true));
    assert_eq!(r.collider_restitution, Some(0.7));
    assert_eq!(r.collider_density, Some(2.5));
    assert_eq!(r.collider_layer_id, Some(4));
    assert_eq!(r.collider_layer_mask, Some(255));
}

#[test]
fn world_entity_record_apply_mesh_and_audio_from_events() {
    let mut world_view = WorldView::new();
    world_view.apply_event(added("scene:M", "Prop", "mesh"));
    world_view.apply_event(authored("scene:M", "meshIsVisible", bool_value(false)));
    world_view.apply_event(authored("scene:M", "meshColor", vec3_value(0.2, 0.5, 1.0)));
    world_view.apply_event(authored("scene:M", "audioVolume", float_value(0.8)));
    world_view.apply_event(authored("scene:M", "audioPlayOnAwake", bool_value(false)));
    world_view.apply_event(authored(
        "scene:M",
        "rigidBodyMotionType",
        string_value("kinematic"),
    ));

    let r = world_view.entity_record("scene:M").unwrap();
    assert_eq!(r.mesh_is_visible, Some(false));
    assert_eq!(r.mesh_color, Some(vec![0.2, 0.5, 1.0]));
    assert_eq!(r.audio_volume, Some(0.8));
    assert_eq!(r.audio_play_on_awake, Some(false));
    assert_eq!(r.rigid_body_motion_type.as_deref(), Some("kinematic"));
}

#[test]
fn world_entity_record_apply_remaining_material_fields_from_events() {
    let mut world_view = WorldView::new();
    world_view.apply_event(added("scene:X", "Metal", "mesh"));
    world_view.apply_event(authored("scene:X", "materialMetallic", float_value(0.9)));
    world_view.apply_event(authored("scene:X", "materialRoughness", float_value(0.1)));
    world_view.apply_event(authored(
        "scene:X",
        "materialEmissive",
        vec3_value(0.0, 0.5, 1.0),
    ));

    let r = world_view.entity_record("scene:X").unwrap();
    assert_eq!(r.material_metallic, Some(0.9));
    assert_eq!(r.material_roughness, Some(0.1));
    assert_eq!(r.material_emissive, Some(vec![0.0, 0.5, 1.0]));
}

// MARK: - JSONValue

#[test]
#[allow(clippy::approx_constant)] // 3.14 is the Swift fixture's arbitrary number, not PI.
fn json_value_decoding() {
    #[derive(serde::Deserialize)]
    struct Wrapper {
        value: JSONValue,
    }
    let string: Wrapper = serde_json::from_str(r#"{"value":"hello"}"#).unwrap();
    let number: Wrapper = serde_json::from_str(r#"{"value":3.14}"#).unwrap();
    let boolean: Wrapper = serde_json::from_str(r#"{"value":true}"#).unwrap();

    assert_eq!(string.value, JSONValue::String("hello".to_string()));
    assert_eq!(number.value, JSONValue::Number(3.14));
    assert_eq!(boolean.value, JSONValue::Bool(true));
}

#[test]
fn json_value_json_fragment() {
    assert_eq!(
        JSONValue::String("hi".to_string()).json_fragment(),
        "\"hi\""
    );
    assert_eq!(JSONValue::Number(42.0).json_fragment(), "42");
    assert_eq!(JSONValue::Number(3.5).json_fragment(), "3.5");
    assert_eq!(JSONValue::Bool(false).json_fragment(), "false");
}

// MARK: - Confidence

#[test]
fn confidence_empty_plan_is_one() {
    let plan = SceneEditPlan::new("Hello".to_string(), None, vec![]);
    assert_eq!(Session::confidence(&plan), 1.0);
}

#[test]
fn confidence_single_safe_op_is_one() {
    let plan = SceneEditPlan::new(
        "rename".to_string(),
        None,
        vec![step(
            json!({"op":"set_name","entity_id":"scene:1","name":"Hero"}),
        )],
    );
    assert_eq!(Session::confidence(&plan), 1.0);
}

#[test]
fn confidence_multiple_steps_decreases() {
    let steps: Vec<SceneEditStep> = (0..4)
        .map(|_| step(json!({"op":"set_name","entity_id":"scene:1","name":"X"})))
        .collect();
    let plan = SceneEditPlan::new("multi".to_string(), None, steps);
    // 1.0 - 3 * 0.03 = 0.91
    assert_close(Session::confidence(&plan), 0.91, 0.001);
}

#[test]
fn confidence_destructive_op_applies_penalty() {
    let plan = SceneEditPlan::new(
        "delete".to_string(),
        None,
        vec![step(json!({"op":"delete_entity","entity_id":"scene:1"}))],
    );
    // 1.0 - 0.10 (delete) - 0.05 (uncompensated delete, no spawn) = 0.85
    assert_close(Session::confidence(&plan), 0.85, 0.001);
}

#[test]
fn confidence_delete_with_spawn_is_not_uncompensated() {
    let plan = SceneEditPlan::new(
        "replace".to_string(),
        None,
        vec![
            step(json!({"op":"delete_entity","entity_id":"scene:1"})),
            step(json!({"op":"spawn_entity","name":"NewProp"})),
        ],
    );
    // 1.0 - 0.10 - 0.03 - 0.05 (orphan spawn) = 0.82; no uncompensated-delete penalty.
    assert_close(Session::confidence(&plan), 0.82, 0.001);
}

#[test]
fn confidence_reasoning_bonus_applied() {
    let plan = SceneEditPlan::new(
        "rename".to_string(),
        Some("The user named this entity after the main character.".to_string()),
        vec![step(
            json!({"op":"set_name","entity_id":"scene:1","name":"Hero"}),
        )],
    );
    // 1.0 + 0.05 capped at 1.0
    assert_close(Session::confidence(&plan), 1.0, 0.001);
}

#[test]
fn confidence_reasoning_bonus_applied_when_below_one() {
    let steps: Vec<SceneEditStep> = (0..4)
        .map(|_| step(json!({"op":"set_name","entity_id":"scene:1","name":"X"})))
        .collect();
    let plan = SceneEditPlan::new(
        "multi".to_string(),
        Some("Renaming for clarity.".to_string()),
        steps,
    );
    // 0.91 + 0.05 = 0.96
    assert_close(Session::confidence(&plan), 0.96, 0.001);
}

#[test]
fn confidence_floor_at_040() {
    let steps: Vec<SceneEditStep> = (0..30)
        .map(|_| step(json!({"op":"delete_entity","entity_id":"scene:1"})))
        .collect();
    let plan = SceneEditPlan::new("massacre".to_string(), None, steps);
    assert!(Session::confidence(&plan) >= 0.40);
}

#[test]
fn confidence_broad_impact_penalty() {
    // 7 distinct entities → broadPenalty = 2 → -0.04
    let steps: Vec<SceneEditStep> = (1..=7)
        .map(|index| step(json!({"op":"set_name","entity_id":format!("scene:{index}"),"name":"X"})))
        .collect();
    let plan = SceneEditPlan::new("rename many".to_string(), None, steps);
    // 1.0 - 6*0.03 - 2*0.02 = 0.78
    assert_close(Session::confidence(&plan), 0.78, 0.001);
}

#[test]
fn confidence_orphan_spawn_penalty() {
    let plan = SceneEditPlan::new(
        "spawn".to_string(),
        None,
        vec![step(json!({"op":"spawn_entity","name":"Prop"}))],
    );
    // 1.0 - 0.05 = 0.95
    assert_close(Session::confidence(&plan), 0.95, 0.001);
}

// MARK: - WorkflowContext

#[test]
fn workflow_context_game_system_prompt_section() {
    let mut intent = GameplayIntent::new(
        "third_person_shooter".to_string(),
        "eliminate_all".to_string(),
    );
    intent.pacing = "tight_action".to_string();
    let mut ctx = GameWorkflowContext::new(intent, "Surrounded but escapable".to_string());
    ctx.level_phase = GameLevelPhase::EncounterDesign;
    let section = ctx.system_prompt_section();
    assert!(section.contains("game/interactive"));
    assert!(section.contains("EncounterDesign"));
    assert!(section.contains("tight_action"));
    assert!(section.contains("Surrounded but escapable"));
}

#[test]
fn workflow_context_film_system_prompt_section() {
    let mut ctx = FilmWorkflowContext::new("seq_010".to_string());
    ctx.active_shot_id = Some("sh_020".to_string());
    ctx.narrative_phase = FilmNarrativePhase::Lighting;
    ctx.director_intent = Some("Moody noir feel".to_string());
    ctx.locked_shot_ids = vec!["sh_010".to_string()];
    let section = ctx.system_prompt_section();
    assert!(section.contains("cinematic / film"));
    assert!(section.contains("lighting"));
    assert!(section.contains("Moody noir feel"));
    assert!(section.contains("sh_010"));
}

#[test]
fn workflow_context_film_review_phase_notes_strict_approval() {
    let mut ctx = FilmWorkflowContext::new("seq_010".to_string());
    ctx.narrative_phase = FilmNarrativePhase::Review;
    let section = ctx.system_prompt_section();
    assert!(section.contains("require explicit approval"));
}

#[test]
fn workflow_context_round_trips_codable() {
    let intent = GameplayIntent::new("puzzle_platformer".to_string(), "reach_exit".to_string());
    let mut game = GameWorkflowContext::new(intent, "Serene discovery".to_string());
    game.level_phase = GameLevelPhase::Polish;
    let context = WorkflowContext::Game(game);
    let data = serde_json::to_vec(&context).unwrap();
    let decoded: WorkflowContext = serde_json::from_slice(&data).unwrap();
    assert_eq!(decoded, context);
}

// MARK: - More snapshot fields

#[test]
fn snapshot_animation_fields_copied_to_entity_record() {
    let record = SceneSemanticSnapshotEntity {
        position: Some(vec![0.0, 0.0, 0.0]),
        components: vec![
            "transform".to_string(),
            "mesh".to_string(),
            "animation".to_string(),
        ],
        animation_clip: Some("walk_cycle".to_string()),
        animation_speed: Some(1.5),
        animation_loop: Some(true),
        animation_is_playing: Some(false),
        ..entity("scene:40", "Walker", "mesh")
    };
    let mut world_view = WorldView::new();
    world_view.apply_snapshot(&snapshot(1, vec![record]));

    let r = world_view.entity_record("scene:40").unwrap();
    assert_eq!(r.animation_clip.as_deref(), Some("walk_cycle"));
    assert_eq!(r.animation_speed, Some(1.5));
    assert_eq!(r.animation_loop, Some(true));
    assert_eq!(r.animation_is_playing, Some(false));
}

#[test]
fn snapshot_mesh_is_visible_false_recorded() {
    let record = SceneSemanticSnapshotEntity {
        position: Some(vec![0.0, 0.0, 0.0]),
        components: vec!["transform".to_string(), "mesh".to_string()],
        mesh_is_visible: Some(false),
        ..entity("scene:41", "HiddenMesh", "mesh")
    };
    let mut world_view = WorldView::new();
    world_view.apply_snapshot(&snapshot(1, vec![record]));

    assert_eq!(
        world_view
            .entity_record("scene:41")
            .unwrap()
            .mesh_is_visible,
        Some(false)
    );
}

#[test]
fn snapshot_constraint_enabled_copied_to_entity_record() {
    let record = SceneSemanticSnapshotEntity {
        position: Some(vec![0.0, 0.0, 0.0]),
        components: vec!["transform".to_string(), "constraint".to_string()],
        constraint_enabled: Some(false),
        ..entity("scene:50", "Hinge", "mesh")
    };
    let mut world_view = WorldView::new();
    world_view.apply_snapshot(&snapshot(1, vec![record]));

    assert_eq!(
        world_view
            .entity_record("scene:50")
            .unwrap()
            .constraint_enabled,
        Some(false)
    );
}

#[test]
fn entity_authored_changed_constraint_enabled_populates_record() {
    let mut world_view = WorldView::new();
    world_view.apply_event(added("scene:51", "Joint", "mesh"));
    world_view.apply_event(authored("scene:51", "constraintEnabled", bool_value(true)));
    assert_eq!(
        world_view
            .entity_record("scene:51")
            .unwrap()
            .constraint_enabled,
        Some(true)
    );
}

#[test]
fn entity_authored_changed_animation_fields_populate_record() {
    let mut world_view = WorldView::new();
    world_view.apply_event(added("scene:42", "Dancer", "mesh"));
    world_view.apply_event(authored("scene:42", "animationClip", string_value("dance")));
    world_view.apply_event(authored("scene:42", "animationIsPlaying", bool_value(true)));
    world_view.apply_event(authored("scene:42", "meshIsVisible", bool_value(false)));

    let r = world_view.entity_record("scene:42").unwrap();
    assert_eq!(r.animation_clip.as_deref(), Some("dance"));
    assert_eq!(r.animation_is_playing, Some(true));
    assert_eq!(r.mesh_is_visible, Some(false));
}

#[test]
fn session_can_be_seeded_from_ai_world_context() {
    let context = AIWorldContext::default();
    context.observe_events(vec![
        added("scene:1", "Hero", "mesh"),
        WorldEvent::EntityInferredUpdated {
            ref_: "scene:1".to_string(),
            property: "object_category".to_string(),
            value: string_value("chair"),
            confidence: 0.91,
            source: Some("perception:fixture_classifier".to_string()),
        },
    ]);

    let session = Session::with_defaults(SessionConfig::open_ai("test"));
    session.replace_world_view(context.snapshot());

    let record = session.entity_record("scene:1").expect("record");
    let inferred = record.inferred.get("object_category").expect("inferred");
    assert_eq!(inferred.display_value, "chair");
    assert_eq!(
        inferred.source.as_deref(),
        Some("perception:fixture_classifier")
    );
}

// MARK: - Camera FOV / active ops

#[test]
fn camera_fov_op_round_trips() {
    let step = decode_step(r#"{"op":"set_camera_fov","entity_id":"scene:5","camera_fov_y":35.0}"#);
    assert_eq!(step.op, SceneEditOp::SetCameraFov);
    assert_eq!(step.entity_ref.as_deref(), Some("scene:5"));
    assert_eq!(step.camera_fov_y_degrees, Some(35.0));
}

#[test]
fn camera_active_op_round_trips() {
    let step =
        decode_step(r#"{"op":"set_camera_active","entity_id":"scene:7","camera_is_active":false}"#);
    assert_eq!(step.op, SceneEditOp::SetCameraActive);
    assert_eq!(step.camera_is_active, Some(false));
}

#[test]
fn world_entity_record_apply_camera_fov_from_event() {
    let mut view = WorldView::new();
    view.apply_event(added("scene:9", "MainCamera", "camera"));
    view.apply_event(authored("scene:9", "cameraFovYDegrees", float_value(50.0)));
    assert_eq!(
        view.entity_record("scene:9").unwrap().camera_fov_y_degrees,
        Some(50.0)
    );
}

#[test]
fn world_entity_record_apply_camera_active_from_event() {
    let mut view = WorldView::new();
    view.apply_event(added("scene:10", "Cam", "camera"));
    view.apply_event(authored("scene:10", "cameraIsActive", bool_value(false)));
    assert_eq!(
        view.entity_record("scene:10").unwrap().camera_is_active,
        Some(false)
    );
}

#[test]
fn light_cast_shadows_op_round_trips() {
    let step = decode_step(
        r#"{"op":"set_light_cast_shadows","entity_id":"scene:11","light_cast_shadows":true}"#,
    );
    assert_eq!(step.op, SceneEditOp::SetLightCastShadows);
    assert_eq!(step.entity_ref.as_deref(), Some("scene:11"));
    assert_eq!(step.light_cast_shadows, Some(true));
}

#[test]
fn world_entity_record_apply_light_cast_shadows_from_event() {
    let mut view = WorldView::new();
    view.apply_event(added("scene:12", "Sun", "light"));
    view.apply_event(authored("scene:12", "lightCastShadows", bool_value(true)));
    assert_eq!(
        view.entity_record("scene:12").unwrap().light_cast_shadows,
        Some(true)
    );
}

#[test]
fn set_script_property_op_round_trips() {
    let step = decode_step(
        r#"{"op":"set_script_property","entity_id":"scene:20","script_index":0,"script_property_name":"speed","script_property_value":5.0}"#,
    );
    assert_eq!(step.op, SceneEditOp::SetScriptProperty);
    assert_eq!(step.entity_ref.as_deref(), Some("scene:20"));
    assert_eq!(step.script_index, Some(0));
    assert_eq!(step.script_property_name.as_deref(), Some("speed"));
    assert_eq!(step.script_property_value, Some(JSONValue::Number(5.0)));
}

#[test]
fn set_script_property_defaults_script_index_to_zero() {
    let step = decode_step(
        r#"{"op":"set_script_property","entity_id":"scene:21","script_property_name":"label","script_property_value":"Patrol"}"#,
    );
    assert!(step.script_index.is_none());
    assert_eq!(
        step.script_property_value,
        Some(JSONValue::String("Patrol".to_string()))
    );
}

#[test]
fn json_value_bool_round_trips() {
    let step = decode_step(
        r#"{"op":"set_script_property","entity_id":"scene:22","script_property_name":"active","script_property_value":true}"#,
    );
    assert_eq!(step.script_property_value, Some(JSONValue::Bool(true)));
}

#[test]
fn set_collider_layer_op_round_trips() {
    let step = decode_step(
        r#"{"op":"set_collider_layer","entity_id":"scene:30","collider_layer_id":2,"collider_layer_mask":5}"#,
    );
    assert_eq!(step.op, SceneEditOp::SetColliderLayer);
    assert_eq!(step.entity_ref.as_deref(), Some("scene:30"));
    assert_eq!(step.collider_layer_id, Some(2));
    assert_eq!(step.collider_layer_mask, Some(5));
}

// MARK: - Executor mutations

#[test]
fn set_collider_layer_executor_emits_both_mutations() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let _ = scene.set_component(
        Collider::with_shape(ColliderShape::Box {
            half_extents: Float3::ONE,
            center: Float3::ZERO,
        }),
        entity,
    );
    let ref_ = entity_ref(entity);

    let transaction = execute_plan(
        "test",
        vec![step(json!({
            "op": "set_collider_layer", "entity_id": ref_,
            "collider_layer_id": 3, "collider_layer_mask": 12
        }))],
        &scene,
    );

    let ops = scene_ops(&transaction);
    let has_collider = ops.iter().any(|mutation| {
        mutation
            .decoded_component::<Collider>("collider")
            .is_some_and(|(_, c)| c.layer_id == 3 && c.layer_mask == 12)
    });
    assert!(
        has_collider,
        "set_collider_layer must produce setCollider mutation with layerID=3 and layerMask=12"
    );
}

#[test]
fn set_collider_shape_executor_produces_shape_type_mutation() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let _ = scene.set_component(
        Collider::with_shape(ColliderShape::Box {
            half_extents: Float3::ONE,
            center: Float3::ZERO,
        }),
        entity,
    );
    let ref_ = entity_ref(entity);

    let transaction = execute_plan(
        "spherify",
        vec![step(json!({
            "op": "set_collider_shape", "entity_id": ref_, "collider_shape": "sphere"
        }))],
        &scene,
    );

    let ops = scene_ops(&transaction);
    let has_shape = ops.iter().any(|mutation| {
        mutation
            .decoded_component::<Collider>("collider")
            .is_some_and(|(_, c)| matches!(c.shape(), ColliderShape::Sphere { .. }))
    });
    assert!(
        has_shape,
        "set_collider_shape sphere must produce setCollider mutation with sphere shape"
    );
}

#[test]
fn set_collider_material_executor_produces_three_mutations() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let _ = scene.set_component(
        Collider::with_shape(ColliderShape::Box {
            half_extents: Float3::ONE,
            center: Float3::ZERO,
        }),
        entity,
    );
    let ref_ = entity_ref(entity);

    let transaction = execute_plan(
        "icy",
        vec![step(json!({
            "op": "set_collider_material", "entity_id": ref_,
            "friction": 0.05, "restitution": 0.9, "density": 0.8
        }))],
        &scene,
    );

    let ops = scene_ops(&transaction);
    let has_collider = ops.iter().any(|mutation| {
        mutation
            .decoded_component::<Collider>("collider")
            .is_some_and(|(_, c)| {
                (c.material.friction - 0.05).abs() < 0.001
                    && (c.material.restitution - 0.9).abs() < 0.001
                    && (c.material.density - 0.8).abs() < 0.001
            })
    });
    assert!(
        has_collider,
        "set_collider_material must produce setCollider mutation with all three material values"
    );
}

#[test]
fn set_script_property_executor_merges_into_existing_bindings() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let existing_binding = ScriptBinding::new(
        ScriptHandle::new(7),
        ScriptBindingID::new(),
        None,
        true,
        r#"{"speed":1.0}"#,
    );
    let _ = scene.set_component(ScriptComponent::new(vec![existing_binding]), entity);
    let ref_ = entity_ref(entity);

    let transaction = execute_plan(
        "set speed",
        vec![step(json!({
            "op": "set_script_property", "entity_id": ref_,
            "script_index": 0, "script_property_name": "speed", "script_property_value": 5.0
        }))],
        &scene,
    );

    let ops = scene_ops(&transaction);
    let bindings = ops
        .iter()
        .find_map(|mutation| {
            mutation
                .decoded_component::<ScriptComponent>("script")
                .map(|(_, component)| component.bindings)
        })
        .expect("expected setScriptBindings mutation");
    assert_eq!(bindings.len(), 1);
    let dict: Value = serde_json::from_str(&bindings[0].parameters_json).unwrap();
    assert_eq!(
        dict["speed"].as_f64(),
        Some(5.0),
        "merged speed should be 5.0"
    );
    assert_eq!(
        bindings[0].script.raw_value, 7,
        "script handle must be preserved"
    );
}

#[test]
fn set_script_property_executor_creates_binding_when_component_absent() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let ref_ = entity_ref(entity);

    let transaction = execute_plan(
        "add label",
        vec![step(json!({
            "op": "set_script_property", "entity_id": ref_,
            "script_identifier": "project.patrol",
            "script_property_name": "label", "script_property_value": "Patrol"
        }))],
        &scene,
    );

    let ops = scene_ops(&transaction);
    let bindings = ops
        .iter()
        .find_map(|mutation| {
            mutation
                .decoded_component::<ScriptComponent>("script")
                .map(|(_, component)| component.bindings)
        })
        .expect("expected setScriptBindings mutation");
    assert_eq!(
        bindings.len(),
        1,
        "executor must create a binding when none exist"
    );
    assert_eq!(bindings[0].identifier.as_deref(), Some("project.patrol"));
    let dict: Value = serde_json::from_str(&bindings[0].parameters_json).unwrap();
    assert_eq!(dict["label"].as_str(), Some("Patrol"));
}

#[test]
fn set_script_enabled_disables_binding() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let binding = ScriptBinding::with_script(ScriptHandle::new(1));
    let _ = scene.set_component(ScriptComponent::new(vec![binding]), entity);
    let ref_ = entity_ref(entity);

    let transaction = execute_plan(
        "disable script",
        vec![step(json!({
            "op": "set_script_enabled", "entity_id": ref_,
            "is_enabled": false, "script_index": 0
        }))],
        &scene,
    );

    let ops = scene_ops(&transaction);
    let bindings = ops
        .iter()
        .find_map(|mutation| {
            mutation
                .decoded_component::<ScriptComponent>("script")
                .map(|(_, component)| component.bindings)
        })
        .expect("expected setScriptBindings mutation");
    assert!(
        !bindings[0].is_enabled,
        "set_script_enabled false must disable the binding"
    );
}

#[test]
fn set_script_enabled_creates_binding_when_component_absent() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let ref_ = entity_ref(entity);

    let transaction = execute_plan(
        "enable script",
        vec![step(json!({
            "op": "set_script_enabled", "entity_id": ref_,
            "script_identifier": "project.runner", "is_enabled": true
        }))],
        &scene,
    );

    let ops = scene_ops(&transaction);
    let bindings = ops
        .iter()
        .find_map(|mutation| {
            mutation
                .decoded_component::<ScriptComponent>("script")
                .map(|(_, component)| component.bindings)
        })
        .expect("expected setScriptBindings mutation");
    assert_eq!(bindings.len(), 1);
    assert!(bindings[0].is_enabled);
    assert_eq!(bindings[0].identifier.as_deref(), Some("project.runner"));
}

#[test]
fn set_script_enabled_missing_field_throws() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let ref_ = entity_ref(entity);

    let plan = SceneEditPlan::new(
        "bad".to_string(),
        None,
        vec![step(json!({"op": "set_script_enabled", "entity_id": ref_}))],
    );
    let result = SceneEditPlanExecutor::new().build_transaction_with_defaults(&plan, &scene);
    assert!(result.is_err());
}

#[test]
fn set_script_enabled_targets_correct_binding_index() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let b0 = ScriptBinding::with_script(ScriptHandle::new(1));
    let b1 = ScriptBinding::with_script(ScriptHandle::new(2));
    let _ = scene.set_component(ScriptComponent::new(vec![b0, b1]), entity);
    let ref_ = entity_ref(entity);

    let transaction = execute_plan(
        "disable second",
        vec![step(json!({
            "op": "set_script_enabled", "entity_id": ref_,
            "is_enabled": false, "script_index": 1
        }))],
        &scene,
    );

    let ops = scene_ops(&transaction);
    let bindings = ops
        .iter()
        .find_map(|mutation| {
            mutation
                .decoded_component::<ScriptComponent>("script")
                .map(|(_, component)| component.bindings)
        })
        .expect("expected setScriptBindings mutation");
    assert!(bindings[0].is_enabled, "binding 0 must remain enabled");
    assert!(!bindings[1].is_enabled, "binding 1 must be disabled");
}

#[test]
fn set_collider_trigger_executor_produces_mutation() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let _ = scene.set_component(
        Collider::with_shape(ColliderShape::Box {
            half_extents: Float3::ONE,
            center: Float3::ZERO,
        }),
        entity,
    );
    let ref_ = entity_ref(entity);

    let transaction = execute_plan(
        "trigger",
        vec![step(json!({
            "op": "set_collider_trigger", "entity_id": ref_, "is_trigger": true
        }))],
        &scene,
    );

    let ops = scene_ops(&transaction);
    let has_trigger = ops.iter().any(|mutation| {
        mutation
            .decoded_component::<Collider>("collider")
            .is_some_and(|(_, c)| c.is_trigger)
    });
    assert!(
        has_trigger,
        "set_collider_trigger must produce setCollider mutation with isTrigger=true"
    );
}

#[test]
fn set_collider_box_extents_executor_produces_mutation() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let _ = scene.set_component(
        Collider::with_shape(ColliderShape::Box {
            half_extents: Float3::ONE,
            center: Float3::ZERO,
        }),
        entity,
    );
    let ref_ = entity_ref(entity);

    let transaction = execute_plan(
        "extents",
        vec![step(json!({
            "op": "set_collider_box_extents", "entity_id": ref_,
            "half_extents": [0.5, 1.0, 2.0]
        }))],
        &scene,
    );

    let ops = scene_ops(&transaction);
    let has_extents = ops.iter().any(|mutation| {
        mutation
            .decoded_component::<Collider>("collider")
            .is_some_and(|(_, c)| match c.shape() {
                ColliderShape::Box { half_extents, .. } => {
                    (half_extents.x - 0.5).abs() < 0.001
                        && (half_extents.y - 1.0).abs() < 0.001
                        && (half_extents.z - 2.0).abs() < 0.001
                }
                _ => false,
            })
    });
    assert!(
        has_extents,
        "set_collider_box_extents must produce setCollider mutation with correct half-extents"
    );
}

#[test]
fn set_collider_sphere_radius_executor_produces_mutation() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let _ = scene.set_component(
        Collider::with_shape(ColliderShape::Sphere {
            radius: 1.0,
            center: Float3::ZERO,
        }),
        entity,
    );
    let ref_ = entity_ref(entity);

    let transaction = execute_plan(
        "sphere",
        vec![step(json!({
            "op": "set_collider_sphere_radius", "entity_id": ref_, "radius": 3.5
        }))],
        &scene,
    );

    let ops = scene_ops(&transaction);
    let has_radius = ops.iter().any(|mutation| {
        mutation
            .decoded_component::<Collider>("collider")
            .is_some_and(|(_, c)| match c.shape() {
                ColliderShape::Sphere { radius, .. } => (radius - 3.5).abs() < 0.001,
                _ => false,
            })
    });
    assert!(
        has_radius,
        "set_collider_sphere_radius must produce setCollider mutation with sphere radius=3.5"
    );
}

#[test]
fn set_collider_capsule_executor_produces_both_mutations() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let _ = scene.set_component(
        Collider::with_shape(ColliderShape::Box {
            half_extents: Float3::ONE,
            center: Float3::ZERO,
        }),
        entity,
    );
    let ref_ = entity_ref(entity);

    let transaction = execute_plan(
        "capsule",
        vec![step(json!({
            "op": "set_collider_capsule", "entity_id": ref_,
            "radius": 0.4, "half_height": 1.2
        }))],
        &scene,
    );

    let ops = scene_ops(&transaction);
    let has_collider = ops.iter().any(|mutation| {
        mutation
            .decoded_component::<Collider>("collider")
            .is_some_and(|(_, c)| match c.shape() {
                ColliderShape::Capsule {
                    radius,
                    half_height,
                    ..
                } => (radius - 0.4).abs() < 0.001 && (half_height - 1.2).abs() < 0.001,
                _ => false,
            })
    });
    assert!(
        has_collider,
        "set_collider_capsule must produce setCollider mutation with radius=0.4 halfHeight=1.2"
    );
}

#[test]
fn set_constraint_enabled_executor_produces_mutation() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let target = scene.create_entity();
    let _ = scene.set_component(
        Constraint::new(
            PhysicsJointConfiguration::Point,
            entity,
            target,
            Float3::ZERO,
            Float3::ZERO,
            true,
            Constraint::DEFAULT_BREAK_LIMIT,
            Constraint::DEFAULT_BREAK_LIMIT,
        ),
        entity,
    );
    let ref_ = entity_ref(entity);

    let transaction = execute_plan(
        "constraint",
        vec![step(json!({
            "op": "set_constraint_enabled", "entity_id": ref_, "is_enabled": false
        }))],
        &scene,
    );

    let ops = scene_ops(&transaction);
    let has_constraint = ops.iter().any(|mutation| match mutation {
        SceneMutation::SetComponentData { type_id, value, .. } if type_id == "constraint" => {
            value
                .object_value()
                .and_then(|object| object.get("isEnabled"))
                .and_then(ComponentValue::as_bool)
                == Some(false)
        }
        _ => false,
    });
    assert!(
        has_constraint,
        "set_constraint_enabled must produce setConstraintEnabled mutation"
    );
}

#[test]
fn set_rigid_body_allow_sleep_executor_produces_mutation() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let ref_ = entity_ref(entity);

    let transaction = execute_plan(
        "sleep",
        vec![step(json!({
            "op": "set_rigidbody_allow_sleep", "entity_id": ref_, "allow_sleep": true
        }))],
        &scene,
    );

    let ops = scene_ops(&transaction);
    let has_sleep = ops.iter().any(|mutation| {
        mutation
            .decoded_component::<RigidBody>("rigidbody")
            .is_some_and(|(_, body)| body.allow_sleep)
    });
    assert!(
        has_sleep,
        "set_rigid_body_allow_sleep must produce setRigidBody mutation with allowSleep=true"
    );
}

#[test]
fn set_mesh_visibility_executor_produces_mutation() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let _ = scene.set_component(
        RenderMeshComponent::new(0, true, Float3::ONE, None, vec![]),
        entity,
    );
    let ref_ = entity_ref(entity);

    let transaction = execute_plan(
        "hide",
        vec![step(json!({
            "op": "set_mesh_visibility", "entity_id": ref_, "is_visible": false
        }))],
        &scene,
    );

    let ops = scene_ops(&transaction);
    let has_visibility = ops.iter().any(|mutation| {
        mutation
            .decoded_component::<RenderMeshComponent>("renderMesh")
            .is_some_and(|(_, component)| !component.is_visible)
    });
    assert!(
        has_visibility,
        "set_mesh_visibility must produce setRenderMeshVisibility mutation"
    );
}

#[test]
fn set_light_type_executor_produces_mutation() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let _ = scene.set_component(
        LightComponent::new(
            LightType::Point,
            Float3::ONE,
            100.0,
            10.0,
            20.0,
            30.0,
            false,
        ),
        entity,
    );
    let ref_ = entity_ref(entity);

    let transaction = execute_plan(
        "spot",
        vec![step(json!({
            "op": "set_light_type", "entity_id": ref_, "light_type": "spot"
        }))],
        &scene,
    );

    let ops = scene_ops(&transaction);
    let has_type = ops.iter().any(|mutation| {
        mutation
            .decoded_component::<LightComponent>("light")
            .is_some_and(|(_, component)| component.light_type == LightType::Spot)
    });
    assert!(
        has_type,
        "set_light_type must produce setLightType(.spot) mutation"
    );
}

#[test]
fn set_light_intensity_executor_produces_mutation() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let _ = scene.set_component(
        LightComponent::new(
            LightType::Directional,
            Float3::ONE,
            1.0,
            100.0,
            20.0,
            30.0,
            false,
        ),
        entity,
    );
    let ref_ = entity_ref(entity);

    let transaction = execute_plan(
        "brighter",
        vec![step(json!({
            "op": "set_light_intensity", "entity_id": ref_, "intensity": 800
        }))],
        &scene,
    );

    let ops = scene_ops(&transaction);
    let has_intensity = ops.iter().any(|mutation| {
        mutation
            .decoded_component::<LightComponent>("light")
            .is_some_and(|(_, component)| (component.intensity - 800.0).abs() < 0.01)
    });
    assert!(
        has_intensity,
        "set_light_intensity must produce setLightIntensity mutation"
    );
}

#[test]
fn set_light_color_executor_produces_mutation() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let _ = scene.set_component(
        LightComponent::new(
            LightType::Point,
            Float3::ONE,
            100.0,
            10.0,
            20.0,
            30.0,
            false,
        ),
        entity,
    );
    let ref_ = entity_ref(entity);

    let transaction = execute_plan(
        "warm",
        vec![step(json!({
            "op": "set_light_color", "entity_id": ref_, "color": [1.0, 0.8, 0.4]
        }))],
        &scene,
    );

    let ops = scene_ops(&transaction);
    let has_color = ops.iter().any(|mutation| {
        mutation
            .decoded_component::<LightComponent>("light")
            .is_some_and(|(_, component)| {
                (component.color.x - 1.0).abs() < 0.01 && (component.color.y - 0.8).abs() < 0.01
            })
    });
    assert!(
        has_color,
        "set_light_color must produce setLightColor mutation"
    );
}

#[test]
fn set_light_range_executor_produces_mutation() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let _ = scene.set_component(
        LightComponent::new(
            LightType::Point,
            Float3::ONE,
            100.0,
            10.0,
            20.0,
            30.0,
            false,
        ),
        entity,
    );
    let ref_ = entity_ref(entity);

    let transaction = execute_plan(
        "range",
        vec![step(json!({
            "op": "set_light_range", "entity_id": ref_, "range": 35.0
        }))],
        &scene,
    );

    let ops = scene_ops(&transaction);
    let has_range = ops.iter().any(|mutation| {
        mutation
            .decoded_component::<LightComponent>("light")
            .is_some_and(|(_, component)| (component.range - 35.0).abs() < 0.01)
    });
    assert!(
        has_range,
        "set_light_range must produce setLightRange mutation"
    );
}

#[test]
fn set_light_spot_angles_executor_produces_both_mutations() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let _ = scene.set_component(
        LightComponent::new(LightType::Spot, Float3::ONE, 100.0, 20.0, 20.0, 30.0, false),
        entity,
    );
    let ref_ = entity_ref(entity);

    let transaction = execute_plan(
        "cone",
        vec![step(json!({
            "op": "set_light_spot_angles", "entity_id": ref_,
            "spot_inner_angle": 15.0, "spot_outer_angle": 40.0
        }))],
        &scene,
    );

    let ops = scene_ops(&transaction);
    let has_inner = ops.iter().any(|mutation| {
        mutation
            .decoded_component::<LightComponent>("light")
            .is_some_and(|(_, component)| (component.spot_inner_angle_degrees - 15.0).abs() < 0.01)
    });
    let has_outer = ops.iter().any(|mutation| {
        mutation
            .decoded_component::<LightComponent>("light")
            .is_some_and(|(_, component)| (component.spot_outer_angle_degrees - 40.0).abs() < 0.01)
    });
    assert!(
        has_inner,
        "set_light_spot_angles must produce setLightSpotInnerAngle mutation"
    );
    assert!(
        has_outer,
        "set_light_spot_angles must produce setLightSpotOuterAngle mutation"
    );
}

#[test]
fn set_mesh_color_executor_produces_mutation() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let _ = scene.set_component(
        RenderMeshComponent::new(0, true, Float3::ONE, None, vec![]),
        entity,
    );
    let ref_ = entity_ref(entity);

    let transaction = execute_plan(
        "tint",
        vec![step(json!({
            "op": "set_mesh_color", "entity_id": ref_, "color": [0.2, 0.5, 0.9]
        }))],
        &scene,
    );

    let ops = scene_ops(&transaction);
    let has_tint = ops.iter().any(|mutation| {
        mutation
            .decoded_component::<RenderMeshComponent>("renderMesh")
            .is_some_and(|(_, component)| {
                let c = component.color_tint;
                (c.x - 0.2).abs() < 0.01 && (c.y - 0.5).abs() < 0.01 && (c.z - 0.9).abs() < 0.01
            })
    });
    assert!(
        has_tint,
        "set_mesh_color must produce setMeshColorTint mutation"
    );
}

#[test]
fn set_camera_fov_executor_produces_mutation() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let _ = scene.set_component(CameraComponent::default(), entity);
    let ref_ = entity_ref(entity);

    let transaction = execute_plan(
        "fov",
        vec![step(json!({
            "op": "set_camera_fov", "entity_id": ref_, "camera_fov_y": 90.0
        }))],
        &scene,
    );

    let ops = scene_ops(&transaction);
    let has_fov = ops.iter().any(|mutation| {
        mutation
            .decoded_component::<CameraComponent>("camera")
            .is_some_and(|(_, component)| {
                let fov = component.fov_y_radians * 180.0 / std::f32::consts::PI;
                (fov - 90.0).abs() < 0.01
            })
    });
    assert!(has_fov, "set_camera_fov must produce setCameraFOV mutation");
}

#[test]
fn set_camera_aspect_executor_produces_mutation() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let _ = scene.set_component(CameraComponent::default(), entity);
    let ref_ = entity_ref(entity);

    let transaction = execute_plan(
        "aspect",
        vec![step(json!({
            "op": "set_camera_aspect_ratio", "entity_id": ref_, "camera_aspect_ratio": 1.777
        }))],
        &scene,
    );

    let ops = scene_ops(&transaction);
    let has_aspect = ops.iter().any(|mutation| {
        mutation
            .decoded_component::<CameraComponent>("camera")
            .is_some_and(|(_, component)| (component.aspect_ratio - 1.777).abs() < 0.001)
    });
    assert!(
        has_aspect,
        "set_camera_aspect_ratio must produce setCameraAspectRatio mutation"
    );
}

#[test]
fn set_camera_active_executor_produces_mutation() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let _ = scene.set_component(CameraComponent::default(), entity);
    let ref_ = entity_ref(entity);

    let transaction = execute_plan(
        "activate",
        vec![step(json!({
            "op": "set_camera_active", "entity_id": ref_, "camera_is_active": true
        }))],
        &scene,
    );

    let ops = scene_ops(&transaction);
    let has_active = ops.iter().any(|mutation| {
        mutation
            .decoded_component::<CameraComponent>("camera")
            .is_some_and(|(_, component)| component.is_active)
    });
    assert!(
        has_active,
        "set_camera_active must produce setCameraActive mutation"
    );
}

#[test]
fn set_rigid_body_motion_executor_produces_mutation() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let _ = scene.set_component(
        RigidBody {
            motion_type: RigidBodyMotionType::Dynamic,
            mass: 1.0,
            gravity_scale: 1.0,
            allow_sleep: true,
            ..RigidBody::default()
        },
        entity,
    );
    let ref_ = entity_ref(entity);

    let transaction = execute_plan(
        "kinematic",
        vec![step(json!({
            "op": "set_rigidbody_motion", "entity_id": ref_, "motion_type": "kinematic"
        }))],
        &scene,
    );

    let ops = scene_ops(&transaction);
    let has_motion = ops.iter().any(|mutation| {
        mutation
            .decoded_component::<RigidBody>("rigidbody")
            .is_some_and(|(_, body)| body.motion_type == RigidBodyMotionType::Kinematic)
    });
    assert!(
        has_motion,
        "set_rigidbody_motion must produce setRigidBody mutation with motionType=.kinematic"
    );
}

#[test]
fn set_rigid_body_mass_executor_produces_mutation() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let _ = scene.set_component(
        RigidBody {
            motion_type: RigidBodyMotionType::Dynamic,
            mass: 1.0,
            gravity_scale: 1.0,
            allow_sleep: true,
            ..RigidBody::default()
        },
        entity,
    );
    let ref_ = entity_ref(entity);

    let transaction = execute_plan(
        "mass",
        vec![step(json!({
            "op": "set_rigidbody_mass", "entity_id": ref_, "mass": 25.0
        }))],
        &scene,
    );

    let ops = scene_ops(&transaction);
    let has_mass = ops.iter().any(|mutation| {
        mutation
            .decoded_component::<RigidBody>("rigidbody")
            .is_some_and(|(_, body)| (body.mass - 25.0).abs() < 0.01)
    });
    assert!(
        has_mass,
        "set_rigidbody_mass must produce setRigidBody mutation with mass=25"
    );
}

#[test]
fn set_rigid_body_gravity_executor_produces_mutation() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let _ = scene.set_component(
        RigidBody {
            motion_type: RigidBodyMotionType::Dynamic,
            mass: 1.0,
            gravity_scale: 1.0,
            allow_sleep: true,
            ..RigidBody::default()
        },
        entity,
    );
    let ref_ = entity_ref(entity);

    let transaction = execute_plan(
        "gravity",
        vec![step(json!({
            "op": "set_rigidbody_gravity", "entity_id": ref_, "gravity_scale": 0.2
        }))],
        &scene,
    );

    let ops = scene_ops(&transaction);
    let has_gravity = ops.iter().any(|mutation| {
        mutation
            .decoded_component::<RigidBody>("rigidbody")
            .is_some_and(|(_, body)| (body.gravity_scale - 0.2).abs() < 0.001)
    });
    assert!(
        has_gravity,
        "set_rigidbody_gravity must produce setRigidBody mutation with gravityScale=0.2"
    );
}

#[test]
fn set_transform_position_only_preserves_existing_transform() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    // Give entity a non-identity transform with y=5.
    let mut initial = LocalTransform::default();
    initial
        .matrix
        .set_column(3, Float4::new(0.0, 5.0, 0.0, 1.0));
    let _ = scene.set_local_transform(initial, entity);
    let ref_ = entity_ref(entity);

    let transaction = execute_plan(
        "move",
        vec![step(json!({
            "op": "set_transform", "entity_id": ref_, "position": [10, 20, 30]
        }))],
        &scene,
    );

    let ops = scene_ops(&transaction);
    let transform = ops
        .iter()
        .find_map(|mutation| match mutation {
            SceneMutation::SetLocalTransform { transform, .. } => Some(transform),
            _ => None,
        })
        .expect("transform");
    assert_close(f64::from(transform.translation().x), 10.0, 0.01);
    assert_close(f64::from(transform.translation().y), 20.0, 0.01);
    assert_close(f64::from(transform.translation().z), 30.0, 0.01);
}

#[test]
fn snap_to_ground_executor_zeros_y_translation() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let mut elevated = LocalTransform::default();
    elevated
        .matrix
        .set_column(3, Float4::new(3.0, 8.0, 1.0, 1.0));
    let _ = scene.set_local_transform(elevated, entity);
    let ref_ = entity_ref(entity);

    let transaction = execute_plan(
        "ground",
        vec![step(json!({"op": "snap_to_ground", "entity_id": ref_}))],
        &scene,
    );

    let ops = scene_ops(&transaction);
    let transform = ops
        .iter()
        .find_map(|mutation| match mutation {
            SceneMutation::SetLocalTransform { transform, .. } => Some(transform),
            _ => None,
        })
        .expect("transform");
    assert_close(f64::from(transform.translation().y), 0.0, 0.001);
    assert_close(f64::from(transform.translation().x), 3.0, 0.01);
    assert_close(f64::from(transform.translation().z), 1.0, 0.01);
}

#[test]
fn set_name_executor_produces_mutation() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let ref_ = entity_ref(entity);

    let transaction = execute_plan(
        "rename",
        vec![step(json!({
            "op": "set_name", "entity_id": ref_, "name": "HeroChar"
        }))],
        &scene,
    );

    let ops = scene_ops(&transaction);
    let has_name = ops.iter().any(|mutation| {
        matches!(mutation, SceneMutation::SetSceneName { value, .. } if value == "HeroChar")
    });
    assert!(has_name, "set_name must produce setSceneName mutation");
}

#[test]
fn delete_entity_executor_produces_mutation() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let ref_ = entity_ref(entity);

    let transaction = execute_plan(
        "delete",
        vec![step(json!({"op": "delete_entity", "entity_id": ref_}))],
        &scene,
    );

    let ops = scene_ops(&transaction);
    let has_delete = ops.iter().any(|mutation| {
        matches!(mutation, SceneMutation::DeleteEntity { entity_id } if *entity_id == entity.raw_value())
    });
    assert!(
        has_delete,
        "delete_entity must produce deleteEntity mutation"
    );
}

#[test]
fn spawn_entity_executor_produces_mutation() {
    let scene = SceneRuntime::new(ComponentRegistry::built_in());

    let transaction = execute_plan(
        "spawn",
        vec![step(json!({
            "op": "spawn_entity", "label": "Barrel", "spawn_position": [0, 0, 5]
        }))],
        &scene,
    );

    let ops = scene_ops(&transaction);
    let has_spawn = ops.iter().any(|mutation| match mutation {
        SceneMutation::SpawnImportedMeshEntity {
            label, position, ..
        } => label == "Barrel" && (position.z - 5.0).abs() < 0.01,
        _ => false,
    });
    assert!(
        has_spawn,
        "spawn_entity must produce spawnImportedMeshEntity mutation with correct label and position"
    );
}

#[test]
fn duplicate_entity_executor_produces_mutation() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let ref_ = entity_ref(entity);

    let transaction = execute_plan(
        "dup",
        vec![step(json!({"op": "duplicate_entity", "entity_id": ref_}))],
        &scene,
    );

    let ops = scene_ops(&transaction);
    let has_dup = ops.iter().any(|mutation| {
        matches!(mutation, SceneMutation::DuplicateEntity { entity_id } if *entity_id == entity.raw_value())
    });
    assert!(
        has_dup,
        "duplicate_entity must produce duplicateEntity mutation"
    );
}

#[test]
fn reparent_entity_to_root_executor_produces_move_entity_mutation() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let ref_ = entity_ref(entity);

    let transaction = execute_plan(
        "reparent",
        vec![step(json!({"op": "reparent_entity", "entity_id": ref_}))],
        &scene,
    );

    let ops = scene_ops(&transaction);
    let has_move = ops.iter().any(|mutation| {
        matches!(
            mutation,
            SceneMutation::MoveEntity { entity_id, parent_id, .. }
                if *entity_id == entity.raw_value() && parent_id.is_none()
        )
    });
    assert!(
        has_move,
        "reparent_entity with no parent_id must produce moveEntity(parentID: nil)"
    );
}

#[test]
fn set_light_cast_shadows_executor_produces_mutation() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let _ = scene.set_component(
        LightComponent::new(
            LightType::Directional,
            Float3::ONE,
            1.0,
            100.0,
            20.0,
            30.0,
            false,
        ),
        entity,
    );
    let ref_ = entity_ref(entity);

    let transaction = execute_plan(
        "shadow",
        vec![step(json!({
            "op": "set_light_cast_shadows", "entity_id": ref_, "light_cast_shadows": true
        }))],
        &scene,
    );

    let ops = scene_ops(&transaction);
    let has_cast = ops.iter().any(|mutation| {
        mutation
            .decoded_component::<LightComponent>("light")
            .is_some_and(|(_, component)| component.cast_shadows)
    });
    assert!(
        has_cast,
        "set_light_cast_shadows must produce setLightCastShadows mutation"
    );
}

#[test]
fn set_camera_pose_executor_produces_mutation() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let _ = scene.set_component(CameraComponent::default(), entity);
    let ref_ = entity_ref(entity);

    let transaction = execute_plan(
        "pose",
        vec![step(json!({
            "op": "set_camera_pose", "entity_id": ref_,
            "position": [5, 3, 10], "camera_target": [0, 0, 0]
        }))],
        &scene,
    );

    let ops = scene_ops(&transaction);
    let has_pose = ops.iter().any(|mutation| match mutation {
        SceneMutation::SetLocalTransform { transform, .. } => {
            (transform.translation().x - 5.0).abs() < 0.01
                && (transform.translation().z - 10.0).abs() < 0.01
        }
        _ => false,
    }) && ops.iter().any(|mutation| {
        mutation
            .decoded_component::<CameraComponent>("camera")
            .is_some_and(|(_, component)| component.target == Float3::ZERO)
    });
    assert!(
        has_pose,
        "set_camera_pose must produce setCameraPose mutation with correct position and target"
    );
}

// MARK: - Executor errors

#[test]
fn executor_throws_unknown_collider_shape() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let _ = scene.set_component(
        Collider::with_shape(ColliderShape::Box {
            half_extents: Float3::ONE,
            center: Float3::ZERO,
        }),
        entity,
    );
    let ref_ = entity_ref(entity);

    let err = executor_error(
        "bad",
        vec![step(json!({
            "op": "set_collider_shape", "entity_id": ref_, "collider_shape": "torus"
        }))],
        &scene,
    );
    assert!(
        matches!(err, SceneEditPlanExecutorError::UnknownColliderShape(ref s) if s == "torus"),
        "expected unknownColliderShape, got {err:?}"
    );
}

#[test]
fn executor_throws_unknown_light_type() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let _ = scene.set_component(
        LightComponent::new(
            LightType::Point,
            Float3::ONE,
            100.0,
            10.0,
            20.0,
            30.0,
            false,
        ),
        entity,
    );
    let ref_ = entity_ref(entity);

    let err = executor_error(
        "bad",
        vec![step(json!({
            "op": "set_light_type", "entity_id": ref_, "light_type": "laser"
        }))],
        &scene,
    );
    assert!(
        matches!(err, SceneEditPlanExecutorError::UnknownLightType(ref s) if s == "laser"),
        "expected unknownLightType, got {err:?}"
    );
}

#[test]
fn executor_throws_unknown_motion_type() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let _ = scene.set_component(
        RigidBody {
            motion_type: RigidBodyMotionType::Dynamic,
            mass: 1.0,
            gravity_scale: 1.0,
            allow_sleep: true,
            ..RigidBody::default()
        },
        entity,
    );
    let ref_ = entity_ref(entity);

    let err = executor_error(
        "bad",
        vec![step(json!({
            "op": "set_rigidbody_motion", "entity_id": ref_, "motion_type": "fluid"
        }))],
        &scene,
    );
    assert!(
        matches!(err, SceneEditPlanExecutorError::UnknownMotionType(ref s) if s == "fluid"),
        "expected unknownMotionType, got {err:?}"
    );
}

#[test]
fn executor_throws_missing_field_for_set_name() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let ref_ = entity_ref(entity);

    let err = executor_error(
        "empty name",
        vec![step(
            json!({"op": "set_name", "entity_id": ref_, "name": ""}),
        )],
        &scene,
    );
    assert!(
        matches!(err, SceneEditPlanExecutorError::MissingField { ref field, .. } if field == "name"),
        "expected missingField(name), got {err:?}"
    );
}

// MARK: - SceneSemanticEncoder

#[test]
fn scene_semantic_encoder_surfaces_collider_layer_and_mask() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let _ = scene.set_component(
        Collider {
            shapes: vec![ColliderShapeInstance::new(ColliderShape::Box {
                half_extents: Float3::ONE,
                center: Float3::ZERO,
            })],
            is_trigger: false,
            layer_id: 4,
            layer_mask: 15,
            material: PhysicsMaterial::default(),
        },
        entity,
    );

    let snapshot =
        SceneSemanticEncoder::new().encode(&scene, None, Some("default".to_string()), None);
    let record = snapshot
        .entities
        .first()
        .expect("expected at least one entity in snapshot");
    assert_eq!(record.collider_layer_id, Some(4));
    assert_eq!(record.collider_layer_mask, Some(15));
}

#[test]
fn world_view_applies_snapshot_with_collider_layer() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let _ = scene.set_component(
        Collider {
            shapes: vec![ColliderShapeInstance::new(ColliderShape::Sphere {
                radius: 1.0,
                center: Float3::ZERO,
            })],
            is_trigger: false,
            layer_id: 7,
            layer_mask: 63,
            material: PhysicsMaterial::default(),
        },
        entity,
    );

    let snapshot = encode(&scene);
    let mut world_view = WorldView::new();
    world_view.apply_snapshot(&snapshot);

    let ref_ = entity_ref(entity);
    let record = world_view.entity_record(&ref_).unwrap();
    assert_eq!(record.collider_layer_id, Some(7));
    assert_eq!(record.collider_layer_mask, Some(63));
}

#[test]
fn scene_semantic_encoder_surfaces_world_scale_for_scaled_entity() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let parent = scene.create_entity();
    let _ = scene.set_component(LocalTransform::new(scaled_matrix(2.0, 3.0, 4.0)), parent);

    let child = scene.create_entity();
    scene.set_parent(Some(parent), child);
    let _ = scene.set_component(LocalTransform::from_translation(Float3::ZERO), child);

    let snapshot = encode(&scene);
    let parent_record = snapshot_entity(&snapshot, &entity_ref(parent));
    let ws = parent_record.world_scale.as_ref().expect("worldScale");
    assert_close(f64::from(ws[0]), 2.0, 0.001);
    assert_close(f64::from(ws[1]), 3.0, 0.001);
    assert_close(f64::from(ws[2]), 4.0, 0.001);
    // Child inherits parent scale; worldScale should also be [2,3,4].
    let child_record = snapshot_entity(&snapshot, &entity_ref(child));
    let ws = child_record.world_scale.as_ref().expect("worldScale");
    assert_close(f64::from(ws[0]), 2.0, 0.001);
    assert_close(f64::from(ws[1]), 3.0, 0.001);
    assert_close(f64::from(ws[2]), 4.0, 0.001);
}

#[test]
fn set_animation_player_executor_produces_mutation() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let _ = scene.set_component(AnimationPlayer::default(), entity);
    let ref_ = entity_ref(entity);

    let transaction = execute_plan(
        "play walk",
        vec![step(json!({
            "op": "set_animation_player", "entity_id": ref_,
            "animation_clip": "walk", "animation_speed": 1.5,
            "animation_loop": true, "animation_is_playing": true
        }))],
        &scene,
    );

    let ops = scene_ops(&transaction);
    let has_anim = ops.iter().any(|mutation| {
        mutation
            .decoded_component::<AnimationPlayer>("animationPlayer")
            .is_some_and(|(id, component)| {
                id == entity.raw_value()
                    && component.clip_name.as_deref() == Some("walk")
                    && (component.speed - 1.5).abs() < 0.001
                    && component.loop_
                    && component.is_playing
            })
    });
    assert!(
        has_anim,
        "set_animation_player must produce a setAnimationPlayer mutation"
    );
}

#[test]
fn scene_semantic_encoder_surfaces_spot_light_angles() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let light = LightComponent {
        light_type: LightType::Spot,
        intensity: 2000.0,
        spot_inner_angle_degrees: 15.0,
        spot_outer_angle_degrees: 30.0,
        ..LightComponent::default()
    };
    let _ = scene.set_component(light, entity);

    let snapshot = encode(&scene);
    let record = snapshot_entity(&snapshot, &entity_ref(entity));
    assert_eq!(record.light_type.as_deref(), Some("spot"));
    assert_close(f64::from(record.light_spot_inner.unwrap()), 15.0, 0.1);
    assert_close(f64::from(record.light_spot_outer.unwrap()), 30.0, 0.1);
    assert_eq!(record.light_cast_shadows, None);
}

#[test]
fn world_entity_record_apply_script_bindings_from_json_event() {
    let mut record = WorldEntityRecord::new("scene:99".to_string());
    record.name = "Mover".to_string();
    let json = r#"[{"handle":42,"identifier":"project.runner","isEnabled":true,"parametersJSON":"{\"speed\":5}"}]"#;
    record.apply("scriptBindings".to_string(), string_value(json));
    let bindings = record.script_bindings.as_ref().unwrap();
    assert_eq!(bindings.len(), 1);
    assert_eq!(bindings[0].handle, 42);
    assert_eq!(bindings[0].identifier.as_deref(), Some("project.runner"));
    assert!(bindings[0].is_enabled);
    assert_eq!(bindings[0].parameters_json, r#"{"speed":5}"#);
}

#[test]
fn scene_semantic_encoder_surfaces_constraint_enabled() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let mut constraint = Constraint::new(
        PhysicsJointConfiguration::Point,
        entity,
        entity,
        Float3::ZERO,
        Float3::ZERO,
        true,
        Constraint::DEFAULT_BREAK_LIMIT,
        Constraint::DEFAULT_BREAK_LIMIT,
    );
    constraint.is_enabled = false;
    let _ = scene.set_component(constraint, entity);

    let snapshot = encode(&scene);
    let record = snapshot_entity(&snapshot, &entity_ref(entity));
    assert_eq!(record.constraint_enabled, Some(false));
}

#[test]
fn scene_semantic_encoder_surfaces_vehicle_configuration() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let mut vehicle = Vehicle::wheeled();
    vehicle.engine = VehicleEngineConfiguration {
        max_torque: 725.0,
        ..VehicleEngineConfiguration::default()
    };
    vehicle.transmission = VehicleTransmissionConfiguration {
        mode: VehicleTransmissionMode::Manual,
        ..VehicleTransmissionConfiguration::default()
    };
    vehicle.is_enabled = false;
    let _ = scene.set_component(vehicle, entity);

    let snapshot = encode(&scene);
    let record = snapshot_entity(&snapshot, &entity_ref(entity));
    assert!(record.components.contains(&"vehicle".to_string()));
    assert_eq!(record.vehicle_is_enabled, Some(false));
    assert_eq!(record.vehicle_controller_kind.as_deref(), Some("wheeled"));
    assert_eq!(record.vehicle_wheel_count, Some(4));
    assert_eq!(record.vehicle_differential_count, Some(1));
    assert_eq!(record.vehicle_transmission_mode.as_deref(), Some("manual"));
    assert_close(f64::from(record.vehicle_max_torque.unwrap()), 725.0, 0.001);
    assert_eq!(record.vehicle_forward_speed, None);
}

#[test]
fn scene_semantic_encoder_surfaces_soft_body_and_cloth_configuration() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let _ = scene.set_component(
        SoftBody {
            pressure: 1.5,
            linear_damping: 0.25,
            vertex_radius: 0.03,
            is_enabled: false,
            ..SoftBody::default()
        },
        entity,
    );
    let _ = scene.set_component(
        Cloth::new(
            6,
            8,
            0.12,
            vec![0, 2, 4],
            1e-5,
            1e-5,
            1e-5,
            ClothBendType::Dihedral,
        ),
        entity,
    );

    let snapshot = encode(&scene);
    let record = snapshot_entity(&snapshot, &entity_ref(entity));
    assert!(record.components.contains(&"softbody".to_string()));
    assert!(record.components.contains(&"cloth".to_string()));
    assert_eq!(record.soft_body_is_enabled, Some(false));
    assert_close(f64::from(record.soft_body_pressure.unwrap()), 1.5, 0.001);
    assert_close(
        f64::from(record.soft_body_linear_damping.unwrap()),
        0.25,
        0.001,
    );
    assert_close(
        f64::from(record.soft_body_vertex_radius.unwrap()),
        0.03,
        0.001,
    );
    assert_eq!(record.cloth_grid_size_x, Some(6));
    assert_eq!(record.cloth_grid_size_z, Some(8));
    assert_close(f64::from(record.cloth_spacing.unwrap()), 0.12, 0.001);
    assert_eq!(record.cloth_fixed_vertex_count, Some(3));
    assert_eq!(record.cloth_bend_type.as_deref(), Some("dihedral"));
    assert_eq!(record.soft_body_deformed_vertex_count, None);
}

#[test]
fn scene_semantic_encoder_surfaces_arbitrary_soft_body_topology() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    scene.set_resource(MeshColliderGeometryResource::new(
        BTreeMap::from([(
            "soft.tetra".to_string(),
            MeshColliderGeometry::new(
                vec![
                    Float3::new(0.0, 0.0, 0.0),
                    Float3::new(1.0, 0.0, 0.0),
                    Float3::new(0.0, 1.0, 0.0),
                    Float3::new(0.0, 0.0, 1.0),
                ],
                vec![0, 2, 1, 0, 1, 3, 1, 2, 3, 2, 0, 3],
                vec![0, 1, 2, 3],
                vec![],
                None,
                9,
            ),
        )]),
        None,
    ));
    let entity = scene.create_entity();
    let _ = scene.set_component(SoftBody::default(), entity);
    let _ = scene.set_component(
        SoftBodyMesh::new(
            Some("soft.tetra".to_string()),
            vec![0, 3],
            1e-5,
            1e-5,
            1e-5,
            0.004,
            ClothBendType::Distance,
        ),
        entity,
    );

    let snapshot = encode(&scene);
    let record = snapshot_entity(&snapshot, &entity_ref(entity));
    assert!(record.components.contains(&"softbody_mesh".to_string()));
    assert_eq!(
        record.soft_body_topology_kind.as_deref(),
        Some("volume_mesh")
    );
    assert_eq!(
        record.soft_body_mesh_resource_id.as_deref(),
        Some("soft.tetra")
    );
    assert_eq!(record.soft_body_mesh_vertex_count, Some(4));
    assert_eq!(record.soft_body_mesh_triangle_count, Some(4));
    assert_eq!(record.soft_body_mesh_tetrahedron_count, Some(1));
    assert_eq!(record.soft_body_mesh_fixed_vertex_count, Some(2));
    assert_eq!(record.soft_body_mesh_bend_type.as_deref(), Some("distance"));
    assert_close(
        f64::from(record.soft_body_mesh_volume_compliance.unwrap()),
        0.004,
        0.0001,
    );
    assert_eq!(record.soft_body_mesh_geometry_revision, Some(9));
}

#[test]
fn scene_semantic_encoder_surfaces_destructible_asset_and_policy() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    scene.set_resource(DestructibleAssetResource::new(BTreeMap::from([(
        "tower.prefractured".to_string(),
        DestructibleAsset::new(
            3,
            vec![
                DestructibleFragmentAsset::with_geometry(0, "fragment.0"),
                DestructibleFragmentAsset::with_geometry(1, "fragment.1"),
            ],
            vec![DestructibleConnectionAsset::unthresholded(7, 0, 1)],
        ),
    )])));
    let entity = scene.create_entity();
    let _ = scene.set_component(
        Destructible::new("tower.prefractured", 80.0, 12.0, 64, 18.0, 2.5, 0.3, false),
        entity,
    );

    let snapshot = encode(&scene);
    let record = snapshot_entity(&snapshot, &entity_ref(entity));
    assert!(record.components.contains(&"destructible".to_string()));
    assert_eq!(record.kind, "Destructible");
    assert_eq!(
        record.destructible_asset_resource_id.as_deref(),
        Some("tower.prefractured")
    );
    assert_eq!(record.destructible_is_enabled, Some(false));
    assert_close(
        f64::from(record.destructible_damage_threshold.unwrap()),
        80.0,
        0.001,
    );
    assert_close(
        f64::from(record.destructible_impulse_threshold.unwrap()),
        12.0,
        0.001,
    );
    assert_eq!(record.destructible_fragment_budget, Some(64));
    assert_close(
        f64::from(
            record
                .destructible_maximum_fragment_lifetime_seconds
                .unwrap(),
        ),
        18.0,
        0.001,
    );
    assert_close(
        f64::from(record.destructible_sleeping_recycle_delay_seconds.unwrap()),
        2.5,
        0.001,
    );
    assert_close(
        f64::from(record.destructible_separation_impulse.unwrap()),
        0.3,
        0.001,
    );
    assert_eq!(record.destructible_asset_revision, Some(3));
    assert_eq!(record.destructible_asset_fragment_count, Some(2));
    assert_eq!(record.destructible_asset_connection_count, Some(1));
    assert_eq!(record.destructible_has_fractured, None);
    assert_eq!(record.destructible_is_fully_fractured, None);
    assert_eq!(record.destructible_released_fragment_count, None);
    assert_eq!(record.destructible_retained_fragment_count, None);
}

#[test]
fn set_audio_source_executor_produces_mutation() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let _ = scene.set_component(AudioSource::default(), entity);
    let ref_ = entity_ref(entity);

    let transaction = execute_plan(
        "add music",
        vec![step(json!({
            "op": "set_audio_source", "entity_id": ref_,
            "audio_clip": "theme", "audio_volume": 0.8,
            "audio_loop": true, "audio_play_on_awake": true
        }))],
        &scene,
    );

    let ops = scene_ops(&transaction);
    let has_audio = ops.iter().any(|mutation| {
        mutation
            .decoded_component::<AudioSource>("audioSource")
            .is_some_and(|(id, src)| {
                id == entity.raw_value()
                    && src.clip_name == "theme"
                    && (src.volume - 0.8).abs() < 0.001
                    && src.loop_
                    && src.play_on_awake
            })
    });
    assert!(
        has_audio,
        "set_audio_source must produce a setAudioSource mutation"
    );
}

#[test]
fn scene_semantic_encoder_surfaces_rigid_body_and_collider_fields() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let _ = scene.set_component(
        RigidBody {
            motion_type: RigidBodyMotionType::Kinematic,
            mass: 7.5,
            gravity_scale: 0.5,
            allow_sleep: false,
            ..RigidBody::default()
        },
        entity,
    );
    let _ = scene.set_component(
        Collider {
            shapes: vec![ColliderShapeInstance::new(ColliderShape::Sphere {
                radius: 2.0,
                center: Float3::ZERO,
            })],
            is_trigger: true,
            layer_id: 2,
            layer_mask: 7,
            material: PhysicsMaterial::new(0.2, 0.8, 1.5),
        },
        entity,
    );

    let snapshot = encode(&scene);
    let record = snapshot_entity(&snapshot, &entity_ref(entity));
    assert_eq!(record.rigid_body_motion_type.as_deref(), Some("kinematic"));
    assert_close(f64::from(record.rigid_body_mass.unwrap()), 7.5, 0.001);
    assert_close(
        f64::from(record.rigid_body_gravity_scale.unwrap()),
        0.5,
        0.001,
    );
    assert_eq!(record.rigid_body_allow_sleep, Some(false));
    assert_eq!(record.collider_shape.as_deref(), Some("sphere"));
    assert_eq!(record.collider_is_trigger, Some(true));
    assert_close(f64::from(record.collider_friction.unwrap()), 0.2, 0.001);
    assert_close(f64::from(record.collider_restitution.unwrap()), 0.8, 0.001);
    assert_close(f64::from(record.collider_density.unwrap()), 1.5, 0.001);
}

#[test]
fn scene_semantic_encoder_surfaces_audio_and_animation_fields() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let audio = AudioSource {
        clip_name: "ambient_loop".to_string(),
        volume: 0.6,
        loop_: true,
        play_on_awake: false,
        ..AudioSource::default()
    };
    let _ = scene.set_component(audio, entity);
    let anim = AnimationPlayer {
        clip_name: Some("idle".to_string()),
        speed: 1.5,
        loop_: true,
        is_playing: true,
        ..AnimationPlayer::default()
    };
    let _ = scene.set_component(anim, entity);

    let snapshot = encode(&scene);
    let record = snapshot_entity(&snapshot, &entity_ref(entity));
    assert_eq!(record.audio_clip.as_deref(), Some("ambient_loop"));
    assert_close(f64::from(record.audio_volume.unwrap()), 0.6, 0.001);
    assert_eq!(record.audio_loop, Some(true));
    assert_eq!(record.audio_play_on_awake, Some(false));
    assert_eq!(record.animation_clip.as_deref(), Some("idle"));
    assert_close(f64::from(record.animation_speed.unwrap()), 1.5, 0.001);
    assert_eq!(record.animation_loop, Some(true));
    assert_eq!(record.animation_is_playing, Some(true));
}

#[test]
fn scene_semantic_encoder_surfaces_mesh_visibility() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let _ = scene.set_component(
        RenderMeshComponent::new(0, false, Float3::ONE, None, vec![]),
        entity,
    );

    let snapshot = encode(&scene);
    let record = snapshot_entity(&snapshot, &entity_ref(entity));
    assert_eq!(record.mesh_is_visible, Some(false));
}

#[test]
fn scene_semantic_encoder_surfaces_pbr_material_fields() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let material = RenderMaterialComponent::new(
        Float4::new(0.3, 0.6, 0.9, 1.0),
        None,
        None,
        0.8,
        0.25,
        Float3::new(0.0, 0.2, 0.4),
        None,
        None,
        None,
    );
    let _ = scene.set_component(material, entity);

    let snapshot = encode(&scene);
    let record = snapshot_entity(&snapshot, &entity_ref(entity));
    assert_close(f64::from(record.material_metallic.unwrap()), 0.8, 0.001);
    assert_close(f64::from(record.material_roughness.unwrap()), 0.25, 0.001);
    let bc = record
        .material_base_color
        .as_ref()
        .expect("materialBaseColor");
    assert_close(f64::from(bc[0]), 0.3, 0.001);
    assert_close(f64::from(bc[1]), 0.6, 0.001);
    assert_close(f64::from(bc[2]), 0.9, 0.001);
    let em = record.material_emissive.as_ref().expect("materialEmissive");
    assert_close(f64::from(em[1]), 0.2, 0.001);
}

// MARK: - AIWorldContext SnapshotProvider

#[test]
fn ai_world_context_materializes_snapshot() {
    let context = AIWorldContext::default();
    context.observe_event(added("scene:1", "Box", "mesh"));

    let (snapshot_id, cursor) = context.materialize_snapshot("scene").unwrap();
    assert!(!snapshot_id.is_empty());
    assert_eq!(cursor.stream_id, "world");
    assert!(cursor.seq > 0);
}

#[test]
fn ai_world_context_snapshot_captures_state_at_call_time() {
    let context = AIWorldContext::default();
    context.observe_event(added("scene:1", "Pre", "mesh"));

    let (snapshot_id, _) = context.materialize_snapshot("scene").unwrap();

    // Events after the snapshot should NOT appear in the captured WorldView.
    context.observe_event(added("scene:2", "Post", "mesh"));

    let captured = context.world_view_for_snapshot(&snapshot_id);
    assert!(
        captured
            .as_ref()
            .and_then(|view| view.entity_record("scene:1"))
            .is_some()
    );
    assert!(
        captured
            .as_ref()
            .and_then(|view| view.entity_record("scene:2"))
            .is_none()
    );
}

#[test]
fn ai_world_context_snapshot_cursor_advances_with_revisions() {
    let context = AIWorldContext::default();
    let (_, cursor1) = context.materialize_snapshot("scene").unwrap();
    context.observe_event(added("scene:1", "A", "mesh"));
    let (_, cursor2) = context.materialize_snapshot("scene").unwrap();
    assert!(cursor1.seq < cursor2.seq);
}

#[test]
fn ai_world_context_evicts_oldest_snapshot_at_limit() {
    let context = AIWorldContext::default();
    let mut ids: Vec<String> = Vec::new();
    for i in 0..9 {
        context.observe_event(added(&format!("scene:{i}"), &format!("E{i}"), "mesh"));
        let (id, _) = context.materialize_snapshot("scene").unwrap();
        ids.push(id);
    }
    // The first snapshot should have been evicted (limit is 8).
    let first = context.world_view_for_snapshot(&ids[0]);
    assert!(first.is_none());
    // The most recent ones should still be present.
    let last = context.world_view_for_snapshot(&ids[8]);
    assert!(last.is_some());
}

// MARK: - Session + ContextMemoryStore integration

#[test]
fn session_forwards_events_to_context_memory() {
    let session = make_session("s1");
    let store = Arc::new(ContextMemoryStore::new().unwrap());
    session.set_context_memory(Some(store.clone()));
    session.observe_event(added("scene:1", "Rock", "mesh"));
    let entries = store.all_entries();
    assert!(!entries.is_empty());
    assert_eq!(entries[0].subject, "scene:1");
}

#[test]
fn session_forwards_batch_events_to_context_memory() {
    let session = make_session("s2");
    let store = Arc::new(ContextMemoryStore::new().unwrap());
    session.set_context_memory(Some(store.clone()));
    session.observe_events(vec![
        WorldEvent::EntityAdded {
            ref_: "scene:2".to_string(),
            name: "A".to_string(),
            kind: None,
        },
        WorldEvent::EntityAdded {
            ref_: "scene:3".to_string(),
            name: "B".to_string(),
            kind: None,
        },
    ]);
    let count = store.all_entries().len();
    assert_eq!(count, 2);
}

#[test]
fn session_context_memory_nil_by_default() {
    // Without setContextMemory, observe must not crash.
    let session = make_session("s3");
    session.observe_event(WorldEvent::EntityAdded {
        ref_: "scene:4".to_string(),
        name: "C".to_string(),
        kind: None,
    });
    // No crash = pass.
}

// MARK: - issueTracked memory

#[test]
fn issue_memory_records_entry_for_empty_plan() {
    let session = make_session("iss1");
    let store = Arc::new(ContextMemoryStore::new().unwrap());
    session.set_context_memory(Some(store.clone()));

    let empty_plan = SceneEditPlan::new("Nothing to do.".to_string(), None, Vec::new());
    session.update_issue_memory("make it fly", &empty_plan);

    let entries = store.lookup_kind(EntryKind::IssueTracked);
    assert_eq!(entries.len(), 1);
    assert_eq!(
        entries[0].payload.get("intent").map(String::as_str),
        Some("make it fly")
    );
    assert_eq!(
        entries[0].payload.get("reason").map(String::as_str),
        Some("Nothing to do.")
    );
    assert_close(entries[0].importance, 0.6, 0.001);
}

#[test]
fn issue_memory_removes_entry_when_plan_is_non_empty() {
    let session = make_session("iss2");
    let store = Arc::new(ContextMemoryStore::new().unwrap());
    session.set_context_memory(Some(store.clone()));

    let empty_plan = SceneEditPlan::new("Cannot do that.".to_string(), None, Vec::new());
    session.update_issue_memory("rotate 45 degrees", &empty_plan);
    let before_entries = store.lookup_kind(EntryKind::IssueTracked);
    assert!(!before_entries.is_empty());

    let resolved_step = step(json!({"op": "set_transform", "entity_id": "scene:1"}));
    let resolved_plan = SceneEditPlan::new("Done.".to_string(), None, vec![resolved_step]);
    session.update_issue_memory("rotate 45 degrees", &resolved_plan);
    let after_entries = store.lookup_kind(EntryKind::IssueTracked);
    assert!(after_entries.is_empty());
}

#[test]
fn issue_memory_key_is_stable_across_identical_intents() {
    let key1 = Session::issue_key("add a point light");
    let key2 = Session::issue_key("add a point light");
    assert_eq!(key1, key2);
}

#[test]
fn issue_memory_key_normalizes_special_chars() {
    let key = Session::issue_key("what's going on?!");
    assert!(key.starts_with("issue:"));
    assert!(!key.contains('\''));
    assert!(!key.contains('?'));
    assert!(!key.contains('!'));
}

#[test]
fn issue_memory_does_nothing_without_store() {
    let session = make_session("iss3");
    let empty_plan = SceneEditPlan::new("empty".to_string(), None, Vec::new());
    session.update_issue_memory("test", &empty_plan);
    // No crash = pass.
}

// MARK: - workflowContext memory

#[test]
fn set_workflow_context_records_game_entry() {
    let session = make_session("wf1");
    let store = Arc::new(ContextMemoryStore::new().unwrap());
    session.set_context_memory(Some(store.clone()));

    let ctx = WorkflowContext::Game(GameWorkflowContext {
        level_phase: GameLevelPhase::Polish,
        ..GameWorkflowContext::new(
            GameplayIntent::new("platformer".to_string(), "reach_exit".to_string()),
            "challenging but fair".to_string(),
        )
    });
    session.set_workflow_context(Some(ctx));

    let entry = store.entry("workflow:active").expect("workflow entry");
    assert_eq!(entry.kind, EntryKind::WorkflowContext);
    assert_eq!(entry.payload.get("kind").map(String::as_str), Some("game"));
    assert_eq!(
        entry.payload.get("level_phase").map(String::as_str),
        Some("Polish")
    );
    assert_eq!(
        entry.payload.get("genre").map(String::as_str),
        Some("platformer")
    );
}

#[test]
fn set_workflow_context_records_film_entry() {
    let session = make_session("wf2");
    let store = Arc::new(ContextMemoryStore::new().unwrap());
    session.set_context_memory(Some(store.clone()));

    let ctx = WorkflowContext::Film(FilmWorkflowContext {
        active_shot_id: Some("shot_05".to_string()),
        narrative_phase: FilmNarrativePhase::CameraLanguage,
        director_intent: Some("wide establishing shot".to_string()),
        ..FilmWorkflowContext::new("seq_01".to_string())
    });
    session.set_workflow_context(Some(ctx));

    let entry = store.entry("workflow:active").expect("workflow entry");
    assert_eq!(entry.payload.get("kind").map(String::as_str), Some("film"));
    assert_eq!(
        entry.payload.get("narrative_phase").map(String::as_str),
        Some("camera_language")
    );
    assert_eq!(
        entry.payload.get("active_sequence").map(String::as_str),
        Some("seq_01")
    );
    assert_eq!(
        entry.payload.get("active_shot").map(String::as_str),
        Some("shot_05")
    );
    assert_eq!(
        entry.payload.get("director_intent").map(String::as_str),
        Some("wide establishing shot")
    );
}

#[test]
fn set_workflow_context_nil_removes_entry() {
    let session = make_session("wf3");
    let store = Arc::new(ContextMemoryStore::new().unwrap());
    session.set_context_memory(Some(store.clone()));

    let ctx = WorkflowContext::Game(GameWorkflowContext::new(
        GameplayIntent::new("rpg".to_string(), "defeat_boss".to_string()),
        "epic".to_string(),
    ));
    session.set_workflow_context(Some(ctx));
    let before_entry = store.entry("workflow:active");
    assert!(before_entry.is_some());

    session.set_workflow_context(None);
    let after_entry = store.entry("workflow:active");
    assert!(after_entry.is_none());
}

#[test]
fn set_workflow_context_without_store_does_not_crash() {
    let session = make_session("wf4");
    let ctx = WorkflowContext::Film(FilmWorkflowContext::new("x".to_string()));
    session.set_workflow_context(Some(ctx));
}

// MARK: - sessionSummary memory

#[test]
fn clear_history_records_session_summary() {
    let session = make_session("sess1");
    let store = Arc::new(ContextMemoryStore::new().unwrap());
    session.set_context_memory(Some(store.clone()));

    session.record_turn(ConversationTurn::new(ConversationTurnKind::UserText(
        "place a spotlight above the stage".to_string(),
    )));
    session.record_turn(ConversationTurn::new(ConversationTurnKind::UserText(
        "set its color to warm white".to_string(),
    )));
    session.clear_history();

    let entries = store.lookup_kind(EntryKind::SessionSummary);
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].id, "summary:sess1");
    assert_eq!(
        entries[0].payload.get("intent_count").map(String::as_str),
        Some("2")
    );
    assert!(
        entries[0]
            .payload
            .get("last_intents")
            .is_some_and(|value| value.contains("spotlight"))
    );
}

#[test]
fn clear_history_with_no_user_turns_records_no_summary() {
    let session = make_session("sess2");
    let store = Arc::new(ContextMemoryStore::new().unwrap());
    session.set_context_memory(Some(store.clone()));

    // Only a tool result turn — no user intents.
    session.record_outcome("t1", "ok", None);
    session.clear_history();
    let entries = store.lookup_kind(EntryKind::SessionSummary);
    assert!(entries.is_empty());
}

#[test]
fn clear_history_does_not_crash_without_store() {
    let session = make_session("sess3");
    session.clear_history();
}

#[test]
fn clear_history_summary_is_idempotent() {
    let session = make_session("sess4");
    let store = Arc::new(ContextMemoryStore::new().unwrap());
    session.set_context_memory(Some(store.clone()));

    // Two clear-history cycles with the same session ID must produce only one entry.
    session.record_turn(ConversationTurn::new(ConversationTurnKind::UserText(
        "first intent".to_string(),
    )));
    session.clear_history();

    session.record_turn(ConversationTurn::new(ConversationTurnKind::UserText(
        "second intent".to_string(),
    )));
    session.clear_history();

    let entries = store.lookup_kind(EntryKind::SessionSummary);
    assert_eq!(
        entries.len(),
        1,
        "same session ID produces exactly one summary entry"
    );
}

#[test]
fn issue_memory_upsert_is_idempotent_for_same_intent() {
    let session = make_session("iss4");
    let store = Arc::new(ContextMemoryStore::new().unwrap());
    session.set_context_memory(Some(store.clone()));

    let empty_plan = SceneEditPlan::new("Can't do it.".to_string(), None, Vec::new());
    session.update_issue_memory("delete all", &empty_plan);
    session.update_issue_memory("delete all", &empty_plan);

    let entries = store.lookup_kind(EntryKind::IssueTracked);
    assert_eq!(entries.len(), 1);
}

// MARK: - set_material roundtrip

#[test]
fn set_material_op_round_trips_all_fields() {
    let json = r#"
    {
        "op": "set_material",
        "entity_id": "scene:7",
        "material_base_color": [0.2, 0.4, 0.6, 1.0],
        "material_metallic": 0.8,
        "material_roughness": 0.3,
        "material_emissive": [0.1, 0.0, 0.5]
    }
    "#;
    let decoded = decode_step(json);
    assert_eq!(decoded.op, SceneEditOp::SetMaterial);
    assert_eq!(decoded.entity_ref.as_deref(), Some("scene:7"));
    assert_eq!(decoded.material_base_color, Some(vec![0.2, 0.4, 0.6, 1.0]));
    assert_close(f64::from(decoded.material_metallic.unwrap()), 0.8, 0.001);
    assert_close(f64::from(decoded.material_roughness.unwrap()), 0.3, 0.001);
    assert_eq!(decoded.material_emissive, Some(vec![0.1, 0.0, 0.5]));
}

#[test]
fn set_material_op_round_trips_minimal_payload() {
    let json = r#"
    {"op": "set_material", "entity_id": "scene:3", "material_base_color": [1.0, 0.0, 0.0, 1.0]}
    "#;
    let decoded = decode_step(json);
    assert_eq!(decoded.op, SceneEditOp::SetMaterial);
    assert!(decoded.material_metallic.is_none());
    assert!(decoded.material_roughness.is_none());
    assert!(decoded.material_emissive.is_none());
}

#[test]
fn set_material_executor_produces_render_material_mutation() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let _ = scene.set_component(
        RenderMaterialComponent::new(
            Float4::ONE,
            None,
            None,
            0.0,
            1.0,
            Float3::ZERO,
            None,
            None,
            None,
        ),
        entity,
    );
    let reference = entity_ref(entity);

    let json = format!(
        r#"{{"summary":"gold","steps":[{{"op":"set_material","entity_id":"{reference}","material_base_color":[1.0,0.8,0.0,1.0],"material_metallic":0.9,"material_roughness":0.2}}]}}"#
    );
    let transaction = build_plan(&json, &scene);

    let ops = scene_ops(&transaction);
    let has_material = ops.iter().any(|mutation| {
        mutation
            .decoded_component::<RenderMaterialComponent>("renderMaterial")
            .is_some_and(|(id, component)| {
                id == entity.raw_value()
                    && (component.base_color_factor.x - 1.0).abs() < 0.001
                    && (component.base_color_factor.y - 0.8).abs() < 0.001
                    && (component.metallic_factor - 0.9).abs() < 0.001
                    && (component.roughness_factor - 0.2).abs() < 0.001
            })
    });
    assert!(
        has_material,
        "set_material must produce a setRenderMaterialComponent mutation"
    );
}

#[test]
fn world_view_applies_snapshot_with_material_fields() {
    let mut record = entity("scene:1", "Cube", "mesh");
    record.position = Some(vec![0.0, 0.0, 0.0]);
    record.components = vec!["transform".to_string(), "mesh".to_string()];
    record.material_metallic = Some(0.9);
    record.material_roughness = Some(0.1);
    record.material_emissive = Some(vec![1.0, 0.5, 0.0]);
    let snap = snapshot(1, vec![record]);
    let mut view = WorldView::new();
    view.apply_snapshot(&snap);
    let record = view.entity_record("scene:1").expect("record");
    assert_close(f64::from(record.material_metallic.unwrap()), 0.9, 0.001);
    assert_close(f64::from(record.material_roughness.unwrap()), 0.1, 0.001);
    assert_eq!(record.material_emissive, Some(vec![1.0, 0.5, 0.0]));
}

#[test]
fn world_view_applies_snapshot_with_material_base_color() {
    let mut record = entity("scene:2", "RedCube", "mesh");
    record.position = Some(vec![0.0, 0.0, 0.0]);
    record.components = vec!["transform".to_string(), "mesh".to_string()];
    record.material_base_color = Some(vec![1.0, 0.0, 0.0, 1.0]);
    let snap = snapshot(1, vec![record]);
    let mut view = WorldView::new();
    view.apply_snapshot(&snap);
    assert_eq!(
        view.entity_record("scene:2").unwrap().material_base_color,
        Some(vec![1.0, 0.0, 0.0, 1.0])
    );
}

#[test]
fn world_entity_record_apply_material_base_color_from_event() {
    let mut record = WorldEntityRecord::new("scene:3".to_string());
    record.name = "Cube".to_string();
    record.apply(
        "materialBaseColor".to_string(),
        vec4_value(0.2, 0.4, 0.6, 1.0),
    );
    assert_eq!(record.material_base_color, Some(vec![0.2, 0.4, 0.6, 1.0]));
}

#[test]
fn session_compact_dict_includes_pbr_material_fields() {
    let mut record = WorldEntityRecord::new("scene:42".to_string());
    record.name = "MetalBox".to_string();
    record.material_base_color = Some(vec![0.8, 0.1, 0.1, 1.0]);
    record.material_metallic = Some(0.9);
    record.material_roughness = Some(0.2);
    record.material_emissive = Some(vec![0.0, 0.5, 0.0]);

    let dict = Session::compact_dict(&record);

    assert_eq!(
        dict_float_array(&dict, "materialBaseColor"),
        Some(vec![0.8, 0.1, 0.1, 1.0])
    );
    assert_eq!(dict_float(&dict, "materialMetallic"), Some(0.9));
    assert_eq!(dict_float(&dict, "materialRoughness"), Some(0.2));
    assert_eq!(
        dict_float_array(&dict, "materialEmissive"),
        Some(vec![0.0, 0.5, 0.0])
    );
}

#[test]
fn session_compact_dict_omits_default_pbr_material_fields() {
    let record = WorldEntityRecord::new("scene:43".to_string());

    let dict = Session::compact_dict(&record);

    assert!(dict.get("materialBaseColor").is_none());
    assert!(dict.get("materialMetallic").is_none());
    assert!(dict.get("materialRoughness").is_none());
    assert!(dict.get("materialEmissive").is_none());
}

#[test]
fn session_compact_dict_omits_mesh_is_visible_when_true() {
    let mut record = WorldEntityRecord::new("scene:44".to_string());
    record.name = "Cube".to_string();
    record.mesh_is_visible = Some(true);

    let dict = Session::compact_dict(&record);
    assert!(
        dict.get("meshIsVisible").is_none(),
        "meshIsVisible:true should be omitted to reduce prompt noise"
    );
}

#[test]
fn session_compact_dict_includes_mesh_is_visible_when_false() {
    let mut record = WorldEntityRecord::new("scene:45".to_string());
    record.name = "Hidden".to_string();
    record.mesh_is_visible = Some(false);

    let dict = Session::compact_dict(&record);
    assert_eq!(
        dict.get("meshIsVisible").and_then(Value::as_bool),
        Some(false),
        "meshIsVisible:false must appear in compact dict"
    );
}

#[test]
fn session_compact_dict_includes_collider_fields() {
    let mut record = WorldEntityRecord::new("scene:46".to_string());
    record.name = "Physics".to_string();
    record.collider_shape = Some("capsule".to_string());
    record.collider_is_trigger = Some(true);
    record.collider_friction = Some(0.3);
    record.collider_layer_id = Some(5);

    let dict = Session::compact_dict(&record);
    assert_eq!(
        dict.get("colliderShape").and_then(Value::as_str),
        Some("capsule")
    );
    assert_eq!(
        dict.get("colliderIsTrigger").and_then(Value::as_bool),
        Some(true)
    );
    assert_eq!(dict_float(&dict, "colliderFriction"), Some(0.3));
    assert_eq!(dict.get("colliderLayerID").and_then(Value::as_i64), Some(5));
}

// MARK: - tagEntity perception integration

/// Swift's `StubPerceptionWorker` — returns a canned result for any image.
struct StubPerceptionWorker {
    result: PerceptionResult,
}

impl PerceptionWorker for StubPerceptionWorker {
    fn manifest(&self) -> PerceptionModelManifest {
        PerceptionModelManifest::new(
            "fixture_classifier",
            "Fixture",
            PerceptionTask::Classification,
            "test",
            PerceptionRuntimeConfig::new("none"),
            "",
            "",
            PerceptionLicenseMetadata::with_defaults(
                "MIT",
                "MIT",
                Vec::new(),
                "allowed",
                "allowed",
            ),
        )
    }

    fn analyze_image(
        &self,
        _url: &Path,
        _request_id: &str,
        _max_results: i64,
    ) -> Result<PerceptionResult, PerceptionRuntimeError> {
        Ok(self.result.clone())
    }
}

/// The classification `PerceptionResult` the Swift tests build inline.
fn fixture_classification_result(
    request_id: &str,
    observation_id: &str,
    label: &str,
    confidence: f64,
) -> PerceptionResult {
    PerceptionResult::new(
        request_id,
        "fixture_classifier",
        "test",
        PerceptionTask::Classification,
        "success",
        vec![PerceptionObservation::Classification(
            ClassificationObservation::new(
                observation_id,
                label,
                "fixture",
                confidence,
                vec![PerceptionSemanticCandidate::new(
                    "object_category",
                    label,
                    confidence,
                )],
                Vec::new(),
            ),
        )],
        PerceptionTimingInfo::new(1.0),
        PerceptionProvenance::new("fixture", "fixture_classifier"),
    )
}

#[test]
fn tag_entity_applies_inferred_events_to_world_view() {
    let session = make_session("percept1");

    let result = fixture_classification_result("r1", "c0", "chair", 0.91);
    let worker = Arc::new(StubPerceptionWorker { result });
    let service = Arc::new(PerceptionService::new());
    service.register(worker);
    session.set_perception_service(Some(service));

    // Seed a minimal entity in world view
    session.observe_event(added("scene:5", "Chair", "mesh"));

    let events = session
        .tag_entity(
            "scene:5",
            Path::new("/dev/null"),
            PerceptionTask::Classification,
            5,
        )
        .unwrap();
    assert!(!events.is_empty());

    // The inferred property should now be in the entity record
    let record = session.entity_record("scene:5").expect("record");
    let inferred = record.inferred.get("object_category").expect("inferred");
    assert_eq!(inferred.display_value, "chair");
}

#[test]
fn tag_entity_without_service_throws() {
    let session = make_session("percept2");
    let error = session
        .tag_entity_default("scene:1", Path::new("/dev/null"))
        .expect_err("Expected error when no service configured");
    let desc = error.to_string();
    assert!(
        desc.contains("PerceptionService") || desc.contains("unavailable"),
        "Unexpected error: {desc}"
    );
}

#[test]
fn tag_entity_records_scene_annotation_in_memory() {
    let session = make_session("percept3");
    let store = Arc::new(ContextMemoryStore::new().unwrap());
    session.set_context_memory(Some(store.clone()));

    let result = fixture_classification_result("r2", "c1", "table", 0.85);
    let worker = Arc::new(StubPerceptionWorker { result });
    let service = Arc::new(PerceptionService::new());
    service.register(worker);
    session.set_perception_service(Some(service));

    let _ = session
        .tag_entity_default("scene:9", Path::new("/dev/null"))
        .unwrap();

    let annotations = store.lookup_kind(EntryKind::SceneAnnotation);
    assert!(!annotations.is_empty());
    assert!(annotations.iter().all(|entry| entry.subject == "scene:9"));
    let has_category = annotations
        .iter()
        .any(|entry| entry.payload.get("property").map(String::as_str) == Some("object_category"));
    assert!(has_category, "Expected object_category annotation");
}

// MARK: - find_entities agentic loop

#[test]
fn find_entities_result_searches_by_name_substring() {
    let mut wv = WorldView::new();
    wv.apply_event(added("scene:1", "Dragon Boss", "Character"));
    wv.apply_event(added("scene:2", "Stone Wall", "Static Mesh"));
    wv.apply_event(added("scene:3", "Dragon Egg", "Prop"));
    let session = session_with_world_view("t", make_test_config(), wv);

    let world = session.world_view();
    let input = json!({"name": "dragon"});
    let json = session.find_entities_result(&world, input.as_object().unwrap());
    let result: Value = serde_json::from_str(&json).unwrap();
    let entities = result["entities"].as_array().unwrap();

    assert_eq!(result["count"].as_i64(), Some(2));
    assert!(entities.iter().all(|entity| {
        entity["name"]
            .as_str()
            .unwrap()
            .to_lowercase()
            .contains("dragon")
    }));
}

#[test]
fn find_entities_result_searches_by_kind() {
    let mut wv = WorldView::new();
    wv.apply_event(added("scene:1", "Main Cam", "Camera"));
    wv.apply_event(added("scene:2", "Ambient Light", "Point Light"));
    wv.apply_event(added("scene:3", "Player Camera", "Camera"));
    let session = session_with_world_view("t", make_test_config(), wv);

    let world = session.world_view();
    let input = json!({"kind": "Camera"});
    let json = session.find_entities_result(&world, input.as_object().unwrap());
    let result: Value = serde_json::from_str(&json).unwrap();
    let entities = result["entities"].as_array().unwrap();

    assert_eq!(result["count"].as_i64(), Some(2));
    assert!(
        entities
            .iter()
            .all(|entity| entity["kind"].as_str() == Some("Camera"))
    );
}

#[test]
fn find_entities_result_respects_limit() {
    let mut wv = WorldView::new();
    for i in 1..=10 {
        wv.apply_event(added(
            &format!("scene:{i}"),
            &format!("Box {i}"),
            "Static Mesh",
        ));
    }
    let session = session_with_world_view("t", make_test_config(), wv);

    let world = session.world_view();
    let input = json!({"limit": 3});
    let json = session.find_entities_result(&world, input.as_object().unwrap());
    let result: Value = serde_json::from_str(&json).unwrap();
    let entities = result["entities"].as_array().unwrap();

    assert_eq!(entities.len(), 3);
    assert_eq!(result["count"].as_i64(), Some(3));
}

#[test]
fn find_entities_result_returns_empty_for_no_match() {
    let mut wv = WorldView::new();
    wv.apply_event(added("scene:1", "Stone Wall", "Static Mesh"));
    let session = session_with_world_view("t", make_test_config(), wv);

    let world = session.world_view();
    let input = json!({"name": "dragon"});
    let json = session.find_entities_result(&world, input.as_object().unwrap());
    let result: Value = serde_json::from_str(&json).unwrap();
    assert_eq!(result["count"].as_i64(), Some(0));
    assert!(result["entities"].as_array().unwrap().is_empty());
}

#[test]
fn session_process_executes_plan_after_find_entities_tool_call() {
    // Simulate the agentic loop: first call returns find_entities, second returns execute_edit_plan
    let find_entities_response = r#"
    {
      "id": "msg_1",
      "content": [
        {"type": "tool_use", "id": "tu_1", "name": "find_entities",
         "input": {"name": "dragon", "limit": 5}}
      ],
      "stop_reason": "tool_use"
    }
    "#;
    let edit_plan_response = r#"
    {
      "id": "msg_2",
      "content": [
        {"type": "tool_use", "id": "tu_2", "name": "execute_edit_plan",
         "input": {"summary": "Move dragon", "steps": []}}
      ],
      "stop_reason": "tool_use"
    }
    "#;
    let responses = [find_entities_response, edit_plan_response];
    let server = FixtureHttpServer::start(move |index, _| responses[index].as_bytes().to_vec());

    let mut wv = WorldView::new();
    wv.apply_event(added("scene:42", "Dragon Boss", "Character"));
    let mut config = make_test_config();
    config.base_url = server.base_url().to_string();
    let session = session_with_world_view("t", config, wv);

    let signal = Signal::NaturalLanguage {
        text: "move the dragon forward".to_string(),
        locale: "en".to_string(),
    };
    let proposal = session.process_with_defaults(&signal).unwrap();

    assert_eq!(
        server.requests().len(),
        2,
        "Should make exactly 2 API calls: find_entities then execute_edit_plan"
    );
    assert_eq!(proposal.plan.summary, "Move dragon");
}

#[test]
fn session_process_openai_format_find_entities_loop() {
    // OpenAI format agentic loop: find_entities followed by execute_edit_plan
    let find_entities_response = r#"
    {
      "choices": [{
        "message": {
          "role": "assistant",
          "tool_calls": [{
            "id": "call_1",
            "type": "function",
            "function": {"name": "find_entities", "arguments": "{\"name\":\"camera\"}"}
          }]
        },
        "finish_reason": "tool_calls"
      }]
    }
    "#;
    let edit_plan_response = r#"
    {
      "choices": [{
        "message": {
          "role": "assistant",
          "tool_calls": [{
            "id": "call_2",
            "type": "function",
            "function": {"name": "execute_edit_plan",
              "arguments": "{\"summary\":\"Activate camera\",\"steps\":[]}"}
          }]
        },
        "finish_reason": "tool_calls"
      }]
    }
    "#;
    let responses = [find_entities_response, edit_plan_response];
    let server = FixtureHttpServer::start(move |index, _| responses[index].as_bytes().to_vec());

    let mut wv = WorldView::new();
    wv.apply_event(added("scene:7", "Main Camera", "Camera"));
    let mut config = SessionConfig::open_ai("test");
    config.base_url = server.base_url().to_string();
    let session = session_with_world_view("t", config, wv);

    let signal = Signal::NaturalLanguage {
        text: "activate the camera".to_string(),
        locale: "en".to_string(),
    };
    let proposal = session.process_with_defaults(&signal).unwrap();

    assert_eq!(
        server.requests().len(),
        2,
        "Should make 2 API calls: find_entities then execute_edit_plan"
    );
    assert_eq!(proposal.plan.summary, "Activate camera");
}

#[test]
fn session_process_throws_after_exceeding_find_entities_call_limit() {
    // After 3 find_entities calls, the loop must throw noPlanInResponse rather than looping forever
    let server = FixtureHttpServer::start(|index, _| {
        let call = index + 1;
        let body = format!(
            r#"{{"id":"msg_{call}","content":[{{"type":"tool_use","id":"tu_{call}","name":"find_entities","input":{{"name":"missing"}}}}],"stop_reason":"tool_use"}}"#
        );
        body.into_bytes()
    });

    let mut config = make_test_config();
    config.base_url = server.base_url().to_string();
    let session = session_with_world_view("t", config, WorldView::new());

    let signal = Signal::NaturalLanguage {
        text: "find the missing entity".to_string(),
        locale: "en".to_string(),
    };
    let error = session
        .process_with_defaults(&signal)
        .expect_err("Expected noPlanInResponse error");
    assert!(matches!(error, SessionError::NoPlanInResponse));
    // Expected: 1 initial call + 3 find_entities = 4 total API calls
    assert_eq!(
        server.requests().len(),
        4,
        "Should make 4 calls (1 base + 3 find_entities) before giving up"
    );
}

#[test]
fn find_entities_result_returns_kind_when_present() {
    let mut wv = WorldView::new();
    wv.apply_event(added("scene:1", "Point Light", "Light"));
    wv.apply_event(WorldEvent::EntityAdded {
        ref_: "scene:2".to_string(),
        name: "Unnamed".to_string(),
        kind: None,
    });
    let session = session_with_world_view("t", make_test_config(), wv);

    let world = session.world_view();
    let input = json!({});
    let json = session.find_entities_result(&world, input.as_object().unwrap());
    let result: Value = serde_json::from_str(&json).unwrap();
    let entities = result["entities"].as_array().unwrap();

    let light_entry = entities
        .iter()
        .find(|entity| entity["id"].as_str() == Some("scene:1"))
        .unwrap();
    let unnamed_entry = entities
        .iter()
        .find(|entity| entity["id"].as_str() == Some("scene:2"))
        .unwrap();
    assert_eq!(
        light_entry["kind"].as_str(),
        Some("Light"),
        "kind should be present when set"
    );
    assert!(
        unnamed_entry.get("kind").is_none(),
        "kind should be absent when nil"
    );
}

// MARK: - Transient failure retry

/// Near-zero delays keep retry tests fast.
fn fast_retry() -> RetryPolicy {
    RetryPolicy::new(3, 0.001, 0.005, 0.0)
}

const EDIT_PLAN_OK: &str = r#"{"id":"msg","content":[{"type":"tool_use","id":"tu","name":"execute_edit_plan","input":{"summary":"Done","steps":[]}}],"stop_reason":"tool_use"}"#;

fn do_it_signal() -> Signal {
    Signal::NaturalLanguage {
        text: "do it".to_string(),
        locale: "en".to_string(),
    }
}

#[test]
fn session_retries_after_429_then_succeeds() {
    let server = FixtureHttpServer::start_with(|index, _| {
        if index == 0 {
            FixtureResponse::with_status(429, br#"{"error":"rate limited"}"#.to_vec())
                .with_header("Retry-After", "0")
        } else {
            FixtureResponse::json(EDIT_PLAN_OK.as_bytes().to_vec())
        }
    });
    let mut config = make_test_config();
    config.base_url = server.base_url().to_string();
    config.retry_policy = fast_retry();
    let session = session_with_world_view("t", config, WorldView::new());

    let proposal = session.process_with_defaults(&do_it_signal()).unwrap();
    assert_eq!(
        server.requests().len(),
        2,
        "should retry once after the 429"
    );
    assert_eq!(proposal.plan.summary, "Done");
}

#[test]
fn session_does_not_retry_non_retryable_status() {
    let server = FixtureHttpServer::start_with(|_, _| {
        FixtureResponse::with_status(401, br#"{"error":"unauthorized"}"#.to_vec())
    });
    let mut config = make_test_config();
    config.base_url = server.base_url().to_string();
    config.retry_policy = fast_retry();
    let session = session_with_world_view("t", config, WorldView::new());

    let result = session.process_with_defaults(&do_it_signal());
    assert!(result.is_err(), "expected an error");
    assert_eq!(server.requests().len(), 1, "401 must not be retried");
}

#[test]
fn session_gives_up_after_max_retries() {
    let server = FixtureHttpServer::start_with(|_, _| {
        FixtureResponse::with_status(503, br#"{"error":"unavailable"}"#.to_vec())
    });
    let mut config = make_test_config();
    config.base_url = server.base_url().to_string();
    config.retry_policy = RetryPolicy::new(2, 0.001, 0.005, 0.0);
    let session = session_with_world_view("t", config, WorldView::new());

    let result = session.process_with_defaults(&do_it_signal());
    assert!(result.is_err(), "expected an error");
    assert_eq!(server.requests().len(), 3, "1 initial attempt + 2 retries");
}

// MARK: - WorldView recentEdits ring

#[test]
fn world_view_recent_edits_accumulates_and_caps_at_twenty() {
    let mut view = WorldView::new();
    for i in 1..=25u64 {
        view.apply_event(WorldEvent::EditApplied {
            edit_id: format!("e{i}"),
            summary: format!("edit {i}"),
            revision: i,
        });
    }
    assert_eq!(view.recent_edits.len(), 20, "recentEdits must cap at 20");
    assert_eq!(view.recent_edits.last().unwrap().summary, "edit 25");
    assert_eq!(
        view.recent_edits.first().unwrap().summary,
        "edit 6",
        "oldest 5 edits must have been dropped"
    );
}

#[test]
fn world_view_apply_edit_summary_convenience_updates_revision_and_ring() {
    let mut view = WorldView::new();
    view.apply_edit_summary("renamed hero".to_string(), 42);
    assert_eq!(view.scene_revision, Some(42));
    assert_eq!(view.recent_edits.len(), 1);
    assert_eq!(view.recent_edits[0].summary, "renamed hero");
    assert_eq!(view.recent_edits[0].revision, 42);
}

#[test]
fn world_view_selection_changed_marks_is_selected_on_records() {
    let mut view = WorldView::new();
    view.apply_event(WorldEvent::EntityAdded {
        ref_: "scene:1".to_string(),
        name: "A".to_string(),
        kind: None,
    });
    view.apply_event(WorldEvent::EntityAdded {
        ref_: "scene:2".to_string(),
        name: "B".to_string(),
        kind: None,
    });
    view.apply_event(WorldEvent::SelectionChanged {
        refs: vec!["scene:1".to_string()],
    });
    assert!(view.entity_index()["scene:1"].is_selected);
    assert!(!view.entity_index()["scene:2"].is_selected);
    assert_eq!(view.selected_entity_refs, vec!["scene:1".to_string()]);
}

#[test]
fn world_view_apply_selection_changed_convenience_wrapper() {
    let mut view = WorldView::new();
    view.apply_event(WorldEvent::EntityAdded {
        ref_: "scene:5".to_string(),
        name: "X".to_string(),
        kind: None,
    });
    view.apply_selection_changed(vec!["scene:5".to_string()]);
    assert!(view.entity_index()["scene:5"].is_selected);
    assert_eq!(view.selected_entity_refs, vec!["scene:5".to_string()]);
}

#[test]
fn world_view_entity_removed_clears_from_selection() {
    let mut view = WorldView::new();
    view.apply_event(WorldEvent::EntityAdded {
        ref_: "scene:3".to_string(),
        name: "C".to_string(),
        kind: None,
    });
    view.apply_event(WorldEvent::SelectionChanged {
        refs: vec!["scene:3".to_string()],
    });
    view.apply_event(WorldEvent::EntityRemoved {
        ref_: "scene:3".to_string(),
    });
    assert!(view.entity_index().get("scene:3").is_none());
    assert!(!view.selected_entity_refs.contains(&"scene:3".to_string()));
}

#[test]
fn world_view_workflow_mode_set_from_snapshot() {
    let snapshot = snapshot(7, vec![entity("scene:1", "E", "Entity")])
        .with_workspace_mode(Some("animation".to_string()));
    let mut view = WorldView::new();
    view.apply_snapshot(&snapshot);
    assert_eq!(view.workflow_mode, Some("animation".to_string()));
    assert_eq!(view.scene_revision, Some(7));
}

// MARK: - Session observation wrappers

#[test]
fn session_observe_snapshot_updates_world_view() {
    let session = make_session("obs1");
    let boulder = SceneSemanticSnapshotEntity {
        position: Some(vec![1.0, 2.0, 3.0]),
        components: vec!["transform".to_string(), "mesh".to_string()],
        ..entity("scene:77", "Boulder", "mesh")
    };
    session.observe_snapshot(&snapshot(5, vec![boulder]));
    let record = session.entity_record("scene:77").unwrap();
    assert_eq!(record.name, "Boulder");
    assert_eq!(record.position, Some(vec![1.0, 2.0, 3.0]));
}

#[test]
fn session_observe_selection_changed_updates_world_view() {
    let session = make_session("obs2");
    session.observe_event(added("scene:10", "Player", "mesh"));
    session.observe_selection_changed(&["scene:10".to_string()]);
    let record = session.entity_record("scene:10").unwrap();
    assert!(record.is_selected);
    let view = session.world_view_snapshot();
    assert_eq!(view.selected_entity_refs, vec!["scene:10".to_string()]);
}

#[test]
fn session_observe_edit_summary_updates_revision_and_triggers_flush() {
    let directory = std::env::temp_dir().join(format!(
        "cove-session-memory-{}",
        diffuse_kernel::codable::new_uuid()
    ));
    let storage_url = directory.join("context_memory.json");
    let session = make_session("obs3");
    let store = ContextMemoryStore::with_storage(&storage_url).unwrap();
    session.set_context_memory(Some(Arc::new(store)));
    session.observe_event(added("scene:99", "Cube", "mesh"));
    session.observe_edit_summary("rotated cube", 99).unwrap();
    let view = session.world_view_snapshot();
    assert_eq!(view.scene_revision, Some(99));
    assert_eq!(view.recent_edits.first().unwrap().summary, "rotated cube");

    let reloaded = ContextMemoryStore::with_storage(&storage_url).unwrap();
    let persisted_entry = reloaded.entry("entity_added:scene:99").unwrap();
    assert_eq!(
        persisted_entry.payload.get("name").map(String::as_str),
        Some("Cube")
    );
    let _ = std::fs::remove_dir_all(&directory);
}

#[test]
fn session_history_snapshot_reflects_recorded_turns() {
    let session = make_session("hist1");
    session.record_turn(ConversationTurn::new(ConversationTurnKind::UserText(
        "hello".to_string(),
    )));
    let history = session.history_snapshot();
    assert_eq!(history.len(), 1);
    match &history[0].kind {
        ConversationTurnKind::UserText(text) => assert_eq!(text, "hello"),
        _ => panic!("Expected userText turn"),
    }
}

#[test]
fn session_world_view_snapshot_returns_current_state() {
    let session = make_session("snap1");
    session.observe_event(added("scene:20", "Camera", "camera"));
    let view = session.world_view_snapshot();
    assert!(view.entity_index().contains_key("scene:20"));
}

// MARK: - findEntitiesResult combined filter

#[test]
fn find_entities_result_combines_name_and_kind_filter() {
    let mut wv = WorldView::new();
    wv.apply_event(added("scene:1", "Dragon Boss", "Character"));
    wv.apply_event(added("scene:2", "Dragon Scale", "Prop"));
    wv.apply_event(added("scene:3", "Small Dragon", "Character"));
    wv.apply_event(added("scene:4", "Stone Wall", "Static Mesh"));
    let session = session_with_world_view("cmb", make_test_config(), wv);

    let world = session.world_view();
    let input = json!({"name": "dragon", "kind": "Character"});
    let json = session.find_entities_result(&world, input.as_object().unwrap());
    let result: Value = serde_json::from_str(&json).unwrap();
    let entities = result["entities"].as_array().unwrap();

    assert_eq!(
        result["count"].as_i64(),
        Some(2),
        "only 'Dragon Boss' and 'Small Dragon' match both filters"
    );
    assert!(
        entities
            .iter()
            .all(|entity| entity["kind"].as_str() == Some("Character"))
    );
    assert!(entities.iter().all(|entity| {
        entity["name"]
            .as_str()
            .unwrap()
            .to_lowercase()
            .contains("dragon")
    }));
}

// MARK: - AIWorldContext.discardSnapshot / replaceWorldView

#[test]
fn ai_world_context_discard_snapshot_removes_entry() {
    let context = AIWorldContext::default();
    context.observe_event(WorldEvent::EntityAdded {
        ref_: "scene:1".to_string(),
        name: "A".to_string(),
        kind: None,
    });
    let (id, _) = context.materialize_snapshot("scene").unwrap();
    let before = context.world_view_for_snapshot(&id);
    assert!(before.is_some());
    context.discard_snapshot(&id);
    let after = context.world_view_for_snapshot(&id);
    assert!(
        after.is_none(),
        "discarded snapshot must not be retrievable"
    );
}

#[test]
fn ai_world_context_replace_world_view_replaces_state() {
    let context = AIWorldContext::default();
    context.observe_event(WorldEvent::EntityAdded {
        ref_: "scene:1".to_string(),
        name: "Old".to_string(),
        kind: None,
    });

    let mut fresh_view = WorldView::new();
    fresh_view.apply_event(WorldEvent::EntityAdded {
        ref_: "scene:99".to_string(),
        name: "New".to_string(),
        kind: None,
    });
    context.replace_world_view(fresh_view);

    let record = context.entity_record("scene:99");
    assert!(
        record.is_some(),
        "replaced WorldView entity should be accessible"
    );
    let old_record = context.entity_record("scene:1");
    assert!(
        old_record.is_none(),
        "old entity must no longer be accessible after replaceWorldView"
    );
}

#[test]
fn ai_world_context_replace_world_view_advances_revision() {
    let context = AIWorldContext::default();
    let (_, cur1) = context.materialize_snapshot("scene").unwrap();
    let mut view = WorldView::new();
    view.apply_event(WorldEvent::EntityAdded {
        ref_: "scene:1".to_string(),
        name: "X".to_string(),
        kind: None,
    });
    context.replace_world_view(view);
    let (_, cur2) = context.materialize_snapshot("scene").unwrap();
    assert!(
        cur1.seq < cur2.seq,
        "revision must advance after replaceWorldView"
    );
}

// MARK: - WorkflowContext prompt extras

#[test]
fn game_workflow_context_includes_scripting_registry_in_prompt() {
    let constraints = GameKnownConstraints {
        scripting_registry: vec![
            "patrol".to_string(),
            "attack".to_string(),
            "flee".to_string(),
        ],
        ..GameKnownConstraints::new()
    };
    let ctx = GameWorkflowContext {
        known_constraints: constraints,
        ..GameWorkflowContext::new(
            GameplayIntent::new("rpg".to_string(), "defeat_boss".to_string()),
            "tense combat".to_string(),
        )
    };
    let section = ctx.system_prompt_section();
    assert!(section.contains("patrol"));
    assert!(section.contains("attack"));
    assert!(section.contains("flee"));
}

#[test]
fn game_workflow_context_includes_nav_mesh_note_when_baked() {
    let constraints = GameKnownConstraints {
        nav_mesh_baked: true,
        performance_budget: "pc_ultra".to_string(),
        ..GameKnownConstraints::new()
    };
    let ctx = GameWorkflowContext {
        level_phase: GameLevelPhase::EncounterDesign,
        known_constraints: constraints,
        ..GameWorkflowContext::new(
            GameplayIntent::new("stealth".to_string(), "escape".to_string()),
            "tense sneaking".to_string(),
        )
    };
    let section = ctx.system_prompt_section();
    assert!(section.contains("NavMesh") || section.contains("traversability"));
}

#[test]
fn game_workflow_context_omits_nav_mesh_note_when_not_baked() {
    let ctx = GameWorkflowContext {
        level_phase: GameLevelPhase::Polish,
        known_constraints: GameKnownConstraints {
            nav_mesh_baked: false,
            ..GameKnownConstraints::new()
        },
        ..GameWorkflowContext::new(
            GameplayIntent::new("puzzle".to_string(), "solve_all".to_string()),
            "calm".to_string(),
        )
    };
    assert!(!ctx.system_prompt_section().contains("NavMesh"));
}

#[test]
fn game_workflow_context_includes_performance_budget_in_prompt() {
    let constraints = GameKnownConstraints {
        performance_budget: "mobile_low".to_string(),
        ..GameKnownConstraints::new()
    };
    let ctx = GameWorkflowContext {
        known_constraints: constraints,
        ..GameWorkflowContext::new(
            GameplayIntent::new("platformer".to_string(), "reach_end".to_string()),
            "casual".to_string(),
        )
    };
    assert!(
        ctx.system_prompt_section().contains("mobile_low"),
        "performance budget should appear in system prompt section"
    );
}

#[test]
fn game_workflow_context_includes_player_count_in_prompt() {
    let ctx = GameWorkflowContext::new(
        GameplayIntent {
            player_count: 4,
            pacing: "action".to_string(),
            ..GameplayIntent::new("co-op".to_string(), "survive".to_string())
        },
        "chaotic fun".to_string(),
    );
    assert!(
        ctx.system_prompt_section().contains("4"),
        "player count should appear in system prompt section"
    );
}

#[test]
fn game_workflow_context_script_schemas_appear_in_prompt() {
    let schema = ScriptSchema::new("PatrolScript".to_string()).with_parameters(vec![
        ScriptParameterDescriptor {
            description: Some("movement speed in m/s".to_string()),
            ..ScriptParameterDescriptor::new("speed".to_string(), "Float".to_string())
        },
        ScriptParameterDescriptor::new("radius".to_string(), "Float".to_string()),
    ]);
    let constraints = GameKnownConstraints {
        script_schemas: vec![schema],
        ..GameKnownConstraints::new()
    };
    let ctx = GameWorkflowContext {
        known_constraints: constraints,
        ..GameWorkflowContext::new(
            GameplayIntent::new("action".to_string(), "survive".to_string()),
            "combat".to_string(),
        )
    };
    let section = ctx.system_prompt_section();
    assert!(section.contains("PatrolScript"), "script name must appear");
    assert!(section.contains("speed"), "parameter name must appear");
    assert!(section.contains("Float"), "parameter type must appear");
    assert!(
        section.contains("movement speed in m/s"),
        "parameter description must appear"
    );
    assert!(section.contains("radius"), "second parameter must appear");
}

#[test]
fn game_workflow_context_script_schemas_take_precedence_over_registry() {
    let schema = ScriptSchema::new("EnemyAI".to_string()).with_parameters(vec![
        ScriptParameterDescriptor::new("health".to_string(), "Int".to_string()),
    ]);
    let constraints = GameKnownConstraints {
        scripting_registry: vec!["legacyScript".to_string()],
        script_schemas: vec![schema],
        ..GameKnownConstraints::new()
    };
    let ctx = GameWorkflowContext {
        known_constraints: constraints,
        ..GameWorkflowContext::new(
            GameplayIntent::new("action".to_string(), "defeat_boss".to_string()),
            "intense".to_string(),
        )
    };
    let section = ctx.system_prompt_section();
    assert!(
        section.contains("EnemyAI"),
        "schema name must appear when schemas present"
    );
    assert!(
        !section.contains("legacyScript"),
        "registry names must be suppressed when schemas are provided"
    );
}

#[test]
fn game_workflow_context_script_schemas_round_trip_codable() {
    let schema = ScriptSchema::new("FlockBoid".to_string()).with_parameters(vec![
        ScriptParameterDescriptor::new("cohesionWeight".to_string(), "Float".to_string()),
        ScriptParameterDescriptor {
            description: Some("min distance".to_string()),
            ..ScriptParameterDescriptor::new("separationDist".to_string(), "Float".to_string())
        },
    ]);
    let constraints = GameKnownConstraints {
        script_schemas: vec![schema],
        ..GameKnownConstraints::new()
    };
    let ctx = GameWorkflowContext {
        level_phase: GameLevelPhase::Polish,
        known_constraints: constraints,
        ..GameWorkflowContext::new(
            GameplayIntent::new("simulation".to_string(), "observe".to_string()),
            "meditative".to_string(),
        )
    };
    let data = serde_json::to_vec(&ctx).unwrap();
    let decoded: GameWorkflowContext = serde_json::from_slice(&data).unwrap();
    assert_eq!(decoded.known_constraints.script_schemas.len(), 1);
    assert_eq!(
        decoded.known_constraints.script_schemas[0].name,
        "FlockBoid"
    );
    assert_eq!(
        decoded.known_constraints.script_schemas[0].parameters[1].description,
        Some("min distance".to_string())
    );
}

// MARK: - Locale propagation

#[test]
fn session_natural_language_with_non_english_locale_produces_proposal() {
    let plan_response = r#"
    {
      "id": "msg_l1",
      "content": [
        {"type": "tool_use", "id": "tu_l1", "name": "execute_edit_plan",
         "input": {"summary": "场景编辑完成", "steps": []}}
      ],
      "stop_reason": "tool_use"
    }
    "#;
    let server = FixtureHttpServer::start(move |_, _| plan_response.as_bytes().to_vec());
    let mut config = make_test_config();
    config.base_url = server.base_url().to_string();
    let session = session_with_world_view("locale1", config, WorldView::new());

    let signal = Signal::NaturalLanguage {
        text: "将所有灯光颜色改为暖白色".to_string(),
        locale: "zh-Hans".to_string(),
    };
    let proposal = session.process_with_defaults(&signal).unwrap();
    assert!(
        !proposal.id.is_empty(),
        "non-English locale signal must still produce a Proposal"
    );
    assert_eq!(proposal.plan.summary, "场景编辑完成");
}

// MARK: - Session.process(.userCorrection) all-accepted path

#[test]
fn session_process_user_correction_all_accepted_returns_noop_proposal() {
    // Given a session with a prior tool call turn in history
    let session = make_session("corr1");
    session.record_turn(ConversationTurn::new(ConversationTurnKind::UserText(
        "add a cube".to_string(),
    )));
    session.record_turn(ConversationTurn::new(
        ConversationTurnKind::AssistantToolCall {
            tool_use_id: "tu_1".to_string(),
            name: "execute_edit_plan".to_string(),
            input_json: "{\"summary\":\"Added cube\",\"steps\":[]}".to_string(),
        },
    ));

    // When: correction with no rejections (all accepted)
    let signal = Signal::UserCorrection {
        proposal_id: "prop_1".to_string(),
        accepted_step_ids: vec!["step_1".to_string()],
        rejected_step_ids: Vec::new(),
    };
    let proposal = session.process_with_defaults(&signal).unwrap();

    // Then: returns empty plan with automatic approval and no additional API call
    assert!(
        proposal.plan.steps.is_empty(),
        "all-accepted correction produces empty plan"
    );
    assert_eq!(
        proposal.approval_policy,
        TransactionApprovalPolicy::Automatic
    );
}

#[test]
fn session_process_user_correction_records_tool_result_in_history() {
    let session = make_session("corr2");
    session.record_turn(ConversationTurn::new(ConversationTurnKind::UserText(
        "move the cube".to_string(),
    )));
    session.record_turn(ConversationTurn::new(
        ConversationTurnKind::AssistantToolCall {
            tool_use_id: "tu_2".to_string(),
            name: "execute_edit_plan".to_string(),
            input_json: "{\"summary\":\"Moved cube\",\"steps\":[]}".to_string(),
        },
    ));

    let signal = Signal::UserCorrection {
        proposal_id: "prop_2".to_string(),
        accepted_step_ids: vec!["step_1".to_string()],
        rejected_step_ids: Vec::new(),
    };
    let _ = session.process_with_defaults(&signal).unwrap();

    let history = session.history_snapshot();
    let has_tool_result = history.iter().any(|turn| match &turn.kind {
        ConversationTurnKind::ToolResult { tool_use_id, .. } => tool_use_id == "tu_2",
        _ => false,
    });
    assert!(
        has_tool_result,
        "processing a correction must record a toolResult for the prior call's toolUseID"
    );
}

#[test]
fn session_process_user_correction_rejected_records_plan_ops_in_context_memory() {
    let plan_json = "{\"summary\":\"Renamed cube\",\"steps\":[{\"op\":\"set_name\",\"entity_id\":\"scene:1\",\"name\":\"New\"}]}";
    let plan_response = r#"
    {
      "id": "msg_r1",
      "content": [
        {"type": "tool_use", "id": "tu_r1", "name": "execute_edit_plan",
         "input": {"summary": "Revised.", "steps": []}}
      ],
      "stop_reason": "tool_use"
    }
    "#;
    let server = FixtureHttpServer::start(move |_, _| plan_response.as_bytes().to_vec());
    let mut config = make_test_config();
    config.base_url = server.base_url().to_string();
    let mem = Arc::new(ContextMemoryStore::new().unwrap());
    let session = session_with_world_view("mem-corr", config, WorldView::new());
    session.set_context_memory(Some(mem.clone()));
    session.record_turn(ConversationTurn::new(ConversationTurnKind::UserText(
        "rename the cube".to_string(),
    )));
    session.record_turn(ConversationTurn::new(
        ConversationTurnKind::AssistantToolCall {
            tool_use_id: "tu_r0".to_string(),
            name: "execute_edit_plan".to_string(),
            input_json: plan_json.to_string(),
        },
    ));

    let signal = Signal::UserCorrection {
        proposal_id: "prop_r1".to_string(),
        accepted_step_ids: Vec::new(),
        rejected_step_ids: vec!["step_0".to_string()],
    };
    let _ = session.process_with_defaults(&signal).unwrap();

    let entry = mem.entry("pref:rejected:prop_r1").unwrap();
    assert_eq!(
        entry.payload.get("plan_ops").map(String::as_str),
        Some("set_name"),
        "plan_ops must contain the operation type from the rejected plan"
    );
    assert_eq!(
        entry.payload.get("plan_summary").map(String::as_str),
        Some("Renamed cube"),
        "plan_summary must capture the plan summary"
    );
}

// MARK: - Executor error paths (missingEntityRef, entityNotFound, invalidEntityRef, invalidColor)

#[test]
fn executor_throws_missing_entity_ref_for_delete_entity() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let _ = scene.create_entity();

    let err = executor_error("del", vec![step(json!({"op": "delete_entity"}))], &scene);
    assert!(
        matches!(err, SceneEditPlanExecutorError::MissingEntityRef { op } if op == SceneEditOp::DeleteEntity),
        "expected missingEntityRef, got {err:?}"
    );
}

#[test]
fn executor_throws_entity_not_found_for_nonexistent_ref() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let _ = scene.create_entity();

    let err = executor_error(
        "del",
        vec![step(
            json!({"op": "delete_entity", "entity_id": "scene:99999"}),
        )],
        &scene,
    );
    assert!(
        matches!(err, SceneEditPlanExecutorError::EntityNotFound(ref r) if r == "scene:99999"),
        "expected entityNotFound, got {err:?}"
    );
}

#[test]
fn executor_throws_invalid_entity_ref_for_malformed_ref() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let _ = scene.create_entity();

    let err = executor_error(
        "bad",
        vec![step(
            json!({"op": "delete_entity", "entity_id": "invalid-format"}),
        )],
        &scene,
    );
    assert!(
        matches!(err, SceneEditPlanExecutorError::InvalidEntityRef(ref r) if r == "invalid-format"),
        "expected invalidEntityRef, got {err:?}"
    );
}

#[test]
fn executor_throws_invalid_color_for_short_color_array() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let _ = scene.set_component(
        RenderMeshComponent::new(0, true, Float3::ONE, None, vec![]),
        entity,
    );
    let ref_ = entity_ref(entity);

    let err = executor_error(
        "bad color",
        vec![step(
            json!({"op": "set_mesh_color", "entity_id": ref_, "color": [1.0, 0.5]}),
        )],
        &scene,
    );
    assert!(
        matches!(err, SceneEditPlanExecutorError::InvalidColor { op } if op == SceneEditOp::SetMeshColor),
        "expected invalidColor, got {err:?}"
    );
}

#[test]
fn executor_throws_missing_field_for_set_light_range_without_range() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let _ = scene.set_component(
        LightComponent::new(
            LightType::Point,
            Float3::ONE,
            100.0,
            10.0,
            20.0,
            30.0,
            false,
        ),
        entity,
    );
    let ref_ = entity_ref(entity);

    let err = executor_error(
        "range",
        vec![step(json!({"op": "set_light_range", "entity_id": ref_}))],
        &scene,
    );
    assert!(
        matches!(err, SceneEditPlanExecutorError::MissingField { ref field, .. } if field == "range"),
        "expected missingField(range), got {err:?}"
    );
}

#[test]
fn executor_throws_missing_field_for_set_collider_layer_with_no_fields() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let _ = scene.set_component(
        Collider::with_shape(ColliderShape::Box {
            half_extents: Float3::ONE,
            center: Float3::ZERO,
        }),
        entity,
    );
    let ref_ = entity_ref(entity);

    let err = executor_error(
        "layer",
        vec![step(json!({"op": "set_collider_layer", "entity_id": ref_}))],
        &scene,
    );
    assert!(
        matches!(err, SceneEditPlanExecutorError::MissingField { .. }),
        "expected missingField, got {err:?}"
    );
}

// MARK: - entityEvaluatedChanged event

#[test]
fn entity_evaluated_changed_populates_evaluated_dict() {
    let mut view = WorldView::new();
    view.apply_event(WorldEvent::EntityAdded {
        ref_: "scene:1".to_string(),
        name: "A".to_string(),
        kind: None,
    });
    view.apply_event(WorldEvent::EntityEvaluatedChanged {
        ref_: "scene:1".to_string(),
        property: "worldPosition".to_string(),
        value: vec3_value(10.0, 20.0, 30.0),
    });
    assert_eq!(
        view.entity_index()["scene:1"]
            .evaluated
            .get("worldPosition"),
        Some(&vec3_value(10.0, 20.0, 30.0))
    );
}

#[test]
fn entity_evaluated_changed_creates_record_when_entity_absent() {
    let mut view = WorldView::new();
    view.apply_event(WorldEvent::EntityEvaluatedChanged {
        ref_: "scene:9".to_string(),
        property: "worldScale".to_string(),
        value: vec3_value(2.0, 2.0, 2.0),
    });
    assert_eq!(
        view.entity_index()["scene:9"].evaluated.get("worldScale"),
        Some(&vec3_value(2.0, 2.0, 2.0))
    );
}

// MARK: - setColliderShape with mesh / convex kinds

#[test]
fn set_collider_shape_mesh_kind_produces_mutation() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let _ = scene.set_component(
        Collider::with_shape(ColliderShape::Box {
            half_extents: Float3::ONE,
            center: Float3::ZERO,
        }),
        entity,
    );
    let ref_ = entity_ref(entity);

    let transaction = execute_plan(
        "mesh collider",
        vec![step(
            json!({"op": "set_collider_shape", "entity_id": ref_, "collider_shape": "mesh"}),
        )],
        &scene,
    );
    let ops = scene_ops(&transaction);
    let has = ops.iter().any(|mutation| {
        mutation
            .decoded_component::<Collider>("collider")
            .is_some_and(|(_, c)| matches!(c.shape(), ColliderShape::Mesh { .. }))
    });
    assert!(
        has,
        "set_collider_shape 'mesh' must produce setCollider mutation with mesh shape"
    );
}

#[test]
fn set_collider_shape_convex_kind_produces_mutation() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let _ = scene.set_component(
        Collider::with_shape(ColliderShape::Box {
            half_extents: Float3::ONE,
            center: Float3::ZERO,
        }),
        entity,
    );
    let ref_ = entity_ref(entity);

    let transaction = execute_plan(
        "convex",
        vec![step(
            json!({"op": "set_collider_shape", "entity_id": ref_, "collider_shape": "convex"}),
        )],
        &scene,
    );
    let ops = scene_ops(&transaction);
    let has = ops.iter().any(|mutation| {
        mutation
            .decoded_component::<Collider>("collider")
            .is_some_and(|(_, c)| matches!(c.shape(), ColliderShape::Convex { .. }))
    });
    assert!(
        has,
        "set_collider_shape 'convex' must produce setCollider mutation with convex shape"
    );
}

// MARK: - Session.process(.referenceImage)

#[test]
fn session_process_reference_image_returns_proposal() {
    let plan_response = r#"
    {
      "id": "msg_1",
      "content": [
        {"type": "tool_use", "id": "tu_1", "name": "execute_edit_plan",
         "input": {"summary": "Created entity from reference.", "steps": []}}
      ],
      "stop_reason": "tool_use"
    }
    "#;
    let server = FixtureHttpServer::start(move |_, _| plan_response.as_bytes().to_vec());
    let mut config = make_test_config();
    config.base_url = server.base_url().to_string();
    let session = session_with_world_view("img1", config, WorldView::new());

    let signal = Signal::ReferenceImage {
        url: "/tmp/ref.png".to_string(),
        entity_ref: Some("scene:1".to_string()),
    };
    let proposal = session.process_with_defaults(&signal).unwrap();
    assert_eq!(proposal.plan.summary, "Created entity from reference.");
}

#[test]
fn session_process_reference_image_records_user_turn_with_filename_and_entity_ref() {
    let plan_response = r#"
    {
      "id": "msg_1",
      "content": [
        {"type": "tool_use", "id": "tu_1", "name": "execute_edit_plan",
         "input": {"summary": "Named entity.", "steps": []}}
      ],
      "stop_reason": "tool_use"
    }
    "#;
    let server = FixtureHttpServer::start(move |_, _| plan_response.as_bytes().to_vec());
    let mut config = make_test_config();
    config.base_url = server.base_url().to_string();
    let session = session_with_world_view("img2", config, WorldView::new());

    let signal = Signal::ReferenceImage {
        url: "/tmp/chair.jpg".to_string(),
        entity_ref: Some("scene:5".to_string()),
    };
    let _ = session.process_with_defaults(&signal).unwrap();

    // The user message is recorded in conversationHistory — check it via historySnapshot.
    let history = session.history_snapshot();
    let user_texts: Vec<&str> = history
        .iter()
        .filter_map(|turn| match &turn.kind {
            ConversationTurnKind::UserText(text) => Some(text.as_str()),
            _ => None,
        })
        .collect();
    let user_message = user_texts.first().unwrap();
    assert!(
        user_message.contains("chair.jpg"),
        "filename must appear in recorded user message"
    );
    assert!(
        user_message.contains("scene:5"),
        "entity ref must appear in recorded user message"
    );
}

// MARK: - setMaterial read-modify-write

#[test]
fn set_material_preserves_existing_fields_when_only_roughness_specified() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let _ = scene.set_component(
        RenderMaterialComponent::new(
            Float4::new(0.2, 0.4, 0.6, 1.0),
            Some(3),
            Some(7),
            0.8,
            0.9,
            Float3::ZERO,
            None,
            None,
            None,
        ),
        entity,
    );
    let ref_ = entity_ref(entity);

    let transaction = execute_plan(
        "rough",
        vec![step(
            json!({"op": "set_material", "entity_id": ref_, "material_roughness": 0.1}),
        )],
        &scene,
    );

    let ops = scene_ops(&transaction);
    let ok = ops.iter().any(|mutation| {
        mutation
            .decoded_component::<RenderMaterialComponent>("renderMaterial")
            .is_some_and(|(id, component)| {
                let base = component.base_color_factor;
                id == entity.raw_value()
                    && (base.x - 0.2).abs() < 0.001 // preserved
                    && (base.y - 0.4).abs() < 0.001 // preserved
                    && (base.z - 0.6).abs() < 0.001 // preserved
                    && component.base_color_texture_index == Some(3)
                    && component.normal_texture_index == Some(7)
                    && (component.metallic_factor - 0.8).abs() < 0.001 // preserved
                    && (component.roughness_factor - 0.1).abs() < 0.001 // updated
            })
    });
    assert!(
        ok,
        "set_material must preserve existing base color and metallic when only roughness is specified"
    );
}

#[test]
fn set_material_preserves_existing_fields_when_only_metallic_specified() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let _ = scene.set_component(
        RenderMaterialComponent::new(
            Float4::new(1.0, 0.0, 0.0, 1.0),
            None,
            None,
            0.0,
            0.3,
            Float3::ZERO,
            None,
            None,
            None,
        ),
        entity,
    );
    let ref_ = entity_ref(entity);

    let transaction = execute_plan(
        "metal",
        vec![step(
            json!({"op": "set_material", "entity_id": ref_, "material_metallic": 1.0}),
        )],
        &scene,
    );

    let ops = scene_ops(&transaction);
    let ok = ops.iter().any(|mutation| {
        mutation
            .decoded_component::<RenderMaterialComponent>("renderMaterial")
            .is_some_and(|(id, component)| {
                let base = component.base_color_factor;
                id == entity.raw_value()
                    && (base.x - 1.0).abs() < 0.001 // preserved
                    && (base.z - 0.0).abs() < 0.001 // preserved
                    && (component.metallic_factor - 1.0).abs() < 0.001 // updated
                    && (component.roughness_factor - 0.3).abs() < 0.001 // preserved
            })
    });
    assert!(
        ok,
        "set_material must preserve existing roughness when only metallic is specified"
    );
}

// MARK: - audioPitch / audioSpatialBlend snapshot pipeline

#[test]
fn snapshot_entity_includes_audio_pitch_when_non_default() {
    let snap = SceneSemanticSnapshotEntity {
        components: vec!["audio_source".to_string()],
        audio_volume: Some(0.8),
        audio_pitch: Some(1.5),
        ..entity("scene:1", "SFX", "Entity")
    };
    let mut wv = WorldView::new();
    wv.apply_snapshot(&snapshot(1, vec![snap]));
    assert_eq!(wv.entity_index()["scene:1"].audio_pitch, Some(1.5));
}

#[test]
fn snapshot_entity_includes_audio_spatial_blend() {
    let snap = SceneSemanticSnapshotEntity {
        components: vec!["audio_source".to_string()],
        audio_volume: Some(1.0),
        audio_spatial_blend: Some(0.75),
        ..entity("scene:2", "Speaker", "Entity")
    };
    let mut wv = WorldView::new();
    wv.apply_snapshot(&snapshot(2, vec![snap]));
    assert_eq!(wv.entity_index()["scene:2"].audio_spatial_blend, Some(0.75));
}

#[test]
fn world_entity_record_apply_audio_pitch_event() {
    let mut record = WorldEntityRecord::new("scene:3".to_string());
    record.apply("audioPitch".to_string(), float_value(0.5));
    assert_eq!(record.audio_pitch, Some(0.5));
}

#[test]
fn world_entity_record_apply_audio_spatial_blend_event() {
    let mut record = WorldEntityRecord::new("scene:4".to_string());
    record.apply("audioSpatialBlend".to_string(), float_value(0.9));
    assert_eq!(record.audio_spatial_blend, Some(0.9));
}

#[test]
fn compact_dict_includes_audio_pitch_and_spatial_blend() {
    let mut record = WorldEntityRecord::new("scene:50".to_string());
    record.name = "BGM".to_string();
    record.audio_pitch = Some(1.25);
    record.audio_spatial_blend = Some(0.6);
    let dict = Session::compact_dict(&record);
    assert_eq!(dict_float(&dict, "audioPitch"), Some(1.25));
    assert_eq!(dict_float(&dict, "audioSpatialBlend"), Some(0.6));
}

#[test]
fn compact_dict_omits_audio_pitch_and_spatial_blend_when_nil() {
    let mut record = WorldEntityRecord::new("scene:51".to_string());
    record.name = "Silent".to_string();
    let dict = Session::compact_dict(&record);
    assert!(dict.get("audioPitch").is_none());
    assert!(dict.get("audioSpatialBlend").is_none());
}

// MARK: - WorldEntityRecord.components snapshot pipeline

#[test]
fn world_view_apply_snapshot_preserves_components_list() {
    let snap = SceneSemanticSnapshotEntity {
        components: vec!["transform".to_string(), "light".to_string()],
        ..entity("scene:1", "Lamp", "Point Light")
    };
    let mut wv = WorldView::new();
    wv.apply_snapshot(&snapshot(1, vec![snap]));
    assert_eq!(
        wv.entity_index()["scene:1"].components,
        vec!["transform".to_string(), "light".to_string()]
    );
}

#[test]
fn compact_dict_includes_components_when_non_empty() {
    let mut record = WorldEntityRecord::new("scene:60".to_string());
    record.name = "Camera".to_string();
    record.components = vec!["transform".to_string(), "camera".to_string()];
    let dict = Session::compact_dict(&record);
    assert_eq!(
        dict.get("components"),
        Some(&json!(["transform", "camera"]))
    );
}

#[test]
fn compact_dict_omits_components_when_empty() {
    let mut record = WorldEntityRecord::new("scene:61".to_string());
    record.name = "Empty".to_string();
    let dict = Session::compact_dict(&record);
    assert!(dict.get("components").is_none());
}

// MARK: - find_entities component filter

#[test]
fn find_entities_component_filter_matches_correct_entities() {
    let mut wv = WorldView::new();
    let light_snap = SceneSemanticSnapshotEntity {
        components: vec!["transform".to_string(), "light".to_string()],
        ..entity("scene:1", "Sun Light", "Directional Light")
    };
    let mesh_snap = SceneSemanticSnapshotEntity {
        components: vec!["transform".to_string(), "mesh".to_string()],
        ..entity("scene:2", "Rock", "Static Mesh")
    };
    let cam_snap = SceneSemanticSnapshotEntity {
        components: vec!["transform".to_string(), "camera".to_string()],
        ..entity("scene:3", "Main Camera", "Camera")
    };
    wv.apply_snapshot(&snapshot(1, vec![light_snap, mesh_snap, cam_snap]));
    let session = session_with_world_view("comp-filter", make_test_config(), wv);

    let world = session.world_view();
    let input = json!({"component": "light"});
    let json = session.find_entities_result(&world, input.as_object().unwrap());
    let result: Value = serde_json::from_str(&json).unwrap();

    assert_eq!(result["count"].as_i64(), Some(1));
    let entities = result["entities"].as_array().unwrap();
    assert_eq!(entities.first().unwrap()["id"].as_str(), Some("scene:1"));
}

#[test]
fn find_entities_component_filter_case_insensitive() {
    let mut wv = WorldView::new();
    let snap = SceneSemanticSnapshotEntity {
        components: vec![
            "transform".to_string(),
            "animation".to_string(),
            "script".to_string(),
        ],
        ..entity("scene:1", "Walker", "Character")
    };
    wv.apply_snapshot(&snapshot(1, vec![snap]));
    let session = session_with_world_view("comp-ci", make_test_config(), wv);

    let world = session.world_view();
    let input = json!({"component": "Animation"});
    let json = session.find_entities_result(&world, input.as_object().unwrap());
    let result: Value = serde_json::from_str(&json).unwrap();
    assert_eq!(
        result["count"].as_i64(),
        Some(1),
        "component filter must be case-insensitive"
    );
}

#[test]
fn find_entities_result_includes_components_array_in_output() {
    let mut wv = WorldView::new();
    let snap = SceneSemanticSnapshotEntity {
        components: vec![
            "transform".to_string(),
            "rigidbody".to_string(),
            "script".to_string(),
        ],
        ..entity("scene:1", "Player", "Character")
    };
    wv.apply_snapshot(&snapshot(1, vec![snap]));
    let session = session_with_world_view("comp-out", make_test_config(), wv);

    let world = session.world_view();
    let input = json!({});
    let json = session.find_entities_result(&world, input.as_object().unwrap());
    let result: Value = serde_json::from_str(&json).unwrap();
    let entities = result["entities"].as_array().unwrap();

    assert_eq!(
        entities.first().unwrap()["components"],
        json!(["transform", "rigidbody", "script"]),
        "components array must appear in findEntities output"
    );
}

#[test]
fn find_entities_result_includes_position_when_available() {
    let mut wv = WorldView::new();
    let snap = SceneSemanticSnapshotEntity {
        position: Some(vec![3.0, 0.0, -5.0]),
        world_position: Some(vec![3.0, 0.0, -5.0]),
        components: vec!["transform".to_string()],
        ..entity("scene:1", "Chest", "Prop")
    };
    wv.apply_snapshot(&snapshot(1, vec![snap]));
    let session = session_with_world_view("pos-find", make_test_config(), wv);

    let world = session.world_view();
    let input = json!({});
    let json = session.find_entities_result(&world, input.as_object().unwrap());
    let result: Value = serde_json::from_str(&json).unwrap();
    let entities = result["entities"].as_array().unwrap();

    assert_eq!(
        entities.first().unwrap()["position"],
        json!([3.0, 0.0, -5.0]),
        "position must appear in findEntities output"
    );
    assert!(
        entities.first().unwrap().get("worldPosition").is_some(),
        "worldPosition must appear in findEntities output when available"
    );
}

#[test]
fn find_entities_result_includes_parent_ref_when_present() {
    let mut wv = WorldView::new();
    let child_snap = SceneSemanticSnapshotEntity {
        parent_ref: Some("scene:1".to_string()),
        ..entity("scene:2", "Child", "Entity")
    };
    wv.apply_snapshot(&snapshot(1, vec![child_snap]));
    let session = session_with_world_view("parent-find", make_test_config(), wv);

    let world = session.world_view();
    let input = json!({});
    let json = session.find_entities_result(&world, input.as_object().unwrap());
    let result: Value = serde_json::from_str(&json).unwrap();
    let entities = result["entities"].as_array().unwrap();

    assert_eq!(
        entities.first().unwrap()["parentRef"].as_str(),
        Some("scene:1"),
        "parentRef must appear in findEntities output when the entity has a parent"
    );
}

// MARK: - WorldView snapshot merge preserves inferred annotations

#[test]
fn apply_snapshot_preserves_inferred_annotations_for_existing_entities() {
    let mut wv = WorldView::new();
    // First snapshot: one entity
    let s1 = SceneSemanticSnapshotEntity {
        position: Some(vec![0.0, 0.0, 0.0]),
        world_position: Some(vec![0.0, 0.0, 0.0]),
        ..entity("scene:100", "Chair", "Static Mesh")
    };
    wv.apply_snapshot(&snapshot(1, vec![s1]));
    // Annotate with inferred data (simulating perception)
    wv.apply_event(WorldEvent::EntityInferredUpdated {
        ref_: "scene:100".to_string(),
        property: "object_category".to_string(),
        value: string_value("dining_chair"),
        confidence: 0.92,
        source: Some("perception".to_string()),
    });

    // Second snapshot for the same entity (e.g. position changed)
    let s1_updated = SceneSemanticSnapshotEntity {
        position: Some(vec![1.0, 0.0, 0.0]),
        world_position: Some(vec![1.0, 0.0, 0.0]),
        ..entity("scene:100", "Chair", "Static Mesh")
    };
    wv.apply_snapshot(&snapshot(2, vec![s1_updated]));

    let record = wv.entity_record("scene:100").unwrap();
    assert_eq!(
        record.position,
        Some(vec![1.0, 0.0, 0.0]),
        "authored position must be updated from new snapshot"
    );
    assert_eq!(
        record.inferred["object_category"].display_value, "dining_chair",
        "inferred annotation must be preserved across snapshot merges"
    );
    assert_eq!(record.inferred["object_category"].confidence, 0.92);
}

#[test]
fn apply_snapshot_removes_entities_absent_from_new_snapshot() {
    let mut wv = WorldView::new();
    let s1 = entity("scene:200", "Temp", "Static Mesh");
    wv.apply_snapshot(&snapshot(1, vec![s1]));
    assert!(wv.entity_index().contains_key("scene:200"));

    // New snapshot with no entities — entity should be removed
    wv.apply_snapshot(&snapshot(2, vec![]));
    assert!(
        wv.entity_index().get("scene:200").is_none(),
        "entity removed from scene must not appear after snapshot merge"
    );
}

// MARK: - planConfidence spawn with explicit position

#[test]
fn plan_confidence_no_orphan_penalty_when_spawn_has_explicit_position() {
    let plan: SceneEditPlan = serde_json::from_str(
        r#"{"summary":"spawn","steps":[{"op":"spawn_entity","label":"Rock","spawn_position":[0,0,5]}]}"#,
    )
    .unwrap();
    let score = Session::confidence(&plan);
    assert!(
        score > 0.90,
        "spawn with explicit spawn_position must not incur the orphan penalty"
    );
}

#[test]
fn plan_confidence_applies_orphan_penalty_when_spawn_lacks_position() {
    let plan: SceneEditPlan = serde_json::from_str(
        r#"{"summary":"spawn","steps":[{"op":"spawn_entity","label":"Rock"}]}"#,
    )
    .unwrap();
    let score = Session::confidence(&plan);
    // Orphan penalty (-0.05) should reduce below the no-penalty score of 1.0
    assert!(
        score < 0.99,
        "spawn without position and no set_transform must incur the orphan penalty"
    );
}

// MARK: - RigidBody read-modify-write (creates component when absent)

#[test]
fn set_rigid_body_motion_creates_rigid_body_when_entity_has_none() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let ref_ = entity_ref(entity);

    let transaction = execute_plan(
        "phys",
        vec![step(
            json!({"op": "set_rigidbody_motion", "entity_id": ref_, "motion_type": "dynamic"}),
        )],
        &scene,
    );
    let ops = scene_ops(&transaction);
    let has_rigid_body = ops.iter().any(|mutation| {
        mutation
            .decoded_component::<RigidBody>("rigidbody")
            .is_some_and(|(eid, body)| {
                eid == entity.raw_value() && body.motion_type == RigidBodyMotionType::Dynamic
            })
    });
    assert!(
        has_rigid_body,
        "set_rigidbody_motion on entity without RigidBody must create it with setRigidBody mutation"
    );
}

#[test]
fn set_rigid_body_motion_preserves_existing_mass_when_changing_motion_type() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let _ = scene.set_component(
        RigidBody {
            mass: 42.0,
            ..RigidBody::default()
        },
        entity,
    );
    let ref_ = entity_ref(entity);

    let transaction = execute_plan(
        "phys",
        vec![step(
            json!({"op": "set_rigidbody_motion", "entity_id": ref_, "motion_type": "kinematic"}),
        )],
        &scene,
    );
    let ops = scene_ops(&transaction);
    let has_correct = ops.iter().any(|mutation| {
        mutation
            .decoded_component::<RigidBody>("rigidbody")
            .is_some_and(|(eid, body)| {
                eid == entity.raw_value()
                    && body.motion_type == RigidBodyMotionType::Kinematic
                    && (body.mass - 42.0).abs() < 0.01
            })
    });
    assert!(
        has_correct,
        "set_rigidbody_motion must preserve existing mass when only changing motion type"
    );
}

// MARK: - Collider read-modify-write

#[test]
fn set_collider_trigger_creates_collider_when_entity_has_none() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let ref_ = entity_ref(entity);

    let transaction = execute_plan(
        "trigger",
        vec![step(
            json!({"op": "set_collider_trigger", "entity_id": ref_, "is_trigger": true}),
        )],
        &scene,
    );
    let ops = scene_ops(&transaction);
    let has_collider = ops.iter().any(|mutation| {
        mutation
            .decoded_component::<Collider>("collider")
            .is_some_and(|(eid, col)| eid == entity.raw_value() && col.is_trigger)
    });
    assert!(
        has_collider,
        "set_collider_trigger on entity without Collider must create it via setCollider"
    );
}

#[test]
fn set_collider_material_preserves_shape_when_entity_has_collider() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let _ = scene.set_component(
        Collider::with_shape(ColliderShape::Sphere {
            radius: 1.5,
            center: Float3::ZERO,
        }),
        entity,
    );
    let ref_ = entity_ref(entity);

    let transaction = execute_plan(
        "mat",
        vec![step(
            json!({"op": "set_collider_material", "entity_id": ref_, "friction": 0.3}),
        )],
        &scene,
    );
    let ops = scene_ops(&transaction);
    let has_collider = ops.iter().any(|mutation| {
        mutation
            .decoded_component::<Collider>("collider")
            .is_some_and(|(eid, col)| {
                matches!(col.shape(), ColliderShape::Sphere { radius, .. } if (radius - 1.5).abs() < 0.001)
                    && eid == entity.raw_value()
                    && (col.material.friction - 0.3).abs() < 0.001
            })
    });
    assert!(
        has_collider,
        "set_collider_material must preserve existing sphere shape while updating friction"
    );
}

#[test]
fn set_collider_box_extents_creates_box_collider_when_entity_has_none() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let ref_ = entity_ref(entity);

    let transaction = execute_plan(
        "box",
        vec![step(
            json!({"op": "set_collider_box_extents", "entity_id": ref_, "half_extents": [1, 2, 3]}),
        )],
        &scene,
    );
    let ops = scene_ops(&transaction);
    let has_collider = ops.iter().any(|mutation| {
        mutation
            .decoded_component::<Collider>("collider")
            .is_some_and(|(eid, col)| match col.shape() {
                ColliderShape::Box { half_extents, .. } => {
                    eid == entity.raw_value()
                        && (half_extents.x - 1.0).abs() < 0.01
                        && (half_extents.y - 2.0).abs() < 0.01
                        && (half_extents.z - 3.0).abs() < 0.01
                }
                _ => false,
            })
    });
    assert!(
        has_collider,
        "set_collider_box_extents on entity without Collider must create box collider"
    );
}

#[test]
fn set_collider_shape_type_switches_to_sphere_preserving_trigger() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let mut col = Collider::with_shape(ColliderShape::Box {
        half_extents: Float3::ONE,
        center: Float3::ZERO,
    });
    col.is_trigger = true;
    let _ = scene.set_component(col, entity);
    let ref_ = entity_ref(entity);

    let transaction = execute_plan(
        "shape",
        vec![step(
            json!({"op": "set_collider_shape", "entity_id": ref_, "collider_shape": "sphere"}),
        )],
        &scene,
    );
    let ops = scene_ops(&transaction);
    let has_collider = ops.iter().any(|mutation| {
        mutation
            .decoded_component::<Collider>("collider")
            .is_some_and(|(eid, c)| {
                matches!(c.shape(), ColliderShape::Sphere { .. })
                    && eid == entity.raw_value()
                    && c.is_trigger
            })
    });
    assert!(
        has_collider,
        "set_collider_shape to sphere must preserve isTrigger=true and switch to sphere shape"
    );
}

// MARK: - Collider dimension tracking in WorldView

#[test]
fn world_view_tracks_box_collider_half_extents_from_snapshot() {
    let mut view = WorldView::new();
    let box_entity = SceneSemanticSnapshotEntity {
        components: vec!["collider".to_string()],
        collider_shape: Some("box".to_string()),
        collider_box_half_extents: Some(vec![1.5, 2.0, 0.5]),
        ..entity("scene:1", "Box", "Entity")
    };
    view.apply_snapshot(&snapshot(1, vec![box_entity]));
    let record = view.entity_record("scene:1").unwrap();
    assert_eq!(record.collider_shape.as_deref(), Some("box"));
    let half_extents = record.collider_box_half_extents.as_ref().unwrap();
    assert_eq!(half_extents.len(), 3);
    assert_close(f64::from(half_extents[0]), 1.5, 0.001);
    assert_close(f64::from(half_extents[1]), 2.0, 0.001);
    assert_close(f64::from(half_extents[2]), 0.5, 0.001);
}

#[test]
fn world_view_tracks_sphere_collider_radius_from_event() {
    let mut view = WorldView::new();
    view.apply_event(added("scene:5", "Sphere", "Entity"));
    view.apply_event(authored("scene:5", "colliderShape", string_value("sphere")));
    view.apply_event(authored(
        "scene:5",
        "colliderSphereRadius",
        float_value(3.7),
    ));
    let record = view.entity_record("scene:5").unwrap();
    assert_eq!(record.collider_shape.as_deref(), Some("sphere"));
    assert_close(
        f64::from(record.collider_sphere_radius.unwrap()),
        3.7,
        0.001,
    );
    assert!(
        record.collider_box_half_extents.is_none(),
        "box extents should be nil for sphere collider"
    );
}

#[test]
fn world_view_clears_stale_collider_dimensions_on_shape_change() {
    let mut view = WorldView::new();
    view.apply_event(added("scene:6", "Entity", "Entity"));
    view.apply_event(authored("scene:6", "colliderShape", string_value("box")));
    view.apply_event(authored(
        "scene:6",
        "colliderBoxHalfExtents",
        vec3_value(1.0, 1.0, 1.0),
    ));
    // Now switch to capsule — box extents should be cleared
    view.apply_event(authored(
        "scene:6",
        "colliderShape",
        string_value("capsule"),
    ));
    let record = view.entity_record("scene:6").unwrap();
    assert!(
        record.collider_box_half_extents.is_none(),
        "box half-extents must be cleared when shape switches to capsule"
    );
}

#[test]
fn set_collider_box_extents_world_event_updates_half_extents() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let ref_ = entity_ref(entity);

    let transaction = execute_plan(
        "big",
        vec![step(
            json!({"op": "set_collider_box_extents", "entity_id": ref_, "half_extents": [2, 3, 4]}),
        )],
        &scene,
    );
    let ops = scene_ops(&transaction);
    let has_extents = ops.iter().any(|mutation| {
        mutation
            .decoded_component::<Collider>("collider")
            .is_some_and(|(_, c)| match c.shape() {
                ColliderShape::Box { half_extents, .. } => {
                    (half_extents.x - 2.0).abs() < 0.01
                        && (half_extents.y - 3.0).abs() < 0.01
                        && (half_extents.z - 4.0).abs() < 0.01
                }
                _ => false,
            })
    });
    assert!(
        has_extents,
        "set_collider_box_extents must produce setCollider with half_extents [2,3,4]"
    );
}

// MARK: - JSONValue array support for set_script_property

#[test]
fn json_value_array_round_trips_via_codable() {
    let plan: SceneEditPlan = serde_json::from_str(
        r#"{"summary":"s","steps":[{"op":"set_script_property","entity_id":"scene:1","script_property_name":"waypoints","script_property_value":[1,2,3]}]}"#,
    )
    .unwrap();
    let edit_step = &plan.steps[0];
    match edit_step.script_property_value.as_ref().unwrap() {
        JSONValue::Array(elements) => {
            assert_eq!(elements.len(), 3);
            match &elements[0] {
                JSONValue::Number(n) => assert_eq!(*n, 1.0),
                _ => panic!("first element should be .number(1)"),
            }
        }
        _ => panic!("scriptPropertyValue should be .array"),
    }
}

#[test]
fn json_value_array_json_fragment() {
    let arr = JSONValue::Array(vec![
        JSONValue::Number(1.0),
        JSONValue::String("a".to_string()),
        JSONValue::Bool(true),
    ]);
    assert_eq!(arr.json_fragment(), r#"[1,"a",true]"#);
}

#[test]
fn set_script_property_with_array_merges_into_parameters_json() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let _ = scene.set_component(ScriptComponent::new(vec![]), entity);
    let ref_ = entity_ref(entity);

    let transaction = execute_plan(
        "s",
        vec![step(json!({
            "op": "set_script_property", "entity_id": ref_,
            "script_identifier": "project.tags", "script_property_name": "tags",
            "script_property_value": ["enemy", "boss"]
        }))],
        &scene,
    );
    let ops = scene_ops(&transaction);
    let has_script = ops.iter().any(|mutation| {
        mutation
            .decoded_component::<ScriptComponent>("script")
            .is_some_and(|(eid, component)| {
                if eid != entity.raw_value() {
                    return false;
                }
                let Some(first) = component.bindings.first() else {
                    return false;
                };
                let Ok(dict) = serde_json::from_str::<Value>(&first.parameters_json) else {
                    return false;
                };
                first.identifier.as_deref() == Some("project.tags")
                    && dict["tags"] == json!(["enemy", "boss"])
            })
    });
    assert!(
        has_script,
        "set_script_property with array value must produce correct setScriptBindings mutation"
    );
}

// MARK: - duplicate_entity with offset

#[test]
fn duplicate_entity_with_offset_produces_duplicate_entity_with_offset_mutation() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let ref_ = entity_ref(entity);

    let transaction = execute_plan(
        "dup",
        vec![step(
            json!({"op": "duplicate_entity", "entity_id": ref_, "duplicate_offset": [3, 0, 0]}),
        )],
        &scene,
    );
    let ops = scene_ops(&transaction);
    let has_offset = ops.iter().any(|mutation| {
        matches!(mutation, SceneMutation::DuplicateEntityWithOffset { entity_id, position_offset }
            if *entity_id == entity.raw_value()
                && (position_offset.x - 3.0).abs() < 0.01
                && position_offset.y.abs() < 0.01
                && position_offset.z.abs() < 0.01)
    });
    assert!(
        has_offset,
        "duplicate_entity with duplicate_offset must produce duplicateEntityWithOffset mutation"
    );
}

#[test]
fn duplicate_entity_without_offset_produces_plain_duplicate_mutation() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let ref_ = entity_ref(entity);

    let transaction = execute_plan(
        "dup",
        vec![step(json!({"op": "duplicate_entity", "entity_id": ref_}))],
        &scene,
    );
    let ops = scene_ops(&transaction);
    let has_plain = ops.iter().any(|mutation| {
        matches!(mutation, SceneMutation::DuplicateEntity { entity_id } if *entity_id == entity.raw_value())
    });
    assert!(
        has_plain,
        "duplicate_entity without offset must produce plain duplicateEntity mutation"
    );
}

// MARK: - spawn_kind support

#[test]
fn spawn_kind_empty_produces_spawn_empty_entity_mutation() {
    let scene = SceneRuntime::new(ComponentRegistry::built_in());
    let transaction = execute_plan(
        "group",
        vec![step(
            json!({"op": "spawn_entity", "label": "Group", "spawn_kind": "empty", "spawn_position": [1, 0, 0]}),
        )],
        &scene,
    );
    let ops = scene_ops(&transaction);
    let has_empty = ops.iter().any(|mutation| {
        matches!(mutation, SceneMutation::SpawnEmptyEntity { label, position, .. }
            if label == "Group" && (position.x - 1.0).abs() < 0.01)
    });
    assert!(
        has_empty,
        "spawn_kind 'empty' must produce spawnEmptyEntity mutation"
    );
}

#[test]
fn spawn_kind_light_produces_spawn_light_entity_mutation() {
    let scene = SceneRuntime::new(ComponentRegistry::built_in());
    let transaction = execute_plan(
        "light",
        vec![step(
            json!({"op": "spawn_entity", "label": "Fill Light", "spawn_kind": "light", "light_type": "point", "spawn_position": [0, 3, 0]}),
        )],
        &scene,
    );
    let ops = scene_ops(&transaction);
    let has_light = ops.iter().any(|mutation| {
        matches!(mutation, SceneMutation::SpawnLightEntity { label, light_type, position, .. }
            if label == "Fill Light" && *light_type == LightType::Point && (position.y - 3.0).abs() < 0.01)
    });
    assert!(
        has_light,
        "spawn_kind 'light' must produce spawnLightEntity mutation with correct type and position"
    );
}

#[test]
fn spawn_kind_light_defaults_to_point_when_light_type_omitted() {
    let scene = SceneRuntime::new(ComponentRegistry::built_in());
    let transaction = execute_plan(
        "light",
        vec![step(
            json!({"op": "spawn_entity", "label": "Key", "spawn_kind": "light"}),
        )],
        &scene,
    );
    let ops = scene_ops(&transaction);
    let has_point_light = ops.iter().any(|mutation| {
        matches!(mutation, SceneMutation::SpawnLightEntity { light_type, .. } if *light_type == LightType::Point)
    });
    assert!(
        has_point_light,
        "spawn_kind 'light' with no light_type should default to point light"
    );
}

#[test]
fn spawn_kind_camera_produces_spawn_camera_entity_mutation() {
    let scene = SceneRuntime::new(ComponentRegistry::built_in());
    let transaction = execute_plan(
        "cam",
        vec![step(
            json!({"op": "spawn_entity", "label": "Security Cam", "spawn_kind": "camera", "spawn_position": [5, 2, -3]}),
        )],
        &scene,
    );
    let ops = scene_ops(&transaction);
    let has_cam = ops.iter().any(|mutation| {
        matches!(mutation, SceneMutation::SpawnCameraEntity { label, position, .. }
            if label == "Security Cam" && (position.x - 5.0).abs() < 0.01)
    });
    assert!(
        has_cam,
        "spawn_kind 'camera' must produce spawnCameraEntity mutation"
    );
}

#[test]
fn spawn_kind_mesh_is_default_when_omitted() {
    let scene = SceneRuntime::new(ComponentRegistry::built_in());
    let transaction = execute_plan(
        "mesh",
        vec![step(json!({"op": "spawn_entity", "label": "Box"}))],
        &scene,
    );
    let ops = scene_ops(&transaction);
    let has_mesh = ops
        .iter()
        .any(|mutation| matches!(mutation, SceneMutation::SpawnImportedMeshEntity { .. }));
    assert!(
        has_mesh,
        "spawn_entity with no spawn_kind must default to spawnImportedMeshEntity"
    );
}

// MARK: - find_entities spatial proximity filter

#[test]
fn find_entities_near_position_returns_close_entities() {
    let mut wv = WorldView::new();
    let s1 = SceneSemanticSnapshotEntity {
        position: Some(vec![0.0, 0.0, 0.0]),
        world_position: Some(vec![0.0, 0.0, 0.0]),
        ..entity("scene:10", "Near", "Static Mesh")
    };
    let s2 = SceneSemanticSnapshotEntity {
        position: Some(vec![100.0, 0.0, 0.0]),
        world_position: Some(vec![100.0, 0.0, 0.0]),
        ..entity("scene:11", "Far", "Static Mesh")
    };
    wv.apply_snapshot(&snapshot(1, vec![s1, s2]));
    let session = session_with_world_view("near-filter", make_test_config(), wv);

    let world = session.world_view();
    let input = json!({"near_position": [0.0, 0.0, 0.0], "near_radius": 5.0});
    let json = session.find_entities_result(&world, input.as_object().unwrap());
    let result: Value = serde_json::from_str(&json).unwrap();
    let entities = result["entities"].as_array().unwrap();

    assert_eq!(
        entities.len(),
        1,
        "only the nearby entity should be returned"
    );
    assert_eq!(entities[0]["name"].as_str(), Some("Near"));
}

#[test]
fn find_entities_near_position_excludes_entities_outside_radius() {
    let mut wv = WorldView::new();
    let s1 = SceneSemanticSnapshotEntity {
        position: Some(vec![3.0, 0.0, 0.0]),
        world_position: Some(vec![3.0, 0.0, 0.0]),
        ..entity("scene:20", "E1", "Static Mesh")
    };
    let s2 = SceneSemanticSnapshotEntity {
        position: Some(vec![6.0, 0.0, 0.0]),
        world_position: Some(vec![6.0, 0.0, 0.0]),
        ..entity("scene:21", "E2", "Static Mesh")
    };
    wv.apply_snapshot(&snapshot(1, vec![s1, s2]));
    let session = session_with_world_view("radius-exclude", make_test_config(), wv);

    let world = session.world_view();
    let input = json!({"near_position": [0.0, 0.0, 0.0], "near_radius": 4.0});
    let json = session.find_entities_result(&world, input.as_object().unwrap());
    let result: Value = serde_json::from_str(&json).unwrap();
    let entities = result["entities"].as_array().unwrap();

    assert_eq!(entities.len(), 1);
    assert_eq!(
        entities[0]["name"].as_str(),
        Some("E1"),
        "entity at distance 3 is within radius 4; entity at distance 6 must be excluded"
    );
}

#[test]
fn find_entities_near_position_falls_back_to_local_position() {
    let mut wv = WorldView::new();
    // Entity with local position only (root entity, no worldPosition in evaluated).
    wv.apply_event(added("scene:30", "RootEntity", "Static Mesh"));
    wv.apply_event(authored("scene:30", "position", vec3_value(2.0, 0.0, 0.0)));
    let session = session_with_world_view("local-pos-fallback", make_test_config(), wv);

    let world = session.world_view();
    let input = json!({"near_position": [0.0, 0.0, 0.0], "near_radius": 5.0});
    let json = session.find_entities_result(&world, input.as_object().unwrap());
    let result: Value = serde_json::from_str(&json).unwrap();
    let entities = result["entities"].as_array().unwrap();

    assert_eq!(
        entities.len(),
        1,
        "entity with only local position at [2,0,0] should match radius 5 query at origin"
    );
}

#[test]
fn find_entities_near_position_sorts_by_distance_nearest_first() {
    let mut wv = WorldView::new();
    let s1 = SceneSemanticSnapshotEntity {
        position: Some(vec![8.0, 0.0, 0.0]),
        world_position: Some(vec![8.0, 0.0, 0.0]),
        ..entity("scene:50", "Far", "Static Mesh")
    };
    let s2 = SceneSemanticSnapshotEntity {
        position: Some(vec![2.0, 0.0, 0.0]),
        world_position: Some(vec![2.0, 0.0, 0.0]),
        ..entity("scene:51", "Near", "Static Mesh")
    };
    wv.apply_snapshot(&snapshot(1, vec![s1, s2]));
    let session = session_with_world_view("sort-near", make_test_config(), wv);

    let world = session.world_view();
    let input = json!({"near_position": [0.0, 0.0, 0.0], "near_radius": 10.0});
    let json = session.find_entities_result(&world, input.as_object().unwrap());
    let result: Value = serde_json::from_str(&json).unwrap();
    let entities = result["entities"].as_array().unwrap();

    assert_eq!(entities.len(), 2);
    assert_eq!(
        entities[0]["name"].as_str(),
        Some("Near"),
        "entity at distance 2 should appear before entity at distance 8"
    );
    assert!(
        entities[0].get("distance").is_some(),
        "distance should be included in proximity results"
    );
}

#[test]
fn find_entities_near_position_requires_both_params() {
    let mut wv = WorldView::new();
    let s = SceneSemanticSnapshotEntity {
        position: Some(vec![0.0, 0.0, 0.0]),
        world_position: Some(vec![0.0, 0.0, 0.0]),
        ..entity("scene:40", "Any", "Static Mesh")
    };
    wv.apply_snapshot(&snapshot(1, vec![s]));
    let session = session_with_world_view("no-radius", make_test_config(), wv);

    // near_position without near_radius — should return all entities (filter not applied).
    let world = session.world_view();
    let input = json!({"near_position": [0.0, 0.0, 0.0]});
    let json = session.find_entities_result(&world, input.as_object().unwrap());
    let result: Value = serde_json::from_str(&json).unwrap();
    let entities = result["entities"].as_array().unwrap();

    assert_eq!(
        entities.len(),
        1,
        "without near_radius the spatial filter should not be applied"
    );
}

// MARK: - find_entities enriched result

#[test]
fn find_entities_result_includes_light_fields() {
    let mut wv = WorldView::new();
    let e = SceneSemanticSnapshotEntity {
        components: vec!["light".to_string()],
        light_type: Some("directional".to_string()),
        light_intensity: Some(8000.0),
        light_cast_shadows: Some(true),
        ..entity("scene:99", "Sun", "Directional Light")
    };
    wv.apply_snapshot(&snapshot(1, vec![e]));
    let session = session_with_world_view("enrich-test", make_test_config(), wv);

    let world = session.world_view();
    let input = json!({"name": "sun"});
    let json = session.find_entities_result(&world, input.as_object().unwrap());
    let result: Value = serde_json::from_str(&json).unwrap();
    let entities = result["entities"].as_array().unwrap();
    assert_eq!(entities.len(), 1);
    assert_eq!(entities[0]["lightType"].as_str(), Some("directional"));
    assert_eq!(value_as_float(&entities[0]["lightIntensity"]), Some(8000.0));
    assert_eq!(entities[0]["lightCastShadows"].as_bool(), Some(true));
}

#[test]
fn find_entities_result_includes_physics_fields() {
    let mut wv = WorldView::new();
    let e = SceneSemanticSnapshotEntity {
        components: vec!["rigidbody".to_string(), "collider".to_string()],
        rigid_body_motion_type: Some("dynamic".to_string()),
        rigid_body_mass: Some(5.0),
        collider_shape: Some("box".to_string()),
        collider_box_half_extents: Some(vec![0.5, 0.5, 0.5]),
        ..entity("scene:77", "Box", "Static Mesh")
    };
    wv.apply_snapshot(&snapshot(1, vec![e]));
    let session = session_with_world_view("enrich-phys", make_test_config(), wv);

    let world = session.world_view();
    let input = json!({"component": "rigidbody"});
    let json = session.find_entities_result(&world, input.as_object().unwrap());
    let result: Value = serde_json::from_str(&json).unwrap();
    let entities = result["entities"].as_array().unwrap();
    assert_eq!(entities.len(), 1);
    assert_eq!(entities[0]["rigidBodyMotionType"].as_str(), Some("dynamic"));
    assert_eq!(entities[0]["colliderShape"].as_str(), Some("box"));
    let extents = value_as_float_array(&entities[0]["colliderBoxHalfExtents"]);
    assert_eq!(extents.map(|values| values.len()), Some(3));
}

#[test]
fn find_entities_result_includes_capsule_half_height() {
    let mut wv = WorldView::new();
    let e = SceneSemanticSnapshotEntity {
        components: vec!["collider".to_string()],
        collider_shape: Some("capsule".to_string()),
        collider_capsule_radius: Some(0.3),
        collider_capsule_half_height: Some(0.8),
        ..entity("scene:88", "Capsule", "Static Mesh")
    };
    wv.apply_snapshot(&snapshot(1, vec![e]));
    let session = session_with_world_view("capsule-find", make_test_config(), wv);

    let world = session.world_view();
    let input = json!({});
    let json = session.find_entities_result(&world, input.as_object().unwrap());
    let result: Value = serde_json::from_str(&json).unwrap();
    let entities = result["entities"].as_array().unwrap();
    assert_eq!(entities.len(), 1);
    assert_close(
        entities[0]["colliderCapsuleRadius"].as_f64().unwrap(),
        0.3,
        0.001,
    );
    assert_close(
        entities[0]["colliderCapsuleHalfHeight"].as_f64().unwrap(),
        0.8,
        0.001,
    );
}

#[test]
fn find_entities_result_includes_script_binding_params() {
    let mut wv = WorldView::new();
    let binding = SceneSemanticSnapshotScriptBindingRecord::new(
        5,
        Some("project.enemy".to_string()),
        true,
        "{\"speed\":3.5,\"patrol\":true}".to_string(),
    );
    let e = SceneSemanticSnapshotEntity {
        components: vec!["script".to_string()],
        script_bindings: Some(vec![binding]),
        ..entity("scene:99", "Enemy", "Character")
    };
    wv.apply_snapshot(&snapshot(1, vec![e]));
    let session = session_with_world_view("script-params-find", make_test_config(), wv);

    let world = session.world_view();
    let input = json!({"component": "script"});
    let json = session.find_entities_result(&world, input.as_object().unwrap());
    let result: Value = serde_json::from_str(&json).unwrap();
    let entities = result["entities"].as_array().unwrap();
    assert_eq!(entities.len(), 1);
    let script_bindings = entities[0]["scriptBindings"].as_array();
    assert!(script_bindings.is_some());
    let bindings = script_bindings.unwrap();
    assert_eq!(bindings[0]["identifier"].as_str(), Some("project.enemy"));
    let params = &bindings[0]["params"];
    assert_eq!(
        params["speed"].as_f64(),
        Some(3.5),
        "findEntities must include script binding params when parametersJSON is not empty"
    );
    assert_eq!(params["patrol"].as_bool(), Some(true));
}

#[test]
fn find_entities_result_includes_transform_rotation_and_scale() {
    let e = SceneSemanticSnapshotEntity {
        position: Some(vec![1.0, 2.0, 3.0]),
        scale: Some(vec![2.0, 2.0, 2.0]),
        euler_degrees: Some(vec![45.0, 0.0, 30.0]),
        components: vec!["transform".to_string(), "mesh".to_string()],
        ..entity("scene:55", "Tilted Cube", "mesh")
    };
    let mut wv = WorldView::new();
    wv.apply_snapshot(&snapshot(1, vec![e]));
    let session = session_with_world_view("rot-scale-find", make_test_config(), wv);

    let world = session.world_view();
    let input = json!({});
    let json = session.find_entities_result(&world, input.as_object().unwrap());
    let result: Value = serde_json::from_str(&json).unwrap();
    let entities = result["entities"].as_array().unwrap();
    assert_eq!(
        value_as_float_array(&entities[0]["eulerDegrees"]),
        Some(vec![45.0, 0.0, 30.0])
    );
    assert_eq!(
        value_as_float_array(&entities[0]["scale"]),
        Some(vec![2.0, 2.0, 2.0])
    );
}

#[test]
fn find_entities_result_includes_light_color_and_range() {
    let e = SceneSemanticSnapshotEntity {
        components: vec!["light".to_string()],
        light_type: Some("directional".to_string()),
        light_intensity: Some(5.0),
        light_color: Some(vec![1.0, 0.9, 0.8]),
        light_range: Some(100.0),
        light_spot_inner: Some(15.0),
        light_spot_outer: Some(30.0),
        light_cast_shadows: Some(true),
        ..entity("scene:31", "Sun", "Directional Light")
    };
    let mut wv = WorldView::new();
    wv.apply_snapshot(&snapshot(1, vec![e]));
    let session = session_with_world_view("light-full-find", make_test_config(), wv);

    let world = session.world_view();
    let input = json!({});
    let json = session.find_entities_result(&world, input.as_object().unwrap());
    let result: Value = serde_json::from_str(&json).unwrap();
    let entity = &result["entities"].as_array().unwrap()[0];
    assert_eq!(
        value_as_float_array(&entity["lightColor"]),
        Some(vec![1.0, 0.9, 0.8])
    );
    assert_eq!(value_as_float(&entity["lightRange"]), Some(100.0));
    assert_eq!(value_as_float(&entity["lightSpotInner"]), Some(15.0));
    assert_eq!(value_as_float(&entity["lightSpotOuter"]), Some(30.0));
}

#[test]
fn find_entities_result_includes_mesh_visibility_and_material() {
    let e = SceneSemanticSnapshotEntity {
        components: vec!["mesh".to_string()],
        mesh_is_visible: Some(false),
        mesh_color: Some(vec![0.5, 0.5, 0.5]),
        material_base_color: Some(vec![0.8, 0.8, 0.8, 1.0]),
        material_metallic: Some(0.2),
        material_roughness: Some(0.6),
        material_emissive: Some(vec![0.1, 0.0, 0.0]),
        ..entity("scene:40", "Ghost", "mesh")
    };
    let mut wv = WorldView::new();
    wv.apply_snapshot(&snapshot(1, vec![e]));
    let session = session_with_world_view("mesh-mat-find", make_test_config(), wv);

    let world = session.world_view();
    let input = json!({});
    let json = session.find_entities_result(&world, input.as_object().unwrap());
    let result: Value = serde_json::from_str(&json).unwrap();
    let entity = &result["entities"].as_array().unwrap()[0];
    assert_eq!(entity["meshIsVisible"].as_bool(), Some(false));
    assert_eq!(
        value_as_float_array(&entity["meshColor"]),
        Some(vec![0.5, 0.5, 0.5])
    );
    assert_eq!(value_as_float(&entity["materialMetallic"]), Some(0.2));
    assert_eq!(value_as_float(&entity["materialRoughness"]), Some(0.6));
    assert!(
        entity.get("materialEmissive").is_some(),
        "materialEmissive must appear"
    );
}

#[test]
fn find_entities_result_includes_audio_fields() {
    let e = SceneSemanticSnapshotEntity {
        components: vec!["audio_source".to_string()],
        audio_clip: Some("ambient_music".to_string()),
        audio_volume: Some(0.8),
        audio_loop: Some(true),
        audio_play_on_awake: Some(true),
        audio_pitch: Some(1.1),
        audio_spatial_blend: Some(0.5),
        ..entity("scene:61", "Speaker", "mesh")
    };
    let mut wv = WorldView::new();
    wv.apply_snapshot(&snapshot(1, vec![e]));
    let session = session_with_world_view("audio-find", make_test_config(), wv);

    let world = session.world_view();
    let input = json!({});
    let json = session.find_entities_result(&world, input.as_object().unwrap());
    let result: Value = serde_json::from_str(&json).unwrap();
    let entity = &result["entities"].as_array().unwrap()[0];
    assert_eq!(entity["audioClip"].as_str(), Some("ambient_music"));
    assert_eq!(value_as_float(&entity["audioVolume"]), Some(0.8));
    assert_eq!(entity["audioLoop"].as_bool(), Some(true));
    assert_eq!(value_as_float(&entity["audioPitch"]), Some(1.1));
    assert_eq!(value_as_float(&entity["audioSpatialBlend"]), Some(0.5));
}

#[test]
fn find_entities_result_includes_animation_fields() {
    let e = SceneSemanticSnapshotEntity {
        components: vec!["animation".to_string()],
        animation_clip: Some("dance_loop".to_string()),
        animation_speed: Some(1.5),
        animation_loop: Some(true),
        animation_is_playing: Some(true),
        ..entity("scene:70", "Dancer", "Character")
    };
    let mut wv = WorldView::new();
    wv.apply_snapshot(&snapshot(1, vec![e]));
    let session = session_with_world_view("anim-find", make_test_config(), wv);

    let world = session.world_view();
    let input = json!({});
    let json = session.find_entities_result(&world, input.as_object().unwrap());
    let result: Value = serde_json::from_str(&json).unwrap();
    let entity = &result["entities"].as_array().unwrap()[0];
    assert_eq!(entity["animationClip"].as_str(), Some("dance_loop"));
    assert_eq!(value_as_float(&entity["animationSpeed"]), Some(1.5));
    assert_eq!(entity["animationLoop"].as_bool(), Some(true));
    assert_eq!(entity["animationIsPlaying"].as_bool(), Some(true));
}

#[test]
fn find_entities_result_includes_collider_material_and_layer_fields() {
    let e = SceneSemanticSnapshotEntity {
        components: vec!["collider".to_string()],
        collider_shape: Some("box".to_string()),
        collider_is_trigger: Some(false),
        collider_friction: Some(0.7),
        collider_restitution: Some(0.1),
        collider_layer_id: Some(3),
        collider_layer_mask: Some(15),
        ..entity("scene:80", "Wall", "mesh")
    };
    let mut wv = WorldView::new();
    wv.apply_snapshot(&snapshot(1, vec![e]));
    let session = session_with_world_view("collider-mat-find", make_test_config(), wv);

    let world = session.world_view();
    let input = json!({});
    let json = session.find_entities_result(&world, input.as_object().unwrap());
    let result: Value = serde_json::from_str(&json).unwrap();
    let entity = &result["entities"].as_array().unwrap()[0];
    assert_eq!(entity["colliderIsTrigger"].as_bool(), Some(false));
    assert_eq!(value_as_float(&entity["colliderFriction"]), Some(0.7));
    assert_eq!(value_as_float(&entity["colliderRestitution"]), Some(0.1));
    assert_eq!(entity["colliderLayerID"].as_i64(), Some(3));
    assert_eq!(entity["colliderLayerMask"].as_i64(), Some(15));
}

#[test]
fn find_entities_result_includes_rigid_body_extended_fields() {
    let e = SceneSemanticSnapshotEntity {
        components: vec!["rigidbody".to_string()],
        rigid_body_motion_type: Some("dynamic".to_string()),
        rigid_body_mass: Some(2.5),
        rigid_body_gravity_scale: Some(0.5),
        rigid_body_allow_sleep: Some(false),
        ..entity("scene:81", "Ball", "mesh")
    };
    let mut wv = WorldView::new();
    wv.apply_snapshot(&snapshot(1, vec![e]));
    let session = session_with_world_view("rb-ext-find", make_test_config(), wv);

    let world = session.world_view();
    let input = json!({});
    let json = session.find_entities_result(&world, input.as_object().unwrap());
    let result: Value = serde_json::from_str(&json).unwrap();
    let entity = &result["entities"].as_array().unwrap()[0];
    assert_eq!(value_as_float(&entity["rigidBodyGravityScale"]), Some(0.5));
    assert_eq!(entity["rigidBodyAllowSleep"].as_bool(), Some(false));
}

#[test]
fn spawn_kind_directional_light_creates_correct_light_type() {
    let scene = SceneRuntime::new(ComponentRegistry::built_in());
    let transaction = build_plan(
        r#"{"summary":"sun","steps":[{"op":"spawn_entity","label":"Sun","spawn_kind":"light","light_type":"directional"}]}"#,
        &scene,
    );
    let ops = scene_ops(&transaction);
    let has_directional = ops.iter().any(|mutation| {
        matches!(mutation, SceneMutation::SpawnLightEntity { light_type, .. }
            if *light_type == LightType::Directional)
    });
    assert!(
        has_directional,
        "spawn_kind 'light' with light_type 'directional' must produce directional light"
    );
}

// MARK: - Multi-step local scene shadow

#[test]
fn multi_step_plan_does_not_overwrite_previous_collider_changes() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let _ = scene.set_component(
        Collider::with_shape(ColliderShape::Box {
            half_extents: Float3::ONE,
            center: Float3::ZERO,
        }),
        entity,
    );
    let ref_ = entity_ref(entity);

    // Step 1: set trigger=true. Step 2: set sphere radius.
    // Without local shadow, step 2 reads original box+isTrigger=false and overwrites trigger.
    let transaction = build_plan(
        &format!(
            r#"{{"summary":"multi","steps":[{{"op":"set_collider_trigger","entity_id":"{ref_}","is_trigger":true}},{{"op":"set_collider_sphere_radius","entity_id":"{ref_}","radius":2.0}}]}}"#
        ),
        &scene,
    );
    let ops = scene_ops(&transaction);
    // The final setCollider (from step 2) should preserve isTrigger=true from step 1.
    let last_collider = ops
        .iter()
        .filter_map(|mutation| {
            mutation
                .decoded_component::<Collider>("collider")
                .map(|(_, collider)| collider)
        })
        .next_back()
        .expect("collider mutation");
    assert!(
        last_collider.is_trigger,
        "step 2's setCollider must preserve isTrigger=true set by step 1"
    );
    match last_collider.shape() {
        ColliderShape::Sphere { radius, .. } => assert_close(radius as f64, 2.0, 0.001),
        _ => panic!("final collider shape must be sphere with radius 2.0"),
    }
}

// MARK: - Spawn light with initial properties

#[test]
fn spawn_light_with_intensity_applies_initial_intensity_in_mutation() {
    let scene = SceneRuntime::new(ComponentRegistry::built_in());
    let transaction = build_plan(
        r#"{"summary":"sun","steps":[{"op":"spawn_entity","label":"Sun","spawn_kind":"light","light_type":"directional","intensity":12000}]}"#,
        &scene,
    );
    let ops = scene_ops(&transaction);
    let has_light = ops.iter().any(|mutation| {
        matches!(mutation, SceneMutation::SpawnLightEntity { initial_intensity, .. }
            if (initial_intensity.unwrap_or(0.0) - 12000.0).abs() < 1.0)
    });
    assert!(
        has_light,
        "spawn_entity with intensity must embed initialIntensity in spawnLightEntity mutation"
    );
}

#[test]
fn spawn_light_with_color_applies_initial_color_in_mutation() {
    let scene = SceneRuntime::new(ComponentRegistry::built_in());
    let transaction = build_plan(
        r#"{"summary":"red","steps":[{"op":"spawn_entity","label":"Red","spawn_kind":"light","color":[1.0,0.2,0.2]}]}"#,
        &scene,
    );
    let ops = scene_ops(&transaction);
    let has_color = ops.iter().any(|mutation| {
        matches!(mutation, SceneMutation::SpawnLightEntity { initial_color: Some(color), .. }
            if (color.x - 1.0).abs() < 0.01 && (color.y - 0.2).abs() < 0.01)
    });
    assert!(
        has_color,
        "spawn_entity with color must embed initialColor in spawnLightEntity mutation"
    );
}

#[test]
fn spawn_camera_with_fov_applies_initial_fov_in_mutation() {
    let scene = SceneRuntime::new(ComponentRegistry::built_in());
    let transaction = build_plan(
        r#"{"summary":"cam","steps":[{"op":"spawn_entity","label":"Cinematic Cam","spawn_kind":"camera","camera_fov_y":30}]}"#,
        &scene,
    );
    let ops = scene_ops(&transaction);
    let has_fov = ops.iter().any(|mutation| {
        matches!(mutation, SceneMutation::SpawnCameraEntity { initial_fov_y_degrees, .. }
            if (initial_fov_y_degrees.unwrap_or(0.0) - 30.0).abs() < 0.01)
    });
    assert!(
        has_fov,
        "spawn_entity camera with camera_fov_y must embed initialFovYDegrees in spawnCameraEntity mutation"
    );
}

// MARK: - spawn_entity with spawn_parent_id

#[test]
fn spawn_entity_with_parent_id_passes_parent_to_mutation() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let parent = scene.create_entity();
    let parent_ref = entity_ref(parent);

    let transaction = build_plan(
        &format!(
            r#"{{"summary":"child","steps":[{{"op":"spawn_entity","label":"Child","spawn_kind":"empty","spawn_parent_id":"{parent_ref}"}}]}}"#
        ),
        &scene,
    );
    let ops = scene_ops(&transaction);
    let has_parent = ops.iter().any(|mutation| {
        matches!(mutation, SceneMutation::SpawnEmptyEntity { label, parent_id, .. }
            if label == "Child" && *parent_id == Some(parent.raw_value()))
    });
    assert!(
        has_parent,
        "spawn_entity with spawn_parent_id must embed parentID in spawnEmptyEntity mutation"
    );
}

#[test]
fn spawn_light_with_parent_id_passes_parent_to_mutation() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let parent = scene.create_entity();
    let parent_ref = entity_ref(parent);

    let transaction = build_plan(
        &format!(
            r#"{{"summary":"child light","steps":[{{"op":"spawn_entity","label":"Child Light","spawn_kind":"light","spawn_parent_id":"{parent_ref}"}}]}}"#
        ),
        &scene,
    );
    let ops = scene_ops(&transaction);
    let has_parent = ops.iter().any(|mutation| {
        matches!(mutation, SceneMutation::SpawnLightEntity { parent_id, .. }
            if *parent_id == Some(parent.raw_value()))
    });
    assert!(
        has_parent,
        "spawn_entity light with spawn_parent_id must embed parentID in spawnLightEntity mutation"
    );
}

#[test]
fn spawn_entity_without_parent_id_has_nil_parent() {
    let scene = SceneRuntime::new(ComponentRegistry::built_in());
    let transaction = build_plan(
        r#"{"summary":"root","steps":[{"op":"spawn_entity","label":"Root","spawn_kind":"empty"}]}"#,
        &scene,
    );
    let ops = scene_ops(&transaction);
    let has_nil_parent = ops.iter().any(|mutation| {
        matches!(mutation, SceneMutation::SpawnEmptyEntity { parent_id, .. } if parent_id.is_none())
    });
    assert!(
        has_nil_parent,
        "spawn_entity without spawn_parent_id must have nil parentID"
    );
}

#[test]
fn spawn_entity_with_invalid_parent_ref_throws() {
    let scene = SceneRuntime::new(ComponentRegistry::built_in());
    let plan: SceneEditPlan = serde_json::from_str(
        r#"{"summary":"bad","steps":[{"op":"spawn_entity","label":"X","spawn_parent_id":"scene:99999"}]}"#,
    )
    .unwrap();
    let result = SceneEditPlanExecutor::new().build_transaction_with_defaults(&plan, &scene);
    assert!(
        result.is_err(),
        "spawn_entity with non-existent spawn_parent_id must throw entityNotFound"
    );
}

// MARK: - AssetCatalog

#[test]
fn asset_catalog_audio_clips_appear_in_system_prompt_section() {
    let catalog = AssetCatalog::new(
        vec!["explosion".to_string(), "footstep".to_string()],
        vec![],
        vec![],
    );
    let section = catalog.system_prompt_section();
    assert!(section.contains("explosion"), "audio clip name must appear");
    assert!(
        section.contains("footstep"),
        "second audio clip name must appear"
    );
    assert!(
        section.contains("set_audio_source"),
        "usage hint must reference set_audio_source"
    );
}

#[test]
fn asset_catalog_animation_clips_appear_in_system_prompt_section() {
    let catalog = AssetCatalog::new(vec![], vec!["run".to_string(), "idle".to_string()], vec![]);
    let section = catalog.system_prompt_section();
    assert!(section.contains("run"), "animation clip name must appear");
    assert!(
        section.contains("idle"),
        "second animation clip name must appear"
    );
    assert!(
        section.contains("set_animation_player"),
        "usage hint must reference set_animation_player"
    );
}

#[test]
fn asset_catalog_mesh_names_appear_in_system_prompt_section() {
    let catalog = AssetCatalog::new(
        vec![],
        vec![],
        vec!["DragonMesh".to_string(), "RockProp".to_string()],
    );
    let section = catalog.system_prompt_section();
    assert!(section.contains("DragonMesh"), "mesh name must appear");
    assert!(section.contains("RockProp"), "second mesh name must appear");
}

#[test]
fn asset_catalog_empty_produces_no_section() {
    let catalog = AssetCatalog::with_defaults();
    assert!(catalog.is_empty(), "default catalog must be empty");
    assert!(
        catalog.system_prompt_section().is_empty(),
        "empty catalog must produce empty section string"
    );
}

#[test]
fn asset_catalog_is_empty_false_when_any_field_populated() {
    assert!(!AssetCatalog::new(vec!["sfx".to_string()], vec![], vec![]).is_empty());
    assert!(!AssetCatalog::new(vec![], vec!["walk".to_string()], vec![]).is_empty());
    assert!(!AssetCatalog::new(vec![], vec![], vec!["cube".to_string()]).is_empty());
}

#[test]
fn session_config_asset_catalog_appears_in_system_prompt_request() {
    let server = FixtureHttpServer::start(|_, _| EDIT_PLAN_OK.as_bytes().to_vec());
    let mut config = make_test_config();
    config.asset_catalog = AssetCatalog::new(
        vec!["gun_shot".to_string()],
        vec!["sprint".to_string()],
        vec![],
    );
    config.base_url = server.base_url().to_string();
    let session = Session::new(
        Some("ac1".to_string()),
        config,
        None,
        None,
        None,
        None,
        None,
        None,
        None,
    );

    let signal = Signal::NaturalLanguage {
        text: "play a sound".to_string(),
        locale: "en".to_string(),
    };
    let _ = session.process_with_defaults(&signal).unwrap();

    let json = server.request_json(0);
    let system_text = json["system"].as_str().unwrap_or("");
    assert!(
        system_text.contains("gun_shot"),
        "audio clip name must appear in system prompt sent to API"
    );
    assert!(
        system_text.contains("sprint"),
        "animation clip name must appear in system prompt sent to API"
    );
}
