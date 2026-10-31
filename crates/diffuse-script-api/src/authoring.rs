//! Authoring vocabulary: `ScriptBehavior`, `ScriptDefinition` and the property
//! builders.
//!
//! Mirrors `ScriptRuntime/Core/ScriptBehavior.swift` and `ScriptDefinition.swift`.
//! Swift's `ScriptBehavior` had default no-op implementations via a protocol
//! extension; Rust gets them from default trait methods.

use crate::abi::Transform3;

pub mod json;

/// The lifecycle a script implements. The default methods are empty, matching
/// Swift's `extension ScriptBehavior { mutating func onStart(_:) {} ... }`.
pub trait ScriptBehavior: Default + 'static {
    fn on_start(&mut self, context: &crate::context::ScriptContext) {
        let _ = context;
    }

    fn on_pre_physics(&mut self, context: &crate::context::ScriptContext) {
        let _ = context;
    }

    fn on_update(&mut self, context: &crate::context::ScriptContext) {
        let _ = context;
    }

    fn on_destroy(&mut self, context: &crate::context::ScriptContext) {
        let _ = context;
    }
}

/// Optional property contract, independent of the executable lifecycle.
pub trait ScriptAuthoring {
    fn definition() -> &'static ScriptDefinition;
}

/// The authoring contract of a behavior. Contains no live script instance.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ScriptDefinition {
    pub properties: Vec<ScriptProperty>,
}

impl ScriptDefinition {
    #[inline]
    pub fn new(properties: Vec<ScriptProperty>) -> Self {
        ScriptDefinition { properties }
    }
}

/// An authored property: its key, default value and accepted values.
#[derive(Clone, Debug, PartialEq)]
pub struct ScriptProperty {
    pub key: String,
    pub label: String,
    pub default_value: ScriptPropertyValue,
    pub options: Vec<ScriptPropertyOption>,
}

impl ScriptProperty {
    #[inline]
    pub fn new(key: impl Into<String>, default_value: ScriptPropertyValue) -> Self {
        let key = key.into();
        ScriptProperty {
            label: key.clone(),
            key,
            default_value,
            options: Vec::new(),
        }
    }

    /// A property restricted to `options`.
    pub fn with_options(mut self, options: Vec<ScriptPropertyOption>) -> Self {
        self.options = options;
        self
    }

    /// True when `value` is accepted by this property. Swift's `accepts(_:)`.
    pub fn accepts(&self, value: &ScriptPropertyValue) -> bool {
        if self.options.is_empty() {
            return value.same_kind_as(&self.default_value);
        }
        self.options.iter().any(|option| &option.value == value)
    }
}

/// One selectable value for a property, as Swift's `ScriptPropertyOption`.
#[derive(Clone, Debug, PartialEq)]
pub struct ScriptPropertyOption {
    pub label: String,
    pub value: ScriptPropertyValue,
}

impl ScriptPropertyOption {
    #[inline]
    pub fn new(label: impl Into<String>, value: ScriptPropertyValue) -> Self {
        ScriptPropertyOption {
            label: label.into(),
            value,
        }
    }
}

/// `ScriptPropertyValue`, matching Swift's cases and JSON shapes.
#[derive(Clone, Debug, PartialEq)]
pub enum ScriptPropertyValue {
    String(String),
    Number(f64),
    Integer(i64),
    Boolean(bool),
    /// `vector3(_:)` — a `SIMD3<Float>` encoded as `[x, y, z]`.
    Vector3([f32; 3]),
    /// `entity(_:)` — an `UInt64` entity id.
    Entity(u64),
}

impl ScriptPropertyValue {
    /// Swift's `jsonValue`.
    pub fn json_value(&self) -> json::JsonValue {
        match self {
            ScriptPropertyValue::String(value) => json::JsonValue::String(value.clone()),
            ScriptPropertyValue::Number(value) => json::JsonValue::Number(*value),
            ScriptPropertyValue::Integer(value) => json::JsonValue::Integer(*value),
            ScriptPropertyValue::Boolean(value) => json::JsonValue::Bool(*value),
            ScriptPropertyValue::Vector3(value) => json::JsonValue::Array(vec![
                json::JsonValue::Number(value[0] as f64),
                json::JsonValue::Number(value[1] as f64),
                json::JsonValue::Number(value[2] as f64),
            ]),
            ScriptPropertyValue::Entity(value) => json::JsonValue::Integer(*value as i64),
        }
    }

