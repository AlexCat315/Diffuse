//! Ported from `Engine/Tests/SceneRuntimeTests/SpatialQueryTests.swift`.
//!
//! Swift's `tick()` takes no arguments; the Rust schedule requires a delta and a
//! frame index, so idle ticks here pass a zero delta and frame 0.

use std::collections::BTreeMap;

use diffuse_kernel::job_system::JobSystem;
use diffuse_math::simd::simd_compat::{Float3, Float4, Float4x4};

use crate::components::core::registry::ComponentRegistry;
use crate::entity_id::EntityID;
use crate::physics::backend::physics_query_scene::PhysicsQueryCacheStats;
use crate::physics::collider::{Collider, ColliderShape, SpatialAABB};
use crate::physics::physics_settings::PhysicsSettingsResource;
use crate::physics::physics_types::PhysicsSimulationMode;
use crate::physics::queries::physics_query_types::{
    PhysicsOverlapAABBQuery, PhysicsOverlapShapeQuery, PhysicsQueryFilter, PhysicsQueryShape,
    PhysicsRaycastQuery, PhysicsSweepAABBQuery, PhysicsSweepShapeQuery,
};
use crate::physics::queries::spatial_queries::{
    MeshColliderBoundsResource, SceneOverlapQuery, SceneRaycastQuery, SceneSweepQuery,
};
use crate::runtime_world::LocalTransform;
use crate::scene_runtime::SceneRuntime;
use crate::scheduling::schedule_commands::RuntimeSystemPhase;

fn runtime() -> SceneRuntime {
    SceneRuntime::new(ComponentRegistry::built_in())
}

fn tick(runtime: &mut SceneRuntime) {
    runtime.tick(0.0, 0, Vec::new());
}

fn box_collider(half_extents: Float3) -> Collider {
    Collider::with_shape(ColliderShape::Box {
        half_extents,
        center: Float3::ZERO,
    })
}

fn sphere_collider(radius: f32) -> Collider {
    Collider::with_shape(ColliderShape::Sphere {
        radius,
        center: Float3::ZERO,
    })
}

fn capsule_collider(radius: f32, half_height: f32) -> Collider {
    Collider::with_shape(ColliderShape::Capsule {
        radius,
        half_height,
        center: Float3::ZERO,
    })
}

fn trigger_box(half_extents: Float3) -> Collider {
    let mut collider = box_collider(half_extents);
    collider.is_trigger = true;
    collider
}

fn boxes(
    hits: &[crate::physics::queries::physics_query_types::PhysicsOverlapHit],
) -> Vec<EntityID> {
    hits.iter().map(|hit| hit.entity).collect()
}

fn spatial_entry_bounds(runtime: &SceneRuntime, entity: EntityID) -> Option<SpatialAABB> {
    runtime
        .spatial_index()
        .entries
        .iter()
        .find(|entry| entry.entity == entity)
        .map(|entry| entry.bounds)
}

fn rotated_box_matrix(angle_radians: f32) -> Float4x4 {
    let (sine, cosine) = angle_radians.sin_cos();
    Float4x4::from_columns([
        Float4::new(cosine, sine, 0.0, 0.0),
        Float4::new(-sine, cosine, 0.0, 0.0),
        Float4::new(0.0, 0.0, 1.0, 0.0),
        Float4::new(0.0, 0.0, 0.0, 1.0),
    ])
}

fn z_rotation_quaternion(angle_radians: f32) -> Float4 {
    Float4::new(
        0.0,
        0.0,
        (angle_radians * 0.5).sin(),
        (angle_radians * 0.5).cos(),
    )
}

fn scale_matrix(scale: Float3) -> Float4x4 {
    Float4x4::from_columns([
        Float4::new(scale.x, 0.0, 0.0, 0.0),
        Float4::new(0.0, scale.y, 0.0, 0.0),
        Float4::new(0.0, 0.0, scale.z, 0.0),
        Float4::new(0.0, 0.0, 0.0, 1.0),
    ])
}

/// Spatial index updates build world-space bounds for colliders.
#[test]
fn spatial_index_update_builds_world_space_bounds() {
    let mut runtime = runtime();

    let parent = runtime.create_entity();
    runtime.set_local_transform(
        LocalTransform::from_translation(Float3::new(2.0, 0.0, 0.0)),
        parent,
    );

    let child_box = runtime.create_entity();
    runtime.set_local_transform(
        LocalTransform::from_translation(Float3::new(1.0, 0.0, 0.0)),
        child_box,
    );
    runtime.set_parent(Some(parent), child_box);
    runtime.set_component(box_collider(Float3::splat(0.5)), child_box);

    tick(&mut runtime);

    let bounds = spatial_entry_bounds(&runtime, child_box).expect("child bounds");
    assert_eq!(bounds.center(), Float3::new(3.0, 0.0, 0.0));
    assert_eq!(bounds.half_extents(), Float3::splat(0.5));
}

