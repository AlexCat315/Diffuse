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

/// Scene manifest round-trips the renderable scene contract.
#[test]
fn scene_manifest_round_trips_renderable_scene_contract() {
    use diffuse_math::simd::simd_compat::{Float3, Float4};
    use diffuse_scene::components::core::value::{ComponentValue, manifest_value_for};
    use diffuse_scene::rendering::render_extraction::{
        RenderMaterialComponent, RenderMeshComponent,
    };

    use crate::scene::manifest::node::EditorSceneManifestNode;

    fn find_node(nodes: &[EditorSceneManifestNode], id: u64) -> Option<&EditorSceneManifestNode> {
        for node in nodes {
            if node.id == id {
                return Some(node);
            }
            if let Some(found) = find_node(&node.children, id) {
                return Some(found);
            }
        }
        None
    }

    fn flatten(nodes: &[crate::scene::models::editor_scene_node::EditorSceneNode]) -> Vec<u64> {
        let mut ids = Vec::new();
        for node in nodes {
            ids.push(node.id);
            ids.extend(flatten(&node.children));
        }
        ids
    }

    let source = preview_adapter();
    let hero_id = flatten(&source.roots())
        .into_iter()
        .find(|id| {
            source
                .entity_summary(Some(*id))
                .is_some_and(|summary| summary.name == "Hero")
        })
        .expect("preview scene hero");
    let hero = diffuse_scene::entity_id::EntityID::from_raw_value(hero_id);
    source.with_scene_mut(|scene| {
        scene.set_component(
            RenderMeshComponent::new(
                12,
                true,
                Float3::new(0.4, 0.5, 0.6),
                Some("hero.asset".to_string()),
                Vec::new(),
            ),
            hero,
        );
        scene.set_component(
            RenderMaterialComponent::new(
                Float4::new(0.8, 0.7, 0.6, 0.9),
                Some(2),
                Some(4),
                0.3,
                0.65,
                Float3::new(0.1, 0.2, 0.3),
                None,
                None,
                None,
            ),
            hero,
        );
    });

    let manifest = source.manifest_for_selection(Some(hero_id));
    let manifest_hero = find_node(&manifest.roots, hero_id).expect("manifest hero");
    let mesh_doc = manifest_value_for(&manifest_hero.components, "renderMesh")
        .and_then(ComponentValue::object_value)
        .expect("mesh document");
    assert_eq!(
        mesh_doc.get("meshIndex"),
        Some(&ComponentValue::Number(12.0))
    );
    assert_eq!(
        mesh_doc.get("assetID"),
        Some(&ComponentValue::String("hero.asset".to_string()))
    );
    assert_eq!(
        mesh_doc.get("colorTint"),
        Some(&ComponentValue::Array(vec![
            ComponentValue::Number(f64::from(0.4f32)),
            ComponentValue::Number(f64::from(0.5f32)),
            ComponentValue::Number(f64::from(0.6f32)),
        ]))
    );
    let material_doc = manifest_value_for(&manifest_hero.components, "renderMaterial")
        .and_then(ComponentValue::object_value)
        .expect("material document");
    assert_eq!(
        material_doc.get("baseColorFactor"),
        Some(&ComponentValue::Array(vec![
            ComponentValue::Number(f64::from(0.8f32)),
            ComponentValue::Number(f64::from(0.7f32)),
            ComponentValue::Number(f64::from(0.6f32)),
            ComponentValue::Number(f64::from(0.9f32)),
        ]))
    );
    assert_eq!(
        material_doc.get("baseColorTextureIndex"),
        Some(&ComponentValue::Number(2.0))
    );
    assert_eq!(
        material_doc.get("normalTextureIndex"),
        Some(&ComponentValue::Number(4.0))
    );

    let restored = preview_adapter();
    let result = restored.load(&manifest);
    let restored_hero = diffuse_scene::entity_id::EntityID::from_raw_value(
        result.selected_entity_id.expect("hero"),
    );
    let scene = restored.scene();
    let restored_mesh = scene
        .component::<RenderMeshComponent>(restored_hero)
        .expect("mesh");
    let restored_material = scene
        .component::<RenderMaterialComponent>(restored_hero)
        .expect("material");
    assert_eq!(restored_mesh.mesh_index, 12);
    assert_eq!(restored_mesh.asset_id.as_deref(), Some("hero.asset"));
    assert_eq!(restored_mesh.color_tint, Float3::new(0.4, 0.5, 0.6));
    assert_eq!(
        restored_material.base_color_factor,
        Float4::new(0.8, 0.7, 0.6, 0.9)
    );
    assert_eq!(restored_material.base_color_texture_index, Some(2));
    assert_eq!(restored_material.normal_texture_index, Some(4));
    assert_eq!(restored_material.metallic_factor, 0.3);
    assert_eq!(restored_material.roughness_factor, 0.65);
    assert_eq!(
        restored_material.emissive_factor,
        Float3::new(0.1, 0.2, 0.3)
    );
}

