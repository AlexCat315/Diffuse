//! Ported from `Engine/Tests/SceneRuntimeTests/RuntimeWorldTests.swift`.
//!
//! Swift's `tick()` takes no arguments; the Rust schedule requires a delta and a
//! frame index, so idle ticks here pass a zero delta and frame 0.

use std::collections::BTreeSet;
use std::sync::{Arc, Mutex};

use diffuse_kernel::input_event::{InputEvent, KeyEvent, KeyModifiers};
use diffuse_kernel::job_system::JobSystem;
use diffuse_math::simd::simd_compat::{Float3, Float4, Float4x4};

use crate::entity_id::{EntityID, RuntimeComponent};
use crate::physics::backend::physics_backend::PhysicsBackend;
use crate::physics::backend::physics_backend_capabilities::PhysicsBackendCapabilities;
use crate::physics::backend::physics_backend_context::{
    PhysicsPrepareContext, PhysicsPrepareResult, PhysicsStepContext, PhysicsStepResult,
    PhysicsSyncEvent,
};
use crate::physics::backend::physics_backend_kind::PhysicsBackendKind;
use crate::physics::collider::{Collider, ColliderShape};
use crate::physics::physics_settings::PhysicsSettingsResource;
use crate::physics::physics_types::PhysicsSimulationMode;
use crate::physics::queries::physics_query_types::{
    PhysicsOverlapAABBQuery, PhysicsOverlapHit, PhysicsOverlapShapeQuery, PhysicsQueryFilter,
    PhysicsRaycastHit, PhysicsRaycastQuery, PhysicsSweepAABBQuery, PhysicsSweepHit,
    PhysicsSweepShapeQuery,
};
use crate::physics::queries::trigger_detection::TriggerFrameResource;
use crate::physics::rigid_body::RigidBody;
use crate::rendering::render_extraction::{CameraComponent, RenderMeshComponent};
use crate::runtime_world::{LocalTransform, RuntimeWorld, WorldTransform};
use crate::scene_runtime::{InputFrameResource, SceneRuntime, SceneRuntimeSnapshot};
use crate::scheduling::schedule_commands::RuntimeSystemPhase;

#[derive(Clone, Debug, PartialEq)]
struct TransformStub {
    x: i32,
    y: i32,
}

impl RuntimeComponent for TransformStub {}

#[derive(Clone, Debug, PartialEq)]
struct NameStub {
    value: String,
}

impl RuntimeComponent for NameStub {}

#[derive(Clone, Debug, PartialEq)]
struct CounterResource {
    value: i32,
}

/// Records every prepare/step context a schedule hands the backend.
struct RecordingPhysicsBackend {
    prepare_contexts: Arc<Mutex<Vec<PhysicsPrepareContext>>>,
    step_contexts: Arc<Mutex<Vec<PhysicsStepContext>>>,
}

impl RecordingPhysicsBackend {
    fn new() -> Self {
        RecordingPhysicsBackend {
            prepare_contexts: Arc::new(Mutex::new(Vec::new())),
            step_contexts: Arc::new(Mutex::new(Vec::new())),
        }
    }
}

impl PhysicsBackend for RecordingPhysicsBackend {
    fn identifier(&self) -> &str {
        "recording"
    }

    fn capabilities(&self) -> PhysicsBackendCapabilities {
        PhysicsBackendCapabilities::all()
    }

    fn prepare(&mut self, context: PhysicsPrepareContext) -> PhysicsPrepareResult {
        let synchronized_bodies = context.active_bodies.len() as i64;
        let synchronized_constraints = context.active_constraints.len() as i64;
        self.prepare_contexts
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .push(context);
        PhysicsPrepareResult {
            synchronized_bodies,
            synchronized_constraints,
            ..PhysicsPrepareResult::default()
        }
    }

    fn step(&mut self, context: PhysicsStepContext) -> PhysicsStepResult {
        let body_count = context.active_bodies.len() as i64;
        let constraint_count = context.active_constraints.len() as i64;
        let step_index = context.step_index;
        let first_body = context.active_bodies.first().map(|body| body.entity);
        self.step_contexts
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .push(context);
        let Some(entity) = first_body else {
            return PhysicsStepResult::default();
        };
        let translation = step_index as f32 + 1.0;
        PhysicsStepResult {
            body_count,
            constraint_count,
            contact_count: 1,
            writebacks: vec![
                crate::physics::backend::physics_backend_context::PhysicsBodyWriteback {
                    entity,
                    world_transform: Some(WorldTransform::new(Float4x4::from_columns([
                        Float4::new(1.0, 0.0, 0.0, 0.0),
                        Float4::new(0.0, 1.0, 0.0, 0.0),
                        Float4::new(0.0, 0.0, 1.0, 0.0),
                        Float4::new(translation, 0.0, 0.0, 1.0),
                    ]))),
                    linear_velocity: Some(Float3::new(translation, 0.0, 0.0)),
                    angular_velocity: Some(Float3::new(0.0, translation, 0.0)),
                    is_sleeping: Some(false),
                },
            ],
            ..PhysicsStepResult::default()
        }
    }

