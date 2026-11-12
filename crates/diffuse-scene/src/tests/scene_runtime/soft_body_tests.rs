//! Ported from `Engine/Tests/SceneRuntimeTests/SoftBodyTests.swift`.
//!
//! Swift's `tick(deltaTime:)` has no frame index; the Rust schedule takes one plus
//! the frame's input events, so every call here supplies the loop index and no
//! input.

use std::collections::BTreeMap;

use diffuse_math::simd::simd_compat::{
    Float2, Float3, Float4, Float4x4, MATRIX_IDENTITY_FLOAT4X4, simd_length,
};

use crate::components::core::registry::ComponentRegistry;
use crate::entity_id::EntityID;
use crate::physics::backend::physics_backend_kind::PhysicsBackendKind;
use crate::physics::character_controller::{CharacterCommand, CharacterController, CharacterState};
use crate::physics::collider::{Collider, ColliderShape};
use crate::physics::physics_settings::{PhysicsCapacitySettings, PhysicsSettingsResource};
use crate::physics::physics_types::{PhysicsBackendErrorCode, PhysicsSimulationMode};
use crate::physics::queries::spatial_queries::{
    MeshColliderGeometry, MeshColliderGeometryResource,
};
use crate::physics::rigid_body::{RigidBody, RigidBodyOptions};
use crate::physics::soft_bodies::cloth::{Cloth, ClothBendType};
use crate::physics::soft_bodies::soft_body::{SoftBody, SoftBodyMesh, SoftBodyMeshState};
use crate::rendering::render_extraction::RenderMeshComponent;
use crate::runtime_world::LocalTransform;
use crate::scene_runtime::SceneRuntime;
use crate::serialization::scene_serializer::SceneSerializer;

const DELTA_TIME: f64 = 1.0 / 60.0;

fn make_runtime(gravity: Float3) -> SceneRuntime {
    let mut runtime = SceneRuntime::new(ComponentRegistry::built_in());
    runtime.set_physics_settings(PhysicsSettingsResource {
        simulation_mode: PhysicsSimulationMode::Play,
        backend_kind: PhysicsBackendKind::preferred(),
        gravity,
        fixed_time_step_seconds: DELTA_TIME,
        max_substeps_per_frame: 1,
        allow_sleep: false,
        capacity: PhysicsCapacitySettings::new(PhysicsCapacitySettings::default().max_bodies, 1),
        ..PhysicsSettingsResource::default()
    });
    runtime
}

fn runtime() -> SceneRuntime {
    make_runtime(Float3::new(0.0, -9.81, 0.0))
}

fn tick(runtime: &mut SceneRuntime, frame: u64) {
    let report = runtime.tick(DELTA_TIME, frame, Vec::new());
    assert!(report.physics.error.is_none());
}

fn state(runtime: &SceneRuntime, entity: EntityID) -> Option<SoftBodyMeshState> {
    runtime.soft_body_state_frame().states.get(&entity).cloned()
}

fn y(positions: &[Float3], index: usize) -> f32 {
    positions
        .get(index)
        .map(|position| position.y)
        .unwrap_or(0.0)
}

/// Natsel cloth streams deformed vertices while fixed vertices stay pinned.
#[test]
fn cloth_simulation_and_vertex_streaming() {
    let mut runtime = runtime();
    let cloth_entity = runtime.create_entity();
    runtime.set_local_transform(
        LocalTransform::from_translation(Float3::new(0.0, 5.0, 0.0)),
        cloth_entity,
    );
    runtime.set_component(
        Cloth::new(
            4,
            4,
            0.5,
            vec![0, 3],
            1.0e-5,
            1.0e-5,
            1.0e-5,
            ClothBendType::Distance,
        ),
        cloth_entity,
    );
    runtime.set_component(
        SoftBody {
            linear_damping: 0.02,
            allow_sleep: false,
            ..SoftBody::default()
        },
        cloth_entity,
    );

    for frame in 0..30u64 {
        tick(&mut runtime, frame);
    }

    let cloth_state = state(&runtime, cloth_entity).expect("cloth state");
    assert_eq!(cloth_state.positions.len(), 16);
    assert_eq!(cloth_state.triangle_indices.len(), 54);
    assert_eq!(runtime.soft_body_state_frame().vertex_count, 16);
    assert!((y(&cloth_state.positions, 0) - 5.0).abs() < 0.01);
    assert!((y(&cloth_state.positions, 3) - 5.0).abs() < 0.01);
    assert!(y(&cloth_state.positions, 10) < 4.8);
}

