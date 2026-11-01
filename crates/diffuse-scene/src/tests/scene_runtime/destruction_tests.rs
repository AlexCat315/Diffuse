//! Ported from `Engine/Tests/SceneRuntimeTests/DestructionTests.swift`.
//!
//! Two Swift/Rust differences shape this file:
//!
//! - Swift's `tick(deltaTime:)` carries no frame index; the Rust schedule takes one
//!   plus the frame's input events. No phase reads the index, so a constant frame
//!   stands in for it here and the deltas stay exactly as authored.
//! - Swift's `runtime.resource(_:)` hands the test a copy, so a mutation must be
//!   written back with `setResource`. `SceneRuntime::resource` clones the same way,
//!   so every helper here edits the clone and then calls `set_resource`.
//!
//! The runtime sorts fragments and connections before budget truncation, so the
//! reversed fragment order installed by `configure_localized_loop` is deliberate:
//! it pins the sort-before-truncate contract rather than the authored order.

use std::collections::BTreeMap;

use diffuse_math::simd::simd_compat::Float3;

use crate::components::core::registry::ComponentRegistry;
use crate::entity_id::EntityID;
use crate::physics::backend::physics_backend_kind::PhysicsBackendKind;
use crate::physics::collider::{Collider, ColliderShape, ColliderShapeKind, PhysicsMaterial};
use crate::physics::destruction::{
    Destructible, DestructibleAsset, DestructibleAssetResource, DestructibleConnectionAsset,
    DestructibleFragment, DestructibleFragmentAsset, DestructibleRetainedFragment,
    DestructionCause, DestructionCommand, DestructionFailureReason, DestructionRecycleReason,
    DestructionSettingsResource, DestructionSourceState,
};
use crate::physics::physics_settings::{PhysicsCapacitySettings, PhysicsSettingsResource};
use crate::physics::physics_types::PhysicsSimulationMode;
use crate::physics::queries::spatial_queries::{
    MeshColliderGeometry, MeshColliderGeometryResource,
};
use crate::physics::rigid_body::{RigidBody, RigidBodyMotionType, RigidBodyOptions};
use crate::rendering::render_extraction::RenderMeshComponent;
use crate::runtime_world::LocalTransform;
use crate::scene_graph::prefab::Prefab;
use crate::scene_runtime::SceneRuntime;
use crate::scheduling::schedule_report::RuntimeScheduleReport;
use crate::serialization::game_save::GameSave;
use crate::serialization::scene_serializer::SceneSerializer;

const RESOURCE_ID: &str = "wall.prefractured";
const DELTA_TIME: f64 = 1.0 / 60.0;

/// Swift's `tick(deltaTime:)`; see the module note about the frame index.
fn tick(runtime: &mut SceneRuntime, delta_time_seconds: f64) -> RuntimeScheduleReport {
    runtime.tick(delta_time_seconds, 0, Vec::new())
}

fn new_runtime() -> SceneRuntime {
    SceneRuntime::new(ComponentRegistry::built_in())
}

fn force_fracture_command(entity: EntityID) -> DestructionCommand {
    DestructionCommand::new(entity, 0.0, Float3::ZERO, None, true)
}

fn impulse_command(
    entity: EntityID,
    impulse: Float3,
    world_point: Option<Float3>,
) -> DestructionCommand {
    DestructionCommand::new(entity, 0.0, impulse, world_point, false)
}

fn state_of(runtime: &SceneRuntime, source: EntityID) -> Option<DestructionSourceState> {
    runtime
        .destruction_state_frame()
        .sources
        .get(&source)
        .cloned()
}

fn fragment_entities(runtime: &SceneRuntime) -> Vec<EntityID> {
    runtime.entities_with::<DestructibleFragment>()
}

/// Swift's defaults: 8 fragments, 30 s lifetime, 5 s sleep delay, no connection
/// impulse threshold.
fn make_runtime() -> (SceneRuntime, EntityID) {
    make_runtime_with(8, 30.0, 5.0, 0.0)
}

fn make_runtime_with(
    fragment_budget: i64,
    maximum_lifetime: f32,
    sleeping_recycle_delay: f32,
    connection_impulse_threshold: f32,
) -> (SceneRuntime, EntityID) {
    let mut runtime = new_runtime();
    runtime.set_physics_settings(PhysicsSettingsResource {
        simulation_mode: PhysicsSimulationMode::Play,
        backend_kind: PhysicsBackendKind::preferred(),
        gravity: Float3::ZERO,
        fixed_time_step_seconds: DELTA_TIME,
        max_substeps_per_frame: 1,
        allow_sleep: true,
        collision_steps: 1,
        capacity: PhysicsCapacitySettings::new(65_536, 1),
    });

    let positions = vec![
        Float3::new(-0.2, -0.2, -0.2),
        Float3::new(0.2, -0.2, -0.2),
        Float3::new(0.0, 0.2, -0.2),
        Float3::new(0.0, 0.0, 0.2),
    ];
    let triangle_indices = vec![0, 2, 1, 0, 1, 3, 1, 2, 3, 2, 0, 3];
    let geometry =
        MeshColliderGeometry::new(positions, triangle_indices, Vec::new(), Vec::new(), None, 0);

    let mut fragments = Vec::new();
    for index in 0..3u32 {
        let resource_id = format!("fragment.{index}");
        let translation = Float3::new((index as f32 - 1.0) * 0.5, 0.0, 0.0);
        fragments.push(DestructibleFragmentAsset::new(
            index,
            resource_id,
            LocalTransform::from_translation(translation),
            (index + 1) as f32,
            None,
            None,
        ));
    }
    let asset = DestructibleAsset::new(
        7,
        fragments,
        vec![
            DestructibleConnectionAsset::new(10, 0, 1, 0.0, connection_impulse_threshold),
            DestructibleConnectionAsset::new(11, 1, 2, 0.0, 50.0),
        ],
    );
    runtime.set_resource(MeshColliderGeometryResource::new(
        BTreeMap::from([
            ("fragment.0".to_string(), geometry.clone()),
            ("fragment.1".to_string(), geometry.clone()),
            ("fragment.2".to_string(), geometry),
        ]),
        None,
    ));
    runtime.set_resource(DestructibleAssetResource::new(BTreeMap::from([(
        RESOURCE_ID.to_string(),
        asset,
    )])));

    let source = runtime.create_entity();
    runtime.set_local_transform(
        LocalTransform::from_translation(Float3::new(2.0, 3.0, 4.0)),
        source,
    );
    let mut collider = Collider::with_shape(ColliderShape::Box {
        half_extents: Float3::new(0.75, 0.5, 0.5),
        center: Float3::ZERO,
    });
    collider.layer_id = 3;
    collider.material = PhysicsMaterial::new(0.8, 0.1, 1.0);
    runtime.set_component(collider, source);
    runtime.set_component(
        RigidBody::new(RigidBodyOptions {
            motion_type: RigidBodyMotionType::Static,
            ..RigidBodyOptions::default()
        }),
        source,
    );
    runtime.set_component(
        RenderMeshComponent::new(42, true, Float3::splat(1.0), None, Vec::new()),
        source,
    );
    runtime.set_component(
        Destructible::new(
            RESOURCE_ID,
            10.0,
            10.0,
            fragment_budget,
            maximum_lifetime,
            sleeping_recycle_delay,
            0.0,
            true,
        ),
        source,
    );
    (runtime, source)
}