/// Mesh colliders use the registered local mesh bounds.
#[test]
fn mesh_colliders_use_registered_local_mesh_bounds() {
    let mut runtime = runtime();
    runtime.set_resource(MeshColliderBoundsResource {
        bounds_by_resource_id: BTreeMap::from([(
            "wide-mesh".to_string(),
            SpatialAABB::new(Float3::new(-2.0, -1.0, -0.25), Float3::new(2.0, 1.0, 0.25)),
        )]),
        default_bounds: None,
    });

    let entity = runtime.create_entity();
    runtime.set_local_transform(
        LocalTransform::from_translation(Float3::new(10.0, 0.0, 0.0)),
        entity,
    );
    runtime.set_component(
        Collider::with_shape(ColliderShape::Mesh {
            resource_id: Some("wide-mesh".to_string()),
            center: Float3::new(1.0, 0.0, 0.0),
        }),
        entity,
    );

    tick(&mut runtime);

    let bounds = spatial_entry_bounds(&runtime, entity).expect("mesh bounds");
    assert_eq!(bounds.center(), Float3::new(11.0, 0.0, 0.0));
    assert_eq!(bounds.half_extents(), Float3::new(2.0, 1.0, 0.25));

    let hit = runtime
        .physics_raycast(
            PhysicsRaycastQuery::with_distance(
                Float3::new(6.0, 0.0, 0.0),
                Float3::new(1.0, 0.0, 0.0),
                10.0,
            ),
            PhysicsQueryFilter::default(),
        )
        .expect("raycast hit");
    assert_eq!(hit.entity, entity);
    assert!((hit.distance - 3.0).abs() < 0.000_1);
}

/// Spatial index updates report job-backed snapshot rebuilds.
#[test]
fn spatial_index_update_reports_job_backed_snapshot_rebuilds() {
    let mut runtime = runtime();
    runtime.set_job_system(JobSystem::new(4, 1));

    let mut entities: Vec<EntityID> = Vec::new();
    for index in 0..4u32 {
        let entity = runtime.create_entity();
        runtime.set_local_transform(
            LocalTransform::from_translation(Float3::new(index as f32, 0.0, 0.0)),
            entity,
        );
        runtime.set_component(box_collider(Float3::splat(0.5)), entity);
        entities.push(entity);
    }

    tick(&mut runtime);
    runtime.set_component(box_collider(Float3::new(1.0, 0.5, 0.5)), entities[0]);

    let report = runtime.tick(0.0, 1, Vec::new());

    assert!(
        report
            .jobs
            .parallel_phases
            .contains(&RuntimeSystemPhase::SpatialIndexUpdate)
    );
    let spatial_jobs = report
        .jobs
        .job_count(RuntimeSystemPhase::SpatialIndexUpdate);
    assert!(
        spatial_jobs >= entities.len(),
        "spatial index jobs = {spatial_jobs}, entities = {}",
        entities.len()
    );
    assert_eq!(runtime.spatial_index().entries.len(), entities.len());
    assert_eq!(
        spatial_entry_bounds(&runtime, entities[0])
            .map(|bounds| bounds.half_extents().x)
            .unwrap_or(0.0),
        1.0
    );
}

/// Raycast returns the nearest collider hit from Natsel.
#[test]
fn raycast_returns_nearest_collider_hit() {
    let mut runtime = runtime();

    let sphere = runtime.create_entity();
    runtime.set_local_transform(
        LocalTransform::from_translation(Float3::new(1.0, 0.0, 0.0)),
        sphere,
    );
    runtime.set_component(sphere_collider(1.0), sphere);

    let box_entity = runtime.create_entity();
    runtime.set_local_transform(
        LocalTransform::from_translation(Float3::new(4.0, 0.0, 0.0)),
        box_entity,
    );
    runtime.set_component(box_collider(Float3::splat(0.5)), box_entity);

    tick(&mut runtime);

    let hit = runtime
        .raycast_scene(SceneRaycastQuery::with_options(
            Float3::new(-5.0, 0.0, 0.0),
            Float3::new(1.0, 0.0, 0.0),
            20.0,
            false,
        ))
        .expect("raycast hit");

    assert_eq!(hit.entity, sphere);
    assert_eq!(hit.distance, 5.0);
    assert_eq!(hit.position, Float3::ZERO);
    assert_eq!(hit.normal, Float3::new(-1.0, 0.0, 0.0));
}

