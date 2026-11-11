//! JSON Schema vocabulary for capability contracts.
//!
//! Swift's `JSONSchema` (CoveUI's `CoveUIAgentCore/Contracts/Schema.swift`) and
//! Cove's Rust `JsonSchema` carry the same JSON but differ in two places:
//! Swift stores `items` as an array and keeps `description`/`allowedValues` as
//! struct fields, while the Rust type has a single optional `items` and
//! builder methods without a description parameter. MIGRATION.md §5.2 keeps the
//! Swift call shape, so this module wraps the Cove type instead of duplicating
//! schema validation.

pub use cove_agent::{JsonSchemaScalar, JsonSchemaType, JsonSchemaValidator, JsonSchemaViolation};

/// The Cove JSON Schema, re-exported so capability code names one type.
pub use cove_agent::JsonSchema;

/// `JSONSchema.string(description:minLength:maxLength:pattern:)`.
pub fn string(
    description: Option<&str>,
    min_length: Option<usize>,
    max_length: Option<usize>,
) -> JsonSchema {
    let mut schema = JsonSchema::string(min_length, max_length);
    schema.description = description.map(str::to_string);
    schema
}

/// `JSONSchema.string(description:pattern:)`.
pub fn string_pattern(
    description: Option<&str>,
    min_length: Option<usize>,
    max_length: Option<usize>,
    pattern: Option<&str>,
) -> JsonSchema {
    let mut schema = string(description, min_length, max_length);
    schema.pattern = pattern.map(str::to_string);
    schema
}

/// `JSONSchema.string(description:allowedValues:)`.
pub fn string_enum(description: Option<&str>, allowed: &[&str]) -> JsonSchema {
    let mut schema = JsonSchema::string(None, None);
    schema.description = description.map(str::to_string);
    schema.allowed_values = allowed
        .iter()
        .map(|value| JsonSchemaScalar::String((*value).to_string()))
        .collect();
    schema
}

/// `JSONSchema.number(description:minimum:maximum:)`.
pub fn number(description: Option<&str>, minimum: Option<f64>, maximum: Option<f64>) -> JsonSchema {
    let mut schema = JsonSchema::number(minimum, maximum);
    schema.description = description.map(str::to_string);
    schema
}

/// `JSONSchema.integer(description:minimum:maximum:)`.
pub fn integer(
    description: Option<&str>,
    minimum: Option<i64>,
    maximum: Option<i64>,
) -> JsonSchema {
    let mut schema = JsonSchema::integer(
        minimum.map(|value| value as f64),
        maximum.map(|value| value as f64),
    );
    schema.description = description.map(str::to_string);
    schema
}

/// `JSONSchema.boolean()`.
pub fn boolean() -> JsonSchema {
    JsonSchema::boolean()
}

/// `JSONSchema.boolean(description:)`.
pub fn boolean_described(description: Option<&str>) -> JsonSchema {
    let mut schema = JsonSchema::boolean();
    schema.description = description.map(str::to_string);
    schema
}

/// `JSONSchema.null()`.
pub fn null() -> JsonSchema {
    JsonSchema::null()
}

/// `JSONSchema.array(of:description:minimumItems:maximumItems:)`.
pub fn array(
    item: JsonSchema,
    description: Option<&str>,
    minimum_items: Option<usize>,
    maximum_items: Option<usize>,
) -> JsonSchema {
    let mut schema = JsonSchema::array_of(item, maximum_items);
    schema.description = description.map(str::to_string);
    schema.minimum_items = minimum_items;
    schema
}

/// `JSONSchema.object(properties:required:description:additionalProperties:)`.
pub fn object(
    properties: std::collections::BTreeMap<String, JsonSchema>,
    required: Vec<String>,
    description: Option<&str>,
    additional_properties: bool,
) -> JsonSchema {
    let mut schema = JsonSchema::object(properties, required);
    schema.description = description.map(str::to_string);
    schema.additional_properties = Some(additional_properties);
    schema
}

