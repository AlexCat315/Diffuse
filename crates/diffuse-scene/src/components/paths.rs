//! Path addressing into a component document (`Components/Paths.swift`).
//!
//! Swift's `extension ComponentValue` becomes inherent methods on the Rust enum.

use std::collections::BTreeMap;

use crate::components::core::value::ComponentValue;

impl ComponentValue {
    /// §Swift `numericValue`.
    pub fn numeric(&self) -> Option<f64> {
        self.numeric_value()
    }

    /// `func value(at path: [String]) -> ComponentValue?`
    pub fn value_at(&self, path: &[String]) -> Option<&ComponentValue> {
        let Some((first, rest)) = path.split_first() else {
            return Some(self);
        };
        match self {
            ComponentValue::Object(values) => {
                values.get(first).and_then(|value| value.value_at(rest))
            }
            ComponentValue::Array(values) => {
                // Swift parses the path element as `Int` and requires a valid index.
                let index: i64 = first.parse().ok()?;
                let index = usize::try_from(index).ok()?;
                if index >= values.len() {
                    return None;
                }
                values[index].value_at(rest)
            }
            _ => None,
        }
    }

    /// `static func fieldPatch(_ value:at path:)` — nests `value` under the
    /// reversed path, producing `{"a": {"b": value}}` for `["a", "b"]`.
    pub fn field_patch(value: ComponentValue, path: &[String]) -> ComponentValue {
        path.iter().rev().fold(value, |accumulated, key| {
            let mut fields = BTreeMap::new();
            fields.insert(key.clone(), accumulated);
            ComponentValue::Object(fields)
        })
    }
}