/// The cloth vertex stream reaches the render scene and survives a frame that
/// does not step physics.
#[test]
fn cloth_render_extraction_and_no_step_persistence() {
    let mut runtime = runtime();
    let entity = runtime.create_entity();
    runtime.set_local_transform(
        LocalTransform::from_translation(Float3::new(2.0, 5.0, -1.0)),
        entity,
    );
    runtime.set_component(
        Cloth::new(
            4,
            3,
            0.4,
            (0..12).collect(),
            1.0e-5,
            1.0e-5,
            1.0e-5,
            ClothBendType::Distance,
        ),
        entity,
    );
    runtime.set_component(
        SoftBody {
            linear_damping: 0.02,
            allow_sleep: false,
            ..SoftBody::default()
        },
        entity,
    );
    runtime.set_component(
        RenderMeshComponent::new(0, true, Float3::splat(1.0), None, Vec::new()),
        entity,
    );

    tick(&mut runtime, 0);
    let scene = runtime.render_scene();
    let first = scene.deformable_meshes.first().expect("deformable mesh");
    let instance = scene
        .instances
        .iter()
        .find(|instance| instance.entity == Some(entity))
        .expect("instance");
    assert_eq!(first.entity, entity);
    assert_eq!(first.positions.len(), 12);
    assert_eq!(first.triangle_indices.len() / 3, 12);
    assert_eq!(
        first.texture_coordinates.first(),
        Some(&Float2::new(0.0, 0.0))
    );
    assert_eq!(
        first.texture_coordinates.last(),
        Some(&Float2::new(1.0, 1.0))
    );
    assert!(
        first
            .normals
            .iter()
            .all(|normal| (simd_length(*normal) - 1.0).abs() < 0.001)
    );
    assert_eq!(instance.transform, MATRIX_IDENTITY_FLOAT4X4);

    let first_positions = first.positions.clone();
    let first_revision = first.revision;
    runtime.tick(0.0, 1, Vec::new());
    let preserved = runtime
        .render_scene()
        .deformable_meshes
        .first()
        .cloned()
        .expect("deformable mesh");
    assert_eq!(preserved.positions, first_positions);
    assert_eq!(preserved.revision, first_revision);
    assert_eq!(
        state(&runtime, entity).expect("cloth state").positions,
        first_positions
    );

    tick(&mut runtime, 2);
    let pinned = runtime
        .render_scene()
        .deformable_meshes
        .first()
        .cloned()
        .expect("deformable mesh");
    assert_eq!(pinned.positions, first_positions);
    assert_eq!(pinned.revision, first_revision);
}

/// Removing cloth topology removes its native soft body and streamed state.
#[test]
fn incremental_removal() {
    let mut runtime = make_runtime(Float3::ZERO);
    let entity = runtime.create_entity();
    runtime.set_component(
        Cloth::new(
            3,
            3,
            0.2,
            Vec::new(),
            1.0e-5,
            1.0e-5,
            1.0e-5,
            ClothBendType::Distance,
        ),
        entity,
    );
    runtime.set_component(
        SoftBody {
            vertex_radius: 0.03,
            allow_sleep: false,
            self_collision: true,
            ..SoftBody::default()
        },
        entity,
    );

    tick(&mut runtime, 0);
    assert_eq!(
        state(&runtime, entity)
            .expect("cloth state")
            .positions
            .len(),
        9
    );

    runtime.remove_component::<Cloth>(entity);
    tick(&mut runtime, 1);
    assert!(state(&runtime, entity).is_none());
    assert_eq!(runtime.soft_body_state_frame().vertex_count, 0);
}

