//! `IntentIR` — the structured intent an AI or human proposes.
//!
//! `IntentArgumentValue` is a hand-written `Codable` in Swift: it encodes as
//! `{"type": "<kind>", "value": ...}` and the kind `stableID` is spelled **`stable_id`**
//! on the wire. That spelling is `Kind.stableID = "stable_id"` in the Swift source, so
//! it is not derivable from the Rust variant name — it is written out here explicitly.

use diffuse_capability::support::swift_date::SwiftDate;
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Who produced an intent.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum IntentSource {
    Human,
    Ai,
    System,
}

/// A plain three-component vector for intent arguments.
///
/// Deliberately not `Float3`: this type is serialized as `{"x":…,"y":…,"z":…}` and is
/// part of the persisted intent format, so its shape must not follow a SIMD layout.
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct IntentVector3 {
    pub x: f32,
    pub y: f32,
    pub z: f32,
}

impl IntentVector3 {
    pub fn new(x: f32, y: f32, z: f32) -> Self {
        IntentVector3 { x, y, z }
    }

    pub fn from_simd(value: diffuse_math::simd::simd_compat::Float3) -> Self {
        IntentVector3 {
            x: value.x,
            y: value.y,
            z: value.z,
        }
    }

    pub fn simd_value(self) -> diffuse_math::simd::simd_compat::Float3 {
        diffuse_math::simd::simd_compat::Float3::new(self.x, self.y, self.z)
    }
}

/// One intent argument.
///
/// Encoded as `{"type": <kind>, "value": <value>}`; see the module comment for the
/// `stable_id` spelling.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", content = "value", rename_all = "camelCase")]
pub enum IntentArgumentValue {
    Bool(bool),
    Integer(i64),
    Number(f64),
    String(String),
    /// The wire kind is `stable_id`, not `stableID`.
    #[serde(rename = "stable_id")]
    StableId(u64),
    Vec3(IntentVector3),
}

impl IntentArgumentValue {
    /// The wire kind string, for a caller that needs to compare without encoding.
    pub const fn kind(&self) -> &'static str {
        match self {
            IntentArgumentValue::Bool(_) => "bool",
            IntentArgumentValue::Integer(_) => "integer",
            IntentArgumentValue::Number(_) => "number",
            IntentArgumentValue::String(_) => "string",
            IntentArgumentValue::StableId(_) => "stable_id",
            IntentArgumentValue::Vec3(_) => "vec3",
        }
    }
}

/// One piece of evidence supporting an intent.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct IntentEvidence {
    pub kind: String,
    pub summary: String,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub target_object_id: Option<String>,
}

impl IntentEvidence {
    pub fn new(kind: impl Into<String>, summary: impl Into<String>) -> Self {
        IntentEvidence {
            kind: kind.into(),
            summary: summary.into(),
            target_object_id: None,
        }
    }
}

/// The structured intent.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct IntentIR {
    pub id: String,
    pub verb: String,
    pub summary: String,
    pub target_object_ids: Vec<String>,
    pub arguments: std::collections::BTreeMap<String, IntentArgumentValue>,
    pub confidence: f64,
    pub evidence: Vec<IntentEvidence>,
    pub source: IntentSource,
    /// Swift's `Date`, i.e. seconds since 2001-01-01.
    pub created_at: SwiftDate,
}

impl IntentIR {
    /// Swift's memberwise initializer with its defaults applied.
    pub fn new(verb: impl Into<String>, summary: impl Into<String>, source: IntentSource) -> Self {
        IntentIR {
            id: crate::planning::edit::new_uuid(),
            verb: verb.into(),
            summary: summary.into(),
            target_object_ids: Vec::new(),
            arguments: std::collections::BTreeMap::new(),
            confidence: 1.0,
            evidence: Vec::new(),
            source,
            created_at: SwiftDate::now(),
        }
    }

    /// A decoded intent with the missing defaults filled in.
    ///
    /// Swift's decoder defaulted `id` to a fresh UUID, collections to empty, confidence
    /// to `1.0` and `createdAt` to now — so an older document without those keys still
    /// decodes instead of failing.
    pub fn from_json(value: &Value) -> Result<IntentIR, serde_json::Error> {
        let object = value.as_object().ok_or_else(|| {
            serde_json::Error::io(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "intent must be a JSON object",
            ))
        })?;