/// Scene manifest restores preview hierarchy and runtime components.
#[test]
fn scene_manifest_restores_preview_hierarchy_and_components() {
    use diffuse_scene::physics::collider::Collider;
    use diffuse_scene::physics::joints::physics_joint::PhysicsJoint;
    use diffuse_scene::physics::joints::physics_joint_configuration::PhysicsJointKind;
    use diffuse_scene::physics::rigid_body::{RigidBody, RigidBodyMotionType};
    use diffuse_scene::rendering::render_extraction::{
        CameraComponent, LightComponent, RenderMeshComponent,
    };

    use crate::scene::models::editor_scene_node::EditorSceneNode;

    fn flatten(nodes: &[EditorSceneNode]) -> Vec<EditorSceneNode> {
        nodes
            .iter()
            .flat_map(|node| {
                let mut all = vec![node.clone()];
                all.extend(flatten(&node.children));
                all
            })
            .collect()
    }

    let source = preview_adapter();
    let manifest = source.manifest_for_selection(source.default_selection_id());
    let restored = preview_adapter();
    let result = restored.load(&manifest);

    assert_eq!(result.entity_count, manifest.entity_count);
    assert!(result.selected_entity_id.is_some());
    let source_names: Vec<String> = source.roots().into_iter().map(|node| node.name).collect();
    let restored_names: Vec<String> = restored.roots().into_iter().map(|node| node.name).collect();
    assert_eq!(restored_names, source_names);

    let nodes = flatten(&restored.roots());
    let hero = nodes.iter().find(|node| node.name == "Hero");
    let camera = nodes.iter().find(|node| node.name == "Main Camera");
    let light = nodes.iter().find(|node| node.name == "Key Light");
    let constraint = nodes.iter().find(|node| node.name == "Hero Follow");
    assert!(hero.is_some() && camera.is_some() && light.is_some() && constraint.is_some());

    let scene = restored.scene();
    if let Some(hero) = hero {
        let entity = diffuse_scene::entity_id::EntityID::from_raw_value(hero.id);
        assert_eq!(
            scene
                .component::<RenderMeshComponent>(entity)
                .map(|mesh| mesh.mesh_index),
            Some(1)
        );
        assert_eq!(
            scene
                .component::<RigidBody>(entity)
                .map(|body| body.motion_type),
            Some(RigidBodyMotionType::Dynamic)
        );
        assert!(scene.component::<Collider>(entity).is_some());
    }
    if let Some(camera) = camera {
        let entity = diffuse_scene::entity_id::EntityID::from_raw_value(camera.id);
        let camera = scene.component::<CameraComponent>(entity).expect("camera");
        assert!(camera.is_active);
        assert_eq!(camera.aspect_ratio, 1.0);
    }
    if let Some(light) = light {
        let entity = diffuse_scene::entity_id::EntityID::from_raw_value(light.id);
        assert_eq!(
            scene
                .component::<LightComponent>(entity)
                .map(|light| light.intensity),
            Some(3.0)
        );
    }
    if let Some(constraint) = constraint {
        let entity = diffuse_scene::entity_id::EntityID::from_raw_value(constraint.id);
        assert_eq!(
            scene
                .component::<PhysicsJoint>(entity)
                .map(|joint| joint.constraint_type()),
            Some(PhysicsJointKind::Distance)
        );
    }
}

/// Scene manifest preserves rigid-body CCD and pending impulses.
#[test]
fn scene_manifest_preserves_complete_rigid_body_state() {
    use diffuse_math::simd::simd_compat::Float3;
    use diffuse_scene::physics::rigid_body::{RigidBody, RigidBodyOptions};
    use diffuse_scene::scene_bootstrap::SceneNameComponent;
    use diffuse_scene::scene_runtime::SceneRuntime;

    let source = preview_adapter();
    source.set_scene(SceneRuntime::new(
        diffuse_scene::components::core::registry::ComponentRegistry::built_in(),
    ));
    let entity = source.with_scene_mut(|scene| {
        let entity = scene.create_entity();
        scene.set_component(SceneNameComponent::new("Physics Body"), entity);
        scene.set_component(
            RigidBody::new(RigidBodyOptions {
                linear_velocity: Float3::new(1.0, 2.0, 3.0),
                angular_velocity: Float3::new(4.0, 5.0, 6.0),
                accumulated_force: Float3::new(7.0, 8.0, 9.0),
                accumulated_torque: Float3::new(10.0, 11.0, 12.0),
                accumulated_linear_impulse: Float3::new(13.0, 14.0, 15.0),
                accumulated_angular_impulse: Float3::new(16.0, 17.0, 18.0),
                continuous_collision_detection: true,
                ..RigidBodyOptions::default()
            }),
            entity,
        );
        entity
    });

    let manifest = source.manifest_for_selection(Some(entity.raw_value()));
    let data = serde_json::to_vec(&manifest).expect("encode");
    let decoded: crate::scene::manifest::editor_scene_manifest::EditorSceneManifest =
        serde_json::from_slice(&data).expect("decode");
    let restored = preview_adapter();
    let _ = restored.load(&decoded);

    let restored_node = restored
        .roots()
        .into_iter()
        .find(|node| node.name == "Physics Body")
        .expect("physics body");
    let body = restored
        .scene()
        .component::<RigidBody>(diffuse_scene::entity_id::EntityID::from_raw_value(
            restored_node.id,
        ))
        .expect("rigid body");
    assert_eq!(body.linear_velocity, Float3::new(1.0, 2.0, 3.0));
    assert_eq!(body.angular_velocity, Float3::new(4.0, 5.0, 6.0));
    assert_eq!(body.accumulated_force, Float3::new(7.0, 8.0, 9.0));
    assert_eq!(body.accumulated_torque, Float3::new(10.0, 11.0, 12.0));
    assert_eq!(
        body.accumulated_linear_impulse,
        Float3::new(13.0, 14.0, 15.0)
    );
    assert_eq!(
        body.accumulated_angular_impulse,
        Float3::new(16.0, 17.0, 18.0)
    );
    assert!(body.continuous_collision_detection);
}