/// Raycast uses Natsel sphere geometry instead of broad-phase bounds.
#[test]
fn raycast_uses_precise_sphere_narrow_phase() {
    let mut runtime = runtime();

    let sphere = runtime.create_entity();
    runtime.set_component(sphere_collider(1.0), sphere);

    tick(&mut runtime);

    let hit = runtime
        .raycast_scene(SceneRaycastQuery::with_options(
            Float3::new(-5.0, 0.5, 0.0),
            Float3::new(1.0, 0.0, 0.0),
            20.0,
            false,
        ))
        .expect("raycast hit");

    assert_eq!(hit.entity, sphere);
    assert!((hit.distance - 4.133_974_6).abs() < 0.000_1);
    assert!((hit.position.x + 0.866_025_4).abs() < 0.000_1);
    assert!((hit.normal.x + 0.866_025_4).abs() < 0.000_1);
    assert!((hit.normal.y - 0.5).abs() < 0.000_1);
}

/// Raycast uses Natsel rotated box geometry instead of broad-phase bounds.
#[test]
fn raycast_uses_precise_rotated_box_narrow_phase() {
    let mut runtime = runtime();

    let box_entity = runtime.create_entity();
    runtime.set_local_transform(
        LocalTransform::new(rotated_box_matrix(std::f32::consts::FRAC_PI_4)),
        box_entity,
    );
    runtime.set_component(box_collider(Float3::new(1.0, 0.2, 0.5)), box_entity);

    tick(&mut runtime);

    let hit = runtime
        .raycast_scene(SceneRaycastQuery::with_options(
            Float3::new(0.0, 5.0, 0.0),
            Float3::new(0.0, -1.0, 0.0),
            20.0,
            false,
        ))
        .expect("raycast hit");

    assert_eq!(hit.entity, box_entity);
    assert!((hit.distance - 4.717_157_4).abs() < 0.000_2);
    assert!((hit.position.y - 0.282_842_7).abs() < 0.000_2);
    assert!((hit.normal.x + 0.707_106_77).abs() < 0.000_2);
    assert!((hit.normal.y - 0.707_106_77).abs() < 0.000_2);
}

/// Raycast applies transform scale to the Natsel shape center.
#[test]
fn raycast_applies_transform_scale_to_natsel_shape_center() {
    let mut runtime = runtime();

    let box_entity = runtime.create_entity();
    runtime.set_local_transform(
        LocalTransform::new(scale_matrix(Float3::new(2.0, 1.0, 1.0))),
        box_entity,
    );
    runtime.set_component(
        Collider::with_shape(ColliderShape::Box {
            half_extents: Float3::splat(0.5),
            center: Float3::new(1.0, 0.0, 0.0),
        }),
        box_entity,
    );

    tick(&mut runtime);

    let hit = runtime
        .raycast_scene(SceneRaycastQuery::with_options(
            Float3::new(-1.0, 0.0, 0.0),
            Float3::new(1.0, 0.0, 0.0),
            10.0,
            false,
        ))
        .expect("raycast hit");

    assert_eq!(hit.entity, box_entity);
    assert!((hit.distance - 2.0).abs() < 0.000_1);
    assert!((hit.position.x - 1.0).abs() < 0.000_1);
}

/// Raycast uses the conservative Natsel scale for a non-uniform sphere.
#[test]
fn raycast_uses_conservative_natsel_scale_for_non_uniform_sphere() {
    let mut runtime = runtime();

    let sphere = runtime.create_entity();
    runtime.set_local_transform(
        LocalTransform::new(scale_matrix(Float3::new(2.0, 1.0, 1.0))),
        sphere,
    );
    runtime.set_component(
        Collider::with_shape(ColliderShape::Sphere {
            radius: 1.0,
            center: Float3::new(0.0, 1.0, 0.0),
        }),
        sphere,
    );

    tick(&mut runtime);

    let hit = runtime
        .raycast_scene(SceneRaycastQuery::with_options(
            Float3::new(-3.0, -0.5, 0.0),
            Float3::new(1.0, 0.0, 0.0),
            10.0,
            false,
        ))
        .expect("raycast hit");

    assert_eq!(hit.entity, sphere);
    assert!((hit.distance - 1.677_124_4).abs() < 0.000_5);
}