    fn raycast(
        &self,
        _query: PhysicsRaycastQuery,
        _filter: PhysicsQueryFilter,
    ) -> Option<PhysicsRaycastHit> {
        None
    }

    fn overlap_aabb(
        &self,
        _query: PhysicsOverlapAABBQuery,
        _filter: PhysicsQueryFilter,
    ) -> Vec<PhysicsOverlapHit> {
        Vec::new()
    }

    fn overlap_shape(
        &self,
        _query: PhysicsOverlapShapeQuery,
        _filter: PhysicsQueryFilter,
    ) -> Vec<PhysicsOverlapHit> {
        Vec::new()
    }

    fn sweep_aabb(
        &self,
        _query: PhysicsSweepAABBQuery,
        _filter: PhysicsQueryFilter,
    ) -> Option<PhysicsSweepHit> {
        None
    }

    fn sweep_shape(
        &self,
        _query: PhysicsSweepShapeQuery,
        _filter: PhysicsQueryFilter,
    ) -> Option<PhysicsSweepHit> {
        None
    }

    fn detect_trigger_frame(&mut self, _max_event_count: usize) -> TriggerFrameResource {
        TriggerFrameResource::default()
    }

    fn reset(&mut self) {}
}

fn tick(runtime: &mut SceneRuntime) {
    runtime.tick(0.0, 0, Vec::new());
}

fn entity_ids<C: RuntimeComponent>(
    queries: &[crate::runtime_world::RuntimeComponentQuery<C>],
) -> Vec<EntityID> {
    queries.iter().map(|query| query.entity).collect()
}

/// Entity slots reuse indices and invalidate stale generations.
#[test]
fn entity_generation_changes_when_reusing_slot() {
    let mut world = RuntimeWorld::default();

    let first = world.create_entity();
    assert!(world.contains(first));

    let destroyed_first = world.destroy_entity(first);
    assert!(destroyed_first);
    assert!(!world.contains(first));

    let reused = world.create_entity();
    assert!(world.contains(reused));
    assert_eq!(first.index, reused.index);
    assert_ne!(first.generation, reused.generation);
}

/// Typed component stores keep component types isolated.
#[test]
fn typed_component_stores_are_per_type() {
    let mut world = RuntimeWorld::default();
    let entity = world.create_entity();

    let inserted_transform = world.set_component(TransformStub { x: 2, y: 4 }, entity);
    let inserted_name = world.set_component(
        NameStub {
            value: "Hero".to_string(),
        },
        entity,
    );
    assert!(inserted_transform);
    assert!(inserted_name);
    assert_eq!(
        world.component::<TransformStub>(entity),
        Some(TransformStub { x: 2, y: 4 })
    );
    assert_eq!(
        world.component::<NameStub>(entity),
        Some(NameStub {
            value: "Hero".to_string()
        })
    );
    assert_eq!(world.summary().component_store_count, 2);

    let updated_transform = world.update_component::<TransformStub>(entity, |transform| {
        transform.x += 1;
        transform.y += 2;
    });
    assert!(updated_transform);
    assert_eq!(
        world.component::<TransformStub>(entity),
        Some(TransformStub { x: 3, y: 6 })
    );

    let removed = world.remove_component::<NameStub>(entity);
    assert_eq!(
        removed,
        Some(NameStub {
            value: "Hero".to_string()
        })
    );
    assert_eq!(world.component::<NameStub>(entity), None);

    let destroyed_entity = world.destroy_entity(entity);
    assert!(destroyed_entity);
    assert_eq!(world.component::<TransformStub>(entity), None);
    let inserted_after_destroy = world.set_component(TransformStub { x: 0, y: 0 }, entity);
    assert!(!inserted_after_destroy);
}