/// Scene manifest preserves backend kind, collision steps, and capacity.
#[test]
fn scene_manifest_preserves_complete_physics_settings() {
    use diffuse_math::simd::simd_compat::Float3;
    use diffuse_scene::physics::backend::physics_backend_kind::PhysicsBackendKind;
    use diffuse_scene::physics::physics_settings::{
        PhysicsCapacitySettings, PhysicsSettingsResource,
    };
    use diffuse_scene::physics::physics_types::PhysicsSimulationMode;

    let source = preview_adapter();
    source.set_scene(diffuse_scene::scene_runtime::SceneRuntime::new(
        diffuse_scene::components::core::registry::ComponentRegistry::built_in(),
    ));
    source.with_scene_mut(|scene| {
        scene.set_resource(PhysicsSettingsResource::new(
            PhysicsSimulationMode::Bake,
            PhysicsBackendKind::None,
            Float3::new(1.0, -15.0, 2.0),
            1.0 / 120.0,
            8,
            false,
            4,
            PhysicsCapacitySettings::new(20_000, 3),
        ));
    });

    let data = serde_json::to_vec(&source.manifest()).expect("encode");
    let decoded: crate::scene::manifest::editor_scene_manifest::EditorSceneManifest =
        serde_json::from_slice(&data).expect("decode");
    let restored = preview_adapter();
    let _ = restored.load(&decoded);

    let settings = restored
        .scene()
        .resource::<PhysicsSettingsResource>()
        .expect("physics settings");
    assert_eq!(settings.backend_kind, PhysicsBackendKind::None);
    assert_eq!(settings.simulation_mode, PhysicsSimulationMode::Bake);
    assert_eq!(settings.gravity, Float3::new(1.0, -15.0, 2.0));
    assert!((settings.fixed_time_step_seconds - 1.0 / 120.0).abs() < 0.000_001);
    assert_eq!(settings.max_substeps_per_frame, 8);
    assert_eq!(settings.collision_steps, 4);
    assert!(!settings.allow_sleep);
    assert_eq!(settings.capacity, PhysicsCapacitySettings::new(20_000, 3));
}

/// Legacy physics settings migrate to Natsel without retaining obsolete tuning.
#[test]
fn legacy_physics_settings_migrate() {
    use diffuse_math::simd::simd_compat::Float3;
    use diffuse_scene::physics::backend::physics_backend_kind::PhysicsBackendKind;
    use diffuse_scene::physics::physics_settings::PhysicsCapacitySettings;

    use crate::scene::manifest::settings::EditorSceneManifestPhysicsSettings;

    let legacy = r#"{"simulationMode":"play","backendKind":"jolt","gravity":{"x":1,"y":-15,"z":2},
     "fixedTimeStepSeconds":0.01,"maxSubstepsPerFrame":8,"allowSleep":false,"collisionSteps":4,
     "capacity":{"maxBodies":64,"workerThreadCount":2},"jolt":{"maxBodyPairs":128}}"#;
    let decoded: EditorSceneManifestPhysicsSettings =
        serde_json::from_str(legacy).expect("legacy settings");
    assert_eq!(decoded.backend_kind, "natsel");
    assert_eq!(decoded.settings().backend_kind, PhysicsBackendKind::Natsel);
    assert_eq!(decoded.settings().gravity, Float3::new(1.0, -15.0, 2.0));
    assert_eq!(decoded.settings().collision_steps, 4);
    assert_eq!(
        decoded.settings().capacity,
        PhysicsCapacitySettings::new(64, 2)
    );
    let encoded = serde_json::to_vec(&decoded).expect("encode");
    let object: serde_json::Value = serde_json::from_slice(&encoded).expect("json");
    assert_eq!(object["backendKind"], "natsel");
    assert!(object.get("jolt").is_none());
}