/// Raycast uses Natsel capsule geometry instead of broad-phase bounds.
#[test]
fn raycast_uses_precise_capsule_narrow_phase() {
    let mut runtime = runtime();

    let capsule = runtime.create_entity();
    runtime.set_component(capsule_collider(0.5, 1.0), capsule);

    tick(&mut runtime);

    let hit = runtime
        .raycast_scene(SceneRaycastQuery::with_options(
            Float3::new(-5.0, 1.3, 0.0),
            Float3::new(1.0, 0.0, 0.0),
            20.0,
            false,
        ))
        .expect("raycast hit");

    assert_eq!(hit.entity, capsule);
    assert!((hit.distance - 4.6).abs() < 0.000_1);
    assert!((hit.position.x + 0.4).abs() < 0.000_1);
    assert!((hit.normal.x + 0.8).abs() < 0.000_1);
    assert!((hit.normal.y - 0.6).abs() < 0.000_1);
}

/// Overlap uses Natsel sphere geometry instead of broad-phase bounds.
#[test]
fn overlap_uses_precise_sphere_narrow_phase() {
    let mut runtime = runtime();

    let sphere = runtime.create_entity();
    runtime.set_component(sphere_collider(1.0), sphere);

    tick(&mut runtime);

    let hits = runtime.overlap_scene(SceneOverlapQuery::new(
        SpatialAABB::from_center_half_extents(Float3::new(0.95, 0.95, 0.0), Float3::splat(0.05)),
    ));

    assert!(hits.is_empty());
}

/// Overlap uses Natsel rotated box geometry instead of broad-phase bounds.
#[test]
fn overlap_uses_precise_rotated_box_narrow_phase() {
    let mut runtime = runtime();

    let box_entity = runtime.create_entity();
    runtime.set_local_transform(
        LocalTransform::new(rotated_box_matrix(std::f32::consts::FRAC_PI_4)),
        box_entity,
    );
    runtime.set_component(box_collider(Float3::new(1.0, 0.2, 0.5)), box_entity);

    tick(&mut runtime);

    let hits = runtime.overlap_scene(SceneOverlapQuery::new(
        SpatialAABB::from_center_half_extents(Float3::new(0.83, 0.83, 0.0), Float3::splat(0.02)),
    ));

    assert!(hits.is_empty());
}

/// Overlap uses Natsel capsule geometry instead of broad-phase bounds.
#[test]
fn overlap_uses_precise_capsule_narrow_phase() {
    let mut runtime = runtime();

    let capsule = runtime.create_entity();
    runtime.set_component(capsule_collider(0.5, 1.0), capsule);

    tick(&mut runtime);

    let hits = runtime.overlap_scene(SceneOverlapQuery::new(
        SpatialAABB::from_center_half_extents(Float3::new(0.45, 1.45, 0.0), Float3::splat(0.05)),
    ));

    assert!(hits.is_empty());
}

/// Physics overlap shape uses Natsel sphere geometry.
#[test]
fn physics_overlap_shape_uses_precise_sphere_narrow_phase() {
    let mut runtime = runtime();

    let sphere = runtime.create_entity();
    runtime.set_component(sphere_collider(1.0), sphere);

    tick(&mut runtime);

    let broad_phase_only_hits = runtime.physics_overlap_shape(
        PhysicsOverlapShapeQuery::new(
            PhysicsQueryShape::Sphere { radius: 0.05 },
            Float3::new(0.95, 0.95, 0.0),
        ),
        PhysicsQueryFilter::default(),
    );
    let narrow_phase_hits = runtime.physics_overlap_shape(
        PhysicsOverlapShapeQuery::new(
            PhysicsQueryShape::Sphere { radius: 0.2 },
            Float3::new(0.9, 0.0, 0.0),
        ),
        PhysicsQueryFilter::default(),
    );

    assert!(broad_phase_only_hits.is_empty());
    assert_eq!(boxes(&narrow_phase_hits), vec![sphere]);
}

/// Physics overlap shape supports rotated Natsel boxes.
#[test]
fn physics_overlap_shape_supports_rotated_boxes() {
    let mut runtime = runtime();

    let sphere = runtime.create_entity();
    runtime.set_local_transform(
        LocalTransform::from_translation(Float3::new(0.75, 0.75, 0.0)),
        sphere,
    );
    runtime.set_component(
        Collider::with_shape(ColliderShape::Sphere {
            radius: 0.1,
            center: Float3::ZERO,
        }),
        sphere,
    );

    tick(&mut runtime);

    let hits = runtime.physics_overlap_shape(
        PhysicsOverlapShapeQuery {
            shape: PhysicsQueryShape::Box {
                half_extents: Float3::new(1.0, 0.1, 0.5),
            },
            position: Float3::ZERO,
            rotation: z_rotation_quaternion(std::f32::consts::FRAC_PI_4),
            max_results: usize::MAX,
        },
        PhysicsQueryFilter::default(),
    );

    assert_eq!(boxes(&hits), vec![sphere]);
}

