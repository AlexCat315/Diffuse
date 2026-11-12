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
