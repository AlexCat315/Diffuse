//! Fine-grained world state changes.
//!
//! `TransactionExecutor` emits one set of these per apply, and the editor's world view
//! consumes them to maintain an incremental entity index instead of refreshing a
//! snapshot. The variants therefore form a contract between the executor and the view:
//! adding a variant is a consumer-visible change.
//!
//! `WorldPropertyValue` encodes as `{"type": <kind>, ...}` with **different keys per
//! kind** — `vec3`/`vec4` write `x`/`y`/`z`/`w` and no `value`, while the scalar kinds
//! write `value` only. That asymmetry is Swift's hand-written `encode(to:)` and is
//! reproduced by hand here.

use serde::de::Error as _;
use serde::ser::SerializeMap;
use serde::{Deserialize, Deserializer, Serialize, Serializer};

use diffuse_scene::components::core::value::ComponentValue;

/// A scalar property value carried by a state change.
#[derive(Clone, Debug, PartialEq)]
pub enum WorldPropertyValue {
    Json(ComponentValue),
    Vec3(f32, f32, f32),
    /// Four components: a bounding rect `(x, y, w, h)`, an RGBA colour, or a quaternion.
    Vec4(f32, f32, f32, f32),
    Float(f32),
    String(String),
    Bool(bool),
}

impl WorldPropertyValue {
    /// The wire kind string.
    pub const fn kind(&self) -> &'static str {
        match self {
            WorldPropertyValue::Json(_) => "json",
            WorldPropertyValue::Vec3(..) => "vec3",
            WorldPropertyValue::Vec4(..) => "vec4",
            WorldPropertyValue::Float(_) => "float",
            WorldPropertyValue::String(_) => "string",
            WorldPropertyValue::Bool(_) => "bool",
        }
    }

    pub fn as_float(&self) -> Option<f32> {
        match self {
            WorldPropertyValue::Float(value) => Some(*value),
            _ => None,
        }
    }

    pub fn as_bool(&self) -> Option<bool> {
        match self {
            WorldPropertyValue::Bool(value) => Some(*value),
            _ => None,
        }
    }

    pub fn as_string(&self) -> Option<&str> {
        match self {
            WorldPropertyValue::String(value) => Some(value),
            _ => None,
        }
    }
}

impl Serialize for WorldPropertyValue {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self {
            // `ComponentValue` has no `Serialize` of its own: it is a runtime store type.
            // Its JSON projection is what the wire carried, so serialize that.
            WorldPropertyValue::Json(value) => {
                let mut map = serializer.serialize_map(Some(2))?;
                map.serialize_entry("type", "json")?;
                map.serialize_entry("value", &value.to_json_value())?;
                map.end()
            }
            WorldPropertyValue::Vec3(x, y, z) => {
                let mut map = serializer.serialize_map(Some(4))?;
                map.serialize_entry("type", "vec3")?;
                map.serialize_entry("x", x)?;
                map.serialize_entry("y", y)?;
                map.serialize_entry("z", z)?;
                map.end()
            }
            WorldPropertyValue::Vec4(x, y, z, w) => {
                let mut map = serializer.serialize_map(Some(5))?;
                map.serialize_entry("type", "vec4")?;
                map.serialize_entry("x", x)?;
                map.serialize_entry("y", y)?;
                map.serialize_entry("z", z)?;
                map.serialize_entry("w", w)?;
                map.end()
            }
            WorldPropertyValue::Float(value) => {
                let mut map = serializer.serialize_map(Some(2))?;
                map.serialize_entry("type", "float")?;
                map.serialize_entry("value", value)?;
                map.end()
            }
            WorldPropertyValue::String(value) => {
                let mut map = serializer.serialize_map(Some(2))?;
                map.serialize_entry("type", "string")?;
                map.serialize_entry("value", value)?;
                map.end()
            }
            WorldPropertyValue::Bool(value) => {
                let mut map = serializer.serialize_map(Some(2))?;
                map.serialize_entry("type", "bool")?;
                map.serialize_entry("value", value)?;
                map.end()
            }
        }
    }
}

impl<'de> Deserialize<'de> for WorldPropertyValue {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let raw = serde_json::Value::deserialize(deserializer)?;
        let object = raw
            .as_object()
            .ok_or_else(|| D::Error::custom("expected an object"))?;
        let kind = object
            .get("type")
            .and_then(serde_json::Value::as_str)
            .ok_or_else(|| D::Error::custom("missing type"))?;

        let number = |key: &str| -> Result<f32, D::Error> {
            object
                .get(key)
                .and_then(serde_json::Value::as_f64)
                .map(|value| value as f32)
                .ok_or_else(|| D::Error::custom(format!("missing numeric {key}")))
        };