/// `JSONSchema.object(properties:)` with no required keys.
pub fn empty_object() -> JsonSchema {
    object(std::collections::BTreeMap::new(), Vec::new(), None, false)
}

/// `JSONSchema.choice([...])`.
pub fn choice(alternatives: Vec<JsonSchema>) -> JsonSchema {
    JsonSchema::choice(alternatives)
}

/// The entity-reference pattern every scene capability declares.
const SCENE_REFERENCE_PATTERN: &str = "^scene:[0-9]+$";

/// Validates capability input against `schema`.
///
/// Swift's `JSONSchemaValidator` evaluates regex patterns. Cove's only matches a
/// literal pattern and one identifier pattern, so the scene-reference pattern is
/// checked here and removed from the copy delegated to Cove. Every Diffuse
/// validation path uses this function; see `.migration/cove-gaps.md` G10.
pub fn validate_capability_input(
    value: &serde_json::Value,
    schema: &JsonSchema,
) -> Result<(), JsonSchemaViolation> {
    let mut delegated = schema.clone();
    strip_scene_reference_patterns(&mut delegated);
    check_scene_references(value, schema, "$")?;
    JsonSchemaValidator::validate(value, &delegated)
}

fn strip_scene_reference_patterns(schema: &mut JsonSchema) {
    if schema.pattern.as_deref() == Some(SCENE_REFERENCE_PATTERN) {
        schema.pattern = None;
    }
    for property in schema.properties.values_mut() {
        strip_scene_reference_patterns(property);
    }
    if let Some(items) = schema.items.as_deref_mut() {
        strip_scene_reference_patterns(items);
    }
    for alternative in &mut schema.one_of {
        strip_scene_reference_patterns(alternative);
    }
}

/// Outcome of walking one schema position for the scene-reference pattern.
enum PatternCheck {
    /// The schema at this position does not carry the pattern.
    NotApplicable,
    /// A patterned position matched, or every patterned position did.
    Satisfied,
    /// A patterned position did not match and no alternative satisfied it.
    Violated(JsonSchemaViolation),
}

/// Checks the scene-reference pattern at the same positions Cove would. The
/// structural checks stay with Cove; this walk only reports a pattern failure.
fn check_scene_references(
    value: &serde_json::Value,
    schema: &JsonSchema,
    path: &str,
) -> Result<(), JsonSchemaViolation> {
    match scene_reference_check(value, schema, path) {
        PatternCheck::Violated(error) => Err(error),
        PatternCheck::NotApplicable | PatternCheck::Satisfied => Ok(()),
    }
}

