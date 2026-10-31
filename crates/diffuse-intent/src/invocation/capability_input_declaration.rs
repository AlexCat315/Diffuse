//! The generated capability-input boundary: which value types an AI may write.
//!
//! Swift enforced this with a `CapabilitySchemaValue` protocol plus property wrappers
//! and `Mirror` reflection over a declared input struct. Rust has no reflection and no
//! property wrappers, so the same guarantee is expressed two ways:
//!
//! - [`CapabilitySchemaValue`] is a trait each allowed value type implements. A type that
//!   does not implement it cannot appear in a capability input at all, which is the
//!   compile-time version of Swift's "conforming is an explicit host decision".
//! - [`DeclaredCapabilityInput::input_schema`] is built from an explicit field list
//!   rather than reflection. The closed-world rule is preserved: a field that is not
//!   declared produces [`JsonSchema::any`], so an undeclared field makes registration
//!   fail closed exactly as Swift's did.
//!
//! Arbitrary dictionaries and untyped JSON therefore cannot silently become AI-write
//! parameters.

use diffuse_capability::capsule_schema::{self, JsonSchema};
use serde::{Deserialize, Serialize};

/// A value type allowed on the capability-input boundary.
pub trait CapabilitySchemaValue: Serialize + for<'de> Deserialize<'de> + Send + Sync {
    /// The JSON schema advertised to the model for this type.
    fn capability_schema() -> JsonSchema;

    /// The value used when the host builds a template input.
    fn capability_placeholder() -> Self;

    /// Whether a field of this type may be omitted. Defaults to required.
    fn capability_is_optional() -> bool {
        false
    }
}

impl CapabilitySchemaValue for String {
    fn capability_schema() -> JsonSchema {
        capsule_schema::string(None, None, None)
    }
    fn capability_placeholder() -> Self {
        String::new()
    }
}

impl CapabilitySchemaValue for bool {
    fn capability_schema() -> JsonSchema {
        capsule_schema::boolean()
    }
    fn capability_placeholder() -> Self {
        false
    }
}

impl CapabilitySchemaValue for i64 {
    fn capability_schema() -> JsonSchema {
        capsule_schema::integer(None, None, None)
    }
    fn capability_placeholder() -> Self {
        0
    }
}

impl CapabilitySchemaValue for f32 {
    fn capability_schema() -> JsonSchema {
        capsule_schema::number(None, None, None)
    }
    fn capability_placeholder() -> Self {
        0.0
    }
}

impl CapabilitySchemaValue for f64 {
    fn capability_schema() -> JsonSchema {
        capsule_schema::number(None, None, None)
    }
    fn capability_placeholder() -> Self {
        0.0
    }
}

impl<T: CapabilitySchemaValue> CapabilitySchemaValue for Option<T> {
    fn capability_schema() -> JsonSchema {
        T::capability_schema()
    }
    fn capability_placeholder() -> Self {
        None
    }
    /// An optional field is never listed as required.
    fn capability_is_optional() -> bool {
        true
    }
}

impl<T: CapabilitySchemaValue> CapabilitySchemaValue for Vec<T> {
    fn capability_schema() -> JsonSchema {
        capsule_schema::array(T::capability_schema(), None, None, None)
    }
    fn capability_placeholder() -> Self {
        Vec::new()
    }
}

/// Why a declared reference or vector was rejected.
#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum CapabilityInputError {
    #[error("invalid scene reference: {0}")]
    InvalidSceneReference(String),
    #[error("expected {expected} elements, found {actual}")]
    InvalidElementCount { expected: usize, actual: usize },
    #[error("invalid range for {field}: {message}")]
    InvalidRange { field: String, message: String },
}

/// A validated `scene:<number>` reference.
///
/// Encoded as a bare JSON string, and both the advertised schema and the decoder reject
/// a malformed reference — so a model cannot smuggle a non-entity through this field.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct SceneEntityRef(String);

