//! Ported from `Engine/Tests/SceneRuntimeTests/ComponentInspectionTests.swift`.

use std::collections::BTreeMap;

use crate::components::core::registry::{
    ComponentCategory, ComponentDecodeContext, ComponentEncodeContext, ComponentEncodePurpose,
    ComponentRegistry, ComponentSchema,
};
use crate::components::core::value::ComponentValue;
use crate::components::inspection::inspection::{
    ComponentDescription, ComponentFieldChoice, ComponentFieldDescriptor, ComponentFieldKind,
    ComponentInspection,
};
use crate::entity_id::{EntityID, RuntimeComponent};
use crate::physics::rigid_body::RigidBodyMotionType;
use crate::rendering::render_extraction::CameraComponent;
use crate::runtime_world::RuntimeWorld;
use crate::scene_runtime::SceneRuntime;
use crate::serialization::scene_serializer::SceneSerializer;

fn object<const N: usize>(entries: [(&str, ComponentValue); N]) -> ComponentValue {
    ComponentValue::Object(
        entries
            .into_iter()
            .map(|(key, value)| (key.to_string(), value))
            .collect::<BTreeMap<_, _>>(),
    )
}

fn path_is(field: &ComponentFieldDescriptor, path: &[&str]) -> bool {
    field.path.len() == path.len()
        && field
            .path
            .iter()
            .zip(path.iter())
            .all(|(actual, expected)| actual == expected)
}

fn runtime() -> SceneRuntime {
    SceneRuntime::new(ComponentRegistry::built_in())
}

/// Physics descriptions retain bounded integers, numeric enum storage and
/// read-only simulation fields.
#[test]
fn physics_descriptions() {
    let scene = runtime();
    let descriptions = scene.component_descriptions(None);
    let body = descriptions
        .iter()
        .find(|description| description.type_id == "rigidbody")
        .expect("rigidbody description");
    assert_eq!(
        body.fields
            .iter()
            .find(|field| path_is(field, &["motionType"]))
            .map(|field| field.choices.clone()),
        Some(
            RigidBodyMotionType::ALL
                .iter()
                .map(|motion_type| ComponentFieldChoice::new(motion_type.raw_value()))
                .collect::<Vec<_>>()
        )
    );
    for key in [
        "isSleeping",
        "accumulatedForce",
        "accumulatedTorque",
        "kinematicTarget",
    ] {
        assert_eq!(
            body.fields
                .iter()
                .find(|field| path_is(field, &[key]))
                .map(|field| field.is_read_only),
            Some(true),
            "key {key}"
        );
    }

    let soft = descriptions
        .iter()
        .find(|description| description.type_id == "softBody")
        .expect("softBody description");
    let iterations = soft
        .fields
        .iter()
        .find(|field| path_is(field, &["solverIterations"]))
        .expect("solverIterations field");
    assert_eq!(iterations.kind, ComponentFieldKind::Integer);
    assert_eq!(iterations.numeric.minimum, Some(1.0));
    assert_eq!(iterations.numeric.maximum, Some(128.0));
    assert!(
        !soft.fields.iter().any(|field| path_is(field, &["positions"])
            || field.id == "soft-body-streamed-vertices")
    );

    let cloth = descriptions
        .iter()
        .find(|description| description.type_id == "cloth")
        .expect("cloth description");
    let bend = cloth
        .fields
        .iter()
        .find(|field| path_is(field, &["bendType"]))
        .expect("bendType field");
    assert_eq!(bend.kind, ComponentFieldKind::Options);
    assert_eq!(
        bend.choices
            .iter()
            .map(|choice| choice.id.as_str())
            .collect::<Vec<_>>(),
        vec!["none", "distance", "dihedral"]
    );
    // Swift compares `.unsignedInteger(rawValue)` against `.number(Double(rawValue))`
    // and its `ComponentValue` equality normalizes numeric representations; Rust
    // equality is variant-strict, so the numeric projection carries the assertion.
    assert_eq!(
        bend.choices
            .iter()
            .map(|choice| choice.value.numeric_value())
            .collect::<Vec<_>>(),
        vec![Some(0.0), Some(1.0), Some(2.0)]
    );

    let mesh = descriptions
        .iter()
        .find(|description| description.type_id == "softBodyMesh")
        .expect("softBodyMesh description");
    assert_eq!(
        mesh.fields
            .iter()
            .find(|field| path_is(field, &["resourceID"]))
            .map(|field| field.is_nullable),
        Some(true)
    );

    let decoded: Vec<ComponentDescription> =
        serde_json::from_slice(&serde_json::to_vec(&descriptions).expect("encode"))
            .expect("decode descriptions");
    assert_eq!(decoded, descriptions);
}

