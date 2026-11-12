//! Ported from `Editor/Tests/EditorCoreTests/EditorSceneAdapterTests.swift`.

/// Ragdoll generator builds bodies, colliders, joints and palette mappings.
#[test]
fn generates_ragdoll_from_skin() {
    use diffuse_assets::asset_pipeline::{MeshAsset, MeshNode, MeshSkin};
    use diffuse_assets::asset_registry::AssetRegistry;
    use diffuse_math::simd::simd_compat::{Float3, Float4, MATRIX_IDENTITY_FLOAT4X4};
    use diffuse_scene::components::core::registry::ComponentRegistry;
    use diffuse_scene::physics::collider::Collider;
    use diffuse_scene::physics::joints::physics_joint::PhysicsJoint;
    use diffuse_scene::physics::ragdoll::Ragdoll;
    use diffuse_scene::physics::rigid_body::RigidBody;
    use diffuse_scene::runtime_world::LocalTransform;
    use diffuse_scene::scene_bootstrap::{AssetReferenceComponent, SceneNameComponent};
    use diffuse_scene::scene_runtime::SceneRuntime;

    use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
    use crate::scene::inspector::rendering::renderers::EditorInspectorRendererRegistry;

    let mesh_index = 98_765;
    let mut translation = MATRIX_IDENTITY_FLOAT4X4;
    translation.set_column(3, Float4::new(0.0, -1.0, 0.0, 1.0));
    let hips = MeshNode {
        name: Some("hips".to_string()),
        ..MeshNode::default()
    };
    let spine = MeshNode {
        name: Some("spine".to_string()),
        parent_index: Some(0),
        local_translation: Float3::new(0.0, 1.0, 0.0),
        ..MeshNode::default()
    };
    let mut mesh = MeshAsset::new("ragdoll-test", Vec::new(), Vec::new());
    mesh.nodes = vec![hips, spine];
    mesh.skins = vec![MeshSkin {
        name: None,
        joint_node_indices: vec![0, 1],
        inverse_bind_matrices: vec![MATRIX_IDENTITY_FLOAT4X4, translation],
    }];
    AssetRegistry::shared().register_for_testing(mesh, mesh_index);

    let adapter = EditorSceneAdapter::new(
        false,
        ComponentRegistry::built_in(),
        EditorInspectorRendererRegistry::new(),
    );
    adapter.set_scene(SceneRuntime::new(ComponentRegistry::built_in()));
    let root = adapter.with_scene_mut(|scene| {
        let root = scene.create_entity();
        scene.set_local_transform(LocalTransform::IDENTITY, root);
        scene.set_component(SceneNameComponent::new("Hero"), root);
        scene.set_component(
            AssetReferenceComponent::new(
                "test",
                "Hero",
                "hero.gltf",
                "/hero.gltf",
                "gltf",
                mesh_index,
            ),
            root,
        );
        root
    });

    let result = adapter.generate_ragdoll(root.raw_value());
    AssetRegistry::shared().unregister_testing_mesh(mesh_index);

    assert_eq!(result.error, None);
    assert_eq!(result.body_count, 2);
    assert_eq!(result.joint_count, 1);
    let scene = adapter.scene();
    let ragdoll = scene.component::<Ragdoll>(root).expect("ragdoll");
    assert_eq!(ragdoll.bones.len(), 2);
    for mapping in &ragdoll.bones {
        assert!(scene.has_component::<RigidBody>(mapping.body_entity));
        assert!(scene.has_component::<Collider>(mapping.body_entity));
    }
    let joint_entity = ragdoll
        .bones
        .iter()
        .find(|mapping| mapping.bone_name == "spine")
        .and_then(|mapping| mapping.joint_entity)
        .expect("spine joint");
    assert!(scene.has_component::<PhysicsJoint>(joint_entity));
}

/// An entity without a registered skinned mesh reports why generation failed.
#[test]
fn ragdoll_requires_skinned_mesh() {
    use diffuse_scene::components::core::registry::ComponentRegistry;

    use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
    use crate::scene::inspector::rendering::renderers::EditorInspectorRendererRegistry;

    let adapter = EditorSceneAdapter::new(
        false,
        ComponentRegistry::built_in(),
        EditorInspectorRendererRegistry::new(),
    );
    let root = adapter.with_scene_mut(|scene| scene.create_entity());
    let result = adapter.generate_ragdoll(root.raw_value());
    assert_eq!(
        result.error.as_deref(),
        Some("Skinned mesh data is unavailable")
    );
    assert_eq!(result.body_count, 0);
    assert_eq!(result.joint_count, 0);
}

/// Soft-body viewport overlay exposes stable volume edges and fixed anchors.
#[test]
fn soft_body_constraint_overlay() {
    use std::collections::BTreeMap;

    use diffuse_math::simd::simd_compat::Float3;
    use diffuse_scene::components::core::registry::ComponentRegistry;
    use diffuse_scene::physics::queries::spatial_queries::{
        MeshColliderGeometry, MeshColliderGeometryResource,
    };
    use diffuse_scene::physics::soft_bodies::soft_body::{SoftBody, SoftBodyMesh};
    use diffuse_scene::runtime_world::LocalTransform;
    use diffuse_scene::scene_runtime::SceneRuntime;

    use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
    use crate::scene::adapter::viewport_interaction::EditorSoftBodyConstraintKind;
    use crate::scene::inspector::rendering::renderers::EditorInspectorRendererRegistry;

    let adapter = EditorSceneAdapter::new(
        false,
        ComponentRegistry::built_in(),
        EditorInspectorRendererRegistry::new(),
    );
    adapter.set_scene(SceneRuntime::new(ComponentRegistry::built_in()));
    adapter.with_scene_mut(|scene| {
        scene.set_resource(MeshColliderGeometryResource::new(
            BTreeMap::from([(
                "soft.tetra".to_string(),
                MeshColliderGeometry::new(
                    vec![
                        Float3::ZERO,
                        Float3::new(1.0, 0.0, 0.0),
                        Float3::new(0.0, 1.0, 0.0),
                        Float3::new(0.0, 0.0, 1.0),
                    ],
                    vec![0, 2, 1, 0, 1, 3, 1, 2, 3, 2, 0, 3],
                    vec![0, 1, 2, 3],
                    Vec::new(),
                    None,
                    0,
                ),
            )]),
            None,
        ));
    });
    let entity = adapter.with_scene_mut(|scene| {
        let entity = scene.create_entity();
        scene.set_local_transform(
            LocalTransform::from_translation(Float3::new(2.0, 3.0, 4.0)),
            entity,
        );
        scene.set_component(SoftBody::default(), entity);
        scene.set_component(
            SoftBodyMesh::new(
                Some("soft.tetra".to_string()),
                vec![3],
                1.0e-5,
                1.0e-5,
                1.0e-5,
                1.0e-6,
                diffuse_scene::physics::soft_bodies::cloth::ClothBendType::Dihedral,
            ),
            entity,
        );
        entity
    });

    let overlay = adapter
        .viewport_soft_body_constraints_default(entity.raw_value())
        .expect("soft body overlay");
    assert!(!overlay.uses_simulated_positions);
    assert_eq!(overlay.lines.len(), 6);
    assert!(
        overlay
            .lines
            .iter()
            .all(|line| line.kind == EditorSoftBodyConstraintKind::Volume)
    );
    let keys: Vec<u64> = overlay
        .lines
        .iter()
        .map(|line| (u64::from(line.vertex_a) << 32) | u64::from(line.vertex_b))
        .collect();
    assert_eq!(
        keys,
        [
            1,
            2,
            3,
            (1u64 << 32) | 2,
            (1u64 << 32) | 3,
            (2u64 << 32) | 3,
        ]
    );
    assert_eq!(overlay.fixed_vertices.len(), 1);
    assert_eq!(overlay.fixed_vertices[0].vertex, 3);
    assert_eq!(
        overlay.fixed_vertices[0].position,
        Float3::new(2.0, 3.0, 5.0)
    );
}