/// A three-fragment loop whose edges all break at impulse 2, so localized hits can
/// detach edges while the entity-level thresholds stay out of reach.
fn configure_localized_loop(runtime: &mut SceneRuntime, source: EntityID) {
    let mut assets = runtime
        .resource::<DestructibleAssetResource>()
        .expect("destructible asset resource");
    let asset = assets
        .assets_by_resource_id
        .get_mut(RESOURCE_ID)
        .expect("destructible asset");
    asset.connections = vec![
        DestructibleConnectionAsset::new(12, 0, 2, 0.0, 2.0),
        DestructibleConnectionAsset::new(11, 1, 2, 0.0, 2.0),
        DestructibleConnectionAsset::new(10, 0, 1, 0.0, 2.0),
    ];
    // Swift reverses in place without re-sorting; the runtime sorts before it
    // truncates, so this only proves order independence.
    asset.fragments.reverse();
    runtime.set_resource(assets);
    runtime.update_component::<Destructible>(source, |destructible| {
        destructible.damage_threshold = 100.0;
        destructible.impulse_threshold = 100.0;
    });
}

/// Every fragment gets a render mesh, which is the precondition for the incremental
/// compound-island path.
fn configure_fragment_rendering(runtime: &mut SceneRuntime) {
    let mut assets = runtime
        .resource::<DestructibleAssetResource>()
        .expect("destructible asset resource");
    let asset = assets
        .assets_by_resource_id
        .get_mut(RESOURCE_ID)
        .expect("destructible asset");
    for fragment in &mut asset.fragments {
        fragment.render_mesh = Some(RenderMeshComponent::new(
            100 + fragment.fragment_id as i64,
            true,
            Float3::splat(1.0),
            None,
            Vec::new(),
        ));
    }
    runtime.set_resource(assets);
}

/// Damage accumulates and fragments participate in the current physics prepare.
#[test]
fn current_frame_activation() {
    let (mut runtime, source) = make_runtime();
    runtime.submit_destruction_command(DestructionCommand::new(
        source,
        4.0,
        Float3::ZERO,
        None,
        false,
    ));
    tick(&mut runtime, DELTA_TIME);
    assert!(runtime.destruction_event_frame().events.is_empty());
    assert_eq!(
        state_of(&runtime, source).map(|state| state.accumulated_damage),
        Some(4.0)
    );

    runtime.submit_destruction_command(DestructionCommand::new(
        source,
        6.0,
        Float3::ZERO,
        None,
        false,
    ));
    let report = tick(&mut runtime, DELTA_TIME);
    let event = runtime
        .destruction_event_frame()
        .events
        .first()
        .cloned()
        .expect("destruction event");
    assert_eq!(event.cause, DestructionCause::Damage);
    assert_eq!(event.fragment_ids, vec![0, 1, 2]);
    assert_eq!(event.broken_connection_ids, vec![10, 11]);
    assert_eq!(report.physics.body_count, 3);
    assert!(runtime.component::<Collider>(source).is_none());
    assert!(runtime.component::<RigidBody>(source).is_none());
    assert_eq!(
        runtime
            .component::<RenderMeshComponent>(source)
            .map(|mesh| mesh.is_visible),
        Some(false)
    );
    assert_eq!(
        state_of(&runtime, source).map(|state| state.has_fractured),
        Some(true)
    );
    assert_eq!(runtime.destruction_state_frame().active_fragment_count(), 3);
    for (index, entity) in event.fragment_entities.iter().enumerate() {
        assert_eq!(
            runtime
                .component::<DestructibleFragment>(*entity)
                .map(|fragment| fragment.fragment_id),
            Some(index as u32)
        );
        assert_eq!(
            runtime
                .component::<RigidBody>(*entity)
                .map(|body| body.motion_type),
            Some(RigidBodyMotionType::Dynamic)
        );
        assert_eq!(
            runtime
                .component::<Collider>(*entity)
                .map(|collider| collider.layer_id),
            Some(3)
        );
    }
    let positions: Vec<f32> = event
        .fragment_entities
        .iter()
        .filter_map(|entity| {
            runtime
                .world_transform(*entity)
                .map(|transform| transform.translation().x)
        })
        .collect();
    assert_eq!(positions, vec![1.5, 2.0, 2.5]);
}

/// A low-threshold connection can detach before the entity threshold.
#[test]
fn connection_graph_activation() {
    let (mut runtime, source) = make_runtime_with(8, 30.0, 5.0, 2.0);
    runtime.submit_destruction_command(impulse_command(source, Float3::new(3.0, 0.0, 0.0), None));
    tick(&mut runtime, DELTA_TIME);
    let event = runtime
        .destruction_event_frame()
        .events
        .first()
        .cloned()
        .expect("destruction event");
    assert_eq!(event.cause, DestructionCause::ConnectionBreak);
    assert_eq!(event.applied_impulse, 3.0);
    assert_eq!(event.broken_connection_ids, vec![10, 11]);
}