/// Physics overlap shape supports Natsel capsules.
#[test]
fn physics_overlap_shape_supports_capsules() {
    let mut runtime = runtime();

    let sphere = runtime.create_entity();
    runtime.set_local_transform(
        LocalTransform::from_translation(Float3::new(0.0, 1.2, 0.0)),
        sphere,
    );
    runtime.set_component(
        Collider::with_shape(ColliderShape::Sphere {
            radius: 0.1,
            center: Float3::ZERO,
        }),
        sphere,
    );

    tick(&mut runtime);

    let hits = runtime.physics_overlap_shape(
        PhysicsOverlapShapeQuery::new(
            PhysicsQueryShape::Capsule {
                radius: 0.15,
                half_height: 1.0,
            },
            Float3::ZERO,
        ),
        PhysicsQueryFilter::default(),
    );

    assert_eq!(boxes(&hits), vec![sphere]);
}

/// Overlap returns every intersecting collider in stable order.
#[test]
fn overlap_returns_intersecting_colliders() {
    let mut runtime = runtime();

    let sphere = runtime.create_entity();
    runtime.set_local_transform(
        LocalTransform::from_translation(Float3::new(1.0, 0.0, 0.0)),
        sphere,
    );
    runtime.set_component(sphere_collider(1.0), sphere);

    let box_entity = runtime.create_entity();
    runtime.set_local_transform(
        LocalTransform::from_translation(Float3::new(4.0, 0.0, 0.0)),
        box_entity,
    );
    runtime.set_component(box_collider(Float3::splat(0.5)), box_entity);

    let trigger = runtime.create_entity();
    runtime.set_local_transform(
        LocalTransform::from_translation(Float3::new(2.0, 0.0, 0.0)),
        trigger,
    );
    runtime.set_component(trigger_box(Float3::splat(0.25)), trigger);

    tick(&mut runtime);

    let bounds = SpatialAABB::from_center_half_extents(
        Float3::new(2.2, 0.0, 0.0),
        Float3::new(2.0, 1.0, 1.0),
    );
    let hits = runtime.overlap_scene(SceneOverlapQuery::new(bounds));
    assert_eq!(boxes_from_scene(&hits), vec![sphere, box_entity]);

    let hits_including_triggers =
        runtime.overlap_scene(SceneOverlapQuery::with_include_triggers(bounds, true));
    let mut expected = vec![sphere, box_entity, trigger];
    expected.sort_by_key(|entity| entity.raw_value());
    assert_eq!(boxes_from_scene(&hits_including_triggers), expected);
}

fn boxes_from_scene(
    hits: &[crate::physics::queries::spatial_queries::SceneOverlapHit],
) -> Vec<EntityID> {
    hits.iter().map(|hit| hit.entity).collect()
}

/// Sweep returns the nearest collider hit from Natsel.
#[test]
fn sweep_returns_nearest_collider_hit() {
    let mut runtime = runtime();

    let near_box = runtime.create_entity();
    runtime.set_local_transform(
        LocalTransform::from_translation(Float3::new(3.0, 0.0, 0.0)),
        near_box,
    );
    runtime.set_component(box_collider(Float3::splat(0.5)), near_box);

    let far_box = runtime.create_entity();
    runtime.set_local_transform(
        LocalTransform::from_translation(Float3::new(6.0, 0.0, 0.0)),
        far_box,
    );
    runtime.set_component(box_collider(Float3::splat(0.5)), far_box);

    tick(&mut runtime);

    let hit = runtime
        .sweep(SceneSweepQuery::new(
            SpatialAABB::from_center_half_extents(Float3::ZERO, Float3::splat(0.5)),
            Float3::new(10.0, 0.0, 0.0),
        ))
        .expect("sweep hit");

    assert_eq!(hit.entity, near_box);
    assert!((hit.fraction - 0.2).abs() < 0.000_1);
    assert!((hit.distance - 2.0).abs() < 0.000_1);
    assert_eq!(hit.position, Float3::new(2.0, 0.0, 0.0));
    assert_eq!(hit.normal, Float3::new(-1.0, 0.0, 0.0));
}