/// Destruction viewport overlay exposes stable world-space connection lines.
#[test]
fn destruction_connection_overlay() {
    use std::collections::BTreeMap;

    use diffuse_math::simd::simd_compat::Float3;
    use diffuse_scene::components::core::registry::ComponentRegistry;
    use diffuse_scene::physics::destruction::{
        Destructible, DestructibleAsset, DestructibleAssetResource, DestructibleConnectionAsset,
        DestructibleFragmentAsset,
    };
    use diffuse_scene::runtime_world::LocalTransform;
    use diffuse_scene::scene_runtime::SceneRuntime;

    use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
    use crate::scene::inspector::rendering::renderers::EditorInspectorRendererRegistry;

    let adapter = EditorSceneAdapter::new(
        false,
        ComponentRegistry::built_in(),
        EditorInspectorRendererRegistry::new(),
    );
    adapter.set_scene(SceneRuntime::new(ComponentRegistry::built_in()));
    adapter.with_scene_mut(|scene| {
        scene.set_resource(DestructibleAssetResource::new(BTreeMap::from([(
            "wall.fracture".to_string(),
            DestructibleAsset::new(
                0,
                vec![
                    DestructibleFragmentAsset::new(
                        2,
                        "fragment.2",
                        LocalTransform::from_translation(Float3::new(1.0, 0.0, 0.0)),
                        1.0,
                        None,
                        None,
                    ),
                    DestructibleFragmentAsset::new(
                        0,
                        "fragment.0",
                        LocalTransform::from_translation(Float3::new(-1.0, 0.0, 0.0)),
                        1.0,
                        None,
                        None,
                    ),
                    DestructibleFragmentAsset::new(
                        1,
                        "fragment.1",
                        LocalTransform::IDENTITY,
                        1.0,
                        None,
                        None,
                    ),
                ],
                vec![
                    DestructibleConnectionAsset::new(8, 1, 2, 0.0, 0.0),
                    DestructibleConnectionAsset::new(4, 0, 1, 0.0, 0.0),
                ],
            ),
        )])));
    });
    let entity = adapter.with_scene_mut(|scene| {
        let entity = scene.create_entity();
        scene.set_local_transform(
            LocalTransform::from_translation(Float3::new(2.0, 3.0, 4.0)),
            entity,
        );
        scene.set_component(
            Destructible::new("wall.fracture", 100.0, 10.0, 256, 30.0, 5.0, 0.05, true),
            entity,
        );
        entity
    });
    adapter.tick_scene_default();

    let lines = adapter.viewport_destruction_connections_default(entity.raw_value());
    let ids: Vec<u32> = lines.iter().map(|line| line.connection_id).collect();
    assert_eq!(ids, [4, 8]);
    let starts: Vec<Float3> = lines.iter().map(|line| line.position_a).collect();
    assert_eq!(
        starts,
        [Float3::new(1.0, 3.0, 4.0), Float3::new(2.0, 3.0, 4.0)]
    );
    let ends: Vec<Float3> = lines.iter().map(|line| line.position_b).collect();
    assert_eq!(
        ends,
        [Float3::new(2.0, 3.0, 4.0), Float3::new(3.0, 3.0, 4.0)]
    );
    assert!(
        lines
            .iter()
            .all(|line| !line.is_broken && !line.is_source_fractured)
    );
    let limited: Vec<u32> = adapter
        .viewport_destruction_connections(entity.raw_value(), 1)
        .iter()
        .map(|line| line.connection_id)
        .collect();
    assert_eq!(limited, [4]);
    assert!(
        adapter
            .viewport_destruction_connections(entity.raw_value(), 0)
            .is_empty()
    );
}