/// Descriptions use codec defaults and never mutate the inspected scene.
#[test]
fn registry_descriptions() {
    let mut scene = runtime();
    let entity = scene.create_entity();
    scene.add_component("camera", entity).expect("add camera");
    scene.update_component::<CameraComponent>(entity, |camera| camera.is_active = true);
    let before = SceneSerializer::serialize(scene.world()).expect("serialize");
    let revision = scene.snapshot().revision;
    let descriptions = scene.component_descriptions(None);
    assert_eq!(
        descriptions
            .iter()
            .map(|description| description.type_id.clone())
            .collect::<Vec<_>>(),
        scene
            .component_registry()
            .component_schemas()
            .into_iter()
            .map(|schema| schema.type_id)
            .collect::<Vec<_>>()
    );
    assert!(
        !descriptions
            .iter()
            .any(|description| description.type_id == "localTransform")
    );

    let camera = descriptions
        .iter()
        .find(|description| description.type_id == "camera")
        .expect("camera description");
    assert_eq!(camera.requires, vec!["localTransform".to_string()]);
    assert_eq!(
        camera
            .defaults
            .as_ref()
            .and_then(|defaults| defaults.value_at(&["isActive".to_string()])),
        Some(&ComponentValue::Bool(false))
    );
    let fov = camera
        .fields
        .iter()
        .find(|field| path_is(field, &["fovYRadians"]))
        .expect("fov field");
    assert_eq!(fov.kind, ComponentFieldKind::Number);
    assert_eq!(fov.numeric.scale, 180.0 / std::f64::consts::PI);
    assert_eq!(fov.numeric.minimum, Some(1.0));
    assert_eq!(fov.numeric.maximum, Some(179.0));

    assert_eq!(scene.snapshot().revision, revision);
    assert_eq!(
        SceneSerializer::serialize(scene.world()).expect("serialize after descriptions"),
        before
    );
    assert_eq!(
        scene.component_descriptions(Some("camera")),
        vec![camera.clone()]
    );
    assert!(scene.component_descriptions(Some("unregistered")).is_empty());

    let constraint = descriptions
        .iter()
        .find(|description| description.type_id == "constraint")
        .expect("constraint description");
    assert_eq!(constraint.defaults, None);
    assert!(!constraint.is_user_addable);
    assert!(
        constraint
            .fields
            .iter()
            .any(|field| path_is(field, &["entityA"]) && field.kind == ComponentFieldKind::Integer)
    );

    let decoded: Vec<ComponentDescription> =
        serde_json::from_slice(&serde_json::to_vec(&descriptions).expect("encode"))
            .expect("decode descriptions");
    assert_eq!(decoded, descriptions);
}

#[derive(Clone, PartialEq)]
struct InspectionSource;

impl RuntimeComponent for InspectionSource {}

fn encode_source(
    world: &RuntimeWorld,
    entity: EntityID,
    context: &mut ComponentEncodeContext,
) -> Option<ComponentValue> {
    if !world.has_component::<InspectionSource>(entity) {
        return None;
    }
    let mut fields = BTreeMap::new();
    fields.insert("authored".to_string(), ComponentValue::Bool(true));
    if context.purpose != ComponentEncodePurpose::Authored {
        fields.insert("transient".to_string(), ComponentValue::Number(100.0));
    }
    Some(ComponentValue::Object(fields))
}