/// Typed queries return stable component views and batch updates.
#[test]
fn typed_queries_return_stable_component_views_and_batch_updates() {
    let mut world = RuntimeWorld::default();
    let first = world.create_entity();
    let second = world.create_entity();
    let third = world.create_entity();

    world.set_component(TransformStub { x: 1, y: 1 }, first);
    world.set_component(
        NameStub {
            value: "First".to_string(),
        },
        first,
    );
    world.set_local_transform(
        LocalTransform::from_translation(Float3::new(1.0, 0.0, 0.0)),
        first,
    );
    world.set_component(TransformStub { x: 2, y: 2 }, second);
    world.set_component(
        NameStub {
            value: "Second".to_string(),
        },
        second,
    );
    world.set_local_transform(
        LocalTransform::from_translation(Float3::new(2.0, 0.0, 0.0)),
        second,
    );
    world.set_component(TransformStub { x: 3, y: 3 }, third);

    assert_eq!(world.component_count::<TransformStub>(), 3);
    assert_eq!(world.entities_with::<NameStub>(), vec![first, second]);
    let mut snapshot_keys: Vec<EntityID> = world
        .component_snapshot::<TransformStub>()
        .keys()
        .copied()
        .collect();
    snapshot_keys.sort_by_key(|entity| entity.raw_value());
    assert_eq!(snapshot_keys, vec![first, second, third]);
    let mut matching_keys: Vec<EntityID> = world
        .component_snapshot_matching::<TransformStub>(&[third, first])
        .keys()
        .copied()
        .collect();
    matching_keys.sort_by_key(|entity| entity.raw_value());
    assert_eq!(matching_keys, vec![first, third]);
    assert_eq!(
        world.local_transform_snapshot().get(&third),
        Some(&LocalTransform::IDENTITY)
    );
    assert_eq!(
        world
            .local_transform_snapshot_matching(&[third])
            .get(&third),
        Some(&LocalTransform::IDENTITY)
    );
    assert_eq!(
        world.world_transform_snapshot().get(&third),
        Some(&WorldTransform::IDENTITY)
    );
    assert_eq!(
        world
            .world_transform_snapshot_matching(&[third])
            .get(&third),
        Some(&WorldTransform::IDENTITY)
    );
    assert_eq!(
        entity_ids(&world.query::<TransformStub>()),
        vec![first, second, third]
    );

    let named_transforms = world.query_pair::<TransformStub, NameStub>();
    assert_eq!(
        named_transforms
            .iter()
            .map(|query| query.entity)
            .collect::<Vec<_>>(),
        vec![first, second]
    );
    assert_eq!(
        named_transforms
            .iter()
            .map(|query| query.a.x)
            .collect::<Vec<_>>(),
        vec![1, 2]
    );
    assert_eq!(
        named_transforms
            .iter()
            .map(|query| query.b.value.clone())
            .collect::<Vec<_>>(),
        vec!["First".to_string(), "Second".to_string()]
    );
    assert_eq!(
        world
            .query_triple::<TransformStub, NameStub, LocalTransform>()
            .iter()
            .map(|query| query.entity)
            .collect::<Vec<_>>(),
        vec![first, second]
    );

    let job_system = JobSystem::new(4, 1);
    let (parallel_transforms, parallel_report) = world.query_parallel::<TransformStub>(&job_system);
    assert_eq!(entity_ids(&parallel_transforms), vec![first, second, third]);
    assert!(parallel_report.executed_in_parallel);

    let (parallel_named_transforms, named_report) =
        world.query_pair_parallel::<TransformStub, NameStub>(&job_system);
    assert_eq!(
        parallel_named_transforms
            .iter()
            .map(|query| query.entity)
            .collect::<Vec<_>>(),
        vec![first, second]
    );
    assert!(named_report.executed_in_parallel);

    let (parallel_triples, triple_report) =
        world.query_triple_parallel::<TransformStub, NameStub, LocalTransform>(&job_system);
    assert_eq!(
        parallel_triples
            .iter()
            .map(|query| query.entity)
            .collect::<Vec<_>>(),
        vec![first, second]
    );
    assert!(triple_report.executed_in_parallel);

    let updated_count = world.update_components::<TransformStub>(|entity, transform| {
        transform.x += entity.index as i32;
        transform.y *= 10;
    });
    assert_eq!(updated_count, 3);
    assert_eq!(
        world.component::<TransformStub>(first),
        Some(TransformStub { x: 1, y: 10 })
    );
    assert_eq!(
        world.component::<TransformStub>(second),
        Some(TransformStub { x: 3, y: 20 })
    );
    assert_eq!(
        world.component::<TransformStub>(third),
        Some(TransformStub { x: 5, y: 30 })
    );

    let destroyed_second = world.destroy_entity(second);
    assert!(destroyed_second);
    let mut remaining: Vec<EntityID> = world
        .component_snapshot::<TransformStub>()
        .keys()
        .copied()
        .collect();
    remaining.sort_by_key(|entity| entity.raw_value());
    assert_eq!(remaining, vec![first, third]);
}