/// Physics debug overlay draws compound shapes, bounds, joint axes and limits.
#[test]
fn physics_debug_overlay() {
    use diffuse_math::simd::simd_compat::{Float3, Float4};
    use diffuse_scene::components::core::registry::ComponentRegistry;
    use diffuse_scene::physics::collider::{Collider, ColliderShape, ColliderShapeInstance};
    use diffuse_scene::physics::joints::physics_joint::PhysicsJoint;
    use diffuse_scene::physics::joints::physics_joint_configuration::{
        HingeJointConfiguration, PhysicsJointConfiguration, SixDofJointConfiguration,
    };
    use diffuse_scene::physics::rigid_body::{RigidBody, RigidBodyMotionType, RigidBodyOptions};
    use diffuse_scene::runtime_world::LocalTransform;
    use diffuse_scene::scene_runtime::SceneRuntime;

    use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
    use crate::scene::adapter::viewport_interaction::EditorPhysicsDebugLineKind;
    use crate::scene::inspector::rendering::renderers::EditorInspectorRendererRegistry;
    use crate::state::editor_state::EditorPhysicsDebugOverlayOptions;

    let adapter = EditorSceneAdapter::new(
        false,
        ComponentRegistry::built_in(),
        EditorInspectorRendererRegistry::new(),
    );
    adapter.set_scene(SceneRuntime::new(ComponentRegistry::built_in()));
    let (body_a, body_b, joint_entity) = adapter.with_scene_mut(|scene| {
        let body_a = scene.create_entity();
        let body_b = scene.create_entity();
        let joint_entity = scene.create_entity();
        scene.set_local_transform(
            LocalTransform::from_translation(Float3::new(1.0, 0.0, 0.0)),
            body_a,
        );
        scene.set_local_transform(
            LocalTransform::from_translation(Float3::new(4.0, 0.0, 0.0)),
            body_b,
        );
        scene.set_component(
            Collider::with_shapes(vec![
                ColliderShapeInstance::with_transform(
                    ColliderShape::Box {
                        half_extents: Float3::splat(0.5),
                        center: Float3::ZERO,
                    },
                    Float3::new(2.0, 0.0, 0.0),
                    Float4::new(0.0, 0.0, 0.0, 1.0),
                    Float3::ONE,
                ),
                ColliderShapeInstance::with_transform(
                    ColliderShape::Sphere {
                        radius: 0.25,
                        center: Float3::ZERO,
                    },
                    Float3::new(-1.0, 0.0, 0.0),
                    Float4::new(0.0, 0.0, 0.0, 1.0),
                    Float3::ONE,
                ),
            ]),
            body_a,
        );
        scene.set_component(
            RigidBody::new(RigidBodyOptions {
                motion_type: RigidBodyMotionType::Static,
                ..RigidBodyOptions::default()
            }),
            body_a,
        );
        scene.set_component(
            Collider::with_shape(ColliderShape::Box {
                half_extents: Float3::splat(0.5),
                center: Float3::ZERO,
            }),
            body_b,
        );
        scene.set_component(
            RigidBody::new(RigidBodyOptions {
                motion_type: RigidBodyMotionType::Static,
                ..RigidBodyOptions::default()
            }),
            body_b,
        );
        scene.set_component(
            PhysicsJoint::new(
                PhysicsJointConfiguration::Hinge(HingeJointConfiguration::new(
                    Float3::new(0.0, 1.0, 0.0),
                    Float3::new(0.0, 1.0, 0.0),
                    -0.5,
                    0.75,
                    Default::default(),
                    Default::default(),
                )),
                body_a,
                body_b,
                Float3::new(0.5, 0.0, 0.0),
                Float3::new(-0.5, 0.0, 0.0),
                true,
                PhysicsJoint::DEFAULT_BREAK_LIMIT,
                PhysicsJoint::DEFAULT_BREAK_LIMIT,
            ),
            joint_entity,
        );
        (body_a, body_b, joint_entity)
    });

    adapter.tick_scene_default();
    let overlay = adapter.viewport_physics_debug_overlay(
        Some(body_a.raw_value()),
        EditorPhysicsDebugOverlayOptions::all(),
        8_192,
        512,
    );
    let collider_lines: Vec<_> = overlay
        .lines
        .iter()
        .filter(|line| line.kind == EditorPhysicsDebugLineKind::Collider)
        .collect();
    assert_eq!(
        overlay
            .lines
            .iter()
            .filter(|line| line.kind == EditorPhysicsDebugLineKind::Bounds)
            .count(),
        12
    );
    assert!(collider_lines.len() > 12);
    assert!(
        collider_lines
            .iter()
            .any(|line| line.position_a.x.max(line.position_b.x) >= 3.5)
    );
    assert!(
        overlay
            .lines
            .iter()
            .any(|line| line.kind == EditorPhysicsDebugLineKind::Joint)
    );
    assert_eq!(
        overlay
            .lines
            .iter()
            .filter(|line| line.kind == EditorPhysicsDebugLineKind::JointAxis)
            .count(),
        2
    );
    assert!(
        overlay
            .lines
            .iter()
            .any(|line| line.kind == EditorPhysicsDebugLineKind::JointLimit)
    );
    assert!(overlay.contacts.is_empty());

    let scene_shapes = adapter.viewport_physics_debug_overlay(
        None,
        EditorPhysicsDebugOverlayOptions::SHAPES,
        8_192,
        512,
    );
    assert!(
        scene_shapes
            .lines
            .iter()
            .all(|line| line.kind == EditorPhysicsDebugLineKind::Collider)
    );
    assert!(
        scene_shapes
            .lines
            .iter()
            .any(|line| line.entity_id == body_a.raw_value())
    );
    assert!(
        scene_shapes
            .lines
            .iter()
            .any(|line| line.entity_id == body_b.raw_value())
    );
    assert_eq!(
        scene_shapes.lines.first().map(|line| line.entity_id),
        Some(body_a.raw_value())
    );

    let scene_joints = adapter.viewport_physics_debug_overlay(
        None,
        EditorPhysicsDebugOverlayOptions::JOINTS,
        8_192,
        512,
    );
    assert!(!scene_joints.lines.is_empty());
    assert!(scene_joints.lines.iter().all(|line| matches!(
        line.kind,
        EditorPhysicsDebugLineKind::Joint
            | EditorPhysicsDebugLineKind::JointAxis
            | EditorPhysicsDebugLineKind::JointLimit
    )));
    assert!(
        scene_joints
            .lines
            .iter()
            .all(|line| line.entity_id == joint_entity.raw_value())
    );

    adapter.with_scene_mut(|scene| {
        scene.update_component::<PhysicsJoint>(joint_entity, |joint| {
            joint.configuration = PhysicsJointConfiguration::SixDof(SixDofJointConfiguration::new(
                Float3::new(1.0, 0.0, 0.0),
                Float3::new(1.0, 0.0, 0.0),
                Float3::new(-1.0, -2.0, -3.0),
                Float3::new(1.0, 2.0, 3.0),
                Float3::splat(-0.25),
                Float3::splat(0.5),
                Default::default(),
                Default::default(),
                Default::default(),
            ));
        });
    });
    adapter.tick_scene_default();
    let six_dof_overlay = adapter.viewport_physics_debug_overlay(
        Some(body_a.raw_value()),
        EditorPhysicsDebugOverlayOptions::all(),
        8_192,
        512,
    );
    assert!(
        six_dof_overlay
            .lines
            .iter()
            .filter(|line| line.kind == EditorPhysicsDebugLineKind::JointLimit)
            .count()
            >= 84
    );

    let bounded = adapter.viewport_physics_debug_overlay(
        Some(body_a.raw_value()),
        EditorPhysicsDebugOverlayOptions::all(),
        10,
        0,
    );
    assert_eq!(bounded.lines.len(), 10);
    assert!(bounded.contacts.is_empty());
}