        match kind {
            "json" => {
                let value = object
                    .get("value")
                    .ok_or_else(|| D::Error::custom("missing value"))?;
                Ok(WorldPropertyValue::Json(ComponentValue::from_json_value(
                    value,
                )))
            }
            "vec3" => Ok(WorldPropertyValue::Vec3(
                number("x")?,
                number("y")?,
                number("z")?,
            )),
            "vec4" => Ok(WorldPropertyValue::Vec4(
                number("x")?,
                number("y")?,
                number("z")?,
                number("w")?,
            )),
            "float" => Ok(WorldPropertyValue::Float(number("value")?)),
            "string" => Ok(WorldPropertyValue::String(
                object
                    .get("value")
                    .and_then(serde_json::Value::as_str)
                    .ok_or_else(|| D::Error::custom("value must be a string"))?
                    .to_string(),
            )),
            "bool" => Ok(WorldPropertyValue::Bool(
                object
                    .get("value")
                    .and_then(serde_json::Value::as_bool)
                    .ok_or_else(|| D::Error::custom("value must be a bool"))?,
            )),
            other => Err(D::Error::custom(format!(
                "unknown WorldPropertyValue type: {other}"
            ))),
        }
    }
}

/// One fine-grained change to the world.
#[derive(Clone, Debug, PartialEq)]
pub enum WorldEvent {
    /// A spawned or duplicated entity.
    EntityAdded {
        ref_: String,
        name: String,
        kind: Option<String>,
    },
    /// An entity permanently removed.
    EntityRemoved { ref_: String },
    /// An authored property changed by a user or AI action.
    EntityAuthoredChanged {
        ref_: String,
        property: String,
        value: WorldPropertyValue,
    },
    /// An edit was applied; this carries the revision bump.
    EditApplied {
        edit_id: String,
        summary: String,
        revision: u64,
    },
    /// The selection set changed.
    SelectionChanged { refs: Vec<String> },
    /// An engine-computed property changed, e.g. a world transform after hierarchy solve.
    EntityEvaluatedChanged {
        ref_: String,
        property: String,
        value: WorldPropertyValue,
    },
    /// The semantic pipeline inferred a property.
    EntityInferredUpdated {
        ref_: String,
        property: String,
        value: WorldPropertyValue,
        confidence: f64,
        source: Option<String>,
    },
}

impl WorldEvent {
    /// The `scene:<id>` reference this event concerns, when it concerns one entity.
    pub fn entity_ref(&self) -> Option<&str> {
        match self {
            WorldEvent::EntityAdded { ref_, .. }
            | WorldEvent::EntityRemoved { ref_ }
            | WorldEvent::EntityAuthoredChanged { ref_, .. }
            | WorldEvent::EntityEvaluatedChanged { ref_, .. }
            | WorldEvent::EntityInferredUpdated { ref_, .. } => Some(ref_),
            WorldEvent::EditApplied { .. } | WorldEvent::SelectionChanged { .. } => None,
        }
    }

    /// The property name, for the property-change variants.
    pub fn property(&self) -> Option<&str> {
        match self {
            WorldEvent::EntityAuthoredChanged { property, .. }
            | WorldEvent::EntityEvaluatedChanged { property, .. }
            | WorldEvent::EntityInferredUpdated { property, .. } => Some(property),
            _ => None,
        }
    }
}

/// Build the canonical entity reference string.
#[inline]
pub fn entity_ref_of(entity_id: u64) -> String {
    format!("scene:{entity_id}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_vec3_value_writes_components_not_a_value_key() {
        let json =
            serde_json::to_value(WorldPropertyValue::Vec3(1.0, 2.0, 3.0)).expect("serialize");
        assert_eq!(
            json,
            serde_json::json!({"type": "vec3", "x": 1.0, "y": 2.0, "z": 3.0})
        );
        assert!(json.get("value").is_none(), "vec3 must not write `value`");
    }

    #[test]
    fn a_vec4_value_writes_four_components() {
        let json =
            serde_json::to_value(WorldPropertyValue::Vec4(1.0, 2.0, 3.0, 4.0)).expect("serialize");
        assert_eq!(
            json,
            serde_json::json!({"type": "vec4", "x": 1.0, "y": 2.0, "z": 3.0, "w": 4.0})
        );
    }

    #[test]
    fn scalar_values_write_a_value_key() {
        assert_eq!(
            serde_json::to_value(WorldPropertyValue::Float(1.5)).expect("serialize"),
            serde_json::json!({"type": "float", "value": 1.5})
        );
        assert_eq!(
            serde_json::to_value(WorldPropertyValue::Bool(true)).expect("serialize"),
            serde_json::json!({"type": "bool", "value": true})
        );
        assert_eq!(
            serde_json::to_value(WorldPropertyValue::String("x".to_string())).expect("serialize"),
            serde_json::json!({"type": "string", "value": "x"})
        );
    }

    #[test]
    fn json_values_round_trip() {
        let value = WorldPropertyValue::Json(ComponentValue::Object(
            [("a".to_string(), ComponentValue::Number(1.0))]
                .into_iter()
                .collect(),
        ));
        let json = serde_json::to_string(&value).expect("serialize");
        let restored: WorldPropertyValue = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(restored, value);
    }

    #[test]
    fn an_unknown_type_is_rejected() {
        let error = serde_json::from_str::<WorldPropertyValue>("{\"type\":\"matrix\"}");
        assert!(error.is_err(), "an unknown kind must not decode");
    }

    #[test]
    fn entity_refs_use_the_scene_prefix() {
        assert_eq!(entity_ref_of(42), "scene:42");
        let event = WorldEvent::EntityRemoved {
            ref_: entity_ref_of(42),
        };
        assert_eq!(event.entity_ref(), Some("scene:42"));
        assert_eq!(event.property(), None);
    }
}
