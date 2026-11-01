//! Ported from `Engine/Tests/SceneRuntimeTests/ComponentDeclarationTests.swift`.

use std::collections::BTreeMap;

use crate::components::core::declarations::{
    ComponentDeclarationError, ComponentDeclarationLimits, ComponentDeclarations,
    ComponentInstallError,
};
use crate::components::core::registry::{ComponentCategory, ComponentRegistry};
use crate::components::core::value::ComponentValue;
use crate::components::inspection::inspection::{
    ComponentDescription, ComponentFieldDescriptor, ComponentFieldKind,
};
use crate::components::editing::ComponentWriteMode;
use crate::scene_runtime::SceneRuntime;

fn object<const N: usize>(entries: [(&str, ComponentValue); N]) -> ComponentValue {
    ComponentValue::Object(
        entries
            .into_iter()
            .map(|(key, value)| (key.to_string(), value))
            .collect::<BTreeMap<_, _>>(),
    )
}

fn make_description(type_id: &str, defaults: Option<ComponentValue>) -> ComponentDescription {
    let mut field = ComponentFieldDescriptor::new(vec!["intensity".to_string()]);
    field.kind = ComponentFieldKind::Number;
    ComponentDescription {
        type_id: type_id.to_string(),
        display_name: "Weather Zone".to_string(),
        category: ComponentCategory::Gameplay,
        requires: Vec::new(),
        is_user_addable: true,
        fields: vec![field],
        defaults,
    }
}

fn default_description(type_id: &str) -> ComponentDescription {
    make_description(
        type_id,
        Some(object([("intensity", ComponentValue::Number(0.5))])),
    )
}

fn encode(descriptions: &[ComponentDescription]) -> Vec<u8> {
    serde_json::to_vec(descriptions).expect("encode declarations")
}

fn decode(descriptions: &[ComponentDescription]) -> Vec<ComponentDescription> {
    ComponentDeclarations::decode(&encode(descriptions), &ComponentDeclarationLimits::new())
        .expect("decode declarations")
}

fn register(registry: &mut ComponentRegistry, descriptions: &[ComponentDescription]) {
    registry
        .register_contents_of(&decode(descriptions))
        .expect("register declarations");
}

/// Declared components store, edit, duplicate and describe through the registry.
#[test]
fn declared_component_lifecycle() {
    let mut registry = ComponentRegistry::built_in();
    register(&mut registry, &[default_description("plugin.weather")]);
    assert_eq!(
        registry.get("plugin.weather").map(|schema| schema.display_name.as_str()),
        Some("Weather Zone")
    );

    let mut scene = SceneRuntime::new(registry);
    let entity = scene.create_entity();
    scene
        .add_component("plugin.weather", entity)
        .expect("add declared component");
    assert!(scene.has_component_by_type_id("plugin.weather", entity));
    assert_eq!(
        scene.component_data("plugin.weather", entity),
        Some(object([("intensity", ComponentValue::Number(0.5))]))
    );

    scene
        .set_component_data(
            &object([("intensity", ComponentValue::Number(0.8))]),
            "plugin.weather",
            entity,
            ComponentWriteMode::Merge,
        )
        .expect("merge declared component");
    assert_eq!(
        scene.component_data("plugin.weather", entity),
        Some(object([("intensity", ComponentValue::Number(0.8))]))
    );

    let copy = scene.create_entity();
    scene.duplicate_component_data(entity, copy);
    assert_eq!(
        scene.component_data("plugin.weather", copy),
        Some(object([("intensity", ComponentValue::Number(0.8))]))
    );

    let description = scene
        .component_descriptions(Some("plugin.weather"))
        .into_iter()
        .next()
        .expect("one declaration");
    assert_eq!(description.display_name, "Weather Zone");
    assert!(
        description
            .fields
            .iter()
            .any(|field| field.id == "intensity")
    );
    assert_eq!(
        description.defaults,
        Some(object([("intensity", ComponentValue::Number(0.5))]))
    );

    scene
        .remove_component_data("plugin.weather", entity)
        .expect("remove declared component");
    assert!(!scene.has_component_by_type_id("plugin.weather", entity));
    assert!(scene.component_data("plugin.weather", copy).is_some());
}

/// Destroying an entity drops its declared documents.
#[test]
fn declared_documents_follow_entities() {
    let mut registry = ComponentRegistry::built_in();
    register(&mut registry, &[default_description("plugin.weather")]);
    let mut scene = SceneRuntime::new(registry);
    let entity = scene.create_entity();
    scene
        .add_component("plugin.weather", entity)
        .expect("add declared component");
    let _ = scene.destroy_entity(entity);
    assert_eq!(scene.component_data("plugin.weather", entity), None);
}

/// Untrusted declarations are rejected instead of trapping.
#[test]
fn declaration_validation() {
    let limits = ComponentDeclarationLimits::new();
    assert_eq!(
        ComponentDeclarations::decode(
            &encode(&[default_description("collider")]),
            &limits
        )
        .err(),
        Some(ComponentDeclarationError::UnnamespacedTypeID(
            "collider".to_string()
        ))
    );
    assert_eq!(
        ComponentDeclarations::decode(
            &encode(&[make_description("plugin.weather", None)]),
            &limits
        )
        .err(),
        Some(ComponentDeclarationError::MissingDefaults(
            "plugin.weather".to_string()
        ))
    );

    let mut tight_limits = ComponentDeclarationLimits::new();
    tight_limits.maximum_components = 1;
    assert_eq!(
        ComponentDeclarations::decode(
            &encode(&[
                default_description("plugin.weather"),
                default_description("plugin.other"),
            ]),
            &tight_limits
        )
        .err(),
        Some(ComponentDeclarationError::TooManyComponents(2))
    );
    assert_eq!(
        ComponentDeclarations::decode(b"{}", &limits).err(),
        Some(ComponentDeclarationError::InvalidPayload)
    );

    let mut installing = ComponentRegistry::built_in();
    let declarations = decode(&[default_description("plugin.weather")]);
    installing
        .register_contents_of(&declarations)
        .expect("first install");
    assert_eq!(
        installing.register_contents_of(&declarations),
        Err(ComponentInstallError::Declaration(
            ComponentDeclarationError::DuplicateTypeID("plugin.weather".to_string())
        ))
    );
}

/// Built-in schemas keep working alongside declared ones.
#[test]
fn built_ins_are_unaffected() {
    let mut registry = ComponentRegistry::built_in();
    register(&mut registry, &[default_description("plugin.weather")]);
    registry.validate_requirements().expect("requirements resolve");
    assert!(registry.get("collider").is_some());
    let declared = registry
        .component_schemas()
        .into_iter()
        .filter(|schema| schema.type_id == "plugin.weather")
        .count();
    assert!(registry.component_schemas().len() > declared);
}
