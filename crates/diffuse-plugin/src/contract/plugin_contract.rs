//! Input metadata emitted by the TypeScript compiler, independent of executable
//! exports.
//!
//! Ported from `Engine/Sources/PluginRuntime/Contract/PluginContract.swift`.

use diffuse_capability::capsule_schema::JsonSchema;
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginInputField {
    pub name: String,
    #[serde(rename = "type")]
    pub kind: PluginInputType,
}

impl PluginInputField {
    pub fn new(name: impl Into<String>, kind: PluginInputType) -> Self {
        PluginInputField {
            name: name.into(),
            kind,
        }
    }
}

/// Input metadata emitted by the TypeScript compiler, independent of executable
/// exports.
///
/// Swift's synthesized `Codable` wrote associated values as
/// `{"caseName": {"_0": …}}`; the neighbouring unit cases wrote as the case name
/// string. The hand-written implementations below reproduce both shapes.
#[derive(Clone, Debug, PartialEq)]
pub enum PluginInputType {
    Bool,
    String,
    S32,
    F64,
    List(Box<PluginInputType>),
    Option(Box<PluginInputType>),
    Record(Vec<PluginInputField>),
    Enumeration(Vec<String>),
    OneOf(Vec<PluginInputType>),
}

impl PluginInputType {
    /// Swift's synthesized tag for each case, which is the JSON key.
    pub const fn codable_key(&self) -> &'static str {
        match self {
            PluginInputType::Bool => "bool",
            PluginInputType::String => "string",
            PluginInputType::S32 => "s32",
            PluginInputType::F64 => "f64",
            PluginInputType::List(_) => "list",
            PluginInputType::Option(_) => "option",
            PluginInputType::Record(_) => "record",
            PluginInputType::Enumeration(_) => "enumeration",
            PluginInputType::OneOf(_) => "oneOf",
        }
    }
}

impl Serialize for PluginInputType {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        use serde::ser::SerializeMap;
        match self {
            // Swift's synthesized encoder writes a unit case as
            // `{"caseName": {}}`.
            PluginInputType::Bool
            | PluginInputType::String
            | PluginInputType::S32
            | PluginInputType::F64 => {
                let mut map = serializer.serialize_map(Some(1))?;
                map.serialize_entry(self.codable_key(), &EmptyObject)?;
                map.end()
            }
            PluginInputType::List(inner) | PluginInputType::Option(inner) => {
                let mut map = serializer.serialize_map(Some(1))?;
                map.serialize_entry(self.codable_key(), &Payload { _0: inner })?;
                map.end()
            }
            PluginInputType::Record(fields) => {
                let mut map = serializer.serialize_map(Some(1))?;
                map.serialize_entry(self.codable_key(), &Payload { _0: fields })?;
                map.end()
            }
            PluginInputType::Enumeration(names) => {
                let mut map = serializer.serialize_map(Some(1))?;
                map.serialize_entry(self.codable_key(), &Payload { _0: names })?;
                map.end()
            }
            PluginInputType::OneOf(types) => {
                let mut map = serializer.serialize_map(Some(1))?;
                map.serialize_entry(self.codable_key(), &Payload { _0: types })?;
                map.end()
            }
        }
    }
}

struct EmptyObject;

impl Serialize for EmptyObject {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        use serde::ser::SerializeMap;
        serializer.serialize_map(Some(0))?.end()
    }
}

struct Payload<'a, T> {
    _0: &'a T,
}

impl<T: Serialize> Serialize for Payload<'_, T> {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        use serde::ser::SerializeMap;
        let mut map = serializer.serialize_map(Some(1))?;
        map.serialize_entry("_0", self._0)?;
        map.end()
    }
}

impl<'de> Deserialize<'de> for PluginInputType {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        use serde::de::Error as _;
        let value = serde_json::Value::deserialize(deserializer)?;
        let serde_json::Value::Object(mut fields) = value else {
            return Err(D::Error::custom(
                "plugin input type must be a single-key object",
            ));
        };
        if fields.len() != 1 {
            return Err(D::Error::custom(
                "plugin input type must be a single-key object",
            ));
        }
        let key = fields
            .keys()
            .next()
            .cloned()
            .ok_or_else(|| D::Error::custom("plugin input type is empty"))?;
        let payload = fields.remove(&key).unwrap_or(serde_json::Value::Null);
        let inner = payload
            .get("_0")
            .cloned()
            .unwrap_or(serde_json::Value::Null);
        let decoded = match key.as_str() {
            "bool" => PluginInputType::Bool,
            "string" => PluginInputType::String,
            "s32" => PluginInputType::S32,
            "f64" => PluginInputType::F64,
            "list" => PluginInputType::List(Box::new(
                serde_json::from_value(inner).map_err(D::Error::custom)?,
            )),
            "option" => PluginInputType::Option(Box::new(
                serde_json::from_value(inner).map_err(D::Error::custom)?,
            )),
            "record" => {
                PluginInputType::Record(serde_json::from_value(inner).map_err(D::Error::custom)?)
            }
            "enumeration" => PluginInputType::Enumeration(
                serde_json::from_value(inner).map_err(D::Error::custom)?,
            ),
            "oneOf" => {
                PluginInputType::OneOf(serde_json::from_value(inner).map_err(D::Error::custom)?)
            }
            other => {
                return Err(D::Error::custom(format!(
                    "unknown plugin input type '{other}'"
                )));
            }
        };
        Ok(decoded)
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginEntryContract {
    pub name: String,
    pub title: String,
    pub description: String,
    pub input_schema: JsonSchema,
    pub input_type: PluginInputType,
}

impl PluginEntryContract {
    pub fn new(
        name: impl Into<String>,
        title: impl Into<String>,
        description: impl Into<String>,
        input_schema: JsonSchema,
        input_type: PluginInputType,
    ) -> Self {
        PluginEntryContract {
            name: name.into(),
            title: title.into(),
            description: description.into(),
            input_schema,
            input_type,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginContract {
    pub imports: Vec<String>,
    pub capability_inputs: Vec<PluginEntryContract>,
}

impl PluginContract {
    /// Swift sorted `imports` and `capabilityInputs` by name on construction.
    pub fn new(imports: Vec<String>, capability_inputs: Vec<PluginEntryContract>) -> Self {
        let mut imports = imports;
        imports.sort();
        let mut capability_inputs = capability_inputs;
        capability_inputs.sort_by(|left, right| left.name.cmp(&right.name));
        PluginContract {
            imports,
            capability_inputs,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum PluginContractError {
    #[error("capabilities.json exceeds 1 MiB")]
    SourceTooLarge,
    #[error("capabilities.json types exceed maximum depth")]
    TypeTooDeep,
    #[error("Invalid entry point: {0}")]
    InvalidCapabilityName(String),
    #[error("Invalid input field: {0}")]
    InvalidFieldName(String),
    #[error("Invalid plugin input type: {0}")]
    UnsupportedType(String),
}
