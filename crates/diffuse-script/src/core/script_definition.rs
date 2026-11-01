//! Script authoring metadata, parameter defaults and Swift Codable enum shapes.

pub use api::ScriptParameterIssue;
pub use api::json::{JsonObject as ScriptParameters, JsonValue};
use diffuse_math::simd::simd_compat::Float3;
use diffuse_script_api::authoring as api;
use serde::{Deserialize, Deserializer, Serialize, Serializer};

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct ScriptDefinition {
    pub properties: Vec<ScriptProperty>,
}

impl ScriptDefinition {
    pub fn new(properties: Vec<ScriptProperty>) -> Self {
        Self { properties }
    }

    pub fn default_parameters(&self, overrides_json: &str) -> ScriptParameters {
        self.to_api().default_parameters(overrides_json)
    }
    pub fn resolved_parameters(
        &self,
        defaults_json: &str,
        overrides_json: &str,
    ) -> ScriptParameters {
        self.to_api()
            .resolved_parameters(defaults_json, overrides_json)
    }
    pub fn default_parameters_json(&self, overrides_json: &str) -> String {
        self.to_api().default_parameters_json(overrides_json)
    }
    pub fn parameter_issues(&self, json: &str) -> Vec<ScriptParameterIssue> {
        self.to_api().parameter_issues(json)
    }
    pub fn decode_parameters(json: &str) -> ScriptParameters {
        api::ScriptDefinition::decode_parameters(json)
    }
    pub fn encode_parameters(values: ScriptParameters) -> Option<String> {
        api::ScriptDefinition::encode_parameters(values)
    }

    pub fn to_api(&self) -> api::ScriptDefinition {
        api::ScriptDefinition::new(self.properties.iter().map(ScriptProperty::to_api).collect())
    }
    pub fn from_api(definition: &api::ScriptDefinition) -> Self {
        Self::new(
            definition
                .properties
                .iter()
                .map(ScriptProperty::from_api)
                .collect(),
        )
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum ScriptPropertyValue {
    String(String),
    Number(f64),
    Integer(i64),
    Boolean(bool),
    Vector3(Float3),
    Entity(u64),
}

impl ScriptPropertyValue {
    pub fn json_value(&self) -> JsonValue {
        self.to_api().json_value()
    }
    pub fn decoding(&self, value: &JsonValue) -> Option<Self> {
        self.to_api()
            .decoding(value)
            .map(|value| Self::from_api(&value))
    }

    pub fn to_api(&self) -> api::ScriptPropertyValue {
        match self {
            Self::String(value) => api::ScriptPropertyValue::String(value.clone()),
            Self::Number(value) => api::ScriptPropertyValue::Number(*value),
            Self::Integer(value) => api::ScriptPropertyValue::Integer(*value),
            Self::Boolean(value) => api::ScriptPropertyValue::Boolean(*value),
            Self::Vector3(value) => api::ScriptPropertyValue::Vector3([value.x, value.y, value.z]),
            Self::Entity(value) => api::ScriptPropertyValue::Entity(*value),
        }
    }

    pub fn from_api(value: &api::ScriptPropertyValue) -> Self {
        match value {
            api::ScriptPropertyValue::String(value) => Self::String(value.clone()),
            api::ScriptPropertyValue::Number(value) => Self::Number(*value),
            api::ScriptPropertyValue::Integer(value) => Self::Integer(*value),
            api::ScriptPropertyValue::Boolean(value) => Self::Boolean(*value),
            api::ScriptPropertyValue::Vector3(value) => {
                Self::Vector3(Float3::new(value[0], value[1], value[2]))
            }
            api::ScriptPropertyValue::Entity(value) => Self::Entity(*value),
        }
    }
}

impl Serialize for ScriptPropertyValue {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let text = self.to_api().codable_value().try_to_json().ok_or_else(|| {
            serde::ser::Error::custom("Swift JSONEncoder rejects non-finite property values")
        })?;
        serde_json::value::RawValue::from_string(text)
            .map_err(serde::ser::Error::custom)?
            .serialize(serializer)
    }
}

impl<'de> Deserialize<'de> for ScriptPropertyValue {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let value = serde_json::Value::deserialize(deserializer)?;
        let object = value
            .as_object()
            .ok_or_else(|| serde::de::Error::custom("expected a ScriptPropertyValue object"))?;
        let cases: Vec<_> = [
            "string", "number", "integer", "boolean", "vector3", "entity",
        ]
        .into_iter()
        .filter(|name| object.contains_key(*name))
        .collect();
        if cases.len() != 1 {
            return Err(serde::de::Error::custom(
                "expected exactly one ScriptPropertyValue case",
            ));
        }
        let payload = object[cases[0]]
            .get("_0")
            .ok_or_else(|| serde::de::Error::custom("missing associated property value _0"))?
            .clone();
        match cases[0] {
            "string" => serde_json::from_value(payload)
                .map(Self::String)
                .map_err(serde::de::Error::custom),
            "number" => serde_json::from_value(payload)
                .map(Self::Number)
                .map_err(serde::de::Error::custom),
            "integer" => serde_json::from_value(payload)
                .map(Self::Integer)
                .map_err(serde::de::Error::custom),
            "boolean" => serde_json::from_value(payload)
                .map(Self::Boolean)
                .map_err(serde::de::Error::custom),
            "entity" => serde_json::from_value(payload)
                .map(Self::Entity)
                .map_err(serde::de::Error::custom),
            "vector3" => {
                let lanes: [f32; 3] =
                    serde_json::from_value(payload).map_err(serde::de::Error::custom)?;
                if !lanes.iter().all(|lane| lane.is_finite()) {
                    return Err(serde::de::Error::custom(
                        "vector3 requires finite Float lanes",
                    ));
                }
                Ok(Self::Vector3(Float3::new(lanes[0], lanes[1], lanes[2])))
            }
            _ => unreachable!("only known case names are collected"),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
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

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScriptProperty {
    pub key: String,
    pub label: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub group: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub help: Option<String>,
    pub default_value: ScriptPropertyValue,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        serialize_with = "diffuse_kernel::codable::serialize_optional_double"
    )]
    pub minimum: Option<f64>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        serialize_with = "diffuse_kernel::codable::serialize_optional_double"
    )]
    pub maximum: Option<f64>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        serialize_with = "diffuse_kernel::codable::serialize_optional_double"
    )]
    pub step: Option<f64>,
    pub options: Vec<ScriptPropertyOption>,
}

impl ScriptProperty {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
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

    pub fn with_default(key: impl Into<String>, default_value: ScriptPropertyValue) -> Self {
        Self::new(
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
    pub fn accepts(&self, value: &JsonValue) -> bool {
        self.to_api().accepts_json(value)
    }

    pub fn to_api(&self) -> api::ScriptProperty {
        api::ScriptProperty::with_details(
            &self.key,
            Some(self.label.clone()),
            self.group.clone(),
            self.help.clone(),
            self.default_value.to_api(),
            self.minimum,
            self.maximum,
            self.step,
            self.options
                .iter()
                .map(|option| {
                    api::ScriptPropertyOption::new(&option.value, Some(option.label.clone()))
                })
                .collect(),
        )
    }

    pub fn from_api(property: &api::ScriptProperty) -> Self {
        Self::new(
            &property.key,
            Some(property.label.clone()),
            property.group.clone(),
            property.help.clone(),
            ScriptPropertyValue::from_api(&property.default_value),
            property.minimum,
            property.maximum,
            property.step,
            property
                .options
                .iter()
                .map(|option| ScriptPropertyOption::new(&option.value, Some(option.label.clone())))
                .collect(),
        )
    }
}
