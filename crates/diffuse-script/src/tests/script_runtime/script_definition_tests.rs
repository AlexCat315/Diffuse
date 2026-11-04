//! Ported from `Engine/Tests/ScriptRuntimeTests/ScriptDefinitionTests.swift`.
//!
//! Swift's `ScriptProperty("speed", defaultValue: .number(2), minimum: 0, …)`
//! relies on a memberwise initializer with defaulted `label`/`group`/`help`/
//! `step`/`options`; Rust has one `ScriptProperty::new` taking all nine, so the
//! helpers below name only the arguments each test actually sets.
//!
//! Swift's `definition.resolvedParameters(defaultsJSON:overridesJSON:)` is
//! `ScriptDefinition::resolved_parameters(&defaults, &overrides)`; the returned
//! `ScriptParameters` is a JSON object map, so the `as? Double`/`as? Int`/`as?
//! Bool`/`as? String` casts become pattern matches on `JsonValue`.

use std::sync::{Arc, Mutex};

use diffuse_math::simd::simd_compat::Float3;
use diffuse_scene::components::core::registry::ComponentRegistry;
use diffuse_scene::scene_runtime::SceneRuntime;

use crate::core::script_behavior::{ScriptAuthoring, ScriptBehavior};
use crate::core::script_component::{ScriptBinding, ScriptComponent};
use crate::core::script_context::ScriptContext;
use crate::core::script_definition::{
    JsonValue, ScriptDefinition, ScriptProperty, ScriptPropertyOption, ScriptPropertyValue,
};
use crate::core::script_lifecycle::Script;
use crate::core::script_runtime::ScriptRuntime;

/// Swift's `SceneRuntime()`; the Rust runtime takes its component registry.
fn scene() -> SceneRuntime {
    SceneRuntime::new(ComponentRegistry::built_in())
}

fn vector3(x: f32, y: f32, z: f32) -> ScriptPropertyValue {
    ScriptPropertyValue::Vector3(Float3::new(x, y, z))
}

/// `abstract property` with only the arguments the suite names.
fn property(
    key: &str,
    default_value: ScriptPropertyValue,
    minimum: Option<f64>,
    maximum: Option<f64>,
    options: Vec<ScriptPropertyOption>,
) -> ScriptProperty {
    ScriptProperty::new(
        key,
        None,
        None,
        None,
        default_value,
        minimum,
        maximum,
        None,
        options,
    )
}

/// `ScriptProperty("speed", defaultValue: .number(2), minimum: 0, maximum: 10)`.
fn number_property(key: &str, default_value: f64) -> ScriptProperty {
    property(
        key,
        ScriptPropertyValue::Number(default_value),
        None,
        None,
        Vec::new(),
    )
}

fn fixture() -> ScriptDefinition {
    ScriptDefinition::new(vec![
        property(
            "speed",
            ScriptPropertyValue::Number(2.0),
            Some(0.0),
            Some(10.0),
            Vec::new(),
        ),
        property(
            "lives",
            ScriptPropertyValue::Integer(3),
            Some(1.0),
            None,
            Vec::new(),
        ),
        property(
            "enabled",
            ScriptPropertyValue::Boolean(true),
            None,
            None,
            Vec::new(),
        ),
        property("axis", vector3(0.0, 1.0, 0.0), None, None, Vec::new()),
        property(
            "mode",
            ScriptPropertyValue::String("ready".into()),
            None,
            None,
            vec![
                ScriptPropertyOption::new("ready", None),
                ScriptPropertyOption::new("playing", None),
            ],
        ),
    ])
}

