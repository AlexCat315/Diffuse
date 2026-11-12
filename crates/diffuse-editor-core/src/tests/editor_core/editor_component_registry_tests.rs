//! Ported from `Editor/Tests/EditorCoreTests/EditorComponentRegistryTests.swift`.

use std::collections::BTreeMap;

use diffuse_scene::components::core::registry::{
    ComponentCategory, ComponentDecodeContext, ComponentEncodeContext, ComponentRegistry,
    ComponentSchema,
};
use diffuse_scene::components::core::value::ComponentValue;
use diffuse_scene::entity_id::{EntityID, RuntimeComponent};
use diffuse_scene::rendering::render_extraction::LightComponent;
use diffuse_scene::runtime_world::RuntimeWorld;
use diffuse_scene::scene_graph::prefab::Prefab;

use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
use crate::scene::inspector::rendering::renderers::EditorInspectorRendererRegistry;

#[derive(Clone, Debug, PartialEq)]
struct EditorRegistryCounter {
    value: i64,
}

impl RuntimeComponent for EditorRegistryCounter {}

fn encode_counter(
    world: &RuntimeWorld,
    entity: EntityID,
    _context: &mut ComponentEncodeContext,
) -> Option<ComponentValue> {
    world
        .component::<EditorRegistryCounter>(entity)
        .map(|counter| {
            ComponentValue::Object(BTreeMap::from([(
                "value".to_string(),
                ComponentValue::Number(counter.value as f64),
            )]))
        })
}

fn decode_counter(
    value: &ComponentValue,
    entity: EntityID,
    _context: &mut ComponentDecodeContext,
    world: &mut RuntimeWorld,
) {
    let counter = value
        .object_value()
        .and_then(|object| object.get("value"))
        .and_then(|value| match value {
            ComponentValue::Number(number) => Some(*number as i64),
            ComponentValue::SignedInteger(integer) => Some(*integer),
            _ => None,
        })
        .unwrap_or(7);
    world.set_component(EditorRegistryCounter { value: counter }, entity);
}

fn counter_schema() -> ComponentSchema {
    ComponentSchema::for_component::<EditorRegistryCounter>(
        "test.counter",
        "Counter",
        ComponentCategory::Gameplay,
        encode_counter,
        decode_counter,
        |entity, world| {
            world.set_component(EditorRegistryCounter { value: 7 }, entity);
        },
    )
}

fn adapter_with_counter() -> EditorSceneAdapter {
    let mut registry = ComponentRegistry::built_in();
    registry.register(counter_schema());
    EditorSceneAdapter::new(false, registry, EditorInspectorRendererRegistry::new())
}

/// A module registration supplies menus, defaults, reset, undo, manifest and
/// prefab persistence.
#[test]
fn contributed_component() {
    let source = adapter_with_counter();
    let (raw_id, entity) = source.with_scene_mut(|scene| {
        let entity = scene.create_entity();
        (entity.raw_value(), entity)
    });
    source.reset_edit_history();
    assert!(
        source
            .addable_component_schemas(raw_id)
            .iter()
            .any(|schema| schema.type_id == "test.counter")
    );
    assert!(source.add_component("test.counter", raw_id));
    assert_eq!(
        source
            .scene()
            .component::<EditorRegistryCounter>(entity)
            .map(|counter| counter.value),
        Some(7)
    );
    assert!(source.undo_edit());
    assert!(!source.has_component("test.counter", raw_id));
    assert!(source.redo_edit());
    source.with_scene_mut(|scene| {
        scene.set_component(EditorRegistryCounter { value: 42 }, entity);
    });
    source.notify_revision_changed_default();

    let manifest = source.manifest_for_selection(Some(raw_id));
    let data = serde_json::to_vec(&manifest).expect("encode");
    let decoded: crate::scene::manifest::editor_scene_manifest::EditorSceneManifest =
        serde_json::from_slice(&data).expect("decode");
    assert_eq!(decoded, manifest);

    let destination = adapter_with_counter();
    let loaded = destination.load(&decoded);
    assert_eq!(loaded.error, None);
    let restored_raw = loaded.selected_entity_id.expect("selected entity");
    let restored = EntityID::from_raw_value(restored_raw);
    assert_eq!(
        destination
            .scene()
            .component::<EditorRegistryCounter>(restored)
            .map(|counter| counter.value),
        Some(42)
    );
    assert!(destination.reset_component_on_entity("test.counter", restored_raw));
    assert_eq!(
        destination
            .scene()
            .component::<EditorRegistryCounter>(restored)
            .map(|counter| counter.value),
        Some(7)
    );
    assert!(destination.undo_edit());
    assert_eq!(
        destination
            .scene()
            .component::<EditorRegistryCounter>(restored)
            .map(|counter| counter.value),
        Some(42)
    );
    assert!(destination.remove_component("test.counter", restored_raw));
    assert!(destination.undo_edit());
    assert!(destination.has_component("test.counter", restored_raw));

    let scene = destination.scene();
    let prefab = Prefab::capture(scene.world(), restored)
        .expect("capture")
        .expect("prefab");
    let instance = destination
        .with_scene_mut(|scene| prefab.instantiate(scene.world_mut(), None, None))
        .expect("instantiate")
        .expect("instance");
    assert_eq!(
        destination
            .scene()
            .component::<EditorRegistryCounter>(instance)
            .map(|counter| counter.value),
        Some(42)
    );
    destination.reset_to_preview_scene();
    assert!(
        destination
            .scene()
            .component_registry()
            .get("test.counter")
            .is_some()
    );
    let default_adapter = EditorSceneAdapter::new(
        false,
        ComponentRegistry::built_in(),
        EditorInspectorRendererRegistry::new(),
    );
    assert!(
        default_adapter
            .scene()
            .component_registry()
            .get("test.counter")
            .is_none()
    );
}

