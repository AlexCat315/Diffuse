//! Any JSON value a manifest carries through for another program, such as a
//! language server's options.
//!
//! Ported from `Engine/Sources/PluginRuntime/Contract/PluginJSON.swift`.

use std::collections::BTreeMap;

use serde::Deserialize;
use serde::de::{self, Deserializer, MapAccess, SeqAccess, Visitor};
use serde::ser::Serialize;
use serde_json::Value;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PluginJSON {
    Null,
    Bool(bool),
    Number(serde_json::Number),
    String(String),
    Array(Vec<PluginJSON>),
    Object(BTreeMap<String, PluginJSON>),
}

impl PluginJSON {
    pub fn string_value(&self) -> Option<&str> {
        match self {
            PluginJSON::String(value) => Some(value),
            _ => None,
        }
    }

    pub fn bool_value(&self) -> Option<bool> {
        match self {
            PluginJSON::Bool(value) => Some(*value),
            _ => None,
        }
    }

    /// The value as `JSONSerialization` objects.
    ///
    /// Swift kept an integral double below `1e15` as `Int(number)`; serde_json
    /// carries every number as a double internally, and the integral values this
    /// conversion produces are the same JSON text.
    pub fn foundation_value(&self) -> Value {
        match self {
            PluginJSON::Null => Value::Null,
            PluginJSON::Bool(value) => Value::Bool(*value),
            PluginJSON::Number(value) => Value::Number(value.clone()),
            PluginJSON::String(value) => Value::String(value.clone()),
            PluginJSON::Array(values) => {
                Value::Array(values.iter().map(PluginJSON::foundation_value).collect())
            }
            PluginJSON::Object(values) => Value::Object(
                values
                    .iter()
                    .map(|(key, value)| (key.clone(), value.foundation_value()))
                    .collect(),
            ),
        }
    }

    /// Rebuilds the value from `foundation_value`'s shape.
    pub fn from_foundation_value(value: &Value) -> PluginJSON {
        match value {
            Value::Null => PluginJSON::Null,
            Value::Bool(flag) => PluginJSON::Bool(*flag),
            Value::Number(number) => PluginJSON::Number(number.clone()),
            Value::String(text) => PluginJSON::String(text.clone()),
            Value::Array(values) => PluginJSON::Array(
                values
                    .iter()
                    .map(PluginJSON::from_foundation_value)
                    .collect(),
            ),
            Value::Object(fields) => PluginJSON::Object(
                fields
                    .iter()
                    .map(|(key, value)| (key.clone(), PluginJSON::from_foundation_value(value)))
                    .collect(),
            ),
        }
    }
}

impl Serialize for PluginJSON {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self {
            PluginJSON::Null => serializer.serialize_unit(),
            PluginJSON::Bool(value) => serializer.serialize_bool(*value),
            PluginJSON::Number(value) => value.serialize(serializer),
            PluginJSON::String(value) => serializer.serialize_str(value),
            PluginJSON::Array(values) => values.serialize(serializer),
            PluginJSON::Object(values) => values.serialize(serializer),
        }
    }
}

struct PluginJSONVisitor;

impl<'de> Visitor<'de> for PluginJSONVisitor {
    type Value = PluginJSON;

    fn expecting(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("any JSON value")
    }

    fn visit_unit<E: de::Error>(self) -> Result<PluginJSON, E> {
        Ok(PluginJSON::Null)
    }

    fn visit_none<E: de::Error>(self) -> Result<PluginJSON, E> {
        Ok(PluginJSON::Null)
    }

    fn visit_some<D: Deserializer<'de>>(self, deserializer: D) -> Result<PluginJSON, D::Error> {
        <PluginJSON as Deserialize>::deserialize(deserializer)
    }

    fn visit_bool<E: de::Error>(self, value: bool) -> Result<PluginJSON, E> {
        Ok(PluginJSON::Bool(value))
    }

    fn visit_i64<E: de::Error>(self, value: i64) -> Result<PluginJSON, E> {
        Ok(PluginJSON::Number(serde_json::Number::from(value)))
    }

    fn visit_u64<E: de::Error>(self, value: u64) -> Result<PluginJSON, E> {
        Ok(PluginJSON::Number(serde_json::Number::from(value)))
    }

    fn visit_f64<E: de::Error>(self, value: f64) -> Result<PluginJSON, E> {
        Ok(PluginJSON::Number(
            serde_json::Number::from_f64(value).unwrap_or_else(|| serde_json::Number::from(0)),
        ))
    }

    fn visit_str<E: de::Error>(self, value: &str) -> Result<PluginJSON, E> {
        Ok(PluginJSON::String(value.to_string()))
    }

    fn visit_string<E: de::Error>(self, value: String) -> Result<PluginJSON, E> {
        Ok(PluginJSON::String(value))
    }

    fn visit_seq<A: SeqAccess<'de>>(self, mut sequence: A) -> Result<PluginJSON, A::Error> {
        let mut values = Vec::new();
        while let Some(value) = sequence.next_element::<PluginJSON>()? {
            values.push(value);
        }
        Ok(PluginJSON::Array(values))
    }

    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<PluginJSON, A::Error> {
        let mut values = BTreeMap::new();
        while let Some((key, value)) = map.next_entry::<String, PluginJSON>()? {
            values.insert(key, value);
        }
        Ok(PluginJSON::Object(values))
    }
}

impl<'de> Deserialize<'de> for PluginJSON {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<PluginJSON, D::Error> {
        // Swift tried nil, Bool, Double, String, array and finally object against
        // one single-value container; `deserialize_any` keeps that order because
        // the visitor answers each primitive directly.
        deserializer.deserialize_any(PluginJSONVisitor)
    }
}