/// `metadata roundtrips and validates typed properties rather than JSON syntax alone`
#[test]
fn typed_validation() {
    let definition = fixture();
    let encoded = serde_json::to_string(&definition).unwrap();
    let restored: ScriptDefinition = serde_json::from_str(&encoded).unwrap();
    assert_eq!(restored, definition);

    assert!(
        definition
            .parameter_issues(
                r#"{"speed":4,"lives":5,"enabled":false,"axis":[1,2,3],"mode":"playing"}"#
            )
            .is_empty()
    );
    // Six problems: speed/enabled/lives/axis element/mode/title are all wrong.
    assert_eq!(
        definition
            .parameter_issues(
                r#"{"speed":true,"lives":2.5,"enabled":1,"axis":[1,true,3],"mode":"other","title":"ignored"}"#
            )
            .len(),
        6
    );
    assert!(!definition.parameter_issues("[]").is_empty());
    assert!(!definition.parameter_issues(r#"{"speed":20}"#).is_empty());
}

/// `definition defaults, project defaults and instance overrides have one precedence order`
#[test]
fn resolves_defaults() {
    let definition = fixture();
    let values =
        definition.resolved_parameters(r#"{"speed":4}"#, r#"{"lives":5,"mode":"playing"}"#);
    assert_eq!(values.get("speed"), Some(&JsonValue::Integer(4)));
    assert_eq!(values.get("lives"), Some(&JsonValue::Integer(5)));
    assert_eq!(values.get("enabled"), Some(&JsonValue::Bool(true)));
    assert_eq!(
        values.get("mode"),
        Some(&JsonValue::String("playing".into()))
    );

    // Invalid overrides fall back to the definition defaults, not the project ones.
    let invalid = definition.resolved_parameters(
        r#"{"speed":4}"#,
        r#"{"speed":true,"lives":0,"mode":"other"}"#,
    );
    assert_eq!(invalid.get("speed"), Some(&JsonValue::Integer(4)));
    assert_eq!(invalid.get("lives"), Some(&JsonValue::Integer(3)));
    assert_eq!(
        invalid.get("mode"),
        Some(&JsonValue::String("ready".into()))
    );
}

/// Swift's `AuthoredBehavior`; `onUpdate` translates by the `speed` parameter.
#[derive(Default)]
struct AuthoredBehavior;

impl ScriptBehavior for AuthoredBehavior {
    fn on_update(&mut self, context: &mut ScriptContext<'_, '_>) {
        let speed = context.float_parameter("speed").unwrap_or(-1.0);
        context.translate(Float3::new(speed, 0.0, 0.0));
    }
}

impl ScriptAuthoring for AuthoredBehavior {
    fn definition() -> ScriptDefinition {
        ScriptDefinition::new(vec![number_property("speed", 6.0)])
    }
}

/// `native behavior registration carries its optional authoring contract`
#[test]
fn native_behavior() {
    let scripts = ScriptRuntime::new();
    let handle = scripts.register_authoring_behavior::<AuthoredBehavior>(None, "{}");
    let binding = ScriptBinding::with_script(handle);
    assert_eq!(
        scripts
            .definition(&binding)
            .and_then(|definition| definition.properties.first().map(|p| p.key.clone())),
        Some("speed".to_string())
    );
    let mut scene = scene();
    scene.set_script_driver(Box::new(scripts));
    let entity = scene.create_entity();
    scene.set_component(ScriptComponent::new(vec![binding]), entity);
    scene.tick(0.1, 0, Vec::new());
    assert_eq!(
        scene.local_transform(entity).map(|t| t.translation().x),
        Some(6.0)
    );
}

/// `destruction retains the previous generation's defaults after reload or binding removal`
#[test]
fn destruction_defaults() {
    let scripts = ScriptRuntime::new();
    let log: Arc<Mutex<Vec<f64>>> = Arc::new(Mutex::new(Vec::new()));

    // Swift's nested `func register(defaultValue:)` returns the handle; the Rust
    // registration replaces the same name so the binding needs a reload.
    let register = |default_value: f64| {
        let log = log.clone();
        scripts.register_factory(
            Some("test.reload"),
            "{}",
            ScriptDefinition::new(vec![number_property("speed", default_value)]),
            move || {
                Script::default().on_destroy(Arc::new({
                    let log = log.clone();
                    move |context| {
                        log.lock()
                            .unwrap()
                            .push(context.double_parameter("speed").unwrap_or(-1.0));
                    }
                }))
            },
        )
    };
    let handle = register(2.0);
    let mut scene = scene();
    scene.set_script_driver(Box::new(scripts.clone()));
    let entity = scene.create_entity();
    let binding = ScriptBinding::with_script(handle);
    scene.set_component(ScriptComponent::new(vec![binding.clone()]), entity);
    scene.tick(0.1, 0, Vec::new());
    register(8.0);
    assert!(scripts.needs_reload(&binding, entity));
    scene.tick(0.1, 0, Vec::new());
    assert_eq!(*log.lock().unwrap(), vec![2.0]);
    scene.remove_component::<ScriptComponent>(entity);
    scene.tick(0.1, 0, Vec::new());
    // The removal destroys the current generation, whose default is 8.
    assert_eq!(*log.lock().unwrap(), vec![2.0, 8.0]);
}

/// `the runtime applies the same defaults and keeps each binding's overrides isolated`
#[test]
fn runtime_defaults() {
    let definition = fixture();
    let scripts = ScriptRuntime::new();
    let handle = scripts.register_factory(
        Some("test.contract"),
        r#"{"speed":4}"#,
        definition.clone(),
        || {
            Script::default().on_tick(Arc::new(|context| {
                let speed = context.float_parameter("speed").unwrap_or(-1.0);
                context.translate(Float3::new(speed, 0.0, 0.0));
            }))
        },
    );
    let mut scene = scene();
    scene.set_script_driver(Box::new(scripts.clone()));
    let first = scene.create_entity();
    let second = scene.create_entity();
    let first_binding = ScriptBinding::with_script(handle);
    let second_binding = ScriptBinding::new(
        handle,
        crate::core::script_component::ScriptBindingID::new(),
        None,
        true,
        r#"{"speed":7}"#,
    );
    scene.set_component(ScriptComponent::new(vec![first_binding.clone()]), first);
    scene.set_component(ScriptComponent::new(vec![second_binding]), second);
    assert_eq!(scripts.definition(&first_binding), Some(definition));
    assert!(!scripts.is_active(&first_binding, first));
    scene.tick(0.1, 0, Vec::new());
    assert_eq!(
        scene.local_transform(first).map(|t| t.translation().x),
        Some(4.0)
    );
    assert_eq!(
        scene.local_transform(second).map(|t| t.translation().x),
        Some(7.0)
    );
    assert!(scripts.is_active(&first_binding, first));
    scripts.stop(&mut scene);
    assert!(!scripts.is_active(&first_binding, first));
}