/// World resources are stored independently from entity components.
#[test]
fn world_resources_are_typed_and_mutable() {
    let mut world = RuntimeWorld::default();

    world.set_resource(CounterResource { value: 1 });
    assert_eq!(
        world.resource::<CounterResource>(),
        Some(CounterResource { value: 1 })
    );
    assert_eq!(world.summary().resource_count, 1);

    let updated_resource = world.update_resource::<CounterResource>(|resource| {
        resource.value += 9;
    });
    assert!(updated_resource);
    assert_eq!(
        world.resource::<CounterResource>(),
        Some(CounterResource { value: 10 })
    );

    let removed = world.remove_resource::<CounterResource>();
    assert_eq!(removed, Some(CounterResource { value: 10 }));
    assert_eq!(world.resource::<CounterResource>(), None);
}

/// The runtime snapshot mirrors the world revision and entity count.
#[test]
fn scene_runtime_snapshot_tracks_world_state() {
    let mut runtime =
        SceneRuntime::new(crate::components::core::registry::ComponentRegistry::built_in());
    assert_eq!(runtime.snapshot(), SceneRuntimeSnapshot::default());

    let entity = runtime.create_entity();
    let after_create = runtime.snapshot();
    assert_eq!(after_create.entity_count, 1);
    assert!(after_create.revision > 0);
    assert!(runtime.contains(entity));

    tick(&mut runtime);
    assert_eq!(runtime.snapshot().revision, after_create.revision + 1);

    let destroyed = runtime.destroy_entity(entity);
    assert!(destroyed);
    assert_eq!(runtime.snapshot().entity_count, 0);
}

/// The runtime exposes job-backed component queries.
#[test]
fn scene_runtime_exposes_job_backed_component_queries() {
    let mut runtime =
        SceneRuntime::new(crate::components::core::registry::ComponentRegistry::built_in());
    let first = runtime.create_entity();
    let second = runtime.create_entity();
    runtime.set_component(TransformStub { x: 1, y: 1 }, first);
    runtime.set_component(TransformStub { x: 2, y: 2 }, second);
    runtime.set_component(
        NameStub {
            value: "Second".to_string(),
        },
        second,
    );
    let job_system = JobSystem::new(2, 1);

    let (transforms, transform_report) =
        runtime.query_with_job_system::<TransformStub>(&job_system);
    assert_eq!(entity_ids(&transforms), vec![first, second]);
    assert!(transform_report.executed_in_parallel);

    let (named_transforms, named_report) =
        runtime.query_pair_with_job_system::<TransformStub, NameStub>(&job_system);
    assert_eq!(
        named_transforms
            .iter()
            .map(|query| query.entity)
            .collect::<Vec<_>>(),
        vec![second]
    );
    assert_eq!(named_report.job_count, 1);
    assert!(!named_report.executed_in_parallel);

    runtime.set_component(
        NameStub {
            value: "First".to_string(),
        },
        first,
    );
    let (both_named, both_report) =
        runtime.query_pair_with_job_system::<TransformStub, NameStub>(&job_system);
    assert_eq!(
        both_named
            .iter()
            .map(|query| query.entity)
            .collect::<Vec<_>>(),
        vec![first, second]
    );
    assert!(both_report.executed_in_parallel);
}

/// Flat transform propagation preserves snapshots and supports a later hierarchy.
#[test]
fn flat_transform_propagation() {
    let mut world = RuntimeWorld::default();
    let first = world.create_entity();
    let second = world.create_entity();
    let empty = world.create_entity();
    world.set_local_transform(
        LocalTransform::from_translation(Float3::new(2.0, 0.0, 0.0)),
        first,
    );
    world.set_local_transform(
        LocalTransform::from_translation(Float3::new(4.0, 0.0, 0.0)),
        second,
    );
    let jobs = JobSystem::new(2, 1);
    assert!(world.propagate_transforms(&jobs).executed_in_parallel);
    assert_eq!(world.component_snapshot::<WorldTransform>().len(), 3);
    assert_eq!(world.world_transform(empty), Some(WorldTransform::IDENTITY));
    let captured = world.component_snapshot::<WorldTransform>();
    let copy = world.clone();
    world.set_local_transform(
        LocalTransform::from_translation(Float3::new(5.0, 0.0, 0.0)),
        first,
    );
    world.propagate_transforms_default();
    assert_eq!(
        world
            .world_transform(first)
            .map(|transform| transform.translation().x),
        Some(5.0)
    );
    assert_eq!(
        world
            .world_transform(second)
            .map(|transform| transform.translation().x),
        Some(4.0)
    );
    assert_eq!(
        copy.world_transform(first)
            .map(|transform| transform.translation().x),
        Some(2.0)
    );
    assert_eq!(
        captured
            .get(&first)
            .map(|transform| transform.translation().x),
        Some(2.0)
    );
    world.set_parent(Some(first), second);
    world.propagate_transforms_default();
    assert_eq!(
        world
            .world_transform(second)
            .map(|transform| transform.translation().x),
        Some(9.0)
    );
}

