//! Ported from `Engine/Tests/ScriptRuntimeTests/ScriptComponentRegistryTests.swift`.
//!
//! Swift's `scene.componentRegistry.registerScriptCodec()` is the
//! [`ComponentRegistryScriptCodec`] extension trait, which must be in scope.
//! `SceneRuntime` owns its registry, so "a fresh runtime has no script codec" is
//! asserted on an independently built registry — the Rust runtime has no
//! `componentRegistry` setter to re-register into an existing instance.
//!
//! `SceneSerializer.serialize(scene)` becomes `SceneSerializer::serialize(world)`
//! and returns `String`, so the JSON is parsed with `serde_json` instead of
//! `JSONSerialization`.

use std::collections::BTreeMap;

use diffuse_scene::components::core::registry::{ComponentDecodeContext, ComponentRegistry};
use diffuse_scene::components::core::value::{ComponentValue, ManifestComponent};
use diffuse_scene::scene_bootstrap::SceneNameComponent;
use diffuse_scene::scene_graph::prefab::Prefab;
use diffuse_scene::scene_runtime::SceneRuntime;
use diffuse_scene::serialization::scene_serializer::SceneSerializer;

use crate::core::script_component::{
    ScriptBinding, ScriptBindingID, ScriptComponent, ScriptHandle,
};
use crate::interop::component_registry_script_codec::ComponentRegistryScriptCodec;

/// A registry with the script codec, as Swift's scene gets after
/// `registerScriptCodec()`.
fn registry_with_script_codec() -> ComponentRegistry {
    let mut registry = ComponentRegistry::built_in();
    registry.register_script_codec("cove.rotator");
    registry
}

/// `once registered, base serialization carries script through the components loop`
#[test]
fn registered_codec_flows_through_uniform_loop() {
    let mut scene = SceneRuntime::new(registry_with_script_codec());
    let entity = scene.create_entity();
    let binding_id = ScriptBindingID::new();
    let binding = ScriptBinding::new(
        ScriptHandle::new(0),
        binding_id.clone(),
        Some("project.native".into()),
        false,
        r#"{"level":3}"#,
    );
    scene.set_component(ScriptComponent::new(vec![binding]), entity);

    let codec = scene
        .component_registry()
        .get("script")
        .expect("the script codec is registered");
    assert_eq!(codec.display_name, "Script");

    let data = SceneSerializer::serialize(scene.world()).expect("the scene serializes");
    let json: serde_json::Value = serde_json::from_str(&data).expect("the document is JSON");
    let entities = json["entities"].as_array().expect("entities is an array");
    let components = entities[0]["components"]
        .as_object()
        .expect("components is an object");
    let script = components
        .get("script")
        .and_then(|value| value.as_object())
        .expect("the script component is present");
    let bindings = script["bindings"].as_array().expect("bindings is an array");
    assert_eq!(bindings.len(), 1);
    // Swift's `ScriptBindingID.uuidString` is `rawValue.uuidString.lowercased()`,
    // and the codec writes that property.
    assert_eq!(
        bindings[0]["bindingID"].as_str(),
        Some(binding_id.uuid_string().as_str())
    );
    assert_eq!(bindings[0]["identifier"].as_str(), Some("project.native"));
    assert_eq!(bindings[0]["isEnabled"].as_bool(), Some(false));
    assert_eq!(
        bindings[0]["parametersJSON"].as_str(),
        Some(r#"{"level":3}"#)
    );

    let mut restored = SceneRuntime::new(registry_with_script_codec());
    SceneSerializer::deserialize(&data, restored.world_mut()).expect("the document restores");
    let restored_entity = restored
        .entities()
        .first()
        .copied()
        .expect("the entity restores");
    let restored_binding = restored
        .component::<ScriptComponent>(restored_entity)
        .and_then(|component| component.bindings.first().cloned())
        .expect("the binding restores");
    assert_eq!(
        restored_binding.identifier.as_deref(),
        Some("project.native")
    );
    assert_eq!(restored_binding.id, binding_id);
    assert_eq!(restored_binding.script.raw_value, 0);
}

/// `registered script codec stays part of the registry and keeps identifiers unique`
#[test]
fn registered_codec_preserves_registry_invariants() {
    let registry = registry_with_script_codec();
    let codecs = &registry.schemas;
    let script_codecs: Vec<_> = codecs
        .iter()
        .filter(|codec| codec.type_id == "script")
        .collect();
    assert_eq!(script_codecs.len(), 1);
    let unique: std::collections::BTreeSet<&str> =
        codecs.iter().map(|codec| codec.type_id.as_str()).collect();
    assert_eq!(unique.len(), codecs.len());
    assert!(!script_codecs[0].type_id.is_empty());
    assert!(!script_codecs[0].display_name.is_empty());
}

/// `script decode defaults to empty bindings and registration is scene-local`
#[test]
fn defaults_and_isolation() {
    let mut scene = SceneRuntime::new(registry_with_script_codec());
    // Registration is per registry: a freshly built one has no script codec.
    assert!(ComponentRegistry::built_in().get("script").is_none());
    let entity = scene.create_entity();
    let mut context = ComponentDecodeContext::new(BTreeMap::from([(0, entity)]));
    SceneSerializer::apply_component_document(
        scene.world_mut(),
        entity,
        &[ManifestComponent::new(
            "script",
            ComponentValue::Object(BTreeMap::new()),
        )],
        &mut context,
    );
    let bindings = scene
        .component::<ScriptComponent>(entity)
        .expect("the component decodes")
        .bindings;
    assert_eq!(bindings, Vec::new());
}

/// `prefab capture embeds scripts in the document natively`
#[test]
fn prefab_carries_script_bindings_in_document() {
    let mut scene = SceneRuntime::new(registry_with_script_codec());
    let root = scene.create_entity();
    scene.set_component(
        SceneNameComponent {
            value: "Root".into(),
        },
        root,
    );
    scene.set_component(
        ScriptComponent::new(vec![ScriptBinding::with_identifier("project.template")]),
        root,
    );

    let prefab = Prefab::capture(scene.world(), root)
        .expect("the subtree captures")
        .expect("the root is authored");
    let json: serde_json::Value =
        serde_json::from_str(prefab.data()).expect("the prefab document is JSON");
    let entities = json["entities"].as_array().expect("entities is an array");
    let components = entities[0]["components"]
        .as_object()
        .expect("components is an object");
    let script = components
        .get("script")
        .and_then(|value| value.as_object())
        .expect("the script component is present");
    let bindings = script["bindings"].as_array().expect("bindings is an array");
    assert_eq!(bindings[0]["identifier"].as_str(), Some("project.template"));

    let mut destination = SceneRuntime::new(registry_with_script_codec());
    let new_root = prefab
        .instantiate(destination.world_mut(), None, None)
        .expect("the prefab instantiates")
        .expect("the prefab has a root");
    assert_eq!(
        destination
            .component::<ScriptComponent>(new_root)
            .and_then(|component| component.bindings.first().map(|b| b.identifier.clone())),
        Some(Some("project.template".to_string()))
    );
}