/// Spawning an imported mesh attaches registered mesh collider bounds.
#[test]
fn spawning_imported_mesh_attaches_registered_mesh_collider_bounds() {
    use diffuse_assets::asset_registry::ImportableAssetKind;
    use diffuse_math::simd::simd_compat::Float3;
    use diffuse_render::registries::mesh_bounds_registry::MeshBoundsRegistry;
    use diffuse_scene::components::core::registry::ComponentRegistry;
    use diffuse_scene::physics::collider::{Collider, ColliderShape};
    use diffuse_scene::physics::queries::spatial_queries::{
        MeshColliderBoundsResource, SceneRaycastQuery,
    };
    use diffuse_scene::scene_runtime::SceneRuntime;

    use crate::assets::asset_catalog::EditorAsset;
    use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
    use crate::scene::inspector::rendering::renderers::EditorInspectorRendererRegistry;

    MeshBoundsRegistry::clear_all();
    let local_min = Float3::new(-2.0, -1.0, -0.25);
    let local_max = Float3::new(2.0, 1.0, 0.25);
    MeshBoundsRegistry::register_min_max(42, local_min, local_max);

    let adapter = EditorSceneAdapter::new(
        false,
        ComponentRegistry::built_in(),
        EditorInspectorRendererRegistry::new(),
    );
    adapter.set_scene(SceneRuntime::new(ComponentRegistry::built_in()));
    let asset = EditorAsset::new(
        "wide-mesh",
        "Wide Mesh",
        "Meshes/Wide.obj",
        "/tmp/Meshes/Wide.obj",
        ImportableAssetKind::Obj,
        42,
    );
    let raw_id = adapter
        .spawn_entity_from_asset(&asset, Float3::new(10.0, 0.0, 0.0))
        .expect("imported mesh spawn");
    let scene = adapter.scene();
    let entity = diffuse_scene::entity_id::EntityID::from_raw_value(raw_id);
    let collider = scene.component::<Collider>(entity).expect("mesh collider");
    match collider.shape() {
        ColliderShape::Mesh {
            resource_id,
            center,
        } => {
            assert_eq!(resource_id.as_deref(), Some("meshIndex:42"));
            assert_eq!(center, Float3::ZERO);
        }
        other => panic!("expected imported mesh collider shape, got {other:?}"),
    }
    let resource = scene
        .resource::<MeshColliderBoundsResource>()
        .expect("mesh collider bounds");
    let bounds = resource
        .bounds_for(Some("meshIndex:42"))
        .expect("registered bounds");
    assert_eq!(bounds.min, local_min);
    assert_eq!(bounds.max, local_max);

    let hit = adapter.with_scene_mut(|scene| {
        scene.raycast_scene(SceneRaycastQuery {
            origin: Float3::new(6.0, 0.0, 0.0),
            direction: Float3::new(1.0, 0.0, 0.0),
            max_distance: 100.0,
            include_triggers: true,
        })
    });
    assert_eq!(hit.as_ref().map(|hit| hit.entity), Some(entity));
    assert_eq!(hit.map(|hit| hit.distance), Some(2.0));
    MeshBoundsRegistry::clear_all();
}

/// Imported entity setup is a single undo step.
#[test]
fn imported_entity_setup_is_a_single_undo_step() {
    use diffuse_assets::asset_registry::ImportableAssetKind;
    use diffuse_scene::components::core::registry::ComponentRegistry;

    use crate::assets::asset_catalog::EditorAsset;
    use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
    use crate::scene::inspector::rendering::renderers::EditorInspectorRendererRegistry;

    let adapter = EditorSceneAdapter::new(
        false,
        ComponentRegistry::built_in(),
        EditorInspectorRendererRegistry::new(),
    );
    let original_count = adapter.entity_count();
    let asset = EditorAsset::new(
        "models/crate.glb",
        "Crate",
        "models/crate.glb",
        "/tmp/crate.glb",
        ImportableAssetKind::Glb,
        2,
    );
    assert!(adapter.spawn_entity_from_asset_default(&asset).is_some());
    assert_eq!(adapter.entity_count(), original_count + 1);

    assert!(adapter.undo_edit());
    assert_eq!(adapter.entity_count(), original_count);
    assert!(!adapter.can_undo_edit());
}

/// Grouped multi-asset spawn arranges and undoes the selection as one step.
#[test]
fn grouped_multi_asset_spawn_undo() {
    use diffuse_assets::asset_registry::ImportableAssetKind;
    use diffuse_math::simd::simd_compat::simd_distance;
    use diffuse_scene::components::core::registry::ComponentRegistry;

    use crate::assets::asset_catalog::EditorAsset;
    use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
    use crate::scene::inspector::rendering::renderers::EditorInspectorRendererRegistry;

    let adapter = EditorSceneAdapter::new(
        false,
        ComponentRegistry::built_in(),
        EditorInspectorRendererRegistry::new(),
    );
    let original_count = adapter.entity_count();
    let assets = [
        EditorAsset::new(
            "models/crate.glb",
            "Crate",
            "models/crate.glb",
            "/tmp/crate.glb",
            ImportableAssetKind::Glb,
            2,
        ),
        EditorAsset::new(
            "models/barrel.obj",
            "Barrel",
            "models/barrel.obj",
            "/tmp/barrel.obj",
            ImportableAssetKind::Obj,
            3,
        ),
        EditorAsset::new(
            "models/rock.glb",
            "Rock",
            "models/rock.glb",
            "/tmp/rock.glb",
            ImportableAssetKind::Glb,
            4,
        ),
    ];
    let entity_ids = adapter
        .spawn_entities_from_assets_default(&assets)
        .expect("spawn group");
    assert_eq!(entity_ids.len(), assets.len());
    assert_eq!(adapter.entity_count(), original_count + assets.len());
    let positions: Vec<_> = entity_ids
        .iter()
        .filter_map(|entity_id| adapter.entity_local_translation(*entity_id))
        .collect();
    assert_eq!(positions.len(), assets.len());
    assert!(simd_distance(positions[0], positions[1]) > 0.5);
    assert!(simd_distance(positions[1], positions[2]) > 0.5);
    assert!(adapter.can_undo_edit());

    assert!(adapter.undo_edit());
    assert_eq!(adapter.entity_count(), original_count);
    assert!(!adapter.can_undo_edit());

    let wood = EditorAsset::new(
        "textures/wood.png",
        "Wood",
        "textures/wood.png",
        "/tmp/wood.png",
        ImportableAssetKind::Png,
        0,
    );
    assert!(
        adapter
            .spawn_entities_from_assets_default(&[assets[0].clone(), wood])
            .is_none()
    );
    assert_eq!(adapter.entity_count(), original_count);
    adapter.set_authoring_enabled(false);
    assert!(
        adapter
            .spawn_entities_from_assets_default(&assets)
            .is_none()
    );
    assert_eq!(adapter.entity_count(), original_count);
    assert!(!adapter.can_undo_edit());
}

fn preview_adapter() -> crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter {
    use diffuse_scene::components::core::registry::ComponentRegistry;

    use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
    use crate::scene::inspector::rendering::renderers::EditorInspectorRendererRegistry;

    EditorSceneAdapter::new(
        true,
        ComponentRegistry::built_in(),
        EditorInspectorRendererRegistry::new(),
    )
}