/// Sweep skips triggers unless the query includes them.
#[test]
fn sweep_skips_triggers_unless_included() {
    let mut runtime = runtime();

    let trigger = runtime.create_entity();
    runtime.set_local_transform(
        LocalTransform::from_translation(Float3::new(2.0, 0.0, 0.0)),
        trigger,
    );
    runtime.set_component(trigger_box(Float3::splat(0.5)), trigger);

    let solid = runtime.create_entity();
    runtime.set_local_transform(
        LocalTransform::from_translation(Float3::new(4.0, 0.0, 0.0)),
        solid,
    );
    runtime.set_component(box_collider(Float3::splat(0.5)), solid);

    tick(&mut runtime);

    let bounds = SpatialAABB::from_center_half_extents(Float3::ZERO, Float3::splat(0.5));
    let translation = Float3::new(10.0, 0.0, 0.0);
    let default_hit = runtime.sweep(SceneSweepQuery::new(bounds, translation));
    let trigger_hit = runtime.sweep(SceneSweepQuery::with_include_triggers(
        bounds,
        translation,
        true,
    ));

    assert_eq!(default_hit.map(|hit| hit.entity), Some(solid));
    let trigger_hit = trigger_hit.expect("trigger hit");
    assert_eq!(trigger_hit.entity, trigger);
    assert!(trigger_hit.is_trigger);
}

/// Sweep uses Natsel sphere geometry instead of broad-phase bounds.
#[test]
fn sweep_uses_precise_sphere_narrow_phase() {
    let mut runtime = runtime();

    let sphere = runtime.create_entity();
    runtime.set_component(sphere_collider(1.0), sphere);

    tick(&mut runtime);

    let hit = runtime.sweep(SceneSweepQuery::new(
        SpatialAABB::from_center_half_extents(Float3::new(-5.0, 1.0, 1.0), Float3::splat(0.05)),
        Float3::new(10.0, 0.0, 0.0),
    ));

    assert!(hit.is_none());
}

/// Physics sweep shape returns the nearest Natsel hit.
#[test]
fn physics_sweep_shape_returns_nearest_hit() {
    let mut runtime = runtime();

    let near_sphere = runtime.create_entity();
    runtime.set_local_transform(
        LocalTransform::from_translation(Float3::new(3.0, 0.0, 0.0)),
        near_sphere,
    );
    runtime.set_component(sphere_collider(0.5), near_sphere);

    let far_sphere = runtime.create_entity();
    runtime.set_local_transform(
        LocalTransform::from_translation(Float3::new(6.0, 0.0, 0.0)),
        far_sphere,
    );
    runtime.set_component(sphere_collider(0.5), far_sphere);

    tick(&mut runtime);

    let hit = runtime
        .physics_sweep_shape(
            PhysicsSweepShapeQuery::new(
                PhysicsQueryShape::Sphere { radius: 0.5 },
                Float3::ZERO,
                Float3::new(5.0, 0.0, 0.0),
            ),
            PhysicsQueryFilter::default(),
        )
        .expect("sweep hit");

    assert_eq!(hit.entity, near_sphere);
    assert!((hit.fraction - 0.4).abs() < 0.000_1);
    assert!((hit.distance - 2.0).abs() < 0.000_1);
    assert!((hit.position.x - 2.0).abs() < 0.000_1);
    assert!((hit.normal.x + 1.0).abs() < 0.000_1);
}

/// Physics sweep shape box hits a diagonal wall.
#[test]
fn physics_sweep_shape_box_hits_diagonal_wall() {
    let mut runtime = runtime();

    let wall = runtime.create_entity();
    runtime.set_local_transform(
        LocalTransform::from_translation(Float3::new(0.0, 2.0, -2.0)),
        wall,
    );
    runtime.set_component(box_collider(Float3::new(2.0, 2.0, 0.5)), wall);

    tick(&mut runtime);

    let hit = runtime
        .physics_sweep_shape(
            PhysicsSweepShapeQuery::new(
                PhysicsQueryShape::Box {
                    half_extents: Float3::new(0.5, 1.0, 0.5),
                },
                Float3::new(0.0, 2.0, 0.0),
                Float3::new(1.767_767, 0.0, -1.767_767),
            ),
            PhysicsQueryFilter::default(),
        )
        .expect("sweep hit");

    assert_eq!(hit.entity, wall);
    assert!(hit.distance < 1.5);
    assert!(hit.normal.z > 0.9);
}