/// Scene manifest round-trips particle scalability settings.
#[test]
fn scene_manifest_round_trips_particle_scalability_settings() {
    use diffuse_scene::particles::particle_scalability::{
        ParticleScalabilityPolicyResource, ParticleScalabilityResource,
    };

    let source = preview_adapter();
    source.with_scene_mut(|scene| {
        scene.set_resource(ParticleScalabilityResource::new(0.4, 0.5, 0.6, 0.7));
        scene.set_resource(ParticleScalabilityPolicyResource::new(
            true, 128, 32, 0.35, 0.25, 0.1,
        ));
    });

    let manifest = source.manifest_for_selection(source.default_selection_id());
    let scalability = manifest.particle_scalability.as_ref().expect("scalability");
    assert_eq!(scalability.emission_scale, 0.4);
    assert_eq!(scalability.burst_scale, 0.5);
    assert_eq!(scalability.distance_emission_scale, 0.6);
    assert_eq!(scalability.max_live_particle_scale, 0.7);
    let policy = manifest
        .particle_scalability_policy
        .as_ref()
        .expect("policy");
    assert!(policy.is_enabled);
    assert_eq!(policy.target_live_particles, 128);
    assert_eq!(policy.target_spawned_particles_per_frame, 32);
    assert_eq!(policy.minimum_scale, 0.35);
    assert_eq!(policy.pressure_step, 0.25);
    assert_eq!(policy.recovery_step, 0.1);

    let data = serde_json::to_vec(&manifest).expect("encode");
    let decoded: crate::scene::manifest::editor_scene_manifest::EditorSceneManifest =
        serde_json::from_slice(&data).expect("decode");
    let restored = preview_adapter();
    let _ = restored.load(&decoded);
    let scene = restored.scene();
    let settings = scene
        .resource::<ParticleScalabilityResource>()
        .expect("scalability");
    assert_eq!(settings.emission_scale, 0.4);
    assert_eq!(settings.burst_scale, 0.5);
    assert_eq!(settings.distance_emission_scale, 0.6);
    assert_eq!(settings.max_live_particle_scale, 0.7);
    let policy = scene
        .resource::<ParticleScalabilityPolicyResource>()
        .expect("policy");
    assert!(policy.is_enabled);
    assert_eq!(policy.target_live_particles, 128);
    assert_eq!(policy.target_spawned_particles_per_frame, 32);
    assert_eq!(policy.minimum_scale, 0.35);
    assert_eq!(policy.pressure_step, 0.25);
    assert_eq!(policy.recovery_step, 0.1);
}

/// Scene manifest round-trips camera aspect ratio.
#[test]
fn scene_manifest_round_trips_camera_aspect_ratio() {
    use diffuse_scene::components::core::value::{ComponentValue, manifest_value_for};
    use diffuse_scene::rendering::render_extraction::CameraComponent;

    use crate::scene::manifest::node::EditorSceneManifestNode;

    fn find_node(nodes: &[EditorSceneManifestNode], id: u64) -> Option<&EditorSceneManifestNode> {
        for node in nodes {
            if node.id == id {
                return Some(node);
            }
            if let Some(found) = find_node(&node.children, id) {
                return Some(found);
            }
        }
        None
    }

    let source = preview_adapter();
    let camera_node = source
        .roots()
        .into_iter()
        .find(|node| node.name == "Main Camera")
        .expect("preview camera");
    let camera_id = diffuse_scene::entity_id::EntityID::from_raw_value(camera_node.id);
    source.with_scene_mut(|scene| {
        scene.update_component::<CameraComponent>(camera_id, |camera| {
            camera.aspect_ratio = 1.777;
        });
    });

    let manifest = source.manifest_for_selection(Some(camera_node.id));
    let camera_doc = find_node(&manifest.roots, camera_node.id)
        .and_then(|node| manifest_value_for(&node.components, "camera"))
        .and_then(ComponentValue::object_value)
        .expect("camera document");
    assert_eq!(
        camera_doc.get("aspectRatio"),
        Some(&ComponentValue::Number(f64::from(1.777f32)))
    );

    let data = serde_json::to_vec(&manifest).expect("encode");
    let decoded: crate::scene::manifest::editor_scene_manifest::EditorSceneManifest =
        serde_json::from_slice(&data).expect("decode");
    let restored = preview_adapter();
    let _ = restored.load(&decoded);
    let restored_id = restored
        .roots()
        .into_iter()
        .find(|node| node.name == "Main Camera")
        .expect("restored camera")
        .id;
    assert_eq!(
        restored
            .scene()
            .component::<CameraComponent>(diffuse_scene::entity_id::EntityID::from_raw_value(
                restored_id
            ))
            .map(|camera| camera.aspect_ratio),
        Some(1.777)
    );
}

