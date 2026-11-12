//! Ported from `Editor/Tests/EditorCoreTests/Scripting/ScriptInspectorContractTests.swift`.

use std::collections::BTreeMap;

use diffuse_scene::components::core::registry::ComponentRegistry;
use diffuse_script::Script;
use diffuse_script::core::script_component::ScriptComponent;
use diffuse_script::core::script_definition::{
    ScriptDefinition, ScriptProperty, ScriptPropertyOption, ScriptPropertyValue,
};

use crate::localization::localized;
use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
use crate::scene::editor_inspector_schema::{
    EditorInspectorFieldPresentation, EditorInspectorFieldValue, EditorInspectorSection,
};
use crate::scene::inspector::rendering::renderers::EditorInspectorRendererRegistry;
use crate::scripting::dynamic::project_script_catalog::ProjectScriptCatalog;

fn make_adapter() -> EditorSceneAdapter {
    let adapter = EditorSceneAdapter::new(
        false,
        ComponentRegistry::built_in(),
        EditorInspectorRendererRegistry::built_in(),
    );
    let _ = adapter.apply_project_script_catalog(&ProjectScriptCatalog::built_in());
    adapter
}

fn entity(adapter: &EditorSceneAdapter) -> u64 {
    adapter
        .with_scene_mut(|scene| scene.create_entity())
        .raw_value()
}

fn scripts_section(adapter: &EditorSceneAdapter, id: u64) -> EditorInspectorSection {
    adapter
        .inspector_sections(Some(id))
        .into_iter()
        .find(|section| section.id == "scripts")
        .expect("scripts section")
}

fn parameters_json(adapter: &EditorSceneAdapter, id: u64) -> String {
    adapter
        .scene()
        .component::<ScriptComponent>(diffuse_scene::entity_id::EntityID::from_raw_value(id))
        .and_then(|component| component.bindings.first().cloned())
        .map(|binding| binding.parameters_json)
        .expect("binding parameters")
}

fn velocity(json: &str) -> Option<Vec<i64>> {
    ScriptDefinition::decode_parameters(json)
        .get("velocity")
        .and_then(|value| value.as_array())
        .map(|values| {
            values
                .iter()
                .filter_map(|value| value.as_u64().map(|number| number as i64))
                .collect::<Vec<_>>()
        })
}

/// Typed fields store only overrides, preserve other keys, support undo and
/// scene roundtrip.
#[test]
fn property_editing() {
    let adapter = make_adapter();
    let id = entity(&adapter);
    assert!(adapter.add_script_binding_with_identifier(id, Some("cove.mover")));

    let original = scripts_section(&adapter, id);
    assert_eq!(original.groups.len(), 1);
    assert_eq!(
        original
            .fields
            .iter()
            .find(|field| field.id == "script-0-parameters")
            .map(|field| field.presentation),
        Some(EditorInspectorFieldPresentation::Advanced)
    );
    let Some(EditorInspectorFieldValue::Vector3 { x, y, z: _ }) = original
        .fields
        .iter()
        .find(|field| field.id == "script-0-property-velocity")
        .map(|field| field.value.clone())
    else {
        panic!("expected typed velocity property");
    };
    assert_eq!(x.get(), 0.0);
    x.set(3.0);
    y.set(2.0);
    let json = parameters_json(&adapter, id);
    assert_eq!(velocity(&json), Some(vec![3, 2, 0]));

    assert!(adapter.undo_edit());
    assert_eq!(y.get(), 0.0);
    assert_eq!(x.get(), 3.0);
    assert!(adapter.redo_edit());
    assert_eq!(y.get(), 2.0);

    let manifest = adapter.manifest();
    let data = serde_json::to_vec(&manifest).expect("encode manifest");
    let decoded: crate::scene::manifest::editor_scene_manifest::EditorSceneManifest =
        serde_json::from_slice(&data).expect("decode manifest");
    let restored = make_adapter();
    let _ = restored.load_with_notify(&decoded, false);
    let restored_root = restored.scene().roots().first().copied().expect("root");
    assert_eq!(
        parameters_json(&restored, restored_root.raw_value()),
        parameters_json(&adapter, id)
    );

    x.set(0.0);
    y.set(0.0);
    let json = parameters_json(&adapter, id);
    assert!(ScriptDefinition::decode_parameters(&json).is_empty());
}

/// Property controls and removal follow binding identity after an earlier
/// binding is removed.
#[test]
fn stable_binding_identity() {
    let adapter = make_adapter();
    let id = entity(&adapter);
    assert!(adapter.add_script_binding_with_identifier(id, Some("cove.mover")));
    assert!(adapter.add_script_binding_with_identifier(id, Some("cove.mover")));

    let initial = scripts_section(&adapter, id);
    let second_group_id = initial.groups[1].id.clone();
    let Some(EditorInspectorFieldValue::Vector3 {
        x: first_x,
        y: _,
        z: _,
    }) = initial
        .fields
        .iter()
        .find(|field| field.id == "script-0-property-velocity")
        .map(|field| field.value.clone())
    else {
        panic!("expected first typed behavior");
    };
    let Some(EditorInspectorFieldValue::Vector3 {
        x: second_x,
        y: _,
        z: _,
    }) = initial
        .fields
        .iter()
        .find(|field| field.id == "script-1-property-velocity")
        .map(|field| field.value.clone())
    else {
        panic!("expected second typed behavior");
    };
    let Some(EditorInspectorFieldValue::Action { action, .. }) = initial
        .fields
        .iter()
        .find(|field| field.id == "script-1-remove")
        .map(|field| field.value.clone())
    else {
        panic!("expected remove action");
    };

    assert!(adapter.remove_script_binding(id, 0));
    first_x.set(99.0); // A stale control must not edit the remaining binding.
    second_x.set(4.0);
    assert_eq!(
        scripts_section(&adapter, id)
            .groups
            .first()
            .map(|group| group.id.clone()),
        Some(second_group_id)
    );
    assert_eq!(
        velocity(&parameters_json(&adapter, id)),
        Some(vec![4, 0, 0])
    );
    action();
    assert!(
        adapter
            .scene()
            .component::<ScriptComponent>(diffuse_scene::entity_id::EntityID::from_raw_value(id))
            .is_some_and(|component| component.bindings.is_empty())
    );
}