/// Hierarchy propagation composes parent and child transforms.
#[test]
fn hierarchy_propagation_builds_world_transform() {
    let mut world = RuntimeWorld::default();
    let parent = world.create_entity();
    let child = world.create_entity();

    let parent_transform_set = world.set_local_transform(
        LocalTransform::from_translation(Float3::new(2.0, 0.0, 0.0)),
        parent,
    );
    let child_transform_set = world.set_local_transform(
        LocalTransform::from_translation(Float3::new(0.0, 3.0, 0.0)),
        child,
    );
    let parented = world.set_parent(Some(parent), child);
    assert!(parent_transform_set);
    assert!(child_transform_set);
    assert!(parented);
    assert!(world.hierarchy_needs_propagation());

    world.propagate_transforms_default();

    assert_eq!(world.parent(child), Some(parent));
    assert_eq!(world.children(parent), vec![child]);

    let resolved_parent = world
        .world_transform(parent)
        .map(|transform| transform.translation());
    let resolved_child = world
        .world_transform(child)
        .map(|transform| transform.translation());
    assert_eq!(resolved_parent, Some(Float3::new(2.0, 0.0, 0.0)));
    assert_eq!(resolved_child, Some(Float3::new(2.0, 3.0, 0.0)));
}

/// Destroying a parent detaches children back to the root.
#[test]
fn destroying_parent_orphans_children_safely() {
    let mut world = RuntimeWorld::default();
    let parent = world.create_entity();
    let child = world.create_entity();

    world.set_local_transform(
        LocalTransform::from_translation(Float3::new(4.0, 0.0, 0.0)),
        parent,
    );
    world.set_local_transform(
        LocalTransform::from_translation(Float3::new(0.0, 1.0, 0.0)),
        child,
    );
    world.set_parent(Some(parent), child);
    world.propagate_transforms_default();

    let destroyed_parent = world.destroy_entity(parent);
    assert!(destroyed_parent);
    assert_eq!(world.parent(child), None);

    world.propagate_transforms_default();
    assert_eq!(
        world
            .world_transform(child)
            .map(|transform| transform.translation()),
        Some(Float3::new(0.0, 1.0, 0.0))
    );
}

/// Hierarchy moves reorder siblings within the same parent.
#[test]
fn move_entity_reorders_siblings() {
    let mut world = RuntimeWorld::default();
    let parent = world.create_entity();
    let a = world.create_entity();
    let b = world.create_entity();
    let c = world.create_entity();

    assert!(world.set_parent(Some(parent), a));
    assert!(world.set_parent(Some(parent), b));
    assert!(world.set_parent(Some(parent), c));
    assert_eq!(world.children(parent), vec![a, b, c]);

    let moved_within_parent = world.move_entity(c, Some(parent), 1);
    assert!(moved_within_parent);
    assert_eq!(world.children(parent), vec![a, c, b]);

    let moved_forward_within_parent = world.move_entity(a, Some(parent), 2);
    assert!(moved_forward_within_parent);
    assert_eq!(world.children(parent), vec![c, a, b]);
}

/// Hierarchy moves reparent into a target slot and support root ordering.
#[test]
fn move_entity_reparents_and_reorders_roots() {
    let mut world = RuntimeWorld::default();
    let root_a = world.create_entity();
    let root_b = world.create_entity();
    let child = world.create_entity();

    assert_eq!(world.roots(), vec![root_a, root_b, child]);
    let reparented_child = world.move_entity(child, Some(root_a), 0);
    assert!(reparented_child);
    assert_eq!(world.parent(child), Some(root_a));
    assert_eq!(world.children(root_a), vec![child]);
    assert_eq!(world.roots(), vec![root_a, root_b]);

    let reordered_root = world.move_entity(root_b, None, 0);
    assert!(reordered_root);
    assert_eq!(world.roots(), vec![root_b, root_a]);

    let root_c = world.create_entity();
    assert_eq!(world.roots(), vec![root_b, root_a, root_c]);
    let moved_root_forward = world.move_entity(root_b, None, 2);
    assert!(moved_root_forward);
    assert_eq!(world.roots(), vec![root_a, root_b, root_c]);
}