/// Scene manifest round-trips destructible configuration.
#[test]
fn scene_manifest_round_trips_destructible() {
    use diffuse_scene::physics::destruction::Destructible;
    use diffuse_scene::scene_bootstrap::SceneNameComponent;
    use diffuse_scene::scene_runtime::SceneRuntime;

    use crate::scene::models::editor_scene_node::EditorSceneNode;

    fn flatten(nodes: &[EditorSceneNode]) -> Vec<EditorSceneNode> {
        nodes
            .iter()
            .flat_map(|node| {
                let mut all = vec![node.clone()];
                all.extend(flatten(&node.children));
                all
            })
            .collect()
    }

    let source = preview_adapter();
    source.set_scene(SceneRuntime::new(
        diffuse_scene::components::core::registry::ComponentRegistry::built_in(),
    ));
    let destructible =
        Destructible::new("tower.prefractured", 90.0, 18.0, 144, 22.0, 3.5, 0.4, false);
    source.with_scene_mut(|scene| {
        let entity = scene.create_entity();
        scene.set_component(SceneNameComponent::new("Breakable Tower"), entity);
        scene.set_component(destructible.clone(), entity);
    });

    let data = serde_json::to_vec(&source.manifest()).expect("encode");
    let manifest: crate::scene::manifest::editor_scene_manifest::EditorSceneManifest =
        serde_json::from_slice(&data).expect("decode");
    let restored = preview_adapter();
    let result = restored.load(&manifest);
    assert_eq!(result.error, None);
    let restored_raw = flatten(&restored.roots())
        .into_iter()
        .find(|node| node.name == "Breakable Tower")
        .expect("breakable tower")
        .id;
    let scene = restored.scene();
    assert_eq!(
        scene.component::<Destructible>(diffuse_scene::entity_id::EntityID::from_raw_value(
            restored_raw
        )),
        Some(destructible)
    );
    assert!(
        restored
            .inspector_sections(Some(restored_raw))
            .iter()
            .any(|section| section.id == "destructible")
    );
}

/// Scene manifest round-trips soft-body and cloth configuration.
#[test]
fn scene_manifest_round_trips_soft_body_and_cloth() {
    use diffuse_scene::physics::soft_bodies::cloth::{Cloth, ClothBendType};
    use diffuse_scene::physics::soft_bodies::soft_body::{SoftBody, SoftBodyMesh};
    use diffuse_scene::scene_bootstrap::SceneNameComponent;
    use diffuse_scene::scene_runtime::SceneRuntime;

    use crate::scene::models::editor_scene_node::EditorSceneNode;

    fn flatten(nodes: &[EditorSceneNode]) -> Vec<EditorSceneNode> {
        nodes
            .iter()
            .flat_map(|node| {
                let mut all = vec![node.clone()];
                all.extend(flatten(&node.children));
                all
            })
            .collect()
    }

    let source = preview_adapter();
    source.set_scene(SceneRuntime::new(
        diffuse_scene::components::core::registry::ComponentRegistry::built_in(),
    ));
    let soft_body = SoftBody::new(
        0.6, 1.25, 0.3, 0.7, 0.15, 0.8, 0.04, 12, 75.0, 4, 0x00FF, false, false, true, true,
    );
    let cloth = Cloth::new(
        9,
        7,
        0.18,
        vec![0, 4, 8],
        0.002,
        0.003,
        0.004,
        ClothBendType::Dihedral,
    );
    let soft_body_mesh = SoftBodyMesh::new(
        Some("asset:soft-tetra".to_string()),
        vec![1, 3],
        0.005,
        0.006,
        0.007,
        0.008,
        ClothBendType::Distance,
    );
    source.with_scene_mut(|scene| {
        let entity = scene.create_entity();
        scene.set_component(SceneNameComponent::new("Cloth Banner"), entity);
        scene.set_component(soft_body.clone(), entity);
        scene.set_component(cloth.clone(), entity);
        let mesh_entity = scene.create_entity();
        scene.set_component(SceneNameComponent::new("Soft Tetra"), mesh_entity);
        scene.set_component(soft_body.clone(), mesh_entity);
        scene.set_component(soft_body_mesh.clone(), mesh_entity);
    });

    let data = serde_json::to_vec(&source.manifest()).expect("encode");
    let manifest: crate::scene::manifest::editor_scene_manifest::EditorSceneManifest =
        serde_json::from_slice(&data).expect("decode");
    let restored = preview_adapter();
    let _ = restored.load(&manifest);
    let nodes = flatten(&restored.roots());
    let restored_raw = nodes
        .iter()
        .find(|node| node.name == "Cloth Banner")
        .expect("cloth banner")
        .id;
    let restored_entity = diffuse_scene::entity_id::EntityID::from_raw_value(restored_raw);
    let scene = restored.scene();
    assert_eq!(
        scene.component::<SoftBody>(restored_entity),
        Some(soft_body.clone())
    );
    assert_eq!(scene.component::<Cloth>(restored_entity), Some(cloth));
    let sections = restored.inspector_sections(Some(restored_raw));
    assert!(sections.iter().any(|section| section.id == "soft-body"));
    assert!(sections.iter().any(|section| section.id == "cloth"));
    let restored_mesh_raw = nodes
        .iter()
        .find(|node| node.name == "Soft Tetra")
        .expect("soft tetra")
        .id;
    let restored_mesh_entity =
        diffuse_scene::entity_id::EntityID::from_raw_value(restored_mesh_raw);
    assert_eq!(
        scene.component::<SoftBody>(restored_mesh_entity),
        Some(soft_body)
    );
    assert_eq!(
        scene.component::<SoftBodyMesh>(restored_mesh_entity),
        Some(soft_body_mesh)
    );
    assert!(
        restored
            .inspector_sections(Some(restored_mesh_raw))
            .iter()
            .any(|section| section.id == "soft-body-mesh")
    );
}