/// Human transform edits undo and redo through the adapter history.
#[test]
fn transform_undo_redo() {
    use diffuse_math::simd::simd_compat::Float3;

    let adapter = preview_adapter();
    let entity_id = adapter.default_selection_id().expect("default selection");
    let original = adapter
        .entity_local_translation(entity_id)
        .expect("translation");
    let edited = original + Float3::new(1.0, 2.0, 3.0);

    adapter.set_entity_local_translation(entity_id, edited);
    assert!(adapter.can_undo_edit());
    assert_eq!(adapter.entity_local_translation(entity_id), Some(edited));

    assert!(adapter.undo_edit());
    assert_eq!(adapter.entity_local_translation(entity_id), Some(original));
    assert!(adapter.can_redo_edit());

    assert!(adapter.redo_edit());
    assert_eq!(adapter.entity_local_translation(entity_id), Some(edited));
}

/// Loading a document starts a fresh edit history.
#[test]
fn load_resets_history() {
    use diffuse_math::simd::simd_compat::Float3;

    let adapter = preview_adapter();
    let entity_id = adapter.default_selection_id().expect("default selection");
    let original = adapter
        .entity_local_translation(entity_id)
        .expect("translation");
    adapter.set_entity_local_translation(entity_id, original + Float3::new(1.0, 0.0, 0.0));
    assert!(adapter.can_undo_edit());

    let _ = adapter.load(&adapter.manifest());
    assert!(!adapter.can_undo_edit());
    assert!(!adapter.can_redo_edit());
}

/// Hierarchy visibility updates render state and participates in undo.
#[test]
fn visibility_undo() {
    use diffuse_scene::rendering::render_extraction::RenderMeshComponent;

    let adapter = preview_adapter();
    let entity = adapter
        .scene()
        .entities_with::<RenderMeshComponent>()
        .first()
        .copied()
        .expect("renderable entity");
    assert!(adapter.is_hierarchy_visible(entity.raw_value()));

    assert!(adapter.set_hierarchy_visibility(
        false,
        &std::collections::BTreeSet::from([entity.raw_value()])
    ));
    assert!(!adapter.is_hierarchy_visible(entity.raw_value()));

    assert!(adapter.undo_edit());
    assert!(adapter.is_hierarchy_visible(entity.raw_value()));
}

/// Locked entities reject authored edits.
#[test]
fn locked_entity_rejects_edit() {
    use std::cell::RefCell;
    use std::rc::Rc;

    use diffuse_math::simd::simd_compat::Float3;

    let adapter = preview_adapter();
    let entity_id = adapter.default_selection_id().expect("default selection");
    let original = adapter
        .entity_local_translation(entity_id)
        .expect("translation");
    let reported_error = Rc::new(RefCell::new(None::<String>));
    {
        let reported_error = reported_error.clone();
        adapter
            .on_transaction_error
            .replace(Some(Rc::new(move |error| {
                *reported_error.borrow_mut() = Some(error);
            })));
    }
    adapter.set_entity_locked(true, &std::collections::BTreeSet::from([entity_id]));

    adapter.set_entity_local_translation(entity_id, original + Float3::new(1.0, 0.0, 0.0));

    assert_eq!(adapter.entity_local_translation(entity_id), Some(original));
    assert!(
        reported_error
            .borrow()
            .as_deref()
            .is_some_and(|error| error.contains("locked"))
    );
    assert!(adapter.can_undo_edit());
    assert!(adapter.undo_edit());
    assert!(!adapter.is_entity_locked(entity_id));
}

/// Multi-entity deletion is atomic and uses one undo step.
#[test]
fn multi_entity_deletion_is_atomic() {
    let adapter = preview_adapter();
    let entity_ids: std::collections::BTreeSet<u64> =
        adapter.roots().iter().take(2).map(|node| node.id).collect();
    let original_count = adapter.entity_count();
    assert_eq!(entity_ids.len(), 2);

    assert!(adapter.delete_entities(&entity_ids));
    assert_eq!(adapter.entity_count(), original_count - 2);
    assert!(
        entity_ids
            .iter()
            .all(|id| adapter.entity_summary(Some(*id)).is_none())
    );

    assert!(adapter.undo_edit());
    assert_eq!(adapter.entity_count(), original_count);
    assert!(
        entity_ids
            .iter()
            .all(|id| adapter.entity_summary(Some(*id)).is_some())
    );
    assert!(!adapter.can_undo_edit());
}

/// Multi-entity deletion fails as a unit when one entity is locked.
#[test]
fn multi_entity_deletion_honors_locks_atomically() {
    use std::cell::RefCell;
    use std::rc::Rc;

    let adapter = preview_adapter();
    let entity_ids: std::collections::BTreeSet<u64> =
        adapter.roots().iter().take(2).map(|node| node.id).collect();
    let locked_id = *entity_ids.iter().next().expect("locked id");
    let original_count = adapter.entity_count();
    let reported_error = Rc::new(RefCell::new(None::<String>));
    {
        let reported_error = reported_error.clone();
        adapter
            .on_transaction_error
            .replace(Some(Rc::new(move |error| {
                *reported_error.borrow_mut() = Some(error);
            })));
    }
    adapter.set_entity_locked(true, &std::collections::BTreeSet::from([locked_id]));

    assert!(!adapter.delete_entities(&entity_ids));
    assert_eq!(adapter.entity_count(), original_count);
    assert!(
        entity_ids
            .iter()
            .all(|id| adapter.entity_summary(Some(*id)).is_some())
    );
    assert!(
        reported_error
            .borrow()
            .as_deref()
            .is_some_and(|error| error.contains("locked"))
    );
}

/// Multi-entity deletion rejects stale selections instead of partially deleting.
#[test]
fn multi_entity_deletion_rejects_stale_selections() {
    let adapter = preview_adapter();
    let valid_id = adapter.roots().first().expect("root").id;
    let original_count = adapter.entity_count();

    assert!(!adapter.delete_entities(&std::collections::BTreeSet::from([valid_id, u64::MAX])));
    assert_eq!(adapter.entity_count(), original_count);
    assert!(adapter.entity_summary(Some(valid_id)).is_some());
    assert!(!adapter.can_undo_edit());
}