/// Free cloth collides with static scene geometry.
#[test]
fn cloth_collides_with_static_ground() {
    let mut runtime = runtime();
    let ground = runtime.create_entity();
    runtime.set_local_transform(
        LocalTransform::from_translation(Float3::new(0.0, -0.25, 0.0)),
        ground,
    );
    runtime.set_component(
        Collider::with_shape(ColliderShape::Box {
            half_extents: Float3::new(4.0, 0.25, 4.0),
            center: Float3::ZERO,
        }),
        ground,
    );

    let cloth_entity = runtime.create_entity();
    runtime.set_local_transform(
        LocalTransform::from_translation(Float3::new(0.0, 2.0, 0.0)),
        cloth_entity,
    );
    runtime.set_component(
        Cloth::new(
            6,
            6,
            0.25,
            Vec::new(),
            1.0e-5,
            1.0e-5,
            1.0e-5,
            ClothBendType::Distance,
        ),
        cloth_entity,
    );
    runtime.set_component(
        SoftBody {
            vertex_radius: 0.03,
            allow_sleep: false,
            ..SoftBody::default()
        },
        cloth_entity,
    );

    for frame in 0..120u64 {
        tick(&mut runtime, frame);
    }
    let cloth_state = state(&runtime, cloth_entity).expect("cloth state");
    let minimum_y = cloth_state
        .positions
        .iter()
        .map(|position| position.y)
        .fold(f32::INFINITY, f32::min);
    let maximum_y = cloth_state
        .positions
        .iter()
        .map(|position| position.y)
        .fold(f32::NEG_INFINITY, f32::max);
    assert!(minimum_y > -0.08);
    assert!(maximum_y < 0.3);
}

/// Pinned cloth collides with a dynamic rigid body.
#[test]
fn cloth_collides_with_dynamic_body() {
    let mut runtime = runtime();
    let cloth_entity = runtime.create_entity();
    runtime.set_local_transform(
        LocalTransform::from_translation(Float3::new(0.0, 2.0, 0.0)),
        cloth_entity,
    );
    let size = 9i64;
    let fixed_boundary: Vec<i64> = (0..(size * size))
        .filter(|index| {
            let x = index % size;
            let z = index / size;
            x == 0 || z == 0 || x == size - 1 || z == size - 1
        })
        .collect();
    runtime.set_component(
        Cloth::new(
            size,
            size,
            0.25,
            fixed_boundary,
            0.0,
            0.0,
            0.0,
            ClothBendType::Dihedral,
        ),
        cloth_entity,
    );
    runtime.set_component(
        SoftBody {
            vertex_mass: 0.25,
            vertex_radius: 0.025,
            allow_sleep: false,
            ..SoftBody::default()
        },
        cloth_entity,
    );

    let sphere = runtime.create_entity();
    runtime.set_local_transform(
        LocalTransform::from_translation(Float3::new(0.0, 3.25, 0.0)),
        sphere,
    );
    runtime.set_component(
        Collider::with_shape(ColliderShape::Sphere {
            radius: 0.25,
            center: Float3::ZERO,
        }),
        sphere,
    );
    runtime.set_component(
        RigidBody::new(RigidBodyOptions {
            mass: 0.5,
            allow_sleep: false,
            ..RigidBodyOptions::default()
        }),
        sphere,
    );

    for frame in 0..120u64 {
        tick(&mut runtime, frame);
    }
    let sphere_y = runtime
        .world_transform(sphere)
        .map(|transform| transform.translation().y)
        .expect("sphere transform");
    let cloth_state = state(&runtime, cloth_entity).expect("cloth state");
    assert!(sphere_y > 1.0);
    assert_eq!(cloth_state.positions.len(), (size * size) as usize);
}

/// A native character stands on pinned cloth only when both collision masks
/// allow it.
#[test]
fn cloth_supports_character() {
    for filter_case in 0..3 {
        let mut runtime = runtime();
        let cloth_entity = runtime.create_entity();
        runtime.set_local_transform(
            LocalTransform::from_translation(Float3::new(0.0, 2.0, 0.0)),
            cloth_entity,
        );
        runtime.set_component(
            Cloth::new(
                9,
                9,
                0.3,
                (0..81).collect(),
                0.0,
                0.0,
                0.0,
                ClothBendType::Distance,
            ),
            cloth_entity,
        );
        runtime.set_component(
            SoftBody {
                vertex_radius: 0.03,
                layer_id: 1,
                layer_mask: if filter_case == 1 { 0 } else { u16::MAX },
                allow_sleep: false,
                ..SoftBody::default()
            },
            cloth_entity,
        );

        let character = runtime.create_entity();
        runtime.set_local_transform(
            LocalTransform::from_translation(Float3::new(0.0, 4.0, 0.0)),
            character,
        );
        runtime.set_component(
            CharacterController {
                layer_mask: if filter_case == 2 { 1 } else { u16::MAX },
                ..CharacterController::default()
            },
            character,
        );

        for frame in 0..120u64 {
            runtime.submit_character_command(CharacterCommand::default(), character);
            tick(&mut runtime, frame);
        }
        let character_state: Option<CharacterState> = runtime
            .character_state_frame()
            .states
            .get(&character)
            .cloned();
        if filter_case == 0 {
            let character_state = character_state.expect("character state");
            assert!(character_state.is_grounded());
            assert!((character_state.position.y - 2.0).abs() < 0.15);
        } else {
            let character_state = character_state.expect("character state");
            assert!(!character_state.is_grounded());
            assert!(character_state.position.y < 0.0);
        }
    }
}