/// Localized hits break the nearest eligible edge before the graph disconnects.
#[test]
fn localized_connection_breaking() {
    let (mut runtime, source) = make_runtime();
    configure_localized_loop(&mut runtime, source);

    runtime.submit_destruction_command(impulse_command(
        source,
        Float3::new(3.0, 0.0, 0.0),
        Some(Float3::new(1.875, 3.0, 4.0)),
    ));
    tick(&mut runtime, 0.0);

    let edge_event = runtime
        .destruction_event_frame()
        .events
        .first()
        .cloned()
        .expect("edge event");
    assert_eq!(edge_event.cause, DestructionCause::ConnectionBreak);
    assert!(edge_event.fragment_entities.is_empty());
    assert_eq!(edge_event.broken_connection_ids, vec![10]);
    assert_eq!(
        state_of(&runtime, source).map(|state| state.has_fractured),
        Some(false)
    );
    assert_eq!(
        state_of(&runtime, source).map(|state| state.broken_connection_ids),
        Some(vec![10])
    );
    assert!(fragment_entities(&runtime).is_empty());
    assert!(runtime.component::<RigidBody>(source).is_some());
    let partial_debug = runtime.physics_debug_frame().destruction_connections;
    assert_eq!(
        partial_debug
            .iter()
            .map(|connection| connection.connection_id)
            .collect::<Vec<_>>(),
        vec![10, 11, 12]
    );
    assert_eq!(
        partial_debug
            .iter()
            .map(|connection| connection.is_broken)
            .collect::<Vec<_>>(),
        vec![true, false, false]
    );
    assert!(
        partial_debug
            .iter()
            .all(|connection| !connection.is_source_fractured)
    );
    assert_eq!(partial_debug[0].world_point_a, Float3::new(1.5, 3.0, 4.0));
    assert_eq!(partial_debug[0].world_point_b, Float3::new(2.0, 3.0, 4.0));

    runtime.submit_destruction_command(impulse_command(
        source,
        Float3::new(3.0, 0.0, 0.0),
        Some(Float3::new(2.0, 3.0, 4.0)),
    ));
    tick(&mut runtime, 0.0);

    let fracture_event = runtime
        .destruction_event_frame()
        .events
        .first()
        .cloned()
        .expect("fracture event");
    assert_eq!(fracture_event.cause, DestructionCause::ConnectionBreak);
    assert_eq!(fracture_event.fragment_ids, vec![0, 1, 2]);
    assert_eq!(fracture_event.broken_connection_ids, vec![10, 11, 12]);
    assert_eq!(
        state_of(&runtime, source).map(|state| state.has_fractured),
        Some(true)
    );
    let fractured_debug = runtime.physics_debug_frame().destruction_connections;
    assert_eq!(
        fractured_debug
            .iter()
            .map(|connection| connection.is_broken)
            .collect::<Vec<_>>(),
        vec![true, true, true]
    );
    assert!(
        fractured_debug
            .iter()
            .all(|connection| connection.is_source_fractured)
    );
}

/// Render-complete assets release detached islands and retain a compound root.
#[test]
fn incremental_island_release() {
    let (mut runtime, source) = make_runtime();
    configure_localized_loop(&mut runtime, source);
    configure_fragment_rendering(&mut runtime);

    runtime.submit_destruction_command(impulse_command(
        source,
        Float3::new(3.0, 0.0, 0.0),
        Some(Float3::new(1.875, 3.0, 4.0)),
    ));
    tick(&mut runtime, 0.0);
    assert_eq!(
        state_of(&runtime, source).map(|state| state.has_fractured),
        Some(false)
    );

    runtime.submit_destruction_command(impulse_command(
        source,
        Float3::new(3.0, 0.0, 0.0),
        Some(Float3::new(2.0, 3.0, 4.0)),
    ));
    let partial_report = tick(&mut runtime, 0.0);

    let event = runtime
        .destruction_event_frame()
        .events
        .first()
        .cloned()
        .expect("destruction event");
    assert_eq!(event.cause, DestructionCause::ConnectionBreak);
    assert_eq!(event.fragment_ids, vec![1, 2]);
    assert_eq!(event.broken_connection_ids, vec![11, 12]);
    assert_eq!(partial_report.physics.body_count, 3);
    let state = state_of(&runtime, source).expect("source state");
    assert!(state.has_fractured);
    assert!(!state.is_fully_fractured);
    assert_eq!(state.broken_connection_ids, vec![10, 11, 12]);
    assert_eq!(state.released_fragment_ids, vec![1, 2]);
    assert_eq!(state.retained_fragment_ids, vec![0]);
    assert_eq!(state.active_fragment_ids, vec![1, 2]);

    let source_collider = runtime
        .component::<Collider>(source)
        .expect("source collider");
    assert_eq!(source_collider.shapes.len(), 1);
    assert_eq!(
        source_collider.shapes[0].shape.resource_id(),
        Some("fragment.0")
    );
    assert_eq!(
        source_collider.shapes[0].local_position,
        Float3::new(-0.5, 0.0, 0.0)
    );
    assert!(runtime.component::<RigidBody>(source).is_some());
    assert_eq!(
        runtime
            .component::<RenderMeshComponent>(source)
            .map(|mesh| mesh.is_visible),
        Some(false)
    );

    let proxies = runtime.entities_with::<DestructibleRetainedFragment>();
    assert_eq!(proxies.len(), 1);
    let proxy = proxies[0];
    assert_eq!(runtime.parent(proxy), Some(source));
    assert_eq!(
        runtime
            .component::<DestructibleRetainedFragment>(proxy)
            .map(|retained| retained.fragment_id),
        Some(0)
    );
    assert_eq!(
        runtime
            .component::<RenderMeshComponent>(proxy)
            .map(|mesh| mesh.mesh_index),
        Some(100)
    );
    assert_eq!(
        runtime
            .local_transform(proxy)
            .map(|transform| transform.translation()),
        Some(Float3::new(-0.5, 0.0, 0.0))
    );

    runtime.submit_destruction_command(force_fracture_command(source));
    tick(&mut runtime, 0.0);
    let final_event = runtime
        .destruction_event_frame()
        .events
        .first()
        .cloned()
        .expect("final event");
    assert_eq!(final_event.fragment_ids, vec![0]);
    assert!(
        runtime
            .entities_with::<DestructibleRetainedFragment>()
            .is_empty()
    );
    assert_eq!(fragment_entities(&runtime).len(), 3);
    assert!(runtime.component::<Collider>(source).is_none());
    let final_state = state_of(&runtime, source).expect("final source state");
    assert!(final_state.is_fully_fractured);
    assert_eq!(final_state.released_fragment_ids, vec![0, 1, 2]);
    assert!(final_state.retained_fragment_ids.is_empty());
    assert_eq!(final_state.active_fragment_ids, vec![0, 1, 2]);
}

/// Incremental island budgets never recreate a dropped fragment.
#[test]
fn incremental_island_budget() {
    let (mut runtime, source) = make_runtime_with(1, 0.01, 0.0, 0.0);
    configure_localized_loop(&mut runtime, source);
    configure_fragment_rendering(&mut runtime);
    runtime.submit_destruction_command(impulse_command(
        source,
        Float3::new(3.0, 0.0, 0.0),
        Some(Float3::new(1.875, 3.0, 4.0)),
    ));
    tick(&mut runtime, 0.0);
    runtime.submit_destruction_command(impulse_command(
        source,
        Float3::new(3.0, 0.0, 0.0),
        Some(Float3::new(2.0, 3.0, 4.0)),
    ));
    tick(&mut runtime, 0.0);

    let partial_event = runtime
        .destruction_event_frame()
        .events
        .first()
        .cloned()
        .expect("partial event");
    assert_eq!(partial_event.fragment_ids, vec![1]);
    assert_eq!(partial_event.dropped_fragment_count, 1);
    assert_eq!(
        state_of(&runtime, source).map(|state| state.released_fragment_ids),
        Some(vec![1, 2])
    );
    assert_eq!(
        state_of(&runtime, source).map(|state| state.active_fragment_ids),
        Some(vec![1])
    );

    tick(&mut runtime, 0.02);
    assert!(fragment_entities(&runtime).is_empty());
    runtime.submit_destruction_command(force_fracture_command(source));
    tick(&mut runtime, 0.0);
    assert_eq!(
        runtime
            .destruction_event_frame()
            .events
            .first()
            .map(|event| event.fragment_ids.clone()),
        Some(vec![0])
    );
    assert_eq!(
        fragment_entities(&runtime)
            .into_iter()
            .filter_map(|entity| {
                runtime
                    .component::<DestructibleFragment>(entity)
                    .map(|fragment| fragment.fragment_id)
            })
            .collect::<Vec<_>>(),
        vec![0]
    );
    assert_eq!(
        state_of(&runtime, source).map(|state| state.released_fragment_ids),
        Some(vec![0, 1, 2])
    );
}

