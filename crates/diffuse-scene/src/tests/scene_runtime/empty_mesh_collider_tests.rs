//! Ported from `Engine/Tests/SceneRuntimeTests/EmptyMeshColliderTests.swift`.
//!
//! Swift's `tick(deltaTime:)` carries no frame index; the Rust schedule takes one
//! plus the frame's input events, so every call here passes frame 0 and no input.
//! Swift's `@Test(arguments:)` over the three mesh-backed shapes becomes one test
//! per shape around a shared helper.

use std::collections::BTreeMap;

use diffuse_math::simd::simd_compat::{Float3, Float4};

use crate::components::core::registry::ComponentRegistry;
use crate::physics::backend::physics_backend_kind::PhysicsBackendKind;
use crate::physics::collider::{Collider, ColliderShape, ColliderShapeInstance};
use crate::physics::physics_settings::PhysicsSettingsResource;
use crate::physics::physics_types::PhysicsSimulationMode;
use crate::physics::queries::physics_query_types::{PhysicsQueryFilter, PhysicsRaycastQuery};
use crate::physics::queries::spatial_queries::{
    MeshColliderGeometry, MeshColliderGeometryResource,
};
use crate::physics::rigid_body::{RigidBody, RigidBodyOptions};
use crate::scene_runtime::SceneRuntime;

fn new_runtime() -> SceneRuntime {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    scene.set_physics_settings(PhysicsSettingsResource {
        simulation_mode: PhysicsSimulationMode::Play,
        backend_kind: PhysicsBackendKind::Natsel,
        gravity: Float3::ZERO,
        ..PhysicsSettingsResource::default()
    });
    scene
}

fn ray(origin: Float3, direction: Float3, max_distance: f32) -> PhysicsRaycastQuery {
    PhysicsRaycastQuery::with_distance(origin, direction, max_distance)
}

fn mesh_shape(resource_id: &str) -> ColliderShape {
    ColliderShape::Mesh {
        resource_id: Some(resource_id.to_string()),
        center: Float3::ZERO,
    }
}

/// An empty mesh is skipped while the remaining compound children keep the
/// authored child IDs.
#[test]
fn compound_child_identity() {
    let mut scene = new_runtime();
    let entity = scene.create_entity();
    scene.set_resource(MeshColliderGeometryResource::new(
        BTreeMap::from([(
            "edit".to_string(),
            MeshColliderGeometry::new(Vec::new(), Vec::new(), Vec::new(), Vec::new(), None, 0),
        )]),
        None,
    ));
    scene.set_component(
        Collider::with_shapes(vec![
            ColliderShapeInstance::new(mesh_shape("edit")),
            ColliderShapeInstance::with_transform(
                ColliderShape::Sphere {
                    radius: 0.5,
                    center: Float3::ZERO,
                },
                Float3::new(2.0, 0.0, 0.0),
                Float4::new(0.0, 0.0, 0.0, 1.0),
                Float3::ONE,
            ),
        ]),
        entity,
    );

    let report = scene.tick(0.0, 0, Vec::new());
    assert!(report.physics.error.is_none());

    let hit = scene.physics_raycast(
        ray(Float3::new(2.0, 0.0, 3.0), Float3::new(0.0, 0.0, -1.0), 6.0),
        PhysicsQueryFilter::default(),
    );
    assert!(
        hit.map(|hit| hit.entity == entity && hit.sub_shape_id == 1)
            .unwrap_or(false)
    );
}

fn empty_and_restore(shape: ColliderShape) {
    let mut scene = new_runtime();
    let entity = scene.create_entity();
    scene.set_component(Collider::with_shape(shape.clone()), entity);
    if matches!(shape, ColliderShape::Convex { .. }) {
        scene.set_component(
            RigidBody::new(RigidBodyOptions {
                gravity_scale: 0.0,
                allow_sleep: false,
                ..RigidBodyOptions::default()
            }),
            entity,
        );
    }

    let points: Vec<Float3> = vec![
        Float3::new(-1.0, -1.0, -1.0),
        Float3::new(1.0, -1.0, -1.0),
        Float3::new(1.0, 1.0, -1.0),
        Float3::new(-1.0, 1.0, -1.0),
        Float3::new(-1.0, -1.0, 1.0),
        Float3::new(1.0, -1.0, 1.0),
        Float3::new(1.0, 1.0, 1.0),
        Float3::new(-1.0, 1.0, 1.0),
    ];
    let faces: [[u32; 4]; 6] = [
        [0, 3, 2, 1],
        [4, 5, 6, 7],
        [0, 1, 5, 4],
        [3, 7, 6, 2],
        [0, 4, 7, 3],
        [1, 2, 6, 5],
    ];
    let mut triangle_indices: Vec<u32> = Vec::new();
    for face in faces {
        for index in [0_usize, 1, 2, 0, 2, 3] {
            triangle_indices.push(face[index]);
        }
    }
    let geometry =
        MeshColliderGeometry::new(points, triangle_indices, Vec::new(), Vec::new(), None, 0);

    let ray_query = ray(Float3::new(0.0, 0.0, 3.0), Float3::new(0.0, 0.0, -1.0), 6.0);
    for empty in [false, true, false] {
        let geometry = if empty {
            MeshColliderGeometry::new(Vec::new(), Vec::new(), Vec::new(), Vec::new(), None, 0)
        } else {
            geometry.clone()
        };
        scene.set_resource(MeshColliderGeometryResource::new(
            BTreeMap::from([("edit".to_string(), geometry)]),
            None,
        ));
        let report = scene.tick(1.0 / 60.0, 0, Vec::new());
        assert!(report.physics.error.is_none());
        assert!(scene.contains(entity));
        let hit = scene.physics_raycast(ray_query, PhysicsQueryFilter::default());
        assert_eq!(hit.map(|hit| hit.entity == entity).unwrap_or(false), !empty);
    }
}

#[test]
fn mesh_colliders_can_become_empty_and_recover() {
    empty_and_restore(mesh_shape("edit"));
}

#[test]
fn convex_colliders_can_become_empty_and_recover() {
    empty_and_restore(ColliderShape::Convex {
        resource_id: Some("edit".to_string()),
        center: Float3::ZERO,
    });
}

#[test]
fn height_field_colliders_can_become_empty_and_recover() {
    empty_and_restore(ColliderShape::HeightField {
        resource_id: Some("edit".to_string()),
        center: Float3::ZERO,
    });
}