/// Independent cloth simulations produce identical checkpoint hashes.
#[test]
fn deterministic_state_hashes() {
    fn make_cloth_runtime() -> SceneRuntime {
        let mut runtime = runtime();
        let entity = runtime.create_entity();
        runtime.set_local_transform(
            LocalTransform::from_translation(Float3::new(0.0, 4.0, 0.0)),
            entity,
        );
        runtime.set_component(Cloth::fixed_top_edge(8, 8, 0.2), entity);
        runtime.set_component(
            SoftBody {
                linear_damping: 0.05,
                allow_sleep: false,
                ..SoftBody::default()
            },
            entity,
        );
        runtime
    }

    let mut first = make_cloth_runtime();
    let mut second = make_cloth_runtime();
    for frame in 0..90u64 {
        tick(&mut first, frame);
        tick(&mut second, frame);
        assert_eq!(
            first.physics_state_hash_frame(),
            second.physics_state_hash_frame()
        );
    }
    assert_ne!(first.physics_state_hash_frame().hash, 0);
}

/// Self collision separates disconnected folded surfaces deterministically.
#[test]
fn self_collision_separates_folded_surfaces() {
    let positions: Vec<Float3> = vec![
        Float3::new(-0.5, 0.0, -0.5),
        Float3::new(0.5, 0.0, -0.5),
        Float3::new(0.0, 0.0, 0.5),
        Float3::new(-0.5, 0.01, -0.5),
        Float3::new(0.5, 0.01, -0.5),
        Float3::new(0.0, 0.01, 0.5),
    ];
    let triangles: Vec<u32> = vec![0, 2, 1, 3, 5, 4];

    fn configured_runtime(positions: &[Float3], triangles: &[u32]) -> (SceneRuntime, EntityID) {
        let mut runtime = make_runtime(Float3::ZERO);
        runtime.set_resource(MeshColliderGeometryResource::new(
            BTreeMap::from([(
                "self-collision.fold".to_string(),
                MeshColliderGeometry::new(
                    positions.to_vec(),
                    triangles.to_vec(),
                    Vec::new(),
                    Vec::new(),
                    None,
                    1,
                ),
            )]),
            None,
        ));
        let entity = runtime.create_entity();
        runtime.set_component(
            SoftBodyMesh::new(
                Some("self-collision.fold".to_string()),
                Vec::new(),
                0.0,
                0.0,
                0.0,
                0.0,
                ClothBendType::None,
            ),
            entity,
        );
        runtime.set_component(
            SoftBody {
                linear_damping: 0.0,
                gravity_scale: 0.0,
                vertex_radius: 0.05,
                solver_iterations: 4,
                max_linear_velocity: 20.0,
                allow_sleep: false,
                self_collision: true,
                ..SoftBody::default()
            },
            entity,
        );
        (runtime, entity)
    }

    let (mut first, first_entity) = configured_runtime(&positions, &triangles);
    let (mut second, second_entity) = configured_runtime(&positions, &triangles);
    for frame in 0..12u64 {
        tick(&mut first, frame);
        tick(&mut second, frame);
    }

    let first_state = state(&first, first_entity).expect("first state");
    let second_state = state(&second, second_entity).expect("second state");
    assert_eq!(first_state.positions, second_state.positions);
    let lower_y = first_state.positions[0..3]
        .iter()
        .map(|position| position.y)
        .sum::<f32>()
        / 3.0;
    let upper_y = first_state.positions[3..6]
        .iter()
        .map(|position| position.y)
        .sum::<f32>()
        / 3.0;
    assert!((upper_y - lower_y).abs() >= 0.045);
}

/// Self collision with a zero vertex radius returns an explicit native error.
#[test]
fn self_collision_rejects_zero_radius() {
    let mut runtime = make_runtime(Float3::ZERO);
    let entity = runtime.create_entity();
    runtime.set_component(
        Cloth::new(
            3,
            3,
            0.2,
            Vec::new(),
            1.0e-5,
            1.0e-5,
            1.0e-5,
            ClothBendType::Distance,
        ),
        entity,
    );
    runtime.set_component(
        SoftBody {
            vertex_radius: 0.0,
            self_collision: true,
            ..SoftBody::default()
        },
        entity,
    );

    let report = runtime.tick(DELTA_TIME, 0, Vec::new());
    assert_eq!(
        report.physics.error.map(|error| error.code),
        Some(PhysicsBackendErrorCode::InvalidArgument)
    );
    assert!(state(&runtime, entity).is_none());
}