        let get_string = |key: &str| -> Result<String, serde_json::Error> {
            match object.get(key) {
                Some(Value::String(text)) => Ok(text.clone()),
                Some(_) => Err(serde_json::Error::io(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    format!("{key} must be a string"),
                ))),
                None => Err(serde_json::Error::io(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    format!("{key} is required"),
                ))),
            }
        };

        let id = match object.get("id") {
            Some(Value::String(text)) => text.clone(),
            None | Some(Value::Null) => crate::planning::edit::new_uuid(),
            Some(_) => {
                return Err(serde_json::Error::io(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "id must be a string",
                )));
            }
        };
        let target_object_ids = match object.get("targetObjectIDs") {
            Some(value) => serde_json::from_value(value.clone())?,
            None => Vec::new(),
        };
        let arguments = match object.get("arguments") {
            Some(value) => serde_json::from_value(value.clone())?,
            None => std::collections::BTreeMap::new(),
        };
        let confidence = match object.get("confidence") {
            Some(Value::Number(number)) => number.as_f64().unwrap_or(1.0),
            None => 1.0,
            Some(_) => {
                return Err(serde_json::Error::io(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "confidence must be a number",
                )));
            }
        };
        let evidence = match object.get("evidence") {
            Some(value) => serde_json::from_value(value.clone())?,
            None => Vec::new(),
        };
        let source: IntentSource =
            serde_json::from_value(object.get("source").cloned().ok_or_else(|| {
                serde_json::Error::io(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "source is required",
                ))
            })?)?;
        let created_at = match object.get("createdAt") {
            Some(value) => serde_json::from_value(value.clone())?,
            None => SwiftDate::now(),
        };

        Ok(IntentIR {
            id,
            verb: get_string("verb")?,
            summary: get_string("summary")?,
            target_object_ids,
            arguments,
            confidence,
            evidence,
            source,
            created_at,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_stable_id_argument_encodes_the_snake_case_kind() {
        let value = IntentArgumentValue::StableId(42);
        let json = serde_json::to_value(&value).expect("serialize");
        assert_eq!(
            json,
            serde_json::json!({"type": "stable_id", "value": 42}),
            "the wire kind is snake_case, not stableID"
        );
    }

    #[test]
    fn every_argument_kind_round_trips() {
        let values = [
            IntentArgumentValue::Bool(true),
            IntentArgumentValue::Integer(-7),
            IntentArgumentValue::Number(1.5),
            IntentArgumentValue::String("hero".to_string()),
            IntentArgumentValue::StableId(9),
            IntentArgumentValue::Vec3(IntentVector3::new(1.0, 2.0, 3.0)),
        ];
        for value in values {
            let json = serde_json::to_string(&value).expect("serialize");
            let restored: IntentArgumentValue = serde_json::from_str(&json).expect("deserialize");
            assert_eq!(restored, value, "round trip failed for {json}");
        }
    }

    #[test]
    fn an_intent_round_trips() {
        let intent = IntentIR::new("move", "move the cube", IntentSource::Ai);
        let json = serde_json::to_string(&intent).expect("serialize");
        let restored: IntentIR = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(restored, intent);
    }

    #[test]
    fn a_document_missing_optional_keys_decodes_with_defaults() {
        let minimal = serde_json::json!({
            "verb": "move",
            "summary": "move it",
            "source": "ai"
        });
        let intent = IntentIR::from_json(&minimal).expect("decode");
        assert_eq!(intent.verb, "move");
        assert_eq!(intent.confidence, 1.0, "confidence defaults to 1.0");
        assert!(intent.target_object_ids.is_empty());
        assert!(intent.arguments.is_empty());
        assert_eq!(intent.id.len(), 36, "a missing id is generated");
    }

    #[test]
    fn a_missing_source_is_rejected() {
        let broken = serde_json::json!({"verb": "move", "summary": "x"});
        assert!(IntentIR::from_json(&broken).is_err(), "source is required");
    }

    #[test]
    fn a_vec3_argument_keeps_its_xyx_shape() {
        let value = IntentArgumentValue::Vec3(IntentVector3::new(1.0, 2.0, 3.0));
        let json = serde_json::to_value(&value).expect("serialize");
        assert_eq!(
            json["value"],
            serde_json::json!({"x": 1.0, "y": 2.0, "z": 3.0})
        );
    }
}