/// Interactive component edits coalesce by entity and component type.
#[test]
fn interactive_component_identity() {
    use std::collections::BTreeSet;

    let adapter = adapter_with_counter();
    let (first, second) =
        adapter.with_scene_mut(|scene| (scene.create_entity(), scene.create_entity()));
    assert!(adapter.add_component_to_selection(
        "test.counter",
        &BTreeSet::from([first.raw_value(), second.raw_value()])
    ));
    assert!(adapter.add_component("light", first.raw_value()));
    adapter.reset_edit_history();

    adapter.begin_interactive_edit_history_group();
    assert!(
        adapter.update_component_data::<EditorRegistryCounter>(first, |counter| {
            counter.value = 8;
        })
    );
    assert!(
        adapter.update_component_data::<EditorRegistryCounter>(first, |counter| {
            counter.value = 9;
        })
    );
    assert!(!adapter.can_undo_edit());
    assert!(
        adapter.update_component_data::<EditorRegistryCounter>(second, |counter| {
            counter.value = 11;
        })
    );
    assert!(
        adapter.update_component_data::<LightComponent>(first, |light| {
            light.intensity = 10.0;
        })
    );
    adapter.end_interactive_edit_history_group();

    assert!(adapter.undo_edit());
    assert_eq!(
        adapter
            .scene()
            .component::<LightComponent>(first)
            .map(|light| light.intensity),
        Some(1.0)
    );
    assert_eq!(
        adapter
            .scene()
            .component::<EditorRegistryCounter>(second)
            .map(|counter| counter.value),
        Some(11)
    );
    assert!(adapter.undo_edit());
    assert_eq!(
        adapter
            .scene()
            .component::<EditorRegistryCounter>(second)
            .map(|counter| counter.value),
        Some(7)
    );
    assert_eq!(
        adapter
            .scene()
            .component::<EditorRegistryCounter>(first)
            .map(|counter| counter.value),
        Some(9)
    );
    assert!(adapter.undo_edit());
    assert_eq!(
        adapter
            .scene()
            .component::<EditorRegistryCounter>(first)
            .map(|counter| counter.value),
        Some(7)
    );
    assert!(!adapter.can_undo_edit());
    assert!(adapter.redo_edit());
    assert_eq!(
        adapter
            .scene()
            .component::<EditorRegistryCounter>(first)
            .map(|counter| counter.value),
        Some(9)
    );
    assert!(adapter.redo_edit());
    assert!(adapter.redo_edit());
    assert_eq!(
        adapter
            .scene()
            .component::<LightComponent>(first)
            .map(|light| light.intensity),
        Some(10.0)
    );
}