/// An arbitrary triangle surface simulates, scales, and streams through the
/// render scene.
#[test]
fn arbitrary_triangle_surface() {
    let mut runtime = runtime();
    let positions: Vec<Float3> = vec![
        Float3::new(-0.75, 0.0, -0.5),
        Float3::new(0.75, 0.0, -0.5),
        Float3::new(0.0, 0.0, 0.75),
        Float3::new(0.0, 1.0, 0.0),
    ];
    let indices: Vec<u32> = vec![0, 2, 1, 0, 1, 3, 1, 2, 3, 2, 0, 3];
    let texture_coordinates: Vec<Float2> = vec![
        Float2::new(0.0, 0.0),
        Float2::new(1.0, 0.0),
        Float2::new(0.5, 1.0),
        Float2::new(0.5, 0.5),
    ];
    runtime.set_resource(MeshColliderGeometryResource::new(
        BTreeMap::from([(
            "soft.tetra".to_string(),
            MeshColliderGeometry::new(
                positions,
                indices.clone(),
                Vec::new(),
                texture_coordinates.clone(),
                None,
                7,
            ),
        )]),
        None,
    ));

    let entity = runtime.create_entity();
    let transform = Float4x4::from_columns([
        Float4::new(1.5, 0.0, 0.0, 0.0),
        Float4::new(0.0, 2.0, 0.0, 0.0),
        Float4::new(0.0, 0.0, 0.75, 0.0),
        Float4::new(0.0, 4.0, 0.0, 1.0),
    ]);
    runtime.set_local_transform(LocalTransform::new(transform), entity);
    runtime.set_component(
        SoftBodyMesh::new(
            Some("soft.tetra".to_string()),
            vec![3],
            1.0e-5,
            1.0e-5,
            1.0e-5,
            1.0e-6,
            ClothBendType::Distance,
        ),
        entity,
    );
    runtime.set_component(
        SoftBody {
            linear_damping: 0.02,
            allow_sleep: false,
            ..SoftBody::default()
        },
        entity,
    );
    runtime.set_component(
        RenderMeshComponent::new(0, true, Float3::splat(1.0), None, Vec::new()),
        entity,
    );

    for frame in 0..30u64 {
        tick(&mut runtime, frame);
    }

    let soft_state = state(&runtime, entity).expect("soft body state");
    assert_eq!(soft_state.positions.len(), 4);
    assert_eq!(soft_state.triangle_indices, indices);
    assert!((y(&soft_state.positions, 3) - 6.0).abs() < 0.02);
    assert!(y(&soft_state.positions, 0) < 3.999);
    let rendered = runtime
        .render_scene()
        .deformable_meshes
        .first()
        .cloned()
        .expect("deformable mesh");
    assert_eq!(rendered.entity, entity);
    assert_eq!(rendered.texture_coordinates, texture_coordinates);
    assert_eq!(rendered.triangle_indices, indices);
}

fn signed_six_volume(vertices: &[Float3]) -> f32 {
    let a = vertices[0] - vertices[3];
    let b = vertices[1] - vertices[3];
    let c = vertices[2] - vertices[3];
    let b_cross_c = Float3::new(
        b.y * c.z - b.z * c.y,
        b.z * c.x - b.x * c.z,
        b.x * c.y - b.y * c.x,
    );
    a.x * b_cross_c.x + a.y * b_cross_c.y + a.z * b_cross_c.z
}