/// Removing a partially fractured source cleans proxies and owned fragments.
#[test]
fn partial_island_source_removal() {
    let (mut runtime, source) = make_runtime_with(8, 0.0, 0.0, 0.0);
    configure_localized_loop(&mut runtime, source);
    configure_fragment_rendering(&mut runtime);
    runtime.submit_destruction_command(impulse_command(
        source,
        Float3::new(3.0, 0.0, 0.0),
        Some(Float3::new(1.875, 3.0, 4.0)),
    ));
    tick(&mut runtime, 0.0);
    runtime.submit_destruction_command(impulse_command(
        source,
        Float3::new(3.0, 0.0, 0.0),
        Some(Float3::new(2.0, 3.0, 4.0)),
    ));
    tick(&mut runtime, 0.0);
    assert_eq!(
        runtime
            .entities_with::<DestructibleRetainedFragment>()
            .len(),
        1
    );
    assert!(runtime.destroy_entity(source));

    tick(&mut runtime, 0.0);
    assert!(
        runtime
            .entities_with::<DestructibleRetainedFragment>()
            .is_empty()
    );
    assert!(fragment_entities(&runtime).is_empty());
    let frame = runtime.destruction_event_frame();
    assert_eq!(frame.recycled_fragments.len(), 2);
    assert!(
        frame
            .recycled_fragments
            .iter()
            .all(|event| event.reason == DestructionRecycleReason::SourceRemoved)
    );
}

/// Fragment budgets use stable fragment-ID truncation.
#[test]
fn stable_budget() {
    let (mut runtime, source) = make_runtime_with(2, 30.0, 5.0, 0.0);
    runtime.set_resource(DestructionSettingsResource::new(2, 1_024));
    runtime.submit_destruction_command(force_fracture_command(source));
    tick(&mut runtime, DELTA_TIME);
    let event = runtime
        .destruction_event_frame()
        .events
        .first()
        .cloned()
        .expect("destruction event");
    assert_eq!(event.fragment_ids, vec![0, 1]);
    assert_eq!(event.dropped_fragment_count, 1);
    assert_eq!(runtime.destruction_state_frame().active_fragment_count(), 2);
}

/// Natsel contact impulses trigger destruction through the unified listener.
#[test]
fn contact_impulse_activation() {
    let (mut runtime, source) = make_runtime();
    runtime.update_component::<Destructible>(source, |destructible| {
        destructible.damage_threshold = 10_000.0;
        destructible.impulse_threshold = 0.01;
    });
    let projectile = runtime.create_entity();
    runtime.set_local_transform(
        LocalTransform::from_translation(Float3::new(2.0, 3.0, 0.0)),
        projectile,
    );
    runtime.set_component(
        Collider::with_shape(ColliderShape::Sphere {
            radius: 0.35,
            center: Float3::ZERO,
        }),
        projectile,
    );
    runtime.set_component(
        RigidBody::new(RigidBodyOptions {
            mass: 2.0,
            linear_velocity: Float3::new(0.0, 0.0, 20.0),
            allow_sleep: false,
            continuous_collision_detection: true,
            ..RigidBodyOptions::default()
        }),
        projectile,
    );
    let mut destruction_event = None;
    for frame in 0..30u64 {
        let report = runtime.tick(DELTA_TIME, frame, Vec::new());
        assert!(report.physics.error.is_none());
        destruction_event = runtime.destruction_event_frame().events.first().cloned();
        if destruction_event.is_some() {
            break;
        }
    }
    let event = destruction_event.expect("contact destruction event");
    assert_eq!(event.source_entity, source);
    assert_eq!(event.cause, DestructionCause::ContactImpulse);
    assert!(event.applied_impulse > 0.0);
}

/// Missing and invalid assets fail without replacing the intact body.
#[test]
fn invalid_assets() {
    let (mut runtime, source) = make_runtime();
    runtime.update_component::<Destructible>(source, |destructible| {
        destructible.asset_resource_id = "missing.asset".to_string();
    });
    runtime.submit_destruction_command(force_fracture_command(source));
    tick(&mut runtime, 0.0);
    assert_eq!(
        runtime
            .destruction_event_frame()
            .failures
            .first()
            .map(|failure| failure.reason),
        Some(DestructionFailureReason::MissingAsset)
    );
    assert!(runtime.component::<Collider>(source).is_some());
    assert!(runtime.component::<RigidBody>(source).is_some());

    runtime.update_component::<Destructible>(source, |destructible| {
        destructible.asset_resource_id = RESOURCE_ID.to_string();
    });
    let mut assets = runtime
        .resource::<DestructibleAssetResource>()
        .expect("destructible asset resource");
    assets
        .assets_by_resource_id
        .get_mut(RESOURCE_ID)
        .expect("destructible asset")
        .connections[0]
        .damage_threshold = f32::NAN;
    runtime.set_resource(assets);
    runtime.submit_destruction_command(force_fracture_command(source));
    tick(&mut runtime, 0.0);
    assert_eq!(
        runtime
            .destruction_event_frame()
            .failures
            .first()
            .map(|failure| failure.reason),
        Some(DestructionFailureReason::InvalidAsset)
    );
    assert!(runtime.component::<RigidBody>(source).is_some());

    let mut assets = runtime
        .resource::<DestructibleAssetResource>()
        .expect("destructible asset resource");
    assets
        .assets_by_resource_id
        .get_mut(RESOURCE_ID)
        .expect("destructible asset")
        .connections[0]
        .damage_threshold = 0.0;
    runtime.set_resource(assets);
    runtime.set_resource(MeshColliderGeometryResource::default());
    runtime.submit_destruction_command(force_fracture_command(source));
    tick(&mut runtime, 0.0);
    assert_eq!(
        runtime
            .destruction_event_frame()
            .failures
            .first()
            .map(|failure| failure.reason),
        Some(DestructionFailureReason::InvalidAsset)
    );
    assert!(runtime.component::<Collider>(source).is_some());
}