/// `set_parent` removes the child from roots so the tree has no duplicates.
#[test]
fn set_parent_removes_from_roots_on_reparent() {
    let mut world = RuntimeWorld::default();
    let parent = world.create_entity();
    let child = world.create_entity();
    assert_eq!(world.roots(), vec![parent, child]);

    world.set_parent(Some(parent), child);
    assert_eq!(world.roots(), vec![parent]);
    assert_eq!(world.children(parent), vec![child]);
    assert_eq!(world.parent(child), Some(parent));
}

/// `set_parent(nil)` restores the child to roots.
#[test]
fn set_parent_nil_restores_to_roots() {
    let mut world = RuntimeWorld::default();
    let parent = world.create_entity();
    let child = world.create_entity();
    world.set_parent(Some(parent), child);
    assert_eq!(world.roots(), vec![parent]);

    world.set_parent(None, child);
    assert_eq!(world.parent(child), None);
    assert!(world.roots().contains(&child));
    assert!(world.children(parent).is_empty());
}

/// The fixed phase schedule runs in order and applies queued commands.
#[test]
fn scene_runtime_runs_deterministic_schedule() {
    let mut runtime =
        SceneRuntime::new(crate::components::core::registry::ComponentRegistry::built_in());
    runtime.create_queued_entity();

    let report = runtime.tick(0.0, 0, Vec::new());

    assert_eq!(report.phases, RuntimeSystemPhase::ALL.to_vec());
    assert_eq!(report.commands.applied_count, 1);
    assert_eq!(report.commands.created_entities.len(), 1);
    assert_eq!(runtime.snapshot().entity_count, 1);
}

/// Queued hierarchy commands are visible after the schedule runs.
#[test]
fn queued_hierarchy_commands_apply_before_render_extraction() {
    let mut runtime =
        SceneRuntime::new(crate::components::core::registry::ComponentRegistry::built_in());
    let parent = runtime.create_entity();
    let child = runtime.create_entity();

    runtime.set_queued_local_transform(
        LocalTransform::from_translation(Float3::new(5.0, 0.0, 0.0)),
        parent,
    );
    runtime.set_queued_local_transform(
        LocalTransform::from_translation(Float3::new(0.0, 2.0, 0.0)),
        child,
    );
    runtime.set_queued_parent(Some(parent), child);

    let report = runtime.tick(0.0, 0, Vec::new());

    assert_eq!(report.commands.applied_count, 3);
    assert_eq!(runtime.parent(child), Some(parent));
    assert_eq!(
        runtime
            .world_transform(child)
            .map(|transform| transform.translation()),
        Some(Float3::new(5.0, 2.0, 0.0))
    );
}

/// The physics schedule respects the fixed timestep and writes back body state.
#[test]
fn physics_schedule_writes_back_body_state() {
    let mut runtime =
        SceneRuntime::new(crate::components::core::registry::ComponentRegistry::built_in());
    let backend = RecordingPhysicsBackend::new();
    let prepare_contexts = backend.prepare_contexts.clone();
    let step_contexts = backend.step_contexts.clone();
    runtime.set_physics_backend(Box::new(backend));
    runtime.set_physics_settings(PhysicsSettingsResource {
        simulation_mode: PhysicsSimulationMode::Play,
        backend_kind: PhysicsBackendKind::None,
        fixed_time_step_seconds: 1.0 / 60.0,
        max_substeps_per_frame: 4,
        ..PhysicsSettingsResource::default()
    });

    let entity = runtime.create_entity();
    runtime.set_local_transform(LocalTransform::IDENTITY, entity);
    runtime.set_component(RigidBody::default(), entity);
    runtime.set_component(
        Collider::with_shape(ColliderShape::Box {
            half_extents: Float3::splat(0.5),
            center: Float3::ZERO,
        }),
        entity,
    );

    let report = runtime.tick(1.0 / 30.0, 0, Vec::new());

    assert_eq!(report.physics.backend_identifier, "recording");
    assert_eq!(report.physics.step_count, 2);
    assert_eq!(report.physics.writeback_count, 1);
    assert_eq!(report.physics.body_count, 1);
    let clock = runtime.physics_clock();
    assert_eq!(clock.last_step_count, 2);
    assert_eq!(clock.simulated_steps, 2);
    assert_eq!(runtime.physics_frame_state().counts.contacts, 2);
    assert_eq!(
        runtime
            .world_transform(entity)
            .map(|transform| transform.translation()),
        Some(Float3::new(2.0, 0.0, 0.0))
    );
    assert_eq!(
        runtime
            .component::<RigidBody>(entity)
            .map(|body| body.linear_velocity),
        Some(Float3::new(2.0, 0.0, 0.0))
    );
    assert_eq!(
        prepare_contexts
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .len(),
        1
    );
    assert_eq!(
        step_contexts
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .len(),
        2
    );
}