/// Physics queries apply `excludeEntity` and layer filters.
#[test]
fn physics_queries_apply_unified_filters() {
    let mut runtime = runtime();

    let excluded = runtime.create_entity();
    runtime.set_local_transform(
        LocalTransform::from_translation(Float3::new(1.0, 0.0, 0.0)),
        excluded,
    );
    let mut collider = box_collider(Float3::splat(0.5));
    collider.layer_id = 1;
    collider.layer_mask = 0b0010;
    runtime.set_component(collider.clone(), excluded);

    let wrong_layer_id = runtime.create_entity();
    runtime.set_local_transform(
        LocalTransform::from_translation(Float3::new(3.0, 0.0, 0.0)),
        wrong_layer_id,
    );
    let mut collider = box_collider(Float3::splat(0.5));
    collider.layer_id = 2;
    collider.layer_mask = 0b0010;
    runtime.set_component(collider, wrong_layer_id);

    let wrong_layer_mask = runtime.create_entity();
    runtime.set_local_transform(
        LocalTransform::from_translation(Float3::new(5.0, 0.0, 0.0)),
        wrong_layer_mask,
    );
    let mut collider = box_collider(Float3::splat(0.5));
    collider.layer_id = 1;
    collider.layer_mask = 0b0100;
    runtime.set_component(collider, wrong_layer_mask);

    let filtered_hit = runtime.create_entity();
    runtime.set_local_transform(
        LocalTransform::from_translation(Float3::new(7.0, 0.0, 0.0)),
        filtered_hit,
    );
    let mut collider = box_collider(Float3::splat(0.5));
    collider.layer_id = 1;
    collider.layer_mask = 0b0010;
    runtime.set_component(collider, filtered_hit);

    tick(&mut runtime);

    let filter = PhysicsQueryFilter::with_options(
        Some(excluded),
        std::collections::BTreeSet::new(),
        false,
        Some(1),
        0b0010,
    );

    let raycast_hit = runtime.physics_raycast(
        PhysicsRaycastQuery::with_distance(
            Float3::new(-5.0, 0.0, 0.0),
            Float3::new(1.0, 0.0, 0.0),
            20.0,
        ),
        filter.clone(),
    );
    let overlap_hits = runtime.physics_overlap_aabb(
        PhysicsOverlapAABBQuery::new(SpatialAABB::from_center_half_extents(
            Float3::new(4.0, 0.0, 0.0),
            Float3::new(4.0, 1.0, 1.0),
        )),
        filter.clone(),
    );
    let sweep_hit = runtime.physics_sweep_aabb(
        PhysicsSweepAABBQuery::new(
            SpatialAABB::from_center_half_extents(Float3::ZERO, Float3::splat(0.5)),
            Float3::new(10.0, 0.0, 0.0),
        ),
        filter.clone(),
    );
    let shape_overlap_hits = runtime.physics_overlap_shape(
        PhysicsOverlapShapeQuery::new(
            PhysicsQueryShape::Sphere { radius: 4.0 },
            Float3::new(4.0, 0.0, 0.0),
        ),
        filter.clone(),
    );
    let shape_sweep_hit = runtime.physics_sweep_shape(
        PhysicsSweepShapeQuery::new(
            PhysicsQueryShape::Sphere { radius: 0.5 },
            Float3::ZERO,
            Float3::new(10.0, 0.0, 0.0),
        ),
        filter,
    );

    assert_eq!(raycast_hit.map(|hit| hit.entity), Some(filtered_hit));
    assert_eq!(boxes(&overlap_hits), vec![filtered_hit]);
    assert_eq!(sweep_hit.map(|hit| hit.entity), Some(filtered_hit));
    assert_eq!(boxes(&shape_overlap_hits), vec![filtered_hit]);
    assert_eq!(shape_sweep_hit.map(|hit| hit.entity), Some(filtered_hit));
}

/// Physics sweep reports the Natsel shape contact normal.
#[test]
fn physics_sweep_reports_precise_contact_normal() {
    let mut runtime = runtime();

    let sphere = runtime.create_entity();
    runtime.set_component(sphere_collider(1.0), sphere);

    tick(&mut runtime);

    let hit = runtime
        .physics_sweep_aabb(
            PhysicsSweepAABBQuery::new(
                SpatialAABB::from_center_half_extents(
                    Float3::new(-5.0, 0.5, 0.0),
                    Float3::splat(0.05),
                ),
                Float3::new(10.0, 0.0, 0.0),
            ),
            PhysicsQueryFilter::default(),
        )
        .expect("sweep hit");
    let expected_distance = 4.056_971_5f32;
    let expected_normal = Float3::new(-0.893_028_56, 0.45, 0.0);

    assert_eq!(hit.entity, sphere);
    assert!((hit.distance - expected_distance).abs() < 0.001);
    assert!((hit.normal.x - expected_normal.x).abs() < 0.01);
    assert!((hit.normal.y - expected_normal.y).abs() < 0.01);
}

