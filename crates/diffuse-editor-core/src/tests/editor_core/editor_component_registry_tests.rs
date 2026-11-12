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