/// Physics prepare emits a removal sync event when a tracked body disappears.
#[test]
fn physics_prepare_emits_removal_events() {
    let mut runtime =
        SceneRuntime::new(crate::components::core::registry::ComponentRegistry::built_in());
    let backend = RecordingPhysicsBackend::new();
    let prepare_contexts = backend.prepare_contexts.clone();
    runtime.set_physics_backend(Box::new(backend));
    runtime.set_physics_settings(PhysicsSettingsResource {
        simulation_mode: PhysicsSimulationMode::Play,
        backend_kind: PhysicsBackendKind::None,
        fixed_time_step_seconds: 1.0 / 60.0,
        max_substeps_per_frame: 1,
        ..PhysicsSettingsResource::default()
    });

    let entity = runtime.create_entity();
    runtime.set_component(RigidBody::default(), entity);
    runtime.set_component(
        Collider::with_shape(ColliderShape::Sphere {
            radius: 0.5,
            center: Float3::ZERO,
        }),
        entity,
    );

    runtime.tick(1.0 / 60.0, 0, Vec::new());
    runtime.destroy_entity(entity);
    runtime.tick(1.0 / 60.0, 1, Vec::new());

    let contexts = prepare_contexts
        .lock()
        .unwrap_or_else(|error| error.into_inner());
    let last_prepare = contexts.last().expect("prepare context");
    assert!(
        last_prepare
            .sync_events
            .contains(&PhysicsSyncEvent::BodyRemove(entity))
    );
}

/// Component updates isolate copied worlds and captured snapshots.
#[test]
fn component_update_copy_isolation() {
    let mut original = RuntimeWorld::default();
    let entity = original.create_entity();
    original.set_component(TransformStub { x: 1, y: 2 }, entity);
    let snapshot = original.component_snapshot::<TransformStub>();
    let mut copy = original.clone();
    assert!(copy.update_component::<TransformStub>(entity, |transform| transform.x = 10));
    assert!(copy.update_component::<TransformStub>(entity, |transform| transform.y = 20));
    assert_eq!(
        copy.component::<TransformStub>(entity),
        Some(TransformStub { x: 10, y: 20 })
    );
    assert_eq!(
        original.component::<TransformStub>(entity),
        Some(TransformStub { x: 1, y: 2 })
    );
    assert_eq!(snapshot.get(&entity), Some(&TransformStub { x: 1, y: 2 }));
    let missing = copy.create_entity();
    assert!(!copy.update_component::<TransformStub>(missing, |transform| transform.x = 99));
    assert_eq!(copy.component::<TransformStub>(missing), None);
}

/// Schedule timing covers every complete phase.
#[test]
fn complete_phase_timings() {
    let mut runtime =
        SceneRuntime::new(crate::components::core::registry::ComponentRegistry::built_in());
    let report = runtime.tick(1.0 / 60.0, 0, Vec::new());
    let timed: BTreeSet<RuntimeSystemPhase> = report.phase_nanoseconds.keys().copied().collect();
    let all: BTreeSet<RuntimeSystemPhase> = RuntimeSystemPhase::ALL.iter().copied().collect();
    assert_eq!(timed, all);
    assert!(report.phase_nanoseconds.values().sum::<u64>() > 0);
}

/// Component snapshots preserve captured values and exclude destroyed generations.
#[test]
fn component_snapshot_lifetime() {
    let mut world = RuntimeWorld::default();
    let old = world.create_entity();
    world.set_component(TransformStub { x: 1, y: 2 }, old);
    let captured = world.component_snapshot::<TransformStub>();
    world.update_component::<TransformStub>(old, |transform| transform.x = 9);
    assert_eq!(captured.get(&old), Some(&TransformStub { x: 1, y: 2 }));
    assert_eq!(
        world
            .component_snapshot::<TransformStub>()
            .get(&old)
            .map(|transform| transform.x),
        Some(9)
    );
    let destroyed = world.destroy_entity(old);
    assert!(destroyed);
    let replacement = world.create_entity();
    world.set_component(TransformStub { x: 3, y: 4 }, replacement);
    let live = world.component_snapshot::<TransformStub>();
    assert_eq!(live.get(&old), None);
    assert_eq!(live.get(&replacement), Some(&TransformStub { x: 3, y: 4 }));
    assert_eq!(captured.get(&old), Some(&TransformStub { x: 1, y: 2 }));
    assert!(
        world
            .component_snapshot_matching::<TransformStub>(&[old])
            .is_empty()
    );
}