/// Tetrahedral volume constraints preserve volume and stream the surface.
#[test]
fn tetrahedral_volume() {
    let positions: Vec<Float3> = vec![
        Float3::new(-1.0, 0.0, -1.0),
        Float3::new(1.0, 0.0, -1.0),
        Float3::new(0.0, 0.0, 1.0),
        Float3::new(0.0, 1.0, 0.0),
    ];
    let triangles: Vec<u32> = vec![0, 2, 1, 0, 1, 3, 1, 2, 3, 2, 0, 3];

    fn simulate(
        positions: &[Float3],
        triangles: &[u32],
        tetrahedron_indices: Vec<u32>,
    ) -> SoftBodyMeshState {
        let mut runtime = runtime();
        runtime.set_resource(MeshColliderGeometryResource::new(
            BTreeMap::from([(
                "deformable.tetra".to_string(),
                MeshColliderGeometry::new(
                    positions.to_vec(),
                    triangles.to_vec(),
                    tetrahedron_indices,
                    Vec::new(),
                    None,
                    11,
                ),
            )]),
            None,
        ));
        let entity = runtime.create_entity();
        runtime.set_local_transform(
            LocalTransform::from_translation(Float3::new(0.0, 4.0, 0.0)),
            entity,
        );
        runtime.set_component(
            SoftBodyMesh::new(
                Some("deformable.tetra".to_string()),
                vec![0, 1, 2],
                0.05,
                0.05,
                0.05,
                0.0,
                ClothBendType::None,
            ),
            entity,
        );
        runtime.set_component(
            SoftBody {
                linear_damping: 0.0,
                solver_iterations: 12,
                allow_sleep: false,
                ..SoftBody::default()
            },
            entity,
        );
        runtime.set_component(
            RenderMeshComponent::new(0, true, Float3::splat(1.0), None, Vec::new()),
            entity,
        );
        for frame in 0..60u64 {
            tick(&mut runtime, frame);
        }
        assert_eq!(
            runtime
                .render_scene()
                .deformable_meshes
                .first()
                .map(|mesh| mesh.triangle_indices.clone()),
            Some(triangles.to_vec())
        );
        state(&runtime, entity).expect("soft body state")
    }

    let volume_state = simulate(&positions, &triangles, vec![0, 1, 2, 3]);
    let surface_state = simulate(&positions, &triangles, Vec::new());
    let rest_six_volume = signed_six_volume(&positions).abs();
    let constrained_six_volume = signed_six_volume(&volume_state.positions).abs();
    let surface_six_volume = signed_six_volume(&surface_state.positions).abs();
    let constrained_error = (constrained_six_volume - rest_six_volume).abs();
    let surface_error = (surface_six_volume - rest_six_volume).abs();
    assert!(
        constrained_error < rest_six_volume * 0.05,
        "rest 6V={rest_six_volume}, constrained 6V={constrained_six_volume}"
    );
    assert!(
        surface_error > constrained_error + rest_six_volume * 0.25,
        "surface 6V={surface_six_volume}, constrained 6V={constrained_six_volume}"
    );
    assert_eq!(
        simulate(&positions, &triangles, vec![0, 1, 2, 3]),
        volume_state
    );
}

/// Tetrahedral assets connect an interior vertex to the rendered surface.
#[test]
fn tetrahedral_interior_edges() {
    let positions: Vec<Float3> = vec![
        Float3::new(-1.0, 0.0, -1.0),
        Float3::new(1.0, 0.0, -1.0),
        Float3::new(0.0, 0.0, 1.0),
        Float3::new(0.0, 1.0, 0.0),
        Float3::new(0.0, 0.25, -0.25),
    ];
    let triangles: Vec<u32> = vec![0, 2, 1, 0, 1, 3, 1, 2, 3, 2, 0, 3];
    let tetrahedra: Vec<u32> = vec![0, 1, 2, 4, 0, 3, 1, 4, 1, 3, 2, 4, 2, 3, 0, 4];
    let mut runtime = runtime();
    runtime.set_resource(MeshColliderGeometryResource::new(
        BTreeMap::from([(
            "deformable.interior".to_string(),
            MeshColliderGeometry::new(
                positions,
                triangles.clone(),
                tetrahedra,
                Vec::new(),
                None,
                0,
            ),
        )]),
        None,
    ));
    let entity = runtime.create_entity();
    runtime.set_local_transform(
        LocalTransform::from_translation(Float3::new(0.0, 4.0, 0.0)),
        entity,
    );
    runtime.set_component(
        SoftBodyMesh::new(
            Some("deformable.interior".to_string()),
            vec![0, 1, 2, 3],
            0.0,
            0.0,
            0.0,
            0.0,
            ClothBendType::Dihedral,
        ),
        entity,
    );
    runtime.set_component(
        SoftBody {
            solver_iterations: 12,
            allow_sleep: false,
            ..SoftBody::default()
        },
        entity,
    );

    for frame in 0..60u64 {
        tick(&mut runtime, frame);
    }
    let soft_state = state(&runtime, entity).expect("soft body state");
    assert_eq!(soft_state.positions.len(), 5);
    assert_eq!(soft_state.triangle_indices, triangles);
    assert!((y(&soft_state.positions, 4) - 4.25).abs() < 0.05);
}