/// Non-finite commands and mutated policies fail before replacing the intact body.
#[test]
fn invalid_command_and_configuration() {
    let (mut runtime, source) = make_runtime();
    // Swift mutates the stored property after `init`, bypassing the clamp; keep the
    // same escape hatch so the runtime really sees the NaN.
    let mut invalid_command = DestructionCommand::new(source, 0.0, Float3::ZERO, None, true);
    invalid_command.damage = f32::NAN;
    runtime.submit_destruction_command(invalid_command);
    tick(&mut runtime, 0.0);
    assert_eq!(
        runtime
            .destruction_event_frame()
            .failures
            .first()
            .map(|failure| failure.reason),
        Some(DestructionFailureReason::InvalidCommand)
    );
    assert!(runtime.component::<RigidBody>(source).is_some());

    runtime.update_component::<Destructible>(source, |destructible| {
        destructible.separation_impulse = f32::INFINITY;
    });
    runtime.submit_destruction_command(force_fracture_command(source));
    tick(&mut runtime, 0.0);
    assert_eq!(
        runtime
            .destruction_event_frame()
            .failures
            .first()
            .map(|failure| failure.reason),
        Some(DestructionFailureReason::InvalidConfiguration)
    );
    assert!(runtime.component::<Collider>(source).is_some());
    assert!(runtime.component::<RigidBody>(source).is_some());
}

/// A mutable partially connected asset is rejected before activation.
#[test]
fn disconnected_mutable_asset() {
    let (mut runtime, source) = make_runtime();
    let mut assets = runtime
        .resource::<DestructibleAssetResource>()
        .expect("destructible asset resource");
    assets
        .assets_by_resource_id
        .get_mut(RESOURCE_ID)
        .expect("destructible asset")
        .connections = vec![DestructibleConnectionAsset::unthresholded(10, 0, 1)];
    runtime.set_resource(assets);

    runtime.submit_destruction_command(force_fracture_command(source));
    tick(&mut runtime, 0.0);

    let failure = runtime
        .destruction_event_frame()
        .failures
        .first()
        .cloned()
        .expect("failure");
    assert_eq!(failure.reason, DestructionFailureReason::InvalidAsset);
    assert!(failure.message.contains("initially disconnected"));
    assert!(runtime.component::<Collider>(source).is_some());
    assert!(runtime.component::<RigidBody>(source).is_some());
    assert!(fragment_entities(&runtime).is_empty());
}

/// Finite damage accumulation saturates instead of overflowing.
#[test]
fn saturating_damage() {
    let (mut runtime, source) = make_runtime();
    runtime.update_component::<Destructible>(source, |destructible| {
        destructible.damage_threshold = 0.0;
        destructible.impulse_threshold = 0.0;
    });
    for _ in 0..2 {
        runtime.submit_destruction_command(DestructionCommand::new(
            source,
            f32::MAX,
            Float3::ZERO,
            None,
            false,
        ));
        tick(&mut runtime, 0.0);
    }

    let damage = state_of(&runtime, source).map(|state| state.accumulated_damage);
    assert_eq!(damage, Some(f32::MAX));
    assert_eq!(damage.map(|value| value.is_finite()), Some(true));
    assert_eq!(
        state_of(&runtime, source).map(|state| state.has_fractured),
        Some(false)
    );
}

/// Fragments recycle after their maximum lifetime.
#[test]
fn lifetime_recycle() {
    let (mut runtime, source) = make_runtime_with(8, 0.02, 0.0, 0.0);
    runtime.submit_destruction_command(force_fracture_command(source));
    tick(&mut runtime, 0.001);
    let fragments = runtime
        .destruction_event_frame()
        .events
        .first()
        .map(|event| event.fragment_entities.clone())
        .expect("fragment entities");
    tick(&mut runtime, 0.03);
    let frame = runtime.destruction_event_frame();
    assert_eq!(frame.recycled_fragments.len(), 3);
    assert!(
        frame
            .recycled_fragments
            .iter()
            .all(|event| event.reason == DestructionRecycleReason::LifetimeExpired)
    );
    assert!(fragments.iter().all(|entity| !runtime.contains(*entity)));
    assert_eq!(runtime.destruction_state_frame().active_fragment_count(), 0);
}

/// Sleeping and removed-source policies recycle owned fragments.
#[test]
fn sleeping_and_source_recycle() {
    let (mut runtime, source) = make_runtime_with(8, 0.0, 0.01, 0.0);
    runtime.submit_destruction_command(force_fracture_command(source));
    tick(&mut runtime, 0.001);
    let fragments = runtime
        .destruction_event_frame()
        .events
        .first()
        .map(|event| event.fragment_entities.clone())
        .expect("fragment entities");
    for fragment in &fragments {
        assert!(runtime.sleep_rigid_body(*fragment));
    }
    tick(&mut runtime, 0.001);
    tick(&mut runtime, 0.02);
    assert!(
        runtime
            .destruction_event_frame()
            .recycled_fragments
            .iter()
            .all(|event| event.reason == DestructionRecycleReason::Sleeping)
    );

    let (mut second_runtime, second_source) = make_runtime_with(8, 0.0, 0.0, 0.0);
    second_runtime.submit_destruction_command(force_fracture_command(second_source));
    tick(&mut second_runtime, 0.0);
    let second_fragments = second_runtime
        .destruction_event_frame()
        .events
        .first()
        .map(|event| event.fragment_entities.clone())
        .expect("fragment entities");
    assert!(second_runtime.destroy_entity(second_source));
    tick(&mut second_runtime, 0.0);
    assert!(
        second_runtime
            .destruction_event_frame()
            .recycled_fragments
            .iter()
            .all(|event| event.reason == DestructionRecycleReason::SourceRemoved)
    );
    assert!(
        second_fragments
            .iter()
            .all(|entity| !second_runtime.contains(*entity))
    );
}

/// Authored destructible policy survives scene serialization.
#[test]
fn serialization() {
    let mut runtime = new_runtime();
    let entity = runtime.create_entity();
    let destructible = Destructible::new("tower.fracture", 75.0, 12.0, 128, 20.0, 3.0, 0.2, false);
    runtime.set_component(destructible.clone(), entity);
    let data = SceneSerializer::serialize(runtime.world()).expect("serialize");
    let mut restored = new_runtime();
    SceneSerializer::deserialize(&data, restored.world_mut()).expect("deserialize");
    let restored_entity = restored.entities().first().copied().expect("entity");
    assert_eq!(
        restored.component::<Destructible>(restored_entity),
        Some(destructible)
    );
    assert!(restored.entities_with::<DestructibleFragment>().is_empty());
}