/// The runtime stores the current frame input as a derived resource.
#[test]
fn scene_runtime_stores_input_frame_resource() {
    let mut runtime =
        SceneRuntime::new(crate::components::core::registry::ComponentRegistry::built_in());
    let input_events = vec![
        InputEvent::KeyDown(KeyEvent {
            scancode: 4,
            keycode: 65,
            modifiers: KeyModifiers::LEFT_SHIFT,
            is_repeat: false,
        }),
        InputEvent::WindowResized {
            width: 1920,
            height: 1080,
        },
    ];

    runtime.tick(0.25, 12, input_events.clone());

    let resource = runtime
        .resource::<InputFrameResource>()
        .expect("input frame");
    assert_eq!(resource.frame_index, 12);
    assert_eq!(resource.delta_time_seconds, 0.25);
    assert_eq!(resource.events.len(), input_events.len());
    match resource.events.first() {
        Some(InputEvent::KeyDown(event)) => {
            assert_eq!(event.keycode, 65);
            assert_eq!(event.modifiers, KeyModifiers::LEFT_SHIFT);
        }
        _ => panic!("expected the first input event to be keyDown"),
    }
}

/// The runtime reports parallel job-backed phases with a multi-worker job system.
#[test]
fn scene_runtime_reports_parallel_job_backed_phases() {
    let mut runtime =
        SceneRuntime::new(crate::components::core::registry::ComponentRegistry::built_in());
    runtime.set_job_system(JobSystem::new(4, 1));
    runtime.set_physics_backend(Box::new(RecordingPhysicsBackend::new()));
    runtime.set_physics_settings(PhysicsSettingsResource {
        simulation_mode: PhysicsSimulationMode::Play,
        backend_kind: PhysicsBackendKind::None,
        fixed_time_step_seconds: 1.0 / 60.0,
        max_substeps_per_frame: 1,
        ..PhysicsSettingsResource::default()
    });

    let camera = runtime.create_entity();
    runtime.set_component(
        CameraComponent {
            is_active: true,
            ..CameraComponent::default()
        },
        camera,
    );

    for mesh_index in 0..4 {
        let entity = runtime.create_entity();
        runtime.set_local_transform(
            LocalTransform::from_translation(Float3::new(mesh_index as f32, 0.0, 0.0)),
            entity,
        );
        runtime.set_component(
            RenderMeshComponent::new(
                (mesh_index % 2) as i64,
                true,
                Float3::splat(1.0),
                None,
                Vec::new(),
            ),
            entity,
        );
        runtime.set_component(
            Collider::with_shape(ColliderShape::Box {
                half_extents: Float3::splat(0.5),
                center: Float3::ZERO,
            }),
            entity,
        );
        runtime.set_component(RigidBody::default(), entity);
    }

    let report = runtime.tick(1.0 / 60.0, 0, Vec::new());

    assert_eq!(report.jobs.worker_count, 4);
    assert!(report.jobs.scheduled_count >= 4);
    assert_eq!(
        report.jobs.scheduled_count,
        report.jobs.phase_job_counts.values().sum::<usize>()
    );
    assert!(
        report
            .jobs
            .job_count(RuntimeSystemPhase::HierarchyPropagate)
            > 0
    );
    assert!(
        report
            .jobs
            .job_count(RuntimeSystemPhase::FixedPhysicsPrepare)
            > 0
    );
    assert!(
        report
            .jobs
            .job_count(RuntimeSystemPhase::SpatialIndexUpdate)
            > 0
    );
    assert!(report.jobs.job_count(RuntimeSystemPhase::RenderExtract) > 0);
    assert!(
        report
            .jobs
            .parallel_phases
            .contains(&RuntimeSystemPhase::HierarchyPropagate)
    );
    assert!(
        report
            .jobs
            .parallel_phases
            .contains(&RuntimeSystemPhase::FixedPhysicsPrepare)
    );
    assert!(
        report
            .jobs
            .parallel_phases
            .contains(&RuntimeSystemPhase::SpatialIndexUpdate)
    );
    assert!(
        report
            .jobs
            .parallel_phases
            .contains(&RuntimeSystemPhase::RenderExtract)
    );
}