fn decode_source(
    _value: &ComponentValue,
    entity: EntityID,
    _context: &mut ComponentDecodeContext,
    world: &mut RuntimeWorld,
) {
    let _ = world.set_component(InspectionSource, entity);
}

fn make_default_source(_entity: EntityID, _world: &mut RuntimeWorld) {}

/// Non-default-constructible schemas infer authored fields from existing
/// instances.
#[test]
fn authored_sample() {
    let mut scene = runtime();
    scene.world_mut().component_registry.register(
        ComponentSchema::for_component::<InspectionSource>(
            "test.source",
            "Source",
            ComponentCategory::Gameplay,
            encode_source,
            decode_source,
            make_default_source,
        ),
    );
    let entity = scene.create_entity();
    scene.set_component(InspectionSource, entity);
    let description = scene
        .component_descriptions(Some("test.source"))
        .into_iter()
        .next()
        .expect("source description");
    assert_eq!(description.defaults, None);
    assert_eq!(
        description
            .fields
            .iter()
            .map(|field| field.id.as_str())
            .collect::<Vec<_>>(),
        vec!["authored"]
    );
    assert_eq!(
        scene
            .component_data("test.source", entity)
            .and_then(|data| data.value_at(&["transient".to_string()]).cloned()),
        Some(ComponentValue::Number(100.0))
    );
}

/// Field inference follows nested codec documents and explicit groups override
/// descendants.
#[test]
fn inference_and_overrides() {
    let document = object([
        (
            "settings",
            object([
                ("enabled", ComponentValue::Bool(true)),
                ("gain", ComponentValue::Number(1.5)),
            ]),
        ),
        (
            "offset",
            ComponentValue::Array(vec![
                ComponentValue::Number(1.0),
                ComponentValue::Number(2.0),
                ComponentValue::Number(3.0),
            ]),
        ),
        ("seed", ComponentValue::UnsignedInteger(u64::MAX)),
        ("items", ComponentValue::Array(Vec::new())),
        ("optional", ComponentValue::Null),
    ]);

    let inferred = ComponentInspection::new().resolved_fields(&document);
    assert_eq!(
        inferred
            .iter()
            .find(|field| path_is(field, &["settings", "enabled"]))
            .map(|field| field.kind),
        Some(ComponentFieldKind::Boolean)
    );
    assert_eq!(
        inferred
            .iter()
            .find(|field| path_is(field, &["settings", "gain"]))
            .map(|field| field.kind),
        Some(ComponentFieldKind::Number)
    );
    assert_eq!(
        inferred
            .iter()
            .find(|field| path_is(field, &["offset"]))
            .map(|field| field.kind),
        Some(ComponentFieldKind::Vector3)
    );
    assert_eq!(
        inferred
            .iter()
            .find(|field| path_is(field, &["seed"]))
            .map(|field| field.kind),
        Some(ComponentFieldKind::Integer)
    );
    assert_eq!(
        inferred
            .iter()
            .find(|field| path_is(field, &["optional"]))
            .map(|field| field.kind),
        Some(ComponentFieldKind::Json)
    );

    let mut settings = ComponentFieldDescriptor::new(vec!["settings".to_string()]);
    settings.kind = ComponentFieldKind::Json;
    let inspection = ComponentInspection {
        is_read_only: true,
        fields: vec![settings],
        ..ComponentInspection::default()
    };
    let fields = inspection.resolved_fields(&document);
    assert_eq!(
        fields
            .iter()
            .filter(|field| field.path.first().map(String::as_str) == Some("settings"))
            .count(),
        1
    );
    assert!(fields.iter().all(|field| field.is_read_only));
    assert!(fields.iter().any(|field| path_is(field, &["items"])));

    let patched = document
        .merging(&ComponentValue::field_patch(
            ComponentValue::Number(9.0),
            &["offset".to_string(), "1".to_string()],
        ))
        .expect("field patch merges");
    assert_eq!(
        patched.value_at(&["offset".to_string()]),
        Some(&ComponentValue::Array(vec![
            ComponentValue::Number(1.0),
            ComponentValue::Number(9.0),
            ComponentValue::Number(3.0),
        ]))
    );
    assert_eq!(
        patched.value_at(&["offset".to_string(), "-1".to_string()]),
        None
    );
    assert_eq!(
        patched.value_at(&["offset".to_string(), "3".to_string()]),
        None
    );
    assert_eq!(patched.value_at(&[]), Some(&patched));
}

