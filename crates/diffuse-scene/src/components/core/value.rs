//! The component document value — the persisted JSON shape shared by scene
//! files, prefabs, game saves and editor transactions (MIGRATION.md §5.4).
//!
//! `ComponentValue` reproduces Swift's `ComponentValue` exactly, including its
//! integer-precision domain: values beyond 2^53 keep an integer representation
//! instead of collapsing into `f64`.

use std::collections::BTreeMap;
use std::fmt;

use serde::de::{self, MapAccess, SeqAccess, Visitor};
use serde::ser::{SerializeMap, SerializeSeq};
use serde::{Deserialize, Deserializer, Serialize, Serializer};

/// `2^53` — the largest integer magnitude `Double` represents exactly. Swift
/// writes the literal `9_007_199_254_740_992`, which is this value.
pub const MAX_EXACT_DOUBLE_INTEGER: u64 = 9_007_199_254_740_992;

/// A lossless, Codable component document. Large integer identifiers and seeds
/// retain their integer representation; ordinary numbers use JSON's numeric value.
#[derive(Clone, Debug)]
pub enum ComponentValue {
    Null,
    Bool(bool),
    String(String),
    Number(f64),
    SignedInteger(i64),
    UnsignedInteger(u64),
    Array(Vec<ComponentValue>),
    /// Swift stores `[String: ComponentValue]`; `BTreeMap` gives the deterministic
    /// iteration order that MIGRATION.md §5.2 requires for output that reaches a
    /// file or hash.
    Object(BTreeMap<String, ComponentValue>),
}

/// Swift's `Int64(exactly:)`.
fn exact_i64(value: f64) -> Option<i64> {
    if value.is_finite()
        && value.fract() == 0.0
        && (-9_223_372_036_854_775_808.0..9_223_372_036_854_775_808.0).contains(&value)
    {
        Some(value as i64)
    } else {
        None
    }
}

/// Swift's `UInt64(exactly:)`.
fn exact_u64(value: f64) -> Option<u64> {
    if value.is_finite()
        && value.fract() == 0.0
        && (0.0..18_446_744_073_709_551_616.0).contains(&value)
    {
        Some(value as u64)
    } else {
        None
    }
}

/// Swift `ComponentValue.==` is hand-written: JSON has one numeric domain, so a
/// number that survived `Codable` normalization as an integer compares equal to
/// its `Double` spelling. Component editing relies on that when it confirms an
/// edit against the re-encoded component document.
impl PartialEq for ComponentValue {
    fn eq(&self, other: &Self) -> bool {
        use ComponentValue::{
            Array, Bool, Null, Number, Object, SignedInteger, String, UnsignedInteger,
        };
        match (self, other) {
            (Null, Null) => true,
            (Bool(a), Bool(b)) => a == b,
            (String(a), String(b)) => a == b,
            (Number(a), Number(b)) => a == b,
            (SignedInteger(a), SignedInteger(b)) => a == b,
            (UnsignedInteger(a), UnsignedInteger(b)) => a == b,
            (Number(a), SignedInteger(b)) | (SignedInteger(b), Number(a)) => {
                exact_i64(*a) == Some(*b)
            }
            (Number(a), UnsignedInteger(b)) | (UnsignedInteger(b), Number(a)) => {
                exact_u64(*a) == Some(*b)
            }
            (SignedInteger(a), UnsignedInteger(b)) | (UnsignedInteger(b), SignedInteger(a)) => {
                u64::try_from(*a).ok() == Some(*b)
            }
            (Array(a), Array(b)) => a == b,
            (Object(a), Object(b)) => a == b,
            _ => false,
        }
    }
}

impl ComponentValue {
    /// Numeric projection used by inference and field merging.
    pub fn numeric_value(&self) -> Option<f64> {
        match self {
            ComponentValue::Number(value) => Some(*value),
            ComponentValue::SignedInteger(value) => Some(*value as f64),
            ComponentValue::UnsignedInteger(value) => Some(*value as f64),
            _ => None,
        }
    }