impl SceneEntityRef {
    /// Parse and validate; `scene:` followed by ASCII digits.
    pub fn parse(raw: &str) -> Result<Self, CapabilityInputError> {
        let Some(digits) = raw.strip_prefix("scene:") else {
            return Err(CapabilityInputError::InvalidSceneReference(raw.to_string()));
        };
        if digits.is_empty() || !digits.bytes().all(|byte| byte.is_ascii_digit()) {
            return Err(CapabilityInputError::InvalidSceneReference(raw.to_string()));
        }
        Ok(SceneEntityRef(raw.to_string()))
    }

    #[inline]
    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// The numeric entity id.
    pub fn entity_id(&self) -> u64 {
        // `parse` guarantees a non-empty digit run, so this cannot fail.
        self.0
            .strip_prefix("scene:")
            .and_then(|digits| digits.parse().ok())
            .unwrap_or(0)
    }
}

impl TryFrom<String> for SceneEntityRef {
    type Error = CapabilityInputError;

    fn try_from(value: String) -> Result<Self, Self::Error> {
        SceneEntityRef::parse(&value)
    }
}

impl From<SceneEntityRef> for String {
    fn from(value: SceneEntityRef) -> Self {
        value.0
    }
}

impl CapabilitySchemaValue for SceneEntityRef {
    fn capability_schema() -> JsonSchema {
        capsule_schema::string_pattern(
            Some("Entity reference in scene:<number> format."),
            Some(7),
            Some(32),
            Some(r"^scene:[0-9]+$"),
        )
    }
    fn capability_placeholder() -> Self {
        SceneEntityRef("scene:0".to_string())
    }
}

/// A two-component vector, encoded as a JSON array of exactly two numbers.
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "Vec<f64>", into = "Vec<f64>")]
pub struct Vec2 {
    pub x: f64,
    pub y: f64,
}

impl Vec2 {
    pub fn new(x: f64, y: f64) -> Self {
        Vec2 { x, y }
    }
}

impl TryFrom<Vec<f64>> for Vec2 {
    type Error = CapabilityInputError;
    fn try_from(values: Vec<f64>) -> Result<Self, Self::Error> {
        if values.len() != 2 {
            return Err(CapabilityInputError::InvalidElementCount {
                expected: 2,
                actual: values.len(),
            });
        }
        Ok(Vec2 {
            x: values[0],
            y: values[1],
        })
    }
}

impl From<Vec2> for Vec<f64> {
    fn from(value: Vec2) -> Self {
        vec![value.x, value.y]
    }
}

impl CapabilitySchemaValue for Vec2 {
    fn capability_schema() -> JsonSchema {
        capsule_schema::array(
            capsule_schema::number(None, None, None),
            None,
            Some(2),
            Some(2),
        )
    }
    fn capability_placeholder() -> Self {
        Vec2::default()
    }
}

/// A three-component vector, encoded as a JSON array of exactly three numbers.
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "Vec<f64>", into = "Vec<f64>")]
pub struct Vec3 {
    pub x: f64,
    pub y: f64,
    pub z: f64,
}

impl Vec3 {
    pub fn new(x: f64, y: f64, z: f64) -> Self {
        Vec3 { x, y, z }
    }
}

impl TryFrom<Vec<f64>> for Vec3 {
    type Error = CapabilityInputError;
    fn try_from(values: Vec<f64>) -> Result<Self, Self::Error> {
        if values.len() != 3 {
            return Err(CapabilityInputError::InvalidElementCount {
                expected: 3,
                actual: values.len(),
            });
        }
        Ok(Vec3 {
            x: values[0],
            y: values[1],
            z: values[2],
        })
    }
}

impl From<Vec3> for Vec<f64> {
    fn from(value: Vec3) -> Self {
        vec![value.x, value.y, value.z]
    }
}

impl CapabilitySchemaValue for Vec3 {
    fn capability_schema() -> JsonSchema {
        capsule_schema::array(
            capsule_schema::number(None, None, None),
            None,
            Some(3),
            Some(3),
        )
    }
    fn capability_placeholder() -> Self {
        Vec3::default()
    }
}

/// A four-component vector, encoded as a JSON array of exactly four numbers.
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "Vec<f64>", into = "Vec<f64>")]
pub struct Vec4 {
    pub x: f64,
    pub y: f64,
    pub z: f64,
    pub w: f64,
}