/// Authored scene capture after fracture restores the intact source only.
#[test]
fn fractured_scene_capture_restores_authored_source() {
    let (mut runtime, source) = make_runtime();
    let authored_body = runtime.component::<RigidBody>(source).expect("body");
    let authored_collider = runtime.component::<Collider>(source).expect("collider");
    let authored_mesh = runtime
        .component::<RenderMeshComponent>(source)
        .expect("render mesh");

    runtime.submit_destruction_command(force_fracture_command(source));
    tick(&mut runtime, 0.0);
    assert_eq!(fragment_entities(&runtime).len(), 3);

    let data = SceneSerializer::serialize(runtime.world()).expect("serialize");
    let mut restored = new_runtime();
    SceneSerializer::deserialize(&data, restored.world_mut()).expect("deserialize");

    let restored_source = restored
        .entities_with::<Destructible>()
        .first()
        .copied()
        .expect("restored source");
    assert_eq!(restored.entities().len(), 1);
    assert!(restored.entities_with::<DestructibleFragment>().is_empty());
    assert_eq!(
        restored.component::<RigidBody>(restored_source),
        Some(authored_body)
    );
    assert_eq!(
        restored.component::<Collider>(restored_source),
        Some(authored_collider)
    );
    assert_eq!(
        restored.component::<RenderMeshComponent>(restored_source),
        Some(authored_mesh)
    );
}

/// Prefab capture after fracture restores the intact source and rejects fragment
/// roots.
#[test]
fn fractured_prefab_capture_restores_authored_source() {
    let (mut runtime, source) = make_runtime();
    let authored_collider = runtime.component::<Collider>(source).expect("collider");
    runtime.submit_destruction_command(force_fracture_command(source));
    tick(&mut runtime, 0.0);
    let fragment = fragment_entities(&runtime)
        .first()
        .copied()
        .expect("fragment");

    assert!(
        Prefab::capture(runtime.world(), fragment)
            .expect("capture fragment root")
            .is_none()
    );
    let prefab = Prefab::capture(runtime.world(), source)
        .expect("capture source")
        .expect("prefab");
    let mut restored = new_runtime();
    let restored_source = prefab
        .instantiate(restored.world_mut(), None, None)
        .expect("instantiate")
        .expect("restored source");

    assert_eq!(restored.entities().len(), 1);
    assert!(restored.entities_with::<DestructibleFragment>().is_empty());
    assert_eq!(
        restored
            .component::<RigidBody>(restored_source)
            .map(|body| body.motion_type),
        Some(RigidBodyMotionType::Static)
    );
    assert_eq!(
        restored.component::<Collider>(restored_source),
        Some(authored_collider)
    );
    assert_eq!(
        restored
            .component::<RenderMeshComponent>(restored_source)
            .map(|mesh| mesh.is_visible),
        Some(true)
    );
}

/// Game save preserves fractured ownership, source snapshot, damage and remaining
/// lifetime.
#[test]
fn fractured_game_save_round_trip() {
    let (mut runtime, source) = make_runtime_with(8, 1.0, 0.0, 0.0);
    runtime.submit_destruction_command(DestructionCommand::new(
        source,
        4.0,
        Float3::ZERO,
        None,
        false,
    ));
    tick(&mut runtime, 0.0);
    runtime.submit_destruction_command(force_fracture_command(source));
    tick(&mut runtime, 0.1);
    tick(&mut runtime, 0.35);
    let moving_fragment = fragment_entities(&runtime)
        .into_iter()
        .find(|entity| {
            runtime
                .component::<DestructibleFragment>(*entity)
                .map(|fragment| fragment.fragment_id)
                == Some(0)
        })
        .expect("fragment 0");
    runtime.update_component::<RigidBody>(moving_fragment, |body| {
        body.linear_velocity = Float3::new(7.0, 8.0, 9.0);
        body.angular_velocity = Float3::new(1.0, 2.0, 3.0);
        body.accumulated_linear_impulse = Float3::new(4.0, 5.0, 6.0);
    });
    let saved_fragment_body = runtime
        .component::<RigidBody>(moving_fragment)
        .expect("saved fragment body");

    let save = GameSave::capture(&runtime, BTreeMap::new()).expect("capture save");
    let loaded = GameSave::load(&save.serialized().expect("serialize save")).expect("load save");
    let mut restored = new_runtime();
    restored.create_entity(); // Prove ownership references are relocatable.
    loaded.restore_scene(&mut restored).expect("restore scene");

    let restored_source = restored
        .entities_with::<Destructible>()
        .first()
        .copied()
        .expect("restored source");
    let fragments = restored.entities_with::<DestructibleFragment>();
    assert_eq!(restored.entities().len(), 5);
    assert_eq!(fragments.len(), 3);
    assert!(restored.component::<RigidBody>(restored_source).is_none());
    assert!(restored.component::<Collider>(restored_source).is_none());
    assert_eq!(
        restored
            .component::<RenderMeshComponent>(restored_source)
            .map(|mesh| mesh.is_visible),
        Some(false)
    );
    assert!(fragments.iter().all(|entity| {
        restored
            .component::<DestructibleFragment>(*entity)
            .map(|fragment| fragment.source_entity)
            == Some(restored_source)
    }));
    let mut fragment_ids: Vec<u32> = fragments
        .iter()
        .filter_map(|entity| {
            restored
                .component::<DestructibleFragment>(*entity)
                .map(|fragment| fragment.fragment_id)
        })
        .collect();
    fragment_ids.sort_unstable();
    assert_eq!(fragment_ids, vec![0, 1, 2]);
    let restored_moving_fragment = fragments
        .iter()
        .copied()
        .find(|entity| {
            restored
                .component::<DestructibleFragment>(*entity)
                .map(|fragment| fragment.fragment_id)
                == Some(0)
        })
        .expect("restored fragment 0");
    assert_eq!(
        restored.component::<RigidBody>(restored_moving_fragment),
        Some(saved_fragment_body)
    );

    tick(&mut restored, 0.0);
    assert_eq!(
        state_of(&restored, restored_source).map(|state| state.has_fractured),
        Some(true)
    );
    assert_eq!(
        state_of(&restored, restored_source).map(|state| state.accumulated_damage),
        Some(4.0)
    );
    assert_eq!(
        restored.destruction_state_frame().active_fragment_count(),
        3
    );

    // Scene capture from a loaded game still has the authored source snapshot.
    let authored_data = SceneSerializer::serialize(restored.world()).expect("serialize authored");
    let mut authored_restore = new_runtime();
    SceneSerializer::deserialize(&authored_data, authored_restore.world_mut())
        .expect("deserialize authored");
    let authored_source = authored_restore
        .entities_with::<Destructible>()
        .first()
        .copied()
        .expect("authored source");
    assert!(
        authored_restore
            .entities_with::<DestructibleFragment>()
            .is_empty()
    );
    assert_eq!(
        authored_restore
            .component::<RigidBody>(authored_source)
            .map(|body| body.motion_type),
        Some(RigidBodyMotionType::Static)
    );
    assert!(
        authored_restore
            .component::<Collider>(authored_source)
            .is_some()
    );
    assert_eq!(
        authored_restore
            .component::<RenderMeshComponent>(authored_source)
            .map(|mesh| mesh.is_visible),
        Some(true)
    );

    tick(&mut restored, 0.60);
    assert_eq!(fragment_entities(&restored).len(), 3);
    tick(&mut restored, 0.06);
    assert!(fragment_entities(&restored).is_empty());
}