/// Non-looping particles stop driving preview frames after they expire.
#[test]
fn non_looping_particles_stop_driving_preview_frames() {
    use diffuse_math::simd::simd_compat::Float3;
    use diffuse_scene::particles::emitter::particle_emitter::ParticleEmitter;
    use diffuse_scene::particles::emitter::particle_emitter_settings::ParticleEmitterSettings;
    use diffuse_scene::scene_runtime::SceneRuntime;

    let adapter = preview_adapter();
    adapter.set_scene(SceneRuntime::new(
        diffuse_scene::components::core::registry::ComponentRegistry::built_in(),
    ));
    let mut settings = ParticleEmitterSettings::default();
    settings.emission.looping = false;
    settings.emission.duration = 0.1;
    settings.emission.emission_rate = 10.0;
    settings.emission.max_particles = 8;
    settings.appearance.lifetime = 0.1;
    settings.velocity.start_velocity = Float3::ZERO;
    settings.forces.gravity = Float3::ZERO;
    adapter.with_scene_mut(|scene| {
        let entity = scene.create_entity();
        scene.set_component(ParticleEmitter::new(settings), entity);
    });

    assert!(adapter.has_active_particles());
    adapter.tick_scene(0.1, 0, Vec::new(), false);
    assert!(adapter.has_active_particles());
    adapter.tick_scene(0.2, 1, Vec::new(), false);
    assert!(!adapter.has_active_particles());
}

/// Editor scene adapter exposes particle frame stats after ticking.
#[test]
fn editor_scene_adapter_exposes_particle_frame_stats() {
    use diffuse_math::simd::simd_compat::Float3;
    use diffuse_scene::particles::emitter::particle_emitter::ParticleEmitter;
    use diffuse_scene::particles::emitter::particle_emitter_settings::ParticleEmitterSettings;

    let adapter = preview_adapter();
    let mut settings = ParticleEmitterSettings::default();
    settings.emission.emission_rate = 10.0;
    settings.emission.max_particles = 100;
    settings.appearance.lifetime = 100.0;
    settings.forces.gravity = Float3::ZERO;
    adapter.with_scene_mut(|scene| {
        let entity = scene.create_entity();
        scene.set_component(ParticleEmitter::new(settings), entity);
    });

    adapter.tick_scene(1.0, 0, Vec::new(), false);

    let stats = adapter.current_particle_frame_stats();
    assert!(stats.emitter_count >= 1);
    assert!(stats.continuous_spawned_count >= 10);
    assert!(stats.spawned_particle_count >= 10);
    assert!(stats.live_particle_count >= 10);
    assert!(stats.max_particle_count >= 100);
}

/// AudioSource round-trips through manifest encode/decode.
#[test]
fn audio_source_round_trips() {
    use diffuse_scene::components::core::registry::ComponentRegistry;
    use diffuse_scene::media::audio::AudioSource;
    use diffuse_scene::runtime_world::LocalTransform;
    use diffuse_scene::scene_bootstrap::{SceneKindComponent, SceneNameComponent};
    use diffuse_scene::scene_runtime::SceneRuntime;

    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    scene.set_component(SceneNameComponent::new("SFX"), entity);
    scene.set_component(SceneKindComponent::new("Audio"), entity);
    scene.set_local_transform(LocalTransform::IDENTITY, entity);
    scene.set_component(
        AudioSource::new("explosion", 0.8, 1.2, true, false, 0.5),
        entity,
    );
    let adapter = preview_adapter();
    adapter.set_scene(scene);
    let manifest = adapter.manifest();
    let restored = preview_adapter();
    let _ = restored.load_with_notify(&manifest, false);
    let scene = restored.scene();
    let restored_entity = scene.entities().into_iter().next().expect("entity");
    let source = scene
        .component::<AudioSource>(restored_entity)
        .expect("audio source");
    assert_eq!(source.clip_name, "explosion");
    assert_eq!(source.volume, 0.8);
    assert!(source.loop_);
    assert!(!source.play_on_awake);
}

/// AudioListener round-trips through manifest encode/decode.
#[test]
fn audio_listener_round_trips() {
    use diffuse_scene::components::core::registry::ComponentRegistry;
    use diffuse_scene::media::audio::AudioListener;
    use diffuse_scene::runtime_world::LocalTransform;
    use diffuse_scene::scene_bootstrap::{SceneKindComponent, SceneNameComponent};
    use diffuse_scene::scene_runtime::SceneRuntime;

    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    scene.set_component(SceneNameComponent::new("Listener"), entity);
    scene.set_component(SceneKindComponent::new("Audio Listener"), entity);
    scene.set_local_transform(LocalTransform::IDENTITY, entity);
    scene.set_component(AudioListener::new(0.35), entity);
    let adapter = preview_adapter();
    adapter.set_scene(scene);
    let data = serde_json::to_vec(&adapter.manifest()).expect("encode");
    let decoded: crate::scene::manifest::editor_scene_manifest::EditorSceneManifest =
        serde_json::from_slice(&data).expect("decode");
    let restored = preview_adapter();
    let _ = restored.load_with_notify(&decoded, false);
    let scene = restored.scene();
    let restored_entity = scene.entities().into_iter().next().expect("entity");
    assert_eq!(
        scene
            .component::<AudioListener>(restored_entity)
            .map(|listener| listener.master_volume),
        Some(0.35)
    );
}