/// Contributed edits cancel cleanly and a new edit invalidates redo.
#[test]
fn contributed_edit_cancellation() {
    let adapter = adapter_with_counter();
    let entity = adapter.with_scene_mut(|scene| scene.create_entity());
    assert!(adapter.add_component("test.counter", entity.raw_value()));
    adapter.reset_edit_history();
    adapter.begin_interactive_edit_history_group();
    assert!(
        adapter.update_component_data::<EditorRegistryCounter>(entity, |counter| {
            counter.value = 21;
        })
    );
    adapter.cancel_interactive_edit_history_group();
    assert_eq!(
        adapter
            .scene()
            .component::<EditorRegistryCounter>(entity)
            .map(|counter| counter.value),
        Some(7)
    );
    assert!(!adapter.can_undo_edit());
    assert!(
        adapter.update_component_data::<EditorRegistryCounter>(entity, |counter| {
            counter.value = 30;
        })
    );
    assert!(adapter.undo_edit());
    assert!(adapter.can_redo_edit());
    assert!(
        adapter.update_component_data::<EditorRegistryCounter>(entity, |counter| {
            counter.value = 40;
        })
    );
    assert!(!adapter.can_redo_edit());
    adapter.set_entity_locked(
        true,
        &std::collections::BTreeSet::from([entity.raw_value()]),
    );
    assert!(
        !adapter.update_component_data::<EditorRegistryCounter>(entity, |counter| {
            counter.value = 50;
        })
    );
    assert_eq!(
        adapter
            .scene()
            .component::<EditorRegistryCounter>(entity)
            .map(|counter| counter.value),
        Some(40)
    );
}

/// Camera and light templates use registry defaults and undo as one creation.
#[test]
fn registry_template_defaults() {
    use diffuse_math::simd::simd_compat::Float3;
    use diffuse_scene::components::core::registry::ComponentRegistry;
    use diffuse_scene::rendering::render_extraction::{CameraComponent, LightComponent, LightType};

    use crate::scene::adapter::spawn::EditorEntityTemplate;

    let adapter = EditorSceneAdapter::new(
        false,
        ComponentRegistry::built_in(),
        EditorInspectorRendererRegistry::new(),
    );
    let defaults = adapter.with_scene_mut(|scene| {
        let entity = scene.create_entity();
        scene.add_component("camera", entity).expect("camera");
        scene.add_component("light", entity).expect("light");
        entity
    });
    let camera_default = adapter
        .scene()
        .component::<CameraComponent>(defaults)
        .expect("camera default");
    let light_default = adapter
        .scene()
        .component::<LightComponent>(defaults)
        .expect("light default");
    adapter.reset_edit_history();
    for (template, light_type) in [
        (
            EditorEntityTemplate::DirectionalLight,
            LightType::Directional,
        ),
        (EditorEntityTemplate::PointLight, LightType::Point),
        (EditorEntityTemplate::SpotLight, LightType::Spot),
    ] {
        let raw_id = adapter
            .spawn_entity(template, Some(Float3::new(2.0, 3.0, 4.0)), None)
            .expect("template entity");
        let entity = diffuse_scene::entity_id::EntityID::from_raw_value(raw_id);
        let mut expected = light_default.clone();
        expected.light_type = light_type;
        assert_eq!(
            adapter.scene().component::<LightComponent>(entity),
            Some(expected.clone())
        );
        assert_eq!(
            adapter
                .scene()
                .local_transform(entity)
                .map(|transform| transform.translation()),
            Some(Float3::new(2.0, 3.0, 4.0))
        );
        assert!(adapter.undo_edit());
        assert!(!adapter.scene().contains(entity));
        assert!(!adapter.can_undo_edit());
        assert!(adapter.redo_edit());
        assert_eq!(
            adapter.scene().component::<LightComponent>(entity),
            Some(expected.clone())
        );
        adapter.reset_edit_history();
    }
    let camera_id = adapter
        .spawn_entity_default(EditorEntityTemplate::Camera)
        .expect("camera");
    assert_eq!(
        adapter.scene().component::<CameraComponent>(
            diffuse_scene::entity_id::EntityID::from_raw_value(camera_id)
        ),
        Some(camera_default)
    );
    assert!(adapter.undo_edit());
    assert!(
        !adapter
            .scene()
            .contains(diffuse_scene::entity_id::EntityID::from_raw_value(
                camera_id
            ))
    );
}