impl Vec4 {
    pub fn new(x: f64, y: f64, z: f64, w: f64) -> Self {
        Vec4 { x, y, z, w }
    }
}

impl TryFrom<Vec<f64>> for Vec4 {
    type Error = CapabilityInputError;
    fn try_from(values: Vec<f64>) -> Result<Self, Self::Error> {
        if values.len() != 4 {
            return Err(CapabilityInputError::InvalidElementCount {
                expected: 4,
                actual: values.len(),
            });
        }
        Ok(Vec4 {
            x: values[0],
            y: values[1],
            z: values[2],
            w: values[3],
        })
    }
}

impl From<Vec4> for Vec<f64> {
    fn from(value: Vec4) -> Self {
        vec![value.x, value.y, value.z, value.w]
    }
}

impl CapabilitySchemaValue for Vec4 {
    fn capability_schema() -> JsonSchema {
        capsule_schema::array(
            capsule_schema::number(None, None, None),
            None,
            Some(4),
            Some(4),
        )
    }
    fn capability_placeholder() -> Self {
        Vec4::default()
    }
}

/// A component an entity reference requires to exist.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub enum SceneComponentRequirement {
    #[serde(rename = "LocalTransform")]
    LocalTransform,
    #[serde(rename = "RigidBody")]
    RigidBody,
    #[serde(rename = "Collider")]
    Collider,
    #[serde(rename = "LightComponent")]
    LightComponent,
    #[serde(rename = "CameraComponent")]
    CameraComponent,
    #[serde(rename = "RenderMeshComponent")]
    RenderMeshComponent,
    #[serde(rename = "PhysicsJoint")]
    PhysicsJoint,
}

/// One declared capability input field.
///
/// This replaces Swift's `AIField`/`ValueRange`/`EntityReference` property wrappers: a
/// field carries its own constraints next to its name.
#[derive(Clone, Debug)]
pub struct DeclaredField {
    pub name: String,
    pub schema: JsonSchema,
    pub is_optional: bool,
}

impl DeclaredField {
    pub fn new(name: impl Into<String>, schema: JsonSchema, is_optional: bool) -> Self {
        DeclaredField {
            name: name.into(),
            schema,
            is_optional,
        }
    }

    /// A field whose type decides its own schema and optionality.
    pub fn of<T: CapabilitySchemaValue>(name: impl Into<String>) -> Self {
        DeclaredField {
            name: name.into(),
            schema: T::capability_schema(),
            is_optional: T::capability_is_optional(),
        }
    }
}

/// An input type that declares its fields explicitly.
///
/// The closed-world guarantee is kept: a declared type builds an object schema with
/// `additional_properties: false`, and any field the caller forgets to declare is not
/// present at all — which fails validation rather than silently accepting a value.
pub trait DeclaredCapabilityInput {
    /// Every field, in the order the schema should list it.
    fn declared_fields() -> Vec<DeclaredField>;

    /// The object schema advertised for this input.
    fn input_schema() -> JsonSchema {
        let fields = Self::declared_fields();
        let mut properties = std::collections::BTreeMap::new();
        let mut required = Vec::new();
        for field in fields {
            if !field.is_optional {
                required.push(field.name.clone());
            }
            properties.insert(field.name, field.schema);
        }
        capsule_schema::object(properties, required, None, false)
    }
}

/// The schema used when a field was not declared: an open node.
///
/// Registration treats this as a failure, matching Swift's
/// `.any(description: "Undeclared capability input field.")`.
pub fn undeclared_field_schema() -> JsonSchema {
    let mut schema = JsonSchema::any();
    schema.description = Some("Undeclared capability input field.".to_string());
    schema
}