/// Game save preserves a partially broken localized connection graph.
#[test]
fn partial_connection_game_save_round_trip() {
    let (mut runtime, source) = make_runtime();
    configure_localized_loop(&mut runtime, source);
    runtime.submit_destruction_command(impulse_command(
        source,
        Float3::new(3.0, 0.0, 0.0),
        Some(Float3::new(1.875, 3.0, 4.0)),
    ));
    tick(&mut runtime, 0.0);
    assert_eq!(
        state_of(&runtime, source).map(|state| state.broken_connection_ids),
        Some(vec![10])
    );

    let assets = runtime
        .resource::<DestructibleAssetResource>()
        .expect("destructible asset resource");
    let geometry = runtime
        .resource::<MeshColliderGeometryResource>()
        .expect("mesh collider geometry resource");
    let save = GameSave::capture(&runtime, BTreeMap::new()).expect("capture save");
    let mut restored = new_runtime();
    restored.create_entity();
    GameSave::load(&save.serialized().expect("serialize save"))
        .expect("load save")
        .restore_scene(&mut restored)
        .expect("restore scene");
    restored.set_resource(assets);
    restored.set_resource(geometry);
    let restored_source = restored
        .entities_with::<Destructible>()
        .first()
        .copied()
        .expect("restored source");

    tick(&mut restored, 0.0);
    assert_eq!(
        state_of(&restored, restored_source).map(|state| state.has_fractured),
        Some(false)
    );
    assert_eq!(
        state_of(&restored, restored_source).map(|state| state.broken_connection_ids),
        Some(vec![10])
    );
    assert!(restored.entities_with::<DestructibleFragment>().is_empty());
    assert!(restored.component::<RigidBody>(restored_source).is_some());

    restored.submit_destruction_command(impulse_command(
        restored_source,
        Float3::new(3.0, 0.0, 0.0),
        Some(Float3::new(2.0, 3.0, 4.0)),
    ));
    tick(&mut restored, 0.0);
    assert_eq!(
        state_of(&restored, restored_source).map(|state| state.has_fractured),
        Some(true)
    );
    assert_eq!(
        restored.destruction_state_frame().active_fragment_count(),
        3
    );
}

/// Game save preserves a partially released compound island and its render proxy.
#[test]
fn partial_island_game_save_round_trip() {
    let (mut runtime, source) = make_runtime_with(8, 0.0, 0.0, 0.0);
    configure_localized_loop(&mut runtime, source);
    configure_fragment_rendering(&mut runtime);
    runtime.submit_destruction_command(impulse_command(
        source,
        Float3::new(3.0, 0.0, 0.0),
        Some(Float3::new(1.875, 3.0, 4.0)),
    ));
    tick(&mut runtime, 0.0);
    runtime.submit_destruction_command(impulse_command(
        source,
        Float3::new(3.0, 0.0, 0.0),
        Some(Float3::new(2.0, 3.0, 4.0)),
    ));
    tick(&mut runtime, 0.0);

    // Runtime proxy children and detached fragments never leak into authored data.
    let authored_data = SceneSerializer::serialize(runtime.world()).expect("serialize authored");
    let mut authored_restore = new_runtime();
    SceneSerializer::deserialize(&authored_data, authored_restore.world_mut())
        .expect("deserialize authored");
    let authored_source = authored_restore
        .entities_with::<Destructible>()
        .first()
        .copied()
        .expect("authored source");
    assert_eq!(authored_restore.entities().len(), 1);
    assert!(
        authored_restore
            .entities_with::<DestructibleRetainedFragment>()
            .is_empty()
    );
    assert_eq!(
        authored_restore
            .component::<Collider>(authored_source)
            .map(|collider| collider.shape().kind()),
        Some(ColliderShapeKind::Box)
    );
    assert_eq!(
        authored_restore
            .component::<RenderMeshComponent>(authored_source)
            .map(|mesh| mesh.is_visible),
        Some(true)
    );

    let prefab = Prefab::capture(runtime.world(), source)
        .expect("capture source")
        .expect("prefab");
    let mut prefab_restore = new_runtime();
    let prefab_source = prefab
        .instantiate(prefab_restore.world_mut(), None, None)
        .expect("instantiate")
        .expect("prefab source");
    assert_eq!(prefab_restore.entities().len(), 1);
    assert!(
        prefab_restore
            .entities_with::<DestructibleRetainedFragment>()
            .is_empty()
    );
    assert_eq!(
        prefab_restore
            .component::<Collider>(prefab_source)
            .map(|collider| collider.shape().kind()),
        Some(ColliderShapeKind::Box)
    );

    let assets = runtime
        .resource::<DestructibleAssetResource>()
        .expect("destructible asset resource");
    let geometry = runtime
        .resource::<MeshColliderGeometryResource>()
        .expect("mesh collider geometry resource");
    let save = GameSave::capture(&runtime, BTreeMap::new()).expect("capture save");
    let mut restored = new_runtime();
    restored.create_entity();
    GameSave::load(&save.serialized().expect("serialize save"))
        .expect("load save")
        .restore_scene(&mut restored)
        .expect("restore scene");
    restored.set_resource(assets);
    restored.set_resource(geometry);
    let restored_source = restored
        .entities_with::<Destructible>()
        .first()
        .copied()
        .expect("restored source");
    tick(&mut restored, 0.0);

    let restored_state = state_of(&restored, restored_source).expect("restored source state");
    assert!(restored_state.has_fractured);
    assert!(!restored_state.is_fully_fractured);
    assert_eq!(restored_state.released_fragment_ids, vec![1, 2]);
    assert_eq!(restored_state.retained_fragment_ids, vec![0]);
    assert_eq!(restored_state.active_fragment_ids, vec![1, 2]);
    assert_eq!(
        restored
            .component::<Collider>(restored_source)
            .map(|collider| collider.shapes.len()),
        Some(1)
    );
    let proxy = restored
        .entities_with::<DestructibleRetainedFragment>()
        .first()
        .copied()
        .expect("retained proxy");
    assert_eq!(restored.parent(proxy), Some(restored_source));
    assert_eq!(
        restored
            .component::<RenderMeshComponent>(proxy)
            .map(|mesh| mesh.mesh_index),
        Some(100)
    );

    restored.submit_destruction_command(force_fracture_command(restored_source));
    tick(&mut restored, 0.0);
    assert_eq!(
        restored
            .destruction_event_frame()
            .events
            .first()
            .map(|event| event.fragment_ids.clone()),
        Some(vec![0])
    );
    assert!(
        restored
            .entities_with::<DestructibleRetainedFragment>()
            .is_empty()
    );
    assert_eq!(fragment_entities(&restored).len(), 3);
    assert_eq!(
        state_of(&restored, restored_source).map(|state| state.is_fully_fractured),
        Some(true)
    );
}

