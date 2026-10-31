//! Component editing operations shared by editor documents and the script API.
//!
//! `Components/Editing.swift` defines the write mode, the edit error domain and
//! the recursive document merge. The `SceneRuntime`-scoped entry points live with
//! the runtime in `components/core/component_editing.rs`.

pub mod motion_quality;
pub mod topology_input;

use thiserror::Error;

use crate::components::core::value::ComponentValue;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ComponentWriteMode {
    Replace,
    Merge,
}

impl ComponentWriteMode {
    pub const fn raw_value(&self) -> &'static str {
        match self {
            ComponentWriteMode::Replace => "replace",
            ComponentWriteMode::Merge => "merge",
        }
    }

    pub fn from_raw_value(value: &str) -> Option<Self> {
        match value {
            "replace" => Some(ComponentWriteMode::Replace),
            "merge" => Some(ComponentWriteMode::Merge),
            _ => None,
        }
    }
}

impl serde::Serialize for ComponentWriteMode {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(self.raw_value())
    }
}

impl<'de> serde::Deserialize<'de> for ComponentWriteMode {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let value = String::deserialize(deserializer)?;
        ComponentWriteMode::from_raw_value(&value)
            .ok_or_else(|| serde::de::Error::custom(format!("Unknown write mode: {value}")))
    }
}

#[derive(Clone, Debug, Error, PartialEq, Eq)]
pub enum ComponentEditError {
    #[error("unknown component type: {0}")]
    UnknownType(String),
    #[error("missing component: {0}")]
    MissingComponent(String),
    #[error("incompatible component: {0}")]
    IncompatibleComponent(String),
    #[error("invalid value: {0}")]
    InvalidValue(String),
    #[error("invalid array index: {0}")]
    InvalidArrayIndex(String),
}

impl ComponentValue {
    /// Every number in the document is finite.
    pub fn is_finite_json(&self) -> bool {
        match self {
            ComponentValue::Number(value) => value.is_finite(),
            ComponentValue::Array(values) => values.iter().all(ComponentValue::is_finite_json),
            ComponentValue::Object(values) => values.values().all(ComponentValue::is_finite_json),
            _ => true,
        }
    }

    /// Objects merge recursively; arrays replace as a whole. An object keyed by
    /// existing array indices edits those elements without dropping sibling shapes.
    pub fn merging(&self, changes: &ComponentValue) -> Result<ComponentValue, ComponentEditError> {
        let ComponentValue::Object(fields) = changes else {
            return Ok(changes.clone());
        };

        if let ComponentValue::Array(values) = self {
            let mut values = values.clone();
            for (key, value) in fields {
                // Swift: `guard let index = Int(key), values.indices.contains(index)`.
                let index = key
                    .parse::<i64>()
                    .ok()
                    .and_then(|index| usize::try_from(index).ok())
                    .filter(|index| *index < values.len())
                    .ok_or_else(|| ComponentEditError::InvalidArrayIndex(key.clone()))?;
                values[index] = values[index].merging(value)?;
            }
            return Ok(ComponentValue::Array(values));
        }

        let ComponentValue::Object(values) = self else {
            return Ok(changes.clone());
        };
        let mut values = values.clone();
        for (key, value) in fields {
            let existing = values.get(key).cloned().unwrap_or(ComponentValue::Null);
            values.insert(key.clone(), existing.merging(value)?);
        }
        Ok(ComponentValue::Object(values))
    }

    /// Tests the supplied fields after decoding. Whole documents use equality;
    /// merged objects and array-index edits only assert their addressed fields.
    pub fn contains_fields(&self, expected: &ComponentValue) -> bool {
        if let (ComponentValue::Number(actual), ComponentValue::Number(value)) = (self, expected) {
            // Swift tolerance: max(1, abs(expected)) * 0.000001.
            return *actual == *value
                || (actual.is_finite()
                    && value.is_finite()
                    && (actual - value).abs() <= value.abs().max(1.0) * 0.000_001);
        }
        let ComponentValue::Object(fields) = expected else {
            return self == expected;
        };
        match self {
            ComponentValue::Object(values) => fields.iter().all(|(key, value)| {
                let entry = values.get(key).cloned().unwrap_or(ComponentValue::Null);
                entry.contains_fields(value)
            }),
            ComponentValue::Array(values) => fields.iter().all(|(key, value)| {
                let Some(index) = key
                    .parse::<i64>()
                    .ok()
                    .and_then(|index| usize::try_from(index).ok())
                else {
                    return false;
                };
                if index >= values.len() {
                    return false;
                }
                values[index].contains_fields(value)
            }),
            _ => false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    fn object(entries: Vec<(&str, ComponentValue)>) -> ComponentValue {
        ComponentValue::Object(
            entries
                .into_iter()
                .map(|(key, value)| (key.to_string(), value))
                .collect::<BTreeMap<_, _>>(),
        )
    }

    #[test]
    fn merging_objects_recursively_keeps_siblings() {
        let previous = object(vec![
            ("a", ComponentValue::Number(1.0)),
            ("b", ComponentValue::Number(2.0)),
        ]);
        let changes = object(vec![("a", ComponentValue::Number(3.0))]);
        let merged = previous.merging(&changes).expect("merge");
        assert_eq!(
            merged,
            object(vec![
                ("a", ComponentValue::Number(3.0)),
                ("b", ComponentValue::Number(2.0)),
            ])
        );
    }

    #[test]
    fn merging_array_by_index_edits_element() {
        let previous = object(vec![(
            "items",
            ComponentValue::Array(vec![
                ComponentValue::Number(1.0),
                ComponentValue::Number(2.0),
            ]),
        )]);
        let changes = object(vec![(
            "items",
            object(vec![("1", ComponentValue::Number(9.0))]),
        )]);
        let merged = previous.merging(&changes).expect("merge");
        assert_eq!(
            merged,
            object(vec![(
                "items",
                ComponentValue::Array(vec![
                    ComponentValue::Number(1.0),
                    ComponentValue::Number(9.0),
                ])
            )])
        );
    }

    #[test]
    fn merging_out_of_range_index_is_an_error() {
        let previous = ComponentValue::Array(vec![ComponentValue::Number(1.0)]);
        let changes = object(vec![("5", ComponentValue::Number(0.0))]);
        assert_eq!(
            previous.merging(&changes),
            Err(ComponentEditError::InvalidArrayIndex("5".to_string()))
        );
    }

    #[test]
    fn contains_fields_uses_tolerance() {
        let actual = object(vec![("a", ComponentValue::Number(1.000_000_1))]);
        let expected = object(vec![("a", ComponentValue::Number(1.0))]);
        assert!(actual.contains_fields(&expected));
    }
}