/// Missing arbitrary soft-body geometry returns an explicit native error.
#[test]
fn missing_arbitrary_surface_geometry() {
    let mut runtime = runtime();
    let entity = runtime.create_entity();
    runtime.set_component(SoftBody::default(), entity);
    runtime.set_component(
        SoftBodyMesh {
            resource_id: Some("missing.soft.asset".to_string()),
            ..SoftBodyMesh::default()
        },
        entity,
    );

    let report = runtime.tick(DELTA_TIME, 0, Vec::new());
    assert_eq!(
        report.physics.error.map(|error| error.code),
        Some(PhysicsBackendErrorCode::InvalidArgument)
    );
    assert!(state(&runtime, entity).is_none());
}

/// Malformed arbitrary surface topology returns an explicit native error.
#[test]
fn malformed_arbitrary_surface_topology() {
    let malformed_geometries = vec![
        MeshColliderGeometry::new(
            vec![
                Float3::ZERO,
                Float3::new(1.0, 0.0, 0.0),
                Float3::new(0.0, 1.0, 0.0),
            ],
            vec![0, 1, 3],
            Vec::new(),
            Vec::new(),
            None,
            0,
        ),
        MeshColliderGeometry::new(
            vec![
                Float3::ZERO,
                Float3::new(1.0, 0.0, 0.0),
                Float3::new(0.0, 1.0, 0.0),
            ],
            vec![0, 1, 1],
            Vec::new(),
            Vec::new(),
            None,
            0,
        ),
        MeshColliderGeometry::new(
            vec![
                Float3::ZERO,
                Float3::new(1.0, 0.0, 0.0),
                Float3::new(2.0, 0.0, 0.0),
            ],
            vec![0, 1, 2],
            Vec::new(),
            Vec::new(),
            None,
            0,
        ),
        MeshColliderGeometry::new(
            vec![
                Float3::ZERO,
                Float3::new(1.0, 0.0, 0.0),
                Float3::new(f32::NAN, 1.0, 0.0),
            ],
            vec![0, 1, 2],
            Vec::new(),
            Vec::new(),
            None,
            0,
        ),
    ];

    for (index, geometry) in malformed_geometries.into_iter().enumerate() {
        let mut runtime = runtime();
        let resource_id = format!("malformed.{index}");
        runtime.set_resource(MeshColliderGeometryResource::new(
            BTreeMap::from([(resource_id.clone(), geometry)]),
            None,
        ));
        let entity = runtime.create_entity();
        runtime.set_component(SoftBody::default(), entity);
        runtime.set_component(
            SoftBodyMesh {
                resource_id: Some(resource_id),
                ..SoftBodyMesh::default()
            },
            entity,
        );

        let report = runtime.tick(DELTA_TIME, 0, Vec::new());
        assert_eq!(
            report.physics.error.map(|error| error.code),
            Some(PhysicsBackendErrorCode::InvalidArgument)
        );
        assert!(state(&runtime, entity).is_none());
    }
}