/// The Natsel query scene is reused until the runtime revision changes.
#[test]
fn natsel_query_scene_caches_by_world_revision() {
    let mut runtime = runtime();
    let sphere = runtime.create_entity();
    runtime.set_component(sphere_collider(1.0), sphere);

    assert_eq!(
        runtime.physics_query_cache_stats(),
        PhysicsQueryCacheStats::default()
    );

    let first_hit = runtime.physics_raycast(
        PhysicsRaycastQuery::with_distance(
            Float3::new(-5.0, 0.0, 0.0),
            Float3::new(1.0, 0.0, 0.0),
            10.0,
        ),
        PhysicsQueryFilter::default(),
    );
    assert_eq!(first_hit.map(|hit| hit.entity), Some(sphere));
    let first_physics_revision = runtime.physics_query_cache_stats().source_revision;
    assert!(first_physics_revision.is_some());
    let stats = runtime.physics_query_cache_stats();
    assert_eq!(stats.body_count, 1);
    assert_eq!(stats.query_count, 1);
    assert_eq!(stats.rebuild_count, 1);
    assert_eq!(stats.cache_hit_count, 0);

    let overlap_hits = runtime.physics_overlap_aabb(
        PhysicsOverlapAABBQuery::new(SpatialAABB::from_center_half_extents(
            Float3::ZERO,
            Float3::splat(2.0),
        )),
        PhysicsQueryFilter::default(),
    );
    assert_eq!(boxes(&overlap_hits), vec![sphere]);
    let stats = runtime.physics_query_cache_stats();
    assert_eq!(stats.query_count, 2);
    assert_eq!(stats.rebuild_count, 1);
    assert_eq!(stats.cache_hit_count, 1);

    runtime.set_resource("render-only change");
    runtime.physics_raycast(
        PhysicsRaycastQuery::with_distance(
            Float3::new(-5.0, 0.0, 0.0),
            Float3::new(1.0, 0.0, 0.0),
            10.0,
        ),
        PhysicsQueryFilter::default(),
    );
    let stats = runtime.physics_query_cache_stats();
    assert_eq!(stats.source_revision, first_physics_revision);
    assert_eq!(stats.query_count, 3);
    assert_eq!(stats.rebuild_count, 1);
    assert_eq!(stats.cache_hit_count, 2);

    runtime.update_component::<Collider>(sphere, |collider| {
        collider.set_shape(ColliderShape::Sphere {
            radius: 2.0,
            center: Float3::ZERO,
        });
    });
    runtime.physics_raycast(
        PhysicsRaycastQuery::with_distance(
            Float3::new(-5.0, 0.0, 0.0),
            Float3::new(1.0, 0.0, 0.0),
            10.0,
        ),
        PhysicsQueryFilter::default(),
    );
    let stats = runtime.physics_query_cache_stats();
    assert_ne!(stats.source_revision, first_physics_revision);
    assert_eq!(stats.query_count, 4);
    assert_eq!(stats.rebuild_count, 2);
    assert_eq!(stats.cache_hit_count, 2);
}

/// Simulation and queries share the same persistent Natsel world.
#[test]
fn simulation_and_queries_share_natsel_world() {
    let mut runtime = runtime();
    runtime.set_resource(PhysicsSettingsResource {
        simulation_mode: PhysicsSimulationMode::Play,
        fixed_time_step_seconds: 1.0 / 60.0,
        max_substeps_per_frame: 1,
        ..PhysicsSettingsResource::default()
    });

    let ground = runtime.create_entity();
    runtime.set_component(box_collider(Float3::new(2.0, 0.5, 2.0)), ground);

    runtime.tick(1.0 / 60.0, 0, Vec::new());
    let stats_after_simulation = runtime.physics_query_cache_stats();
    assert_eq!(stats_after_simulation.body_count, 1);
    assert_eq!(stats_after_simulation.rebuild_count, 0);

    let hit = runtime
        .physics_raycast(
            PhysicsRaycastQuery::with_distance(
                Float3::new(0.0, 2.0, 0.0),
                Float3::new(0.0, -1.0, 0.0),
                10.0,
            ),
            PhysicsQueryFilter::default(),
        )
        .expect("raycast hit");

    assert_eq!(hit.entity, ground);
    let stats = runtime.physics_query_cache_stats();
    assert_eq!(stats.query_count, 1);
    assert_eq!(stats.rebuild_count, 0);
    assert_eq!(stats.cache_hit_count, 1);
}