/// Deleting an ancestor and its selected descendant is a single valid transaction.
#[test]
fn multi_entity_deletion_collapses_selected_descendants() {
    use crate::scene::adapter::spawn::EditorEntityTemplate;

    let adapter = preview_adapter();
    let parent_id = adapter
        .spawn_entity_default(EditorEntityTemplate::Empty)
        .expect("parent");
    let child_id = adapter
        .spawn_entity(EditorEntityTemplate::Empty, None, Some(parent_id))
        .expect("child");
    let populated_count = adapter.entity_count();

    assert!(adapter.delete_entities(&std::collections::BTreeSet::from([parent_id, child_id])));
    assert_eq!(adapter.entity_count(), populated_count - 2);
    assert!(adapter.entity_summary(Some(parent_id)).is_none());
    assert!(adapter.entity_summary(Some(child_id)).is_none());

    assert!(adapter.undo_edit());
    assert!(adapter.entity_summary(Some(parent_id)).is_some());
    assert!(adapter.entity_summary(Some(child_id)).is_some());
    assert!(adapter.entity_has_ancestor(child_id, &std::collections::BTreeSet::from([parent_id])));
}

/// Hierarchy rename trims input, rejects empty names, and is undoable.
#[test]
fn hierarchy_rename_is_validated_and_undoable() {
    let adapter = preview_adapter();
    let entity_id = adapter.default_selection_id().expect("default selection");
    let original_name = adapter
        .entity_summary(Some(entity_id))
        .expect("summary")
        .name;

    assert!(!adapter.rename_entity(entity_id, "   \n"));
    assert_eq!(
        adapter
            .entity_summary(Some(entity_id))
            .map(|summary| summary.name),
        Some(original_name.clone())
    );
    assert!(!adapter.can_undo_edit());

    assert!(adapter.rename_entity(entity_id, "  Production Camera  "));
    assert_eq!(
        adapter
            .entity_summary(Some(entity_id))
            .map(|summary| summary.name),
        Some("Production Camera".to_string())
    );
    assert!(adapter.undo_edit());
    assert_eq!(
        adapter
            .entity_summary(Some(entity_id))
            .map(|summary| summary.name),
        Some(original_name)
    );
    assert!(!adapter.can_undo_edit());
}

/// Multi-entity duplication is atomic and uses one undo step.
#[test]
fn multi_entity_duplication_is_atomic() {
    let adapter = preview_adapter();
    let source_ids: std::collections::BTreeSet<u64> =
        adapter.roots().iter().take(2).map(|node| node.id).collect();
    let original_count = adapter.entity_count();
    assert_eq!(source_ids.len(), 2);

    let duplicated_ids = adapter.duplicate_entities(&source_ids).expect("duplicates");
    assert_eq!(duplicated_ids.len(), 2);
    assert_eq!(adapter.entity_count(), original_count + 2);
    assert!(
        duplicated_ids
            .iter()
            .all(|id| adapter.entity_summary(Some(*id)).is_some())
    );

    assert!(adapter.undo_edit());
    assert_eq!(adapter.entity_count(), original_count);
    assert!(
        duplicated_ids
            .iter()
            .all(|id| adapter.entity_summary(Some(*id)).is_none())
    );
    assert!(!adapter.can_undo_edit());
}

/// Multi-entity duplication rejects a locked member as a unit.
#[test]
fn multi_entity_duplication_honors_locks_atomically() {
    let adapter = preview_adapter();
    let source_ids: std::collections::BTreeSet<u64> =
        adapter.roots().iter().take(2).map(|node| node.id).collect();
    let locked_id = *source_ids.iter().next().expect("locked id");
    let original_count = adapter.entity_count();
    adapter.set_entity_locked(true, &std::collections::BTreeSet::from([locked_id]));

    assert!(adapter.duplicate_entities(&source_ids).is_none());
    assert_eq!(adapter.entity_count(), original_count);
}

/// Moving a nested multi-selection to root preserves descendants and is one undo step.
#[test]
fn multi_entity_move_to_root_is_atomic() {
    use crate::scene::adapter::spawn::EditorEntityTemplate;

    let adapter = preview_adapter();
    let grandparent_id = adapter
        .spawn_entity_default(EditorEntityTemplate::Empty)
        .expect("grandparent");
    let parent_id = adapter
        .spawn_entity(EditorEntityTemplate::Empty, None, Some(grandparent_id))
        .expect("parent");
    let child_id = adapter
        .spawn_entity(EditorEntityTemplate::Empty, None, Some(parent_id))
        .expect("child");

    assert!(
        adapter.move_entities_to_root(&std::collections::BTreeSet::from([parent_id, child_id]))
    );
    assert!(adapter.roots().iter().any(|node| node.id == parent_id));
    assert!(!adapter.roots().iter().any(|node| node.id == child_id));
    assert!(adapter.entity_has_ancestor(child_id, &std::collections::BTreeSet::from([parent_id])));

    assert!(adapter.undo_edit());
    assert!(adapter.entity_has_ancestor(
        parent_id,
        &std::collections::BTreeSet::from([grandparent_id])
    ));
    assert!(adapter.entity_has_ancestor(child_id, &std::collections::BTreeSet::from([parent_id])));
}

/// Moving a root selected with its descendant does not detach the descendant.
#[test]
fn move_to_root_collapses_selected_descendants() {
    use crate::scene::adapter::spawn::EditorEntityTemplate;

    let adapter = preview_adapter();
    let root_id = adapter
        .spawn_entity_default(EditorEntityTemplate::Empty)
        .expect("root");
    let child_id = adapter
        .spawn_entity(EditorEntityTemplate::Empty, None, Some(root_id))
        .expect("child");

    assert!(!adapter.move_entities_to_root(&std::collections::BTreeSet::from([root_id, child_id])));
    assert!(adapter.entity_has_ancestor(child_id, &std::collections::BTreeSet::from([root_id])));
}

/// Moving a multi-selection to root preserves the hierarchy's visible order.
#[test]
fn move_to_root_preserves_sibling_order() {
    use crate::scene::adapter::spawn::EditorEntityTemplate;

    let adapter = preview_adapter();
    let parent_id = adapter
        .spawn_entity_default(EditorEntityTemplate::Empty)
        .expect("parent");
    let first_id = adapter
        .spawn_entity(EditorEntityTemplate::Empty, None, Some(parent_id))
        .expect("first");
    let second_id = adapter
        .spawn_entity(EditorEntityTemplate::Empty, None, Some(parent_id))
        .expect("second");

    assert!(adapter.move_entity(second_id, Some(parent_id), 0).is_some());
    let sibling_order: Vec<u64> = adapter
        .roots()
        .into_iter()
        .find(|node| node.id == parent_id)
        .expect("parent node")
        .children
        .iter()
        .map(|child| child.id)
        .collect();
    assert_eq!(sibling_order, [second_id, first_id]);

    assert!(
        adapter.move_entities_to_root(&std::collections::BTreeSet::from([first_id, second_id]))
    );
    let root_order: Vec<u64> = adapter.roots().iter().map(|node| node.id).collect();
    assert_eq!(&root_order[root_order.len() - 2..], [second_id, first_id]);

    assert!(adapter.undo_edit());
    let restored_children: Vec<u64> = adapter
        .roots()
        .into_iter()
        .find(|node| node.id == parent_id)
        .expect("parent node")
        .children
        .iter()
        .map(|child| child.id)
        .collect();
    assert_eq!(restored_children, [second_id, first_id]);
}