/// Validate that a numeric constraint is usable for the given schema type.
pub fn validate_range(
    field: &str,
    minimum: Option<f64>,
    maximum: Option<f64>,
) -> Result<(), CapabilityInputError> {
    if let (Some(minimum), Some(maximum)) = (minimum, maximum)
        && minimum > maximum
    {
        return Err(CapabilityInputError::InvalidRange {
            field: field.to_string(),
            message: format!("minimum {minimum} exceeds maximum {maximum}"),
        });
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_scene_reference_rejects_a_bare_number() {
        assert_eq!(
            SceneEntityRef::parse("42"),
            Err(CapabilityInputError::InvalidSceneReference(
                "42".to_string()
            ))
        );
    }

    #[test]
    fn a_scene_reference_rejects_non_digits() {
        assert!(SceneEntityRef::parse("scene:abc").is_err());
        assert!(SceneEntityRef::parse("scene:").is_err());
        assert!(SceneEntityRef::parse("scene:1a").is_err());
    }

    #[test]
    fn a_valid_scene_reference_reports_its_id() {
        let reference = SceneEntityRef::parse("scene:123").expect("valid");
        assert_eq!(reference.entity_id(), 123);
        assert_eq!(reference.as_str(), "scene:123");
    }

    #[test]
    fn a_scene_reference_encodes_as_a_bare_string() {
        let reference = SceneEntityRef::parse("scene:7").expect("valid");
        assert_eq!(
            serde_json::to_string(&reference).expect("serialize"),
            "\"scene:7\""
        );
    }

    #[test]
    fn a_scene_reference_decodes_from_a_bare_string() {
        let reference: SceneEntityRef = serde_json::from_str("\"scene:9\"").expect("deserialize");
        assert_eq!(reference.entity_id(), 9);
        assert!(serde_json::from_str::<SceneEntityRef>("\"nope\"").is_err());
    }

    #[test]
    fn vectors_encode_as_bare_arrays() {
        assert_eq!(
            serde_json::to_string(&Vec2::new(1.0, 2.0)).expect("serialize"),
            "[1.0,2.0]"
        );
        assert_eq!(
            serde_json::to_string(&Vec3::new(1.0, 2.0, 3.0)).expect("serialize"),
            "[1.0,2.0,3.0]"
        );
        assert_eq!(
            serde_json::to_string(&Vec4::new(1.0, 2.0, 3.0, 4.0)).expect("serialize"),
            "[1.0,2.0,3.0,4.0]"
        );
    }

    #[test]
    fn a_vector_with_the_wrong_element_count_is_rejected() {
        assert!(
            serde_json::from_str::<Vec3>("[1.0,2.0]")
                .unwrap_err()
                .to_string()
                .contains('3')
        );
        assert!(serde_json::from_str::<Vec2>("[1.0,2.0,3.0]").is_err());
    }

    #[test]
    fn an_option_field_is_never_required() {
        assert!(<Option<String> as CapabilitySchemaValue>::capability_is_optional());
        assert!(!<String as CapabilitySchemaValue>::capability_is_optional());
    }

    #[test]
    fn a_declared_input_lists_only_required_non_optional_fields() {
        struct Input;
        impl DeclaredCapabilityInput for Input {
            fn declared_fields() -> Vec<DeclaredField> {
                vec![
                    DeclaredField::of::<SceneEntityRef>("entity"),
                    DeclaredField::of::<Option<String>>("name"),
                    DeclaredField::of::<f64>("mass"),
                ]
            }
        }

        let schema = Input::input_schema();
        let json = serde_json::to_value(&schema).expect("serialize");
        let required: Vec<&str> = json["required"]
            .as_array()
            .expect("required")
            .iter()
            .filter_map(|value| value.as_str())
            .collect();
        assert_eq!(required, vec!["entity", "mass"], "name is optional");
        // The field is not renamed in `cove_agent`, so it serializes snake_case.
        assert_eq!(json["additional_properties"], serde_json::json!(false));
    }

    #[test]
    fn an_inverted_range_is_rejected() {
        assert!(validate_range("mass", Some(10.0), Some(1.0)).is_err());
        assert!(validate_range("mass", Some(1.0), Some(10.0)).is_ok());
        assert!(validate_range("mass", None, None).is_ok());
    }

    #[test]
    fn component_requirements_use_their_swift_raw_values() {
        assert_eq!(
            serde_json::to_string(&SceneComponentRequirement::LocalTransform).expect("serialize"),
            "\"LocalTransform\""
        );
        assert_eq!(
            serde_json::to_string(&SceneComponentRequirement::PhysicsJoint).expect("serialize"),
            "\"PhysicsJoint\""
        );
    }
}
