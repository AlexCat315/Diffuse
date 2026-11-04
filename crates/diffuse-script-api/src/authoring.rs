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
pub trait ScriptBehavior: Default + Send + 'static {
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

/// Macro support: concrete behavior types select optional authoring using autoref resolution.
#[doc(hidden)]
pub struct ScriptDefinitionProbe<T>(core::marker::PhantomData<T>);
impl<T> ScriptDefinitionProbe<T> {
    pub fn new() -> Self {
        Self(core::marker::PhantomData)
    }
}
impl<T> Default for ScriptDefinitionProbe<T> {
    fn default() -> Self {
        Self::new()
    }
}
#[doc(hidden)]
pub trait ResolveScriptDefinition {
    fn resolve_script_definition(self) -> &'static ScriptDefinition;
}
impl<T> ResolveScriptDefinition for &ScriptDefinitionProbe<T> {
    fn resolve_script_definition(self) -> &'static ScriptDefinition {
        static EMPTY: std::sync::OnceLock<ScriptDefinition> = std::sync::OnceLock::new();
        EMPTY.get_or_init(ScriptDefinition::default)
    }
}
impl<T: ScriptAuthoring> ResolveScriptDefinition for &&ScriptDefinitionProbe<T> {
    fn resolve_script_definition(self) -> &'static ScriptDefinition {
        T::definition()
    }
}

/// The authoring contract of a behavior, independent of live instances.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ScriptDefinition {
    pub properties: Vec<ScriptProperty>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ScriptParameterIssue {
    InvalidDocument,
    Unknown(String),
    Invalid(String),
}

impl ScriptDefinition {
    pub fn new(properties: Vec<ScriptProperty>) -> Self {
        Self { properties }
    }

    pub fn default_parameters(&self, overrides_json: &str) -> json::JsonObject {
        let mut values = json::JsonObject::new();
        for property in &self.properties {
            values.insert(property.key.clone(), property.default_value.json_value());
        }
        values.extend(Self::decode_parameters(overrides_json));
        values
    }

    pub fn resolved_parameters(
        &self,
        defaults_json: &str,
        overrides_json: &str,
    ) -> json::JsonObject {
        let mut values = self.default_parameters(defaults_json);
        for property in &self.properties {
            if let Some(value) = values.get(&property.key)
                && !property.accepts_json(value)
            {
                values.insert(property.key.clone(), property.default_value.json_value());
            }
        }
        for (key, value) in Self::decode_parameters(overrides_json) {
            if let Some(property) = self.properties.iter().find(|property| property.key == key)
                && !property.accepts_json(&value)
            {
                continue;
            }
            values.insert(key, value);
        }
        values
    }

    pub fn default_parameters_json(&self, overrides_json: &str) -> String {
        Self::encode_parameters(self.default_parameters(overrides_json))
            .unwrap_or_else(|| "{}".to_string())
    }

    pub fn parameter_issues(&self, text: &str) -> Vec<ScriptParameterIssue> {
        let Some(json::JsonValue::Object(values)) = json::parse(text) else {
            return vec![ScriptParameterIssue::InvalidDocument];
        };
        if self.properties.is_empty() {
            return Vec::new();
        }
        let mut issues: Vec<_> = values
            .keys()
            .filter(|key| !self.properties.iter().any(|property| &property.key == *key))
            .cloned()
            .map(ScriptParameterIssue::Unknown)
            .collect();
        for property in &self.properties {
            if let Some(value) = values.get(&property.key)
                && !property.accepts_json(value)
            {
                issues.push(ScriptParameterIssue::Invalid(property.key.clone()));
            }
        }
        issues
    }

    pub fn decode_parameters(text: &str) -> json::JsonObject {
        json::parse_object(text)
    }
    pub fn encode_parameters(values: json::JsonObject) -> Option<String> {
        json::JsonValue::Object(values).try_to_json()
    }