/// Rendering and playback descriptions share nullable strings, color ranges and
/// advanced fields with the editor.
#[test]
fn generated_form_metadata() {
    let scene = runtime();
    let mesh = scene
        .component_descriptions(Some("renderMesh"))
        .into_iter()
        .next()
        .expect("renderMesh description");
    assert_eq!(
        mesh.fields
            .iter()
            .filter(|field| !field.is_advanced)
            .map(|field| field.id.clone())
            .collect::<Vec<_>>(),
        vec!["mesh-visible".to_string(), "mesh-color-tint".to_string()]
    );
    assert_eq!(
        mesh.fields
            .iter()
            .find(|field| path_is(field, &["meshIndex"]))
            .map(|field| field.is_read_only),
        Some(true)
    );

    let material = scene
        .component_descriptions(Some("renderMaterial"))
        .into_iter()
        .next()
        .expect("renderMaterial description");
    let base_color = material
        .fields
        .iter()
        .find(|field| path_is(field, &["baseColorFactor"]))
        .expect("base color field");
    let emissive = material
        .fields
        .iter()
        .find(|field| path_is(field, &["emissiveFactor"]))
        .expect("emissive field");
    assert_eq!(base_color.kind, ComponentFieldKind::Color);
    assert_eq!(base_color.color.maximum, Some(1.0));
    assert_eq!(emissive.kind, ComponentFieldKind::Color);
    assert_eq!(emissive.color.minimum, 0.0);
    assert_eq!(emissive.color.maximum, None);

    let player = scene
        .component_descriptions(Some("animationPlayer"))
        .into_iter()
        .next()
        .expect("animationPlayer description");
    assert!(
        player
            .defaults
            .as_ref()
            .and_then(|defaults| defaults.value_at(&["clipName".to_string()]))
            .is_none()
    );
    let clip = player
        .fields
        .iter()
        .find(|field| field.id == "anim-clip")
        .expect("clip field");
    assert_eq!(clip.kind, ComponentFieldKind::String);
    assert!(clip.is_nullable);
    let time = player
        .fields
        .iter()
        .find(|field| path_is(field, &["time"]))
        .expect("time field");
    assert!(time.is_read_only);
    assert!(time.is_advanced);

    let encoded = serde_json::to_vec(&[&mesh, &material, &player]).expect("encode");
    let decoded: Vec<ComponentDescription> = serde_json::from_slice(&encoded).expect("decode");
    assert_eq!(decoded, vec![mesh, material, player]);

    let mut visible = ComponentFieldDescriptor::new(vec!["visible".to_string()]);
    visible.kind = ComponentFieldKind::Boolean;
    let inferred = ComponentInspection {
        inferred_fields_are_advanced: true,
        fields: vec![visible],
        ..ComponentInspection::default()
    }
    .resolved_fields(&object([
        ("visible", ComponentValue::Bool(true)),
        ("details", object([("gain", ComponentValue::Number(1.0))])),
    ]));
    assert_eq!(
        inferred
            .iter()
            .find(|field| field.id == "visible")
            .map(|field| field.is_advanced),
        Some(false)
    );
    assert_eq!(
        inferred
            .iter()
            .find(|field| field.id == "details.gain")
            .map(|field| field.is_advanced),
        Some(true)
    );
}