/// Hierarchy locks round-trip and remap entity identifiers.
#[test]
fn locked_entity_round_trip() {
    let adapter = preview_adapter();
    let original_id = adapter.default_selection_id().expect("default selection");
    adapter.set_entity_locked(true, &std::collections::BTreeSet::from([original_id]));

    let manifest = adapter.manifest_for_selection(Some(original_id));
    assert_eq!(manifest.locked_entity_ids, Some(vec![original_id]));

    let restored = preview_adapter();
    let result = restored.load_with_notify(&manifest, false);
    let remapped_id = result.selected_entity_id.expect("remapped selection");
    assert!(restored.is_entity_locked(remapped_id));
}

/// Hierarchy lock changes participate in one-step undo and redo.
#[test]
fn hierarchy_lock_undo_redo() {
    let adapter = preview_adapter();
    let entity_id = adapter.default_selection_id().expect("default selection");

    adapter.set_entity_locked(true, &std::collections::BTreeSet::from([entity_id]));
    assert!(adapter.is_entity_locked(entity_id));
    assert!(adapter.can_undo_edit());
    assert!(adapter.undo_edit());
    assert!(!adapter.is_entity_locked(entity_id));
    assert!(adapter.can_redo_edit());
    assert!(adapter.redo_edit());
    assert!(adapter.is_entity_locked(entity_id));
}

/// Interactive transform updates coalesce into one undo entry.
#[test]
fn interactive_transforms_coalesce_for_undo() {
    let adapter = preview_adapter();
    let entity_id = adapter.default_selection_id().expect("default selection");
    let original = adapter
        .entity_local_translation(entity_id)
        .expect("translation");

    adapter.begin_interactive_edit_history_group();
    for x in 1..=5 {
        let mut matrix = adapter.entity_local_matrix(entity_id).expect("matrix");
        matrix.columns[3].x = original.x + x as f32;
        assert!(
            adapter.set_entity_local_matrices(&std::collections::BTreeMap::from([(
                entity_id, matrix
            )]))
        );
    }
    assert!(!adapter.can_undo_edit());
    adapter.end_interactive_edit_history_group();

    assert!(adapter.can_undo_edit());
    assert!(adapter.undo_edit());
    assert_eq!(adapter.entity_local_translation(entity_id), Some(original));
    assert!(!adapter.can_undo_edit());
}

/// Cancelling an interactive transform restores its starting scene without history.
#[test]
fn interactive_transform_cancellation_restores_start() {
    use std::cell::Cell;
    use std::rc::Rc;

    let adapter = preview_adapter();
    let entity_id = adapter.default_selection_id().expect("default selection");
    let original = adapter
        .entity_local_translation(entity_id)
        .expect("translation");
    let revision_notifications = Rc::new(Cell::new(0));
    {
        let revision_notifications = revision_notifications.clone();
        adapter.on_revision_changed.replace(Some(Rc::new(move |_| {
            revision_notifications.set(revision_notifications.get() + 1);
        })));
    }

    adapter.begin_interactive_edit_history_group();
    let mut matrix = adapter.entity_local_matrix(entity_id).expect("matrix");
    matrix.columns[3].x = original.x + 12.0;
    assert!(
        adapter.set_entity_local_matrices(&std::collections::BTreeMap::from([(entity_id, matrix)]))
    );

    adapter.cancel_interactive_edit_history_group();
    adapter.end_interactive_edit_history_group();

    assert_eq!(adapter.entity_local_translation(entity_id), Some(original));
    assert!(!adapter.can_undo_edit());
    assert!(revision_notifications.get() >= 2);
}

/// Multi-entity transforms reject locked members atomically.
#[test]
fn multi_entity_transforms_honor_locks_atomically() {
    let adapter = preview_adapter();
    let ids: Vec<u64> = adapter.roots().iter().take(2).map(|node| node.id).collect();
    assert_eq!(ids.len(), 2);
    let first_id = ids[0];
    let second_id = ids[1];
    let first_original = adapter.entity_local_matrix(first_id).expect("first");
    let second_original = adapter.entity_local_matrix(second_id).expect("second");
    adapter.set_entity_locked(true, &std::collections::BTreeSet::from([second_id]));
    let mut first_next = first_original;
    let mut second_next = second_original;
    first_next.columns[3].x += 3.0;
    second_next.columns[3].x += 3.0;

    assert!(
        !adapter.set_entity_local_matrices(&std::collections::BTreeMap::from([
            (first_id, first_next),
            (second_id, second_next),
        ]))
    );
    assert_eq!(
        adapter
            .entity_local_matrix(first_id)
            .map(|matrix| matrix.columns[3]),
        Some(first_original.columns[3])
    );
    assert_eq!(
        adapter
            .entity_local_matrix(second_id)
            .map(|matrix| matrix.columns[3]),
        Some(second_original.columns[3])
    );
}

/// Preview scene manifest captures hierarchy roots.
#[test]
fn preview_manifest_captures_hierarchy_roots() {
    use diffuse_scene::components::core::value::manifest_value_for;

    let adapter = preview_adapter();
    let manifest = adapter.manifest_for_selection(adapter.default_selection_id());

    assert_eq!(
        manifest.schema_version,
        crate::scene::manifest::editor_scene_manifest::EditorSceneManifest::CURRENT_SCHEMA_VERSION
    );
    assert_eq!(manifest.revision, adapter.revision());
    assert_eq!(manifest.entity_count, adapter.entity_count() as i64);
    assert_eq!(manifest.selected_entity_id, adapter.default_selection_id());
    assert!(!manifest.roots.is_empty());
    assert!(manifest.roots.iter().any(|node| node.name == "Main Camera"));
    assert!(manifest.roots.iter().any(|node| {
        manifest_value_for(&node.components, "camera")
            .and_then(|value| value.object_value())
            .is_some()
    }));
}

/// Preview scene reports active particles so the viewport keeps driving frames.
#[test]
fn preview_scene_has_active_particles() {
    let adapter = preview_adapter();
    assert!(adapter.has_active_particles());
}