/// Templates honor contributed defaults and manifest loading supplies omitted
/// dependencies.
#[test]
fn contributed_template_defaults() {
    use diffuse_scene::runtime_world::LocalTransform;

    use crate::scene::adapter::spawn::EditorEntityTemplate;
    use crate::scene::manifest::editor_scene_manifest::EditorSceneManifest;
    use crate::scene::manifest::node::EditorSceneManifestNode;

    let adapter = contributed_template_adapter();
    let raw_id = adapter
        .spawn_entity_default(EditorEntityTemplate::Camera)
        .expect("camera");
    let entity = diffuse_scene::entity_id::EntityID::from_raw_value(raw_id);
    assert_eq!(
        adapter
            .scene()
            .component::<diffuse_scene::rendering::render_extraction::CameraComponent>(entity)
            .map(|camera| camera.fov_y_radians),
        Some(0.7)
    );
    let node = adapter.manifest().roots.first().cloned().expect("root");
    assert!(
        !node
            .components
            .iter()
            .any(|component| component.type_id == "localTransform")
    );
    let without_transform = EditorSceneManifestNode::with_options(
        node.id,
        node.name.clone(),
        node.kind.clone(),
        None,
        node.components.clone(),
        Vec::new(),
    );
    let manifest = EditorSceneManifest::new(0, 1, vec![without_transform]);
    let restored = contributed_template_adapter();
    let loaded = restored.load(&manifest);
    assert_eq!(loaded.error, None);
    let restored_entity = restored
        .scene()
        .entities()
        .into_iter()
        .next()
        .expect("entity");
    assert_eq!(
        restored
            .scene()
            .component::<LocalTransform>(restored_entity),
        Some(LocalTransform::IDENTITY)
    );
    assert_eq!(
        restored
            .scene()
            .component::<diffuse_scene::rendering::render_extraction::CameraComponent>(
                restored_entity
            )
            .map(|camera| camera.fov_y_radians),
        Some(0.7)
    );
}

fn contributed_template_adapter() -> EditorSceneAdapter {
    use diffuse_scene::components::core::registry::{
        ComponentCategory, ComponentRegistry, ComponentSchema,
    };
    use diffuse_scene::rendering::render_extraction::CameraComponent;

    let builtin = ComponentRegistry::built_in();
    let camera = builtin.get("camera").cloned().expect("camera schema");
    let mut registry = ComponentRegistry::new();
    for schema in builtin
        .schemas
        .iter()
        .filter(|schema| schema.type_id != "camera")
    {
        registry.register(schema.clone());
    }
    let mut schema = ComponentSchema::for_component::<CameraComponent>(
        "camera",
        "Camera",
        ComponentCategory::Rendering,
        camera.encode,
        camera.decode,
        |entity, world| {
            world.set_component(
                diffuse_scene::rendering::render_extraction::CameraComponent::new(
                    diffuse_math::simd::simd_compat::Float3::ZERO,
                    diffuse_math::simd::simd_compat::Float3::new(0.0, 1.0, 0.0),
                    0.7,
                    1.0,
                    0.25,
                    250.0,
                    false,
                ),
                entity,
            );
        },
    );
    schema.requires = vec!["localTransform".to_string()];
    registry.register(schema);
    EditorSceneAdapter::new(false, registry, EditorInspectorRendererRegistry::new())
}

