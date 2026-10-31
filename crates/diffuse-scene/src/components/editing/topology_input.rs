//! Vertex-index normalization for deformable topology edits.
//!
//! `Components/Editing/TopologyInput.swift` extends `BuiltinComponentCodecs` with
//! `normalizeClothChanges` / `normalizeSoftBodyMeshChanges`. Both are document
//! transformations over [`ComponentValue`]: they validate `fixedVertexIndices`
//! against the decoded component and canonicalize whitespace in `resourceID`.
//!
//! The decoding half (`deserializeCloth`, `deserializeSoftBodyMesh`) belongs to the
//! codec batch; this module provides the closed validation and normalization rules
//! that the codecs call.

use crate::components::core::value::ComponentValue;
use crate::components::editing::ComponentEditError;

/// Swift `validateVertexIndices` — the value must decode as `[Int]`.
pub fn validate_vertex_indices(
    value: Option<&ComponentValue>,
    type_id: &str,
) -> Result<(), ComponentEditError> {
    let Some(value) = value else {
        return Err(ComponentEditError::InvalidValue(type_id.to_string()));
    };
    match value {
        ComponentValue::Array(values) => {
            if values.iter().all(is_integer_value) {
                Ok(())
            } else {
                Err(ComponentEditError::InvalidValue(type_id.to_string()))
            }
        }
        _ => Err(ComponentEditError::InvalidValue(type_id.to_string())),
    }
}

fn is_integer_value(value: &ComponentValue) -> bool {
    match value {
        ComponentValue::SignedInteger(_) => true,
        ComponentValue::UnsignedInteger(value) => i64::try_from(*value).is_ok(),
        // Swift decodes `[Int]` from a JSON number, which also accepts an integral
        // `Double` such as `3.0`.
        ComponentValue::Number(value) => {
            value.is_finite()
                && value.fract() == 0.0
                && *value >= i64::MIN as f64
                && *value <= i64::MAX as f64
        }
        _ => false,
    }
}

/// Encodes a validated index list the way Swift writes it: signed integers.
pub fn vertex_indices_value(indices: &[i64]) -> ComponentValue {
    ComponentValue::Array(
        indices
            .iter()
            .map(|index| ComponentValue::SignedInteger(*index))
            .collect(),
    )
}

/// Swift `normalizeSoftBodyMeshChanges`'s `resourceID` rule: trim surrounding
/// whitespace, and replace an empty result with `null`.
pub fn normalize_resource_id(value: Option<&ComponentValue>) -> Option<ComponentValue> {
    let ComponentValue::String(resource) = value? else {
        return None;
    };
    let trimmed = resource.trim_matches(|character: char| character.is_whitespace());
    Some(if trimmed.is_empty() {
        ComponentValue::Null
    } else {
        ComponentValue::String(trimmed.to_string())
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn integer_array_is_valid() {
        let value = ComponentValue::Array(vec![
            ComponentValue::SignedInteger(0),
            ComponentValue::Number(3.0),
        ]);
        assert!(validate_vertex_indices(Some(&value), "cloth").is_ok());
    }

    #[test]
    fn fractional_entry_is_invalid() {
        let value = ComponentValue::Array(vec![ComponentValue::Number(1.5)]);
        assert_eq!(
            validate_vertex_indices(Some(&value), "cloth"),
            Err(ComponentEditError::InvalidValue("cloth".to_string()))
        );
    }

    #[test]
    fn missing_value_is_invalid() {
        assert_eq!(
            validate_vertex_indices(None, "softBodyMesh"),
            Err(ComponentEditError::InvalidValue("softBodyMesh".to_string()))
        );
    }

    #[test]
    fn blank_resource_id_becomes_null() {
        assert_eq!(
            normalize_resource_id(Some(&ComponentValue::String("   ".to_string()))),
            Some(ComponentValue::Null)
        );
        assert_eq!(
            normalize_resource_id(Some(&ComponentValue::String("  meshA ".to_string()))),
            Some(ComponentValue::String("meshA".to_string()))
        );
    }
}
