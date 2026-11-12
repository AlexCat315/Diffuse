//! Ported from `Editor/Tests/EditorCoreTests/EditorSceneAdapterTests.swift`.

/// Ragdoll generator builds bodies, colliders, joints and palette mappings.
#[test]
fn generates_ragdoll_from_skin() {
    use diffuse_assets::asset_pipeline::{
        MeshAsset, MeshNode, MeshSkin,
    };
    use diffuse_assets::asset_registry::AssetRegistry;
    use diffuse_math::simd::simd_compat::{
        Float3, Float4, Float4x4, MATRIX_IDENTITY_FLOAT4X4,
    };
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
    let mut hips = MeshNode::default();
    hips.name = Some("hips".to_string());
    let mut spine = MeshNode::default();
    spine.name = Some("spine".to_string());
    spine.parent_index = Some(0);
    spine.local_translation = Float3::new(0.0, 1.0, 0.0);
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
            AssetReferenceComponent::new("test", "Hero", "hero.gltf", "/hero.gltf", "gltf", mesh_index),
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