/// Manifest and prefab use the same component values and remap forward references.
#[test]
fn prefab_interoperation() {
    use diffuse_math::simd::simd_compat::{Float3, MATRIX_IDENTITY_FLOAT4X4};
    use diffuse_scene::components::core::registry::ComponentRegistry;
    use diffuse_scene::components::core::value::ComponentValue;
    use diffuse_scene::physics::joints::physics_joint::PhysicsJoint;
    use diffuse_scene::physics::joints::physics_joint_configuration::{
        HingeJointConfiguration, PhysicsJointConfiguration,
    };
    use diffuse_scene::physics::ragdoll::{Ragdoll, RagdollBoneMapping, RagdollMode};
    use diffuse_scene::physics::rigid_body::RigidBodyMotionType;
    use diffuse_scene::runtime_world::LocalTransform;
    use diffuse_scene::scene_runtime::SceneRuntime;
    use diffuse_script::core::script_component::{ScriptBinding, ScriptBindingID, ScriptComponent};
    use diffuse_script::interop::component_registry_script_codec::ComponentRegistryScriptCodec;

    let source = EditorSceneAdapter::new(
        false,
        ComponentRegistry::built_in(),
        EditorInspectorRendererRegistry::new(),
    );
    let (root, child) = source.with_scene_mut(|scene| {
        let root = scene.create_entity();
        let child = scene.create_entity();
        scene.set_local_transform(LocalTransform::IDENTITY, root);
        scene.set_local_transform(
            LocalTransform::from_translation(Float3::new(1.0, 2.0, 3.0)),
            child,
        );
        scene.set_parent(Some(root), child);
        scene.set_component(
            PhysicsJoint::new(
                PhysicsJointConfiguration::Hinge(HingeJointConfiguration::default()),
                root,
                child,
                Float3::ZERO,
                Float3::ZERO,
                true,
                PhysicsJoint::DEFAULT_BREAK_LIMIT,
                PhysicsJoint::DEFAULT_BREAK_LIMIT,
            ),
            root,
        );
        scene.set_component(
            Ragdoll::new(
                RagdollMode::Animated,
                1.0,
                true,
                vec![RagdollBoneMapping::with_mapping(
                    "Hip",
                    0,
                    child,
                    Some(root),
                    MATRIX_IDENTITY_FLOAT4X4,
                    RigidBodyMotionType::Dynamic,
                    true,
                    1.0,
                )],
            ),
            root,
        );
        scene.set_component(
            ScriptComponent::new(vec![ScriptBinding::from_identifier(
                "project.test",
                ScriptBindingID::new(),
                true,
                "{}",
            )]),
            child,
        );
        (root, child)
    });
    let manifest = source.manifest();
    let scene = source.scene();
    let prefab = Prefab::capture(scene.world(), root)
        .expect("capture")
        .expect("prefab");
    let document: serde_json::Value = serde_json::from_str(prefab.data()).expect("prefab JSON");
    let records = document["entities"].as_array().expect("entities");
    for (node, record) in [
        (manifest.roots[0].clone(), &records[0]),
        (manifest.roots[0].children[0].clone(), &records[1]),
    ] {
        let runtime_values = record["components"].as_object().expect("components");
        let authored: ComponentValue = ComponentValue::Object(
            node.components
                .iter()
                .map(|component| (component.type_id.clone(), component.value.clone()))
                .collect(),
        );
        // Put both documents through the JSON boundary before comparing, as the
        // prefab values have already crossed it.
        let authored_json: serde_json::Value = serde_json::from_str(
            &serde_json::to_string(&authored.to_json_value()).expect("authored json"),
        )
        .expect("authored wire json");
        let authored_wire = ComponentValue::from_json_value(&authored_json);
        let runtime_wire =
            ComponentValue::from_json_value(&serde_json::Value::Object(runtime_values.clone()));
        assert_eq!(runtime_wire, authored_wire);
    }

    let mut occupied_registry = ComponentRegistry::built_in();
    occupied_registry.register_default_script_codec();
    let mut occupied = SceneRuntime::new(occupied_registry);
    let _ = occupied.create_entity();
    let instance = prefab
        .instantiate(occupied.world_mut(), None, None)
        .expect("instantiate")
        .expect("instance");
    let instance_child = occupied.children(instance)[0];
    assert_eq!(
        occupied
            .component::<PhysicsJoint>(instance)
            .map(|joint| joint.entity_b),
        Some(instance_child)
    );
    assert_eq!(
        occupied
            .component::<Ragdoll>(instance)
            .and_then(|ragdoll| ragdoll.bones.first().and_then(|bone| bone.joint_entity)),
        Some(instance)
    );
    assert_eq!(
        occupied
            .component::<ScriptComponent>(instance_child)
            .and_then(|component| component
                .bindings
                .first()
                .and_then(|binding| binding.identifier.clone())),
        Some("project.test".to_string())
    );

    let restored = EditorSceneAdapter::new(
        false,
        ComponentRegistry::built_in(),
        EditorInspectorRendererRegistry::new(),
    );
    assert_eq!(restored.load(&manifest).error, None);
    let restored_scene = restored.scene();
    let restored_root = restored_scene.roots()[0];
    let restored_child = restored_scene.children(restored_root)[0];
    assert_eq!(
        restored_scene
            .component::<PhysicsJoint>(restored_root)
            .map(|joint| joint.entity_b),
        Some(restored_child)
    );
    assert_eq!(
        restored_scene
            .component::<Ragdoll>(restored_root)
            .and_then(|ragdoll| ragdoll.bones.first().map(|bone| bone.body_entity)),
        Some(restored_child)
    );
    let _ = child;
}