    /// Builds a value from a `serde_json::Value`, mirroring
    /// `init(jsonObject:)`'s number-domain normalization.
    pub fn from_json_value(value: &serde_json::Value) -> ComponentValue {
        match value {
            serde_json::Value::Null => ComponentValue::Null,
            serde_json::Value::Bool(value) => ComponentValue::Bool(*value),
            serde_json::Value::Number(number) => {
                if let Some(value) = number.as_u64() {
                    if value > MAX_EXACT_DOUBLE_INTEGER {
                        return ComponentValue::UnsignedInteger(value);
                    }
                    ComponentValue::Number(value as f64)
                } else if let Some(value) = number.as_i64() {
                    if value < -(MAX_EXACT_DOUBLE_INTEGER as i64) {
                        return ComponentValue::SignedInteger(value);
                    }
                    ComponentValue::Number(value as f64)
                } else {
                    ComponentValue::Number(number.as_f64().unwrap_or(0.0))
                }
            }
            serde_json::Value::String(value) => ComponentValue::String(value.clone()),
            serde_json::Value::Array(values) => ComponentValue::Array(
                values
                    .iter()
                    .map(ComponentValue::from_json_value)
                    .collect::<Vec<_>>(),
            ),
            serde_json::Value::Object(values) => ComponentValue::Object(
                values
                    .iter()
                    .map(|(key, value)| (key.clone(), ComponentValue::from_json_value(value)))
                    .collect::<BTreeMap<_, _>>(),
            ),
        }
    }

    /// Swift `var jsonObject: Any`.
    pub fn to_json_value(&self) -> serde_json::Value {
        match self {
            ComponentValue::Null => serde_json::Value::Null,
            ComponentValue::Bool(value) => serde_json::Value::Bool(*value),
            ComponentValue::String(value) => serde_json::Value::String(value.clone()),
            ComponentValue::Number(value) => serde_json::Number::from_f64(*value)
                .map(serde_json::Value::Number)
                .unwrap_or(serde_json::Value::Null),
            ComponentValue::SignedInteger(value) => serde_json::Value::Number((*value).into()),
            ComponentValue::UnsignedInteger(value) => serde_json::Value::Number((*value).into()),
            ComponentValue::Array(values) => {
                serde_json::Value::Array(values.iter().map(ComponentValue::to_json_value).collect())
            }
            ComponentValue::Object(values) => serde_json::Value::Object(
                values
                    .iter()
                    .map(|(key, value)| (key.clone(), value.to_json_value()))
                    .collect(),
            ),
        }
    }

    /// `var objectValue: [String: Any]?`
    pub fn object_value(&self) -> Option<&BTreeMap<String, ComponentValue>> {
        match self {
            ComponentValue::Object(values) => Some(values),
            _ => None,
        }
    }

    /// Mutable counterpart used by the field-merging helpers.
    pub fn object_value_mut(&mut self) -> Option<&mut BTreeMap<String, ComponentValue>> {
        match self {
            ComponentValue::Object(values) => Some(values),
            _ => None,
        }
    }

    /// Convenience for callers that need an owned object document.
    pub fn into_object(self) -> Option<BTreeMap<String, ComponentValue>> {
        match self {
            ComponentValue::Object(values) => Some(values),
            _ => None,
        }
    }

    pub fn as_str(&self) -> Option<&str> {
        match self {
            ComponentValue::String(value) => Some(value),
            _ => None,
        }
    }

    pub fn as_bool(&self) -> Option<bool> {
        match self {
            ComponentValue::Bool(value) => Some(*value),
            _ => None,
        }
    }

    pub fn as_array(&self) -> Option<&[ComponentValue]> {
        match self {
            ComponentValue::Array(values) => Some(values),
            _ => None,
        }
    }
}

impl fmt::Display for ComponentValue {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.to_json_value())
    }
}

impl Serialize for ComponentValue {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self {
            ComponentValue::Null => serializer.serialize_unit(),
            ComponentValue::Bool(value) => serializer.serialize_bool(*value),
            ComponentValue::String(value) => serializer.serialize_str(value),
            ComponentValue::Number(value) => serializer.serialize_f64(*value),
            ComponentValue::SignedInteger(value) => serializer.serialize_i64(*value),
            ComponentValue::UnsignedInteger(value) => serializer.serialize_u64(*value),
            ComponentValue::Array(values) => {
                let mut sequence = serializer.serialize_seq(Some(values.len()))?;
                for value in values {
                    sequence.serialize_element(value)?;
                }
                sequence.end()
            }
            ComponentValue::Object(values) => {
                let mut map = serializer.serialize_map(Some(values.len()))?;
                for (key, value) in values {
                    map.serialize_entry(key, value)?;
                }
                map.end()
            }
        }
    }
}

