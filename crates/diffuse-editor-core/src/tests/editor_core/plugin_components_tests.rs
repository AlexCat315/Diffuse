//! Ported from `Editor/Tests/EditorCoreTests/PluginComponentsTests.swift`.
//!
//! The generated inspector form localizes its labels through the packaged
//! `DiffuseEditor_EditorCore` resource bundle, so that assertion runs only when
//! the bundle is present; the registry, add-menu and AI-schema assertions do not
//! depend on it.

use std::collections::BTreeMap;

use cove_platform::ResourceBundle;
use diffuse_plugin::contract::plugin_component_capability::PluginComponentCapability;
use diffuse_scene::components::core::registry::ComponentCategory;
use diffuse_scene::components::core::value::ComponentValue;
use diffuse_scene::components::inspection::inspection::{
    ComponentDescription, ComponentFieldDescriptor, ComponentFieldKind,
};

use crate::application::plugins::plugin_components::PluginComponentStore;
use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
use crate::scene::inspector::rendering::renderers::EditorInspectorRendererRegistry;

fn weather_description() -> ComponentDescription {
    let mut field = ComponentFieldDescriptor::new(vec!["intensity".to_string()]);
    field.kind = ComponentFieldKind::Number;
    ComponentDescription {
        type_id: "plugin.weather".to_string(),
        display_name: "Weather Zone".to_string(),
        category: ComponentCategory::Gameplay,
        requires: Vec::new(),
        is_user_addable: true,
        fields: vec![field],
        defaults: Some(ComponentValue::Object(BTreeMap::from([(
            "intensity".to_string(),
            ComponentValue::Number(0.5),
        )]))),
    }
}

fn adapter(store: &PluginComponentStore) -> EditorSceneAdapter {
    EditorSceneAdapter::new(
        false,
        store.registry(),
        EditorInspectorRendererRegistry::new(),
    )
}

/// The packaged editor resources; absent in an unpackaged test run.
fn editor_bundle_available() -> bool {
    ResourceBundle::beside_executable(&[
        "DiffuseEditor_EditorCore",
        "DiffuseEditor_EditorCore.resources",
    ])
    .ok()
    .flatten()
    .is_some()
}

/// A declared component reaches the add menu, the generated inspector form and
/// the AI/MCP schema.
#[test]
fn declared_component_end_to_end() {
    let store = PluginComponentStore::new();
    store.set(vec![weather_description()], "test.plugin");
    let adapter = adapter(&store);
    assert!(
        adapter
            .scene()
            .component_registry()
            .get("plugin.weather")
            .is_some()
    );

    let entity = adapter.with_scene_mut(|scene| scene.create_entity());
    assert!(adapter.add_component("plugin.weather", entity.raw_value()));

    let described = adapter.component_descriptions(Some("plugin.weather"));
    assert_eq!(described.len(), 1);
    assert_eq!(described[0].display_name, "Weather Zone");
    assert!(
        described[0]
            .fields
            .iter()
            .any(|field| field.id == "intensity")
    );

    if !editor_bundle_available() {
        return;
    }
    let section = adapter
        .inspector_sections(Some(entity.raw_value()))
        .into_iter()
        .find(|section| section.component_type_id.as_deref() == Some("plugin.weather"))
        .expect("declared component inspector section");
    assert!(section.fields.iter().any(|field| field.id == "intensity"));
}

/// Withdrawing a plugin removes its component from registries built afterwards
/// while built-ins stay available.
#[test]
fn withdrawal() {
    let store = PluginComponentStore::new();
    store.set(vec![weather_description()], "test.plugin");
    assert!(store.registry().get("plugin.weather").is_some());

    store.remove("test.plugin");
    assert!(store.is_empty());
    assert!(store.registry().get("plugin.weather").is_none());
    assert!(store.registry().get("collider").is_some());
}

/// The reserved capability is namespaced by plugin ID.
#[test]
fn reserved_capability() {
    assert_eq!(
        PluginComponentCapability::capability_id("acme.weather"),
        "acme.weather.components"
    );
    assert_eq!(PluginComponentCapability::NAME, "components");
}
