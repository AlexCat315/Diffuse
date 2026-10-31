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