/// Destruction commands are captured by deterministic physics recording.
#[test]
fn recording() {
    let (mut runtime, source) = make_runtime();
    runtime.begin_physics_command_recording(2);
    runtime.submit_destruction_command(DestructionCommand::new(
        source,
        3.0,
        Float3::new(1.0, 2.0, 3.0),
        Some(Float3::new(2.0, 3.0, 4.0)),
        false,
    ));
    tick(&mut runtime, DELTA_TIME);
    let tape = runtime.end_physics_command_recording();
    let frame = tape.frames.first().expect("recorded frame");
    assert_eq!(frame.destruction_commands.len(), 1);
    assert_eq!(frame.destruction_commands[0].entity, source);
    assert_eq!(frame.destruction_commands[0].damage, 3.0);
}

/// Event capacity reports overflow without changing stable command order.
#[test]
fn event_capacity_overflow() {
    let (mut runtime, first_source) = make_runtime();
    runtime.update_component::<Destructible>(first_source, |destructible| {
        destructible.asset_resource_id = "missing.first".to_string();
    });
    let second_source = runtime.create_entity();
    runtime.set_component(
        Destructible {
            asset_resource_id: "missing.second".to_string(),
            ..Destructible::default()
        },
        second_source,
    );
    runtime.set_resource(DestructionSettingsResource::new(8, 1));
    runtime.submit_destruction_command(force_fracture_command(second_source));
    runtime.submit_destruction_command(force_fracture_command(first_source));

    tick(&mut runtime, 0.0);

    let frame = runtime.destruction_event_frame();
    let failure = frame.failures.first().expect("failure");
    assert_eq!(failure.source_entity, first_source);
    assert_eq!(frame.failures.len(), 1);
    assert!(frame.did_overflow);
}

/// Recorded damage and fracture replay to identical destruction hashes.
#[test]
fn deterministic_replay() {
    let (mut recording_runtime, source) = make_runtime();
    recording_runtime.begin_physics_command_recording(4);
    recording_runtime.submit_destruction_command(DestructionCommand::new(
        source,
        4.0,
        Float3::ZERO,
        None,
        false,
    ));
    tick(&mut recording_runtime, DELTA_TIME);
    recording_runtime.submit_destruction_command(DestructionCommand::new(
        source,
        6.0,
        Float3::ZERO,
        None,
        false,
    ));
    tick(&mut recording_runtime, DELTA_TIME);
    let expected_state = recording_runtime.destruction_state_frame();
    let tape = recording_runtime.end_physics_command_recording();
    assert_eq!(tape.frames.len(), 2);
    assert_ne!(
        tape.frames[0].expected_state_hash,
        tape.frames[1].expected_state_hash
    );

    let (mut replay_runtime, replay_source) = make_runtime();
    assert_eq!(replay_source, source);
    let replay = replay_runtime.replay_physics_commands(&tape);

    assert!(replay.is_deterministic());
    assert_eq!(replay.replayed_frame_count, 2);
    assert_eq!(replay_runtime.destruction_state_frame(), expected_state);
    assert_eq!(
        state_of(&replay_runtime, replay_source).map(|state| state.active_fragment_ids),
        Some(vec![0, 1, 2])
    );
}

/// Localized connection breaks replay to identical intermediate and final hashes.
#[test]
fn localized_deterministic_replay() {
    let (mut recording_runtime, source) = make_runtime();
    configure_localized_loop(&mut recording_runtime, source);
    recording_runtime.begin_physics_command_recording(4);
    recording_runtime.submit_destruction_command(impulse_command(
        source,
        Float3::new(3.0, 0.0, 0.0),
        Some(Float3::new(1.875, 3.0, 4.0)),
    ));
    tick(&mut recording_runtime, 0.0);
    recording_runtime.submit_destruction_command(impulse_command(
        source,
        Float3::new(3.0, 0.0, 0.0),
        Some(Float3::new(2.0, 3.0, 4.0)),
    ));
    tick(&mut recording_runtime, 0.0);
    let tape = recording_runtime.end_physics_command_recording();
    let expected_state = recording_runtime.destruction_state_frame();
    assert_eq!(tape.frames.len(), 2);
    assert_ne!(
        tape.frames[0].expected_state_hash,
        tape.frames[1].expected_state_hash
    );

    let (mut replay_runtime, replay_source) = make_runtime();
    configure_localized_loop(&mut replay_runtime, replay_source);
    let replay = replay_runtime.replay_physics_commands(&tape);

    assert!(replay.is_deterministic());
    assert_eq!(replay.replayed_frame_count, 2);
    assert_eq!(replay_runtime.destruction_state_frame(), expected_state);
    assert_eq!(
        state_of(&replay_runtime, replay_source).map(|state| state.has_fractured),
        Some(true)
    );
}

/// Incremental island release replays to the same compound and fragment state.
#[test]
fn incremental_island_deterministic_replay() {
    let (mut recording_runtime, source) = make_runtime();
    configure_localized_loop(&mut recording_runtime, source);
    configure_fragment_rendering(&mut recording_runtime);
    recording_runtime.begin_physics_command_recording(3);
    recording_runtime.submit_destruction_command(impulse_command(
        source,
        Float3::new(3.0, 0.0, 0.0),
        Some(Float3::new(1.875, 3.0, 4.0)),
    ));
    tick(&mut recording_runtime, 0.0);
    recording_runtime.submit_destruction_command(impulse_command(
        source,
        Float3::new(3.0, 0.0, 0.0),
        Some(Float3::new(2.0, 3.0, 4.0)),
    ));
    tick(&mut recording_runtime, 0.0);
    let expected_state = recording_runtime.destruction_state_frame();
    let tape = recording_runtime.end_physics_command_recording();

    let (mut replay_runtime, replay_source) = make_runtime();
    configure_localized_loop(&mut replay_runtime, replay_source);
    configure_fragment_rendering(&mut replay_runtime);
    let report = replay_runtime.replay_physics_commands(&tape);

    assert!(report.is_deterministic());
    assert_eq!(replay_runtime.destruction_state_frame(), expected_state);
    assert_eq!(
        state_of(&replay_runtime, replay_source).map(|state| state.is_fully_fractured),
        Some(false)
    );
    assert_eq!(
        state_of(&replay_runtime, replay_source).map(|state| state.released_fragment_ids),
        Some(vec![1, 2])
    );
    assert_eq!(
        replay_runtime
            .component::<Collider>(replay_source)
            .map(|collider| collider.shapes.len()),
        Some(1)
    );
    assert_eq!(
        replay_runtime
            .entities_with::<DestructibleRetainedFragment>()
            .len(),
        1
    );
}