fn scene_reference_check(
    value: &serde_json::Value,
    schema: &JsonSchema,
    path: &str,
) -> PatternCheck {
    if !schema.one_of.is_empty() {
        let mut satisfied = false;
        let mut violation = None;
        for alternative in &schema.one_of {
            match scene_reference_check(value, alternative, path) {
                PatternCheck::Satisfied => satisfied = true,
                PatternCheck::Violated(error) => {
                    violation.get_or_insert(error);
                }
                PatternCheck::NotApplicable => {}
            }
        }
        // An alternative that carries no pattern cannot excuse a value the
        // patterned alternative rejects: `choice([string(pattern), null])` must
        // still reject `"nope"`.
        if satisfied {
            return PatternCheck::Satisfied;
        }
        if let Some(error) = violation {
            return PatternCheck::Violated(error);
        }
        return PatternCheck::NotApplicable;
    }
    match value {
        serde_json::Value::Object(object) => {
            let mut satisfied = false;
            for (key, child) in object {
                if let Some(child_schema) = schema.properties.get(key) {
                    match scene_reference_check(child, child_schema, &format!("{path}.{key}")) {
                        PatternCheck::Satisfied => satisfied = true,
                        PatternCheck::Violated(error) => return PatternCheck::Violated(error),
                        PatternCheck::NotApplicable => {}
                    }
                }
            }
            if satisfied {
                PatternCheck::Satisfied
            } else {
                PatternCheck::NotApplicable
            }
        }
        serde_json::Value::Array(values) => {
            let Some(items) = &schema.items else {
                return PatternCheck::NotApplicable;
            };
            let mut satisfied = false;
            for (index, child) in values.iter().enumerate() {
                match scene_reference_check(child, items, &format!("{path}[{index}]")) {
                    PatternCheck::Satisfied => satisfied = true,
                    PatternCheck::Violated(error) => return PatternCheck::Violated(error),
                    PatternCheck::NotApplicable => {}
                }
            }
            if satisfied {
                PatternCheck::Satisfied
            } else {
                PatternCheck::NotApplicable
            }
        }
        serde_json::Value::String(string)
            if schema.pattern.as_deref() == Some(SCENE_REFERENCE_PATTERN) =>
        {
            let valid = string.strip_prefix("scene:").is_some_and(|digits| {
                !digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit())
            });
            if valid {
                PatternCheck::Satisfied
            } else {
                PatternCheck::Violated(JsonSchemaViolation {
                    path: path.to_string(),
                    reason: "does not match required pattern".to_string(),
                })
            }
        }
        _ => PatternCheck::NotApplicable,
    }
}

#[cfg(test)]
mod tests {
    use super::{JsonSchema, SCENE_REFERENCE_PATTERN, string_pattern, validate_capability_input};

    fn scene_schema() -> JsonSchema {
        string_pattern(None, Some(7), Some(32), Some(SCENE_REFERENCE_PATTERN))
    }

    #[test]
    fn scene_references_match_the_swift_pattern() {
        for reference in ["scene:0", "scene:1", "scene:123"] {
            validate_capability_input(&serde_json::json!(reference), &scene_schema())
                .unwrap_or_else(|error| panic!("{reference} rejected: {error}"));
        }
    }

    #[test]
    fn malformed_scene_references_are_rejected() {
        for reference in ["1", "scene:", "scene:1a", "scene:-1", "Scene:1"] {
            let error = validate_capability_input(&serde_json::json!(reference), &scene_schema())
                .expect_err(reference);
            assert_eq!(error.path, "$");
            assert_eq!(error.reason, "does not match required pattern");
        }
    }

    #[test]
    fn scene_references_inside_objects_report_their_path() {
        let mut properties = std::collections::BTreeMap::new();
        properties.insert("entity_id".to_string(), scene_schema());
        let schema = super::object(properties, vec!["entity_id".to_string()], None, false);
        let error = validate_capability_input(&serde_json::json!({"entity_id": "nope"}), &schema)
            .expect_err("invalid reference");
        assert_eq!(error.path, "$.entity_id");
    }

    #[test]
    fn optional_scene_references_still_reject_malformed_strings() {
        let schema = super::choice(vec![scene_schema(), super::null()]);
        validate_capability_input(&serde_json::json!(null), &schema).expect("null is allowed");
        validate_capability_input(&serde_json::json!("scene:7"), &schema)
            .expect("valid reference is allowed");
        let error = validate_capability_input(&serde_json::json!("nope"), &schema)
            .expect_err("invalid reference inside choice");
        assert_eq!(error.path, "$");
        assert_eq!(error.reason, "does not match required pattern");
    }

    #[test]
    fn optional_object_properties_reject_malformed_scene_references() {
        let mut properties = std::collections::BTreeMap::new();
        properties.insert("entity_id".to_string(), scene_schema());
        let schema = super::object(properties, Vec::new(), None, false);
        validate_capability_input(&serde_json::json!({"entity_id": null}), &schema)
            .expect("null is allowed");
        let error = validate_capability_input(&serde_json::json!({"entity_id": "nope"}), &schema)
            .expect_err("invalid optional reference");
        assert_eq!(error.path, "$.entity_id");
    }
}