    pub fn codable_value(&self) -> json::JsonValue {
        json::JsonValue::Object(json::JsonObject::from([(
            "properties".to_string(),
            json::JsonValue::Array(
                self.properties
                    .iter()
                    .map(ScriptProperty::codable_value)
                    .collect(),
            ),
        )]))
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct ScriptProperty {
    pub key: String,
    pub label: String,
    pub group: Option<String>,
    pub help: Option<String>,
    pub default_value: ScriptPropertyValue,
    pub minimum: Option<f64>,
    pub maximum: Option<f64>,
    pub step: Option<f64>,
    pub options: Vec<ScriptPropertyOption>,
}

impl ScriptProperty {
    pub fn new(key: impl Into<String>, default_value: ScriptPropertyValue) -> Self {
        Self::with_details(
            key,
            None,
            None,
            None,
            default_value,
            None,
            None,
            None,
            Vec::new(),
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub fn with_details(
        key: impl Into<String>,
        label: Option<String>,
        group: Option<String>,
        help: Option<String>,
        default_value: ScriptPropertyValue,
        minimum: Option<f64>,
        maximum: Option<f64>,
        step: Option<f64>,
        options: Vec<ScriptPropertyOption>,
    ) -> Self {
        let key = key.into();
        Self {
            label: label.unwrap_or_else(|| key.clone()),
            key,
            group,
            help,
            default_value,
            minimum,
            maximum,
            step,
            options,
        }
    }

    pub fn with_options(mut self, options: Vec<ScriptPropertyOption>) -> Self {
        self.options = options;
        self
    }
    pub fn accepts(&self, value: &ScriptPropertyValue) -> bool {
        self.accepts_json(&value.json_value())
    }

    pub fn accepts_json(&self, value: &json::JsonValue) -> bool {
        let Some(decoded) = self.default_value.decoding(value) else {
            return false;
        };
        match decoded {
            ScriptPropertyValue::String(value) => {
                self.options.is_empty() || self.options.iter().any(|option| option.value == value)
            }
            ScriptPropertyValue::Number(value) => {
                self.minimum.is_none_or(|minimum| value >= minimum)
                    && self.maximum.is_none_or(|maximum| value <= maximum)
            }
            ScriptPropertyValue::Integer(value) => {
                self.minimum.is_none_or(|minimum| value as f64 >= minimum)
                    && self.maximum.is_none_or(|maximum| value as f64 <= maximum)
            }
            _ => true,
        }
    }

    fn codable_value(&self) -> json::JsonValue {
        use json::JsonValue as Value;
        let mut fields = json::JsonObject::from([
            ("key".to_string(), Value::String(self.key.clone())),
            ("label".to_string(), Value::String(self.label.clone())),
            (
                "defaultValue".to_string(),
                self.default_value.codable_value(),
            ),
            (
                "options".to_string(),
                Value::Array(
                    self.options
                        .iter()
                        .map(|option| {
                            Value::Object(json::JsonObject::from([
                                ("value".to_string(), Value::String(option.value.clone())),
                                ("label".to_string(), Value::String(option.label.clone())),
                            ]))
                        })
                        .collect(),
                ),
            ),
        ]);
        for (key, value) in [("group", &self.group), ("help", &self.help)] {
            if let Some(value) = value {
                fields.insert(key.to_string(), Value::String(value.clone()));
            }
        }
        for (key, value) in [
            ("minimum", self.minimum),
            ("maximum", self.maximum),
            ("step", self.step),
        ] {
            if let Some(value) = value {
                fields.insert(key.to_string(), Value::Number(value));
            }
        }
        Value::Object(fields)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScriptPropertyOption {
    pub value: String,
    pub label: String,
}

impl ScriptPropertyOption {
    pub fn new(value: impl Into<String>, label: Option<String>) -> Self {
        let value = value.into();
        Self {
            label: label.unwrap_or_else(|| value.clone()),
            value,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum ScriptPropertyValue {
    String(String),
    Number(f64),
    Integer(i64),
    Boolean(bool),
    Vector3([f32; 3]),
    Entity(u64),
}

impl ScriptPropertyValue {
    pub fn json_value(&self) -> json::JsonValue {
        match self {
            Self::String(value) => json::JsonValue::String(value.clone()),
            Self::Number(value) => json::JsonValue::Number(*value),
            Self::Integer(value) => json::JsonValue::Integer(*value),
            Self::Boolean(value) => json::JsonValue::Bool(*value),
            Self::Vector3(value) => json::JsonValue::Array(
                value
                    .iter()
                    .map(|&value| json::JsonValue::Float(value))
                    .collect(),
            ),
            Self::Entity(value) => json::JsonValue::Unsigned(*value),
        }
    }

    pub fn decoding(&self, value: &json::JsonValue) -> Option<Self> {
        match self {
            Self::String(_) => value.as_str().map(|value| Self::String(value.to_string())),
            Self::Boolean(_) => {
                if let json::JsonValue::Bool(value) = value {
                    Some(Self::Boolean(*value))
                } else {
                    None
                }
            }
            Self::Number(_) => value
                .as_f64()
                .filter(|number| number.is_finite())
                .map(Self::Number),
            Self::Integer(_) => {
                let number = value.as_f64()?;
                if number.is_finite()
                    && number >= i64::MIN as f64
                    && number < 9_223_372_036_854_775_808.0
                    && number.fract() == 0.0
                {
                    Some(Self::Integer(number as i64))
                } else {
                    None
                }
            }
            Self::Entity(_) => value.as_u64().map(Self::Entity),
            Self::Vector3(_) => {
                let values = if let Some(values) = value.as_array() {
                    if values.len() != 3 {
                        return None;
                    }
                    [values.first()?, values.get(1)?, values.get(2)?]
                } else {
                    let values = value.as_object()?;
                    [values.get("x")?, values.get("y")?, values.get("z")?]
                };
                let mut result = [0.0; 3];
                for index in 0..3 {
                    result[index] = values[index].as_f64()? as f32;
                    if !result[index].is_finite() {
                        return None;
                    }
                }
                Some(Self::Vector3(result))
            }
        }
    }

    pub fn codable_value(&self) -> json::JsonValue {
        let name = match self {
            Self::String(_) => "string",
            Self::Number(_) => "number",
            Self::Integer(_) => "integer",
            Self::Boolean(_) => "boolean",
            Self::Vector3(_) => "vector3",
            Self::Entity(_) => "entity",
        };
        json::JsonValue::Object(json::JsonObject::from([(
            name.to_string(),
            json::JsonValue::Object(json::JsonObject::from([(
                "_0".to_string(),
                self.json_value(),
            )])),
        )]))
    }

    pub fn same_kind_as(&self, other: &Self) -> bool {
        std::mem::discriminant(self) == std::mem::discriminant(other)
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct ScriptParameters {
    pub values: json::JsonObject,
}

impl ScriptParameters {
    pub fn resolve(
        definition: &ScriptDefinition,
        defaults_json: &str,
        overrides_json: &str,
    ) -> Self {
        Self {
            values: definition.resolved_parameters(defaults_json, overrides_json),
        }
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
        transform.columns[3][0],
        transform.columns[3][1],
        transform.columns[3][2],
    ])
}

/// What the host reports for `ScriptContext.reportState`.
#[derive(Clone, Debug, PartialEq)]
pub struct ReportedState(pub json::JsonObject);