/// AnimationPlayer round-trips through manifest encode/decode.
#[test]
fn animation_player_round_trips() {
    use diffuse_scene::components::core::registry::ComponentRegistry;
    use diffuse_scene::media::animation::AnimationPlayer;
    use diffuse_scene::runtime_world::LocalTransform;
    use diffuse_scene::scene_bootstrap::{SceneKindComponent, SceneNameComponent};
    use diffuse_scene::scene_runtime::SceneRuntime;

    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    scene.set_component(SceneNameComponent::new("Hero"), entity);
    scene.set_component(SceneKindComponent::new("Character"), entity);
    scene.set_local_transform(LocalTransform::IDENTITY, entity);
    scene.set_component(
        AnimationPlayer::new(Some("run".to_string()), 1.5, true, true, 3.25),
        entity,
    );
    let adapter = preview_adapter();
    adapter.set_scene(scene);
    let manifest = adapter.manifest();
    let restored = preview_adapter();
    let _ = restored.load_with_notify(&manifest, false);
    let scene = restored.scene();
    let restored_entity = scene.entities().into_iter().next().expect("entity");
    let player = scene
        .component::<AnimationPlayer>(restored_entity)
        .expect("animation player");
    assert_eq!(player.clip_name.as_deref(), Some("run"));
    assert_eq!(player.speed, 1.5);
    assert_eq!(player.time, 3.25);
    assert!(player.is_playing);
}

/// AnimationGraphPlayer round-trips through manifest encode/decode.
#[test]
fn animation_graph_player_round_trips() {
    use std::collections::BTreeMap;

    use diffuse_scene::components::core::registry::ComponentRegistry;
    use diffuse_scene::media::animation::{
        AnimationBlendSample1D, AnimationBlendSpace1D, AnimationGraph, AnimationGraphPlayer,
        AnimationMotion, AnimationState, AnimationStateMachine, AnimationTransition,
        AnimationTransitionComparison,
    };
    use diffuse_scene::runtime_world::LocalTransform;
    use diffuse_scene::scene_bootstrap::{SceneKindComponent, SceneNameComponent};
    use diffuse_scene::scene_runtime::SceneRuntime;

    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    scene.set_component(SceneNameComponent::new("Hero"), entity);
    scene.set_component(SceneKindComponent::new("Character"), entity);
    scene.set_local_transform(LocalTransform::IDENTITY, entity);
    let graph = AnimationGraph::new(
        vec![AnimationBlendSpace1D::new(
            "locomotion",
            "speed",
            vec![
                AnimationBlendSample1D::new(Some("idle".to_string()), 0.0),
                AnimationBlendSample1D::new(Some("run".to_string()), 1.0),
            ],
        )],
        AnimationStateMachine::new(
            "Idle",
            vec![
                AnimationState::new(
                    "Idle",
                    AnimationMotion::Clip(Some("idle".to_string())),
                    1.0,
                    true,
                ),
                AnimationState::new(
                    "Run",
                    AnimationMotion::BlendSpace1D("locomotion".to_string()),
                    1.0,
                    true,
                ),
            ],
            vec![AnimationTransition::new(
                "Idle",
                "Run",
                "speed",
                AnimationTransitionComparison::GreaterThan,
                0.5,
                0.25,
            )],
        ),
    );
    scene.set_component(
        AnimationGraphPlayer::new(
            graph,
            BTreeMap::from([("speed".to_string(), 0.8)]),
            Some("Run".to_string()),
            Some("Idle".to_string()),
            0.0,
            0.0,
            0.0,
            0.0,
            1.0,
            true,
        ),
        entity,
    );
    let adapter = preview_adapter();
    adapter.set_scene(scene);
    let manifest = adapter.manifest();
    let restored = preview_adapter();
    let _ = restored.load_with_notify(&manifest, false);
    let scene = restored.scene();
    let restored_entity = scene.entities().into_iter().next().expect("entity");
    let player = scene
        .component::<AnimationGraphPlayer>(restored_entity)
        .expect("graph player");
    assert_eq!(
        player
            .graph
            .blend_spaces_1d
            .first()
            .map(|space| space.name.as_str()),
        Some("locomotion")
    );
    assert_eq!(
        player
            .graph
            .state_machine
            .transitions
            .first()
            .map(|transition| transition.duration),
        Some(0.25)
    );
    assert_eq!(player.parameters.get("speed"), Some(&0.8));
    assert_eq!(player.active_state.as_deref(), Some("Run"));
    assert_eq!(player.previous_state.as_deref(), Some("Idle"));
}