/// Malformed tetrahedra return an explicit native error.
#[test]
fn malformed_tetrahedral_topology() {
    let positions: Vec<Float3> = vec![
        Float3::ZERO,
        Float3::new(1.0, 0.0, 0.0),
        Float3::new(0.0, 1.0, 0.0),
        Float3::new(0.0, 0.0, 1.0),
    ];
    let triangles: Vec<u32> = vec![0, 2, 1, 0, 1, 3, 1, 2, 3, 2, 0, 3];
    let malformed_tetrahedra: Vec<Vec<u32>> =
        vec![vec![0, 1, 2], vec![0, 1, 2, 4], vec![0, 1, 2, 2]];

    for (index, tetrahedra) in malformed_tetrahedra.into_iter().enumerate() {
        let mut runtime = runtime();
        let resource_id = format!("malformed.tetra.{index}");
        runtime.set_resource(MeshColliderGeometryResource::new(
            BTreeMap::from([(
                resource_id.clone(),
                MeshColliderGeometry::new(
                    positions.clone(),
                    triangles.clone(),
                    tetrahedra,
                    Vec::new(),
                    None,
                    0,
                ),
            )]),
            None,
        ));
        let entity = runtime.create_entity();
        runtime.set_component(SoftBody::default(), entity);
        runtime.set_component(
            SoftBodyMesh {
                resource_id: Some(resource_id),
                ..SoftBodyMesh::default()
            },
            entity,
        );

        let report = runtime.tick(DELTA_TIME, 0, Vec::new());
        assert_eq!(
            report.physics.error.map(|error| error.code),
            Some(PhysicsBackendErrorCode::InvalidArgument)
        );
        assert!(state(&runtime, entity).is_none());
    }

    let mut zero_volume_runtime = runtime();
    zero_volume_runtime.set_resource(MeshColliderGeometryResource::new(
        BTreeMap::from([(
            "zero.volume".to_string(),
            MeshColliderGeometry::new(
                vec![
                    Float3::ZERO,
                    Float3::new(1.0, 0.0, 0.0),
                    Float3::new(0.0, 1.0, 0.0),
                    Float3::new(1.0, 1.0, 0.0),
                ],
                vec![0, 1, 2, 1, 3, 2],
                vec![0, 1, 2, 3],
                Vec::new(),
                None,
                0,
            ),
        )]),
        None,
    ));
    let entity = zero_volume_runtime.create_entity();
    zero_volume_runtime.set_component(SoftBody::default(), entity);
    zero_volume_runtime.set_component(
        SoftBodyMesh {
            resource_id: Some("zero.volume".to_string()),
            ..SoftBodyMesh::default()
        },
        entity,
    );
    assert_eq!(
        zero_volume_runtime
            .tick(DELTA_TIME, 0, Vec::new())
            .physics
            .error
            .map(|error| error.code),
        Some(PhysicsBackendErrorCode::InvalidArgument)
    );
}

/// Cloth and surface topology on one entity is rejected.
#[test]
fn conflicting_topology() {
    let mut runtime = runtime();
    let entity = runtime.create_entity();
    runtime.set_component(SoftBody::default(), entity);
    runtime.set_component(
        Cloth::new(
            3,
            3,
            0.2,
            Vec::new(),
            1.0e-5,
            1.0e-5,
            1.0e-5,
            ClothBendType::Distance,
        ),
        entity,
    );
    runtime.set_component(
        SoftBodyMesh {
            resource_id: Some("soft.asset".to_string()),
            ..SoftBodyMesh::default()
        },
        entity,
    );

    let report = runtime.tick(DELTA_TIME, 0, Vec::new());
    assert_eq!(
        report.physics.error.map(|error| error.code),
        Some(PhysicsBackendErrorCode::InvalidArgument)
    );
    assert!(state(&runtime, entity).is_none());
}

/// Soft-body and cloth configuration survives a scene round-trip.
#[test]
fn scene_round_trip() {
    let mut original = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = original.create_entity();
    let soft_body = SoftBody::new(
        0.75, 2.0, 0.3, 0.6, 0.1, 0.8, 0.04, 9, 80.0, 3, 0x00FF, false, false, true, true,
    );
    let cloth = Cloth::new(
        5,
        7,
        0.15,
        vec![0, 2, 4],
        0.002,
        0.003,
        0.004,
        ClothBendType::Dihedral,
    );
    original.set_component(soft_body.clone(), entity);
    original.set_component(cloth.clone(), entity);

    let mesh_entity = original.create_entity();
    let soft_body_mesh = SoftBodyMesh::new(
        Some("asset:deformable.tetra".to_string()),
        vec![1, 4, 7],
        0.005,
        0.006,
        0.007,
        0.008,
        ClothBendType::Distance,
    );
    original.set_component(soft_body.clone(), mesh_entity);
    original.set_component(soft_body_mesh.clone(), mesh_entity);

    let data = SceneSerializer::serialize(original.world()).expect("serialize");
    let mut restored = SceneRuntime::new(ComponentRegistry::built_in());
    SceneSerializer::deserialize(&data, restored.world_mut()).expect("deserialize");
    let mut restored_entities = restored.entities();
    restored_entities.sort_by_key(|entity| entity.raw_value());
    let restored_entity = restored_entities[0];
    assert_eq!(
        restored.component::<SoftBody>(restored_entity),
        Some(soft_body.clone())
    );
    assert_eq!(restored.component::<Cloth>(restored_entity), Some(cloth));
    let restored_mesh_entity = *restored_entities.last().expect("mesh entity");
    assert_eq!(
        restored.component::<SoftBody>(restored_mesh_entity),
        Some(soft_body)
    );
    assert_eq!(
        restored.component::<SoftBodyMesh>(restored_mesh_entity),
        Some(soft_body_mesh)
    );
}