/// Viewport framing centers and fits a complete multi-selection.
#[test]
fn viewport_framing_fits_multi_selection() {
    use diffuse_math::simd::simd_compat::{Float3, simd_distance};
    use diffuse_scene::runtime_world::LocalTransform;

    let adapter = preview_adapter();
    adapter.set_editor_viewport_camera_enabled(true);
    let (left, right) = adapter.with_scene_mut(|scene| {
        let left = scene.create_entity();
        let right = scene.create_entity();
        scene.set_local_transform(
            LocalTransform::from_translation(Float3::new(-2.0, 0.0, 0.0)),
            left,
        );
        scene.set_local_transform(
            LocalTransform::from_translation(Float3::new(3.0, 4.0, 1.0)),
            right,
        );
        (left, right)
    });
    adapter.with_scene_mut(|scene| scene.propagate_transforms());
    adapter.tick_scene_default();

    let selected: std::collections::BTreeSet<u64> =
        [left.raw_value(), right.raw_value()].into_iter().collect();
    let expected_min = Float3::new(-2.25, -0.25, -0.25);
    let expected_max = Float3::new(3.25, 4.25, 1.25);
    let expected_center = (expected_min + expected_max) * 0.5;

    adapter.frame_entities(&selected, Some(16.0 / 9.0));

    assert!(simd_distance(adapter.current_render_camera().target, expected_center) < 1e-4);
}

/// Resetting preview scene publishes a new revision.
#[test]
fn reset_preview_scene_publishes_revision() {
    use std::cell::RefCell;
    use std::rc::Rc;

    let adapter = preview_adapter();
    let revisions = Rc::new(RefCell::new(Vec::new()));
    {
        let revisions = revisions.clone();
        adapter
            .on_revision_changed
            .replace(Some(Rc::new(move |revision| {
                revisions.borrow_mut().push(revision);
            })));
    }

    adapter.reset_to_preview_scene();

    assert_eq!(*revisions.borrow(), [adapter.revision()]);
    assert!(adapter.default_selection_id().is_some());
}

/// Ticking drives animation and writes a non-empty joint palette for a skinned entity.
#[test]
fn current_joint_palette_map_returns_palette_after_tick() {
    use diffuse_assets::asset_pipeline::{
        MeshAnimation, MeshAnimationChannel, MeshAnimationInterpolation, MeshAnimationPath,
        MeshAnimationSampler, MeshAsset, MeshNode, MeshSkin,
    };
    use diffuse_assets::asset_registry::AssetRegistry;
    use diffuse_math::simd::simd_compat::{Float4, MATRIX_IDENTITY_FLOAT4X4};
    use diffuse_scene::media::animation::AnimationPlayer;
    use diffuse_scene::scene_bootstrap::AssetReferenceComponent;

    let mesh_index = 9_001;
    let sampler = MeshAnimationSampler::new(
        vec![0.0, 1.0],
        vec![
            Float4::new(0.0, 0.0, 0.0, 0.0),
            Float4::new(1.0, 0.0, 0.0, 0.0),
        ],
        MeshAnimationInterpolation::Linear,
    );
    let channel = MeshAnimationChannel {
        sampler_index: 0,
        target_node_index: Some(0),
        path: MeshAnimationPath::Translation,
    };
    let clip = MeshAnimation {
        name: Some("walk".to_string()),
        samplers: vec![sampler],
        channels: vec![channel],
    };
    let mut mesh = MeshAsset::new("test_skinned", Vec::new(), Vec::new());
    mesh.nodes = vec![MeshNode {
        name: Some("root".to_string()),
        ..MeshNode::default()
    }];
    mesh.skins = vec![MeshSkin {
        name: None,
        joint_node_indices: vec![0],
        inverse_bind_matrices: vec![MATRIX_IDENTITY_FLOAT4X4],
    }];
    mesh.animations = vec![clip];
    AssetRegistry::shared().register_for_testing(mesh, mesh_index);

    let adapter = preview_adapter();
    let entity = adapter.with_scene_mut(|scene| {
        let entity = scene.create_entity();
        scene.set_component(AnimationPlayer::new(None, 1.0, true, true, 0.0), entity);
        scene.set_component(
            AssetReferenceComponent::new(
                format!("test:{mesh_index}"),
                "test",
                "test.gltf",
                "/test.gltf",
                "gltf",
                mesh_index,
            ),
            entity,
        );
        entity
    });

    adapter.tick_scene(0.1, 0, Vec::new(), false);
    AssetRegistry::shared().unregister_testing_mesh(mesh_index);

    let palette = adapter.current_joint_palette_map();
    assert!(palette.palette(entity).is_some());
    assert!(
        !palette
            .palette(entity)
            .expect("palette")
            .matrices
            .is_empty()
    );
}

/// New manifests use the current schema version.
#[test]
fn current_schema_version() {
    let adapter = preview_adapter();
    let manifest = adapter.manifest();
    assert_eq!(
        manifest.schema_version,
        crate::scene::manifest::editor_scene_manifest::EditorSceneManifest::CURRENT_SCHEMA_VERSION
    );
}

/// GameSaveDocument write and read round-trip.
#[test]
fn game_save_document_write_read() {
    use std::sync::atomic::{AtomicU64, Ordering};

    use crate::scene::game_save_document::GameSaveDocument;

    static NEXT_SLOT_DIR: AtomicU64 = AtomicU64::new(0);
    let unique = NEXT_SLOT_DIR.fetch_add(1, Ordering::Relaxed);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or(0);
    let tmp = std::env::temp_dir().join(format!(
        "diffuse-game-save-{}-{nanos}-{unique}",
        std::process::id()
    ));
    std::fs::create_dir_all(&tmp).expect("save directory");

    let adapter = preview_adapter();
    let manifest = adapter.manifest();
    // The manifest already holds JSON numbers; compare the persisted form so
    // f32-to-f64 widening cannot make an identical scene unequal.
    let normalized: crate::scene::manifest::editor_scene_manifest::EditorSceneManifest =
        serde_json::from_slice(&serde_json::to_vec(&manifest).expect("normalize"))
            .expect("normalized manifest");
    let document = GameSaveDocument::new(0, manifest);
    let url = GameSaveDocument::url(0, &tmp);
    document.write(&url).expect("write save");

    let loaded = GameSaveDocument::read(&url)
        .expect("read save")
        .expect("save");
    assert_eq!(loaded.slot, 0);
    assert_eq!(loaded.manifest, normalized);
    let _ = std::fs::remove_dir_all(tmp);
}

/// GameSaveDocument read returns nil for a missing file.
#[test]
fn game_save_read_missing_returns_nil() {
    use crate::scene::game_save_document::GameSaveDocument;

    let unique = format!(
        "nonexistent-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|duration| duration.as_nanos())
            .unwrap_or(0)
    );
    let url = GameSaveDocument::url(99, &std::env::temp_dir().join(unique));
    let result = GameSaveDocument::read(&url).expect("read missing");
    assert!(result.is_none());
}