/// Scene manifest round-trips a complete wheel vehicle.
#[test]
fn scene_manifest_round_trips_vehicle() {
    use diffuse_math::simd::simd_compat::Float3;
    use diffuse_scene::components::core::registry::ComponentRegistry;
    use diffuse_scene::physics::vehicles::vehicle::Vehicle;
    use diffuse_scene::physics::vehicles::vehicle_controller_configuration::VehicleControllerConfiguration;
    use diffuse_scene::physics::vehicles::vehicle_powertrain::{
        VehicleEngineConfiguration, VehicleTransmissionConfiguration,
    };
    use diffuse_scene::physics::vehicles::vehicle_wheel_configuration::{
        VehicleAntiRollBarConfiguration, VehicleDifferentialConfiguration, VehicleTransmissionMode,
        VehicleWheelConfiguration,
    };
    use diffuse_scene::scene_bootstrap::SceneNameComponent;
    use diffuse_scene::scene_runtime::SceneRuntime;

    use crate::scene::models::editor_scene_node::EditorSceneNode;

    fn flatten(nodes: &[EditorSceneNode]) -> Vec<EditorSceneNode> {
        nodes
            .iter()
            .flat_map(|node| {
                let mut all = vec![node.clone()];
                all.extend(flatten(&node.children));
                all
            })
            .collect()
    }

    let wheel = |position: Float3| {
        let mut wheel = VehicleWheelConfiguration::at_position(position);
        wheel.suspension_frequency = 2.25;
        wheel.radius = 0.42;
        wheel.max_steer_angle = 0.6;
        wheel
    };
    let mut anti_roll_bar = VehicleAntiRollBarConfiguration::new(0, 1);
    anti_roll_bar.stiffness = 1_800.0;
    let vehicle = Vehicle::new(
        VehicleControllerConfiguration::Wheeled,
        vec![
            wheel(Float3::new(0.8, -0.3, 1.2)),
            wheel(Float3::new(-0.8, -0.3, 1.2)),
        ],
        vec![VehicleDifferentialConfiguration::new(0, 1)],
        vec![anti_roll_bar],
        VehicleEngineConfiguration::new(640.0, 850.0, 7_200.0, 0.5, 0.2),
        VehicleTransmissionConfiguration::new(
            VehicleTransmissionMode::Manual,
            vec![3.2, 2.1, 1.4],
            vec![-3.0],
            0.5,
            0.3,
            0.5,
            4_000.0,
            2_000.0,
            14.0,
        ),
        Float3::new(0.0, 1.0, 0.0),
        Float3::new(0.0, 0.0, 1.0),
        1.2,
        false,
    );

    let source = preview_adapter();
    source.set_scene(SceneRuntime::new(ComponentRegistry::built_in()));
    let raw_id = source.with_scene_mut(|scene| {
        let entity = scene.create_entity();
        scene.set_component(SceneNameComponent::new("Test Vehicle"), entity);
        scene.set_component(vehicle.clone(), entity);
        entity.raw_value()
    });

    let data = serde_json::to_vec(&source.manifest_for_selection(Some(raw_id))).expect("encode");
    let decoded: crate::scene::manifest::editor_scene_manifest::EditorSceneManifest =
        serde_json::from_slice(&data).expect("decode");
    let restored = preview_adapter();
    let _ = restored.load(&decoded);
    let restored_raw = flatten(&restored.roots())
        .into_iter()
        .find(|node| node.name == "Test Vehicle")
        .expect("test vehicle")
        .id;
    assert_eq!(
        restored
            .scene()
            .component::<Vehicle>(diffuse_scene::entity_id::EntityID::from_raw_value(
                restored_raw
            )),
        Some(vehicle)
    );
    assert!(
        restored
            .inspector_sections(Some(restored_raw))
            .iter()
            .any(|section| section.id == "vehicle")
    );
}

/// Scene manifest preserves tracked and motorcycle controller settings.
#[test]
fn scene_manifest_round_trips_vehicle_controllers() {
    use diffuse_scene::components::core::registry::ComponentRegistry;
    use diffuse_scene::physics::vehicles::vehicle::Vehicle;
    use diffuse_scene::scene_bootstrap::SceneNameComponent;
    use diffuse_scene::scene_runtime::SceneRuntime;

    use crate::scene::models::editor_scene_node::EditorSceneNode;

    fn flatten(nodes: &[EditorSceneNode]) -> Vec<EditorSceneNode> {
        nodes
            .iter()
            .flat_map(|node| {
                let mut all = vec![node.clone()];
                all.extend(flatten(&node.children));
                all
            })
            .collect()
    }

    for (name, vehicle) in [
        ("Tracked Vehicle", Vehicle::tracked_default()),
        ("Motorcycle", Vehicle::motorcycle_default()),
    ] {
        let source = preview_adapter();
        source.set_scene(SceneRuntime::new(ComponentRegistry::built_in()));
        source.with_scene_mut(|scene| {
            let entity = scene.create_entity();
            scene.set_component(SceneNameComponent::new(name), entity);
            scene.set_component(vehicle.clone(), entity);
        });
        let data = serde_json::to_vec(&source.manifest()).expect("encode");
        let manifest: crate::scene::manifest::editor_scene_manifest::EditorSceneManifest =
            serde_json::from_slice(&data).expect("decode");
        let restored = preview_adapter();
        let _ = restored.load(&manifest);
        let restored_raw = flatten(&restored.roots())
            .into_iter()
            .find(|node| node.name == name)
            .expect("vehicle")
            .id;
        assert_eq!(
            restored.scene().component::<Vehicle>(
                diffuse_scene::entity_id::EntityID::from_raw_value(restored_raw)
            ),
            Some(vehicle),
            "{name}"
        );
    }
}