/// Mirrors `init(from:)`'s probe order: nil, Bool, oversized integers, Double,
/// String, array, object.
struct ComponentValueVisitor;

impl<'de> Visitor<'de> for ComponentValueVisitor {
    type Value = ComponentValue;

    fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("any JSON value")
    }

    fn visit_unit<E: de::Error>(self) -> Result<ComponentValue, E> {
        Ok(ComponentValue::Null)
    }

    fn visit_none<E: de::Error>(self) -> Result<ComponentValue, E> {
        Ok(ComponentValue::Null)
    }

    fn visit_some<D: Deserializer<'de>>(self, deserializer: D) -> Result<ComponentValue, D::Error> {
        deserializer.deserialize_any(ComponentValueVisitor)
    }

    fn visit_bool<E: de::Error>(self, value: bool) -> Result<ComponentValue, E> {
        Ok(ComponentValue::Bool(value))
    }

    fn visit_u64<E: de::Error>(self, value: u64) -> Result<ComponentValue, E> {
        if value > MAX_EXACT_DOUBLE_INTEGER {
            Ok(ComponentValue::UnsignedInteger(value))
        } else {
            Ok(ComponentValue::Number(value as f64))
        }
    }

    fn visit_i64<E: de::Error>(self, value: i64) -> Result<ComponentValue, E> {
        if value < -(MAX_EXACT_DOUBLE_INTEGER as i64) {
            Ok(ComponentValue::SignedInteger(value))
        } else {
            Ok(ComponentValue::Number(value as f64))
        }
    }

    fn visit_u128<E: de::Error>(self, value: u128) -> Result<ComponentValue, E> {
        match u64::try_from(value) {
            Ok(value) => self.visit_u64(value),
            Err(_) => Ok(ComponentValue::Number(value as f64)),
        }
    }

    fn visit_i128<E: de::Error>(self, value: i128) -> Result<ComponentValue, E> {
        match i64::try_from(value) {
            Ok(value) => self.visit_i64(value),
            Err(_) => Ok(ComponentValue::Number(value as f64)),
        }
    }

    fn visit_f64<E: de::Error>(self, value: f64) -> Result<ComponentValue, E> {
        Ok(ComponentValue::Number(value))
    }

    fn visit_str<E: de::Error>(self, value: &str) -> Result<ComponentValue, E> {
        Ok(ComponentValue::String(value.to_owned()))
    }

    fn visit_string<E: de::Error>(self, value: String) -> Result<ComponentValue, E> {
        Ok(ComponentValue::String(value))
    }

    fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<ComponentValue, A::Error> {
        let mut values = Vec::with_capacity(seq.size_hint().unwrap_or(0));
        while let Some(value) = seq.next_element::<ComponentValue>()? {
            values.push(value);
        }
        Ok(ComponentValue::Array(values))
    }

    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<ComponentValue, A::Error> {
        let mut values = BTreeMap::new();
        while let Some((key, value)) = map.next_entry::<String, ComponentValue>()? {
            values.insert(key, value);
        }
        Ok(ComponentValue::Object(values))
    }
}

impl<'de> Deserialize<'de> for ComponentValue {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<ComponentValue, D::Error> {
        deserializer.deserialize_any(ComponentValueVisitor)
    }
}

/// One component's `(typeID, value)` pair inside a persisted document.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ManifestComponent {
    #[serde(rename = "type")]
    pub type_id: String,
    pub value: ComponentValue,
}

impl ManifestComponent {
    pub fn new(type_id: impl Into<String>, value: ComponentValue) -> Self {
        ManifestComponent {
            type_id: type_id.into(),
            value,
        }
    }
}

/// Swift's `extension Array where Element == ManifestComponent`.
pub fn manifest_value_for<'a>(
    components: &'a [ManifestComponent],
    type_id: &str,
) -> Option<&'a ComponentValue> {
    components
        .iter()
        .find(|component| component.type_id == type_id)
        .map(|component| &component.value)
}