    /// Swift's `accepts` used a kind check when a property had no options.
    pub fn same_kind_as(&self, other: &ScriptPropertyValue) -> bool {
        matches!(
            (self, other),
            (
                ScriptPropertyValue::String(_),
                ScriptPropertyValue::String(_)
            ) | (
                ScriptPropertyValue::Number(_),
                ScriptPropertyValue::Number(_)
            ) | (
                ScriptPropertyValue::Integer(_),
                ScriptPropertyValue::Integer(_)
            ) | (
                ScriptPropertyValue::Boolean(_),
                ScriptPropertyValue::Boolean(_)
            ) | (
                ScriptPropertyValue::Vector3(_),
                ScriptPropertyValue::Vector3(_)
            ) | (
                ScriptPropertyValue::Entity(_),
                ScriptPropertyValue::Entity(_)
            )
        )
    }
}

/// A resolved parameter set handed to a script instance.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ScriptParameters {
    pub values: json::JsonObject,
}

impl ScriptParameters {
    /// Resolves the definition's defaults, then the binding's overrides — the
    /// order Swift's `resolvedParameters(defaultsJSON:overridesJSON:)` used.
    pub fn resolve(
        definition: &ScriptDefinition,
        defaults_json: &str,
        overrides_json: &str,
    ) -> ScriptParameters {
        let mut values = json::JsonObject::new();
        for property in &definition.properties {
            values.insert(property.key.clone(), property.default_value.json_value());
        }
        for (key, value) in json::parse_object(defaults_json) {
            values.insert(key, value);
        }
        for property in &definition.properties {
            if let Some(value) = values.get(&property.key)
                && !property.accepts_json(value)
            {
                values.insert(property.key.clone(), property.default_value.json_value());
            }
        }
        for (key, value) in json::parse_object(overrides_json) {
            if let Some(property) = definition.properties.iter().find(|entry| entry.key == key)
                && !property.accepts_json(&value)
            {
                continue;
            }
            values.insert(key, value);
        }
        ScriptParameters { values }
    }
}

impl ScriptProperty {
    /// Swift's `accepts(_:)` over a decoded JSON value.
    pub fn accepts_json(&self, value: &json::JsonValue) -> bool {
        if self.options.is_empty() {
            return self.default_value.json_value().same_json_kind(value);
        }
        self.options
            .iter()
            .any(|option| option.value.json_value().json_equals(value))
    }
}

/// A builder for `ScriptDefinition`, matching `ScriptAuthoring`'s ergonomics.
#[derive(Default)]
pub struct ScriptDefinitionBuilder {
    properties: Vec<ScriptProperty>,
}

impl ScriptDefinitionBuilder {
    #[inline]
    pub fn new() -> Self {
        ScriptDefinitionBuilder {
            properties: Vec::new(),
        }
    }

    pub fn property(mut self, key: impl Into<String>, default_value: ScriptPropertyValue) -> Self {
        self.properties
            .push(ScriptProperty::new(key, default_value));
        self
    }

    pub fn property_with(mut self, property: ScriptProperty) -> Self {
        self.properties.push(property);
        self
    }

    pub fn build(self) -> ScriptDefinition {
        ScriptDefinition {
            properties: self.properties,
        }
    }
}

/// Convenience conversion from the engine's `Transform3` to a `Vector3` property
/// value, so scripts can carry authored transforms through the property system.
#[inline]
pub fn vector3_from_transform(transform: &Transform3) -> ScriptPropertyValue {
    ScriptPropertyValue::Vector3([
        transform.translation[0],
        transform.translation[1],
        transform.translation[2],
    ])
}

/// What the host reports for `ScriptContext.reportState`.
#[derive(Clone, Debug, PartialEq)]
pub struct ReportedState(pub json::JsonObject);