/// Legacy bindings retain the behavior name and source link without
/// duplicating the script picker.
#[test]
fn legacy_source_identity() {
    let adapter = EditorSceneAdapter::new(
        false,
        ComponentRegistry::built_in(),
        EditorInspectorRendererRegistry::built_in(),
    );
    adapter.set_dynamic_script_options(
        BTreeMap::from([("scripts.asset.player".to_string(), "Player".to_string())]),
        BTreeMap::from([(
            "scripts.Player".to_string(),
            "scripts.asset.player".to_string(),
        )]),
    );
    let id = entity(&adapter);
    assert!(adapter.add_script_binding_with_identifier(id, Some("scripts.Player")));
    let schema = scripts_section(&adapter, id);
    let group = schema.groups.first().expect("group");
    assert_eq!(group.title, "Player · Swift");
    assert_eq!(
        group.source_identifier.as_deref(),
        Some("scripts.asset.player")
    );
    match schema
        .fields
        .iter()
        .find(|field| field.id == "script-0-interface")
        .map(|field| field.value.clone())
    {
        Some(EditorInspectorFieldValue::ReadOnly(message)) => {
            assert_eq!(message, localized("Build script to load properties"));
        }
        _ => panic!("expected unbuilt script property guidance"),
    }
    assert_eq!(
        adapter
            .available_script_options()
            .iter()
            .map(|option| option.value.clone())
            .collect::<Vec<_>>(),
        ["scripts.asset.player"]
    );
    adapter.unregister_dynamic_script_option("scripts.asset.player");
    assert_eq!(
        scripts_section(&adapter, id)
            .groups
            .first()
            .and_then(|group| group.source_identifier.clone()),
        None
    );
}

/// Custom definitions expose choices, project defaults and semantic errors
/// for legacy JSON.
#[test]
fn custom_contract() {
    let adapter = EditorSceneAdapter::new(
        false,
        ComponentRegistry::built_in(),
        EditorInspectorRendererRegistry::built_in(),
    );
    let definition = ScriptDefinition::new(vec![
        ScriptProperty::new(
            "speed",
            Some("Speed".to_string()),
            Some("Movement".to_string()),
            None,
            ScriptPropertyValue::Number(2.0),
            Some(0.0),
            Some(10.0),
            None,
            Vec::new(),
        ),
        ScriptProperty::new(
            "mode",
            Some("Mode".to_string()),
            None,
            None,
            ScriptPropertyValue::String("ready".to_string()),
            None,
            None,
            None,
            vec![
                ScriptPropertyOption::new("ready", None),
                ScriptPropertyOption::new("playing", None),
            ],
        ),
    ]);
    adapter.script_runtime.register_factory(
        Some("test.player"),
        r#"{"speed":5}"#,
        definition,
        || Script::new(None, None, None, None),
    );
    adapter.register_dynamic_script_option("test.player", "Player", &[]);
    let id = entity(&adapter);
    assert!(adapter.add_script_binding_with_identifier(id, Some("test.player")));
    let schema = scripts_section(&adapter, id);
    assert_eq!(
        schema
            .groups
            .first()
            .and_then(|group| group.source_identifier.as_deref()),
        Some("test.player")
    );
    let Some(EditorInspectorFieldValue::ConstrainedNumber { binding: speed, .. }) = schema
        .fields
        .iter()
        .find(|field| field.id == "script-0-property-speed")
        .map(|field| field.value.clone())
    else {
        panic!("expected constrained speed");
    };
    let Some(EditorInspectorFieldValue::StringOptions {
        binding: mode,
        options,
    }) = schema
        .fields
        .iter()
        .find(|field| field.id == "script-0-property-mode")
        .map(|field| field.value.clone())
    else {
        panic!("expected mode choices");
    };
    let Some(EditorInspectorFieldValue::Json { binding: raw, .. }) = schema
        .fields
        .iter()
        .find(|field| field.id == "script-0-parameters")
        .map(|field| field.value.clone())
    else {
        panic!("expected raw JSON");
    };
    assert_eq!(speed.get(), 5.0);
    assert_eq!(options.len(), 2);
    speed.set(11.0);
    assert_eq!(speed.get(), 5.0);
    mode.set("playing".to_string());
    raw.set(r#"{"speed":true,"title":"ignored"}"#.to_string());
    assert_eq!(speed.get(), 5.0);
    assert!(
        scripts_section(&adapter, id)
            .fields
            .iter()
            .any(|field| field.id == "script-0-issues")
    );
    raw.set("[]".to_string());
    assert_ne!(raw.get(), "[]");
}
