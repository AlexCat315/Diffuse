//! `ComponentJSONHelpers.swift` — the JSON bridging used by the value codecs.
//!
//! Swift codecs produce `[String: Any]` and read it back with the `jsonTo…`
//! helpers, whose exact quirks matter for persisted documents:
//!
//! * `jsonToFloat` / `jsonToDouble` / `jsonToInt` accept any `NSNumber`, which in
//!   Swift includes booleans bridged to `1` / `0`. A `String` never converts.
//! * `jsonToBool` and `jsonToString` are strict — only a real `Bool` / `String`.
//! * `jsonToFloatArray` returns `nil` for a non-array and *drops* non-numeric
//!   entries for an array, so `[]` and `nil` stay different fallbacks.
//!
//! On the Rust side the same values are [`ComponentValue`] documents, which is
//! the persisted shape (MIGRATION.md §5.4); `encode_json_value` /
//! `decode_json_value` stand in for `JSONEncoder` / `JSONDecoder` on nested
//! `Codable` payloads.

use std::collections::BTreeMap;

use diffuse_math::simd::simd_compat::{Float3, Float4, Float4x4};
use serde::Serialize;
use serde::de::DeserializeOwned;

use crate::components::core::value::ComponentValue;

/// Swift `vec3ToJSON` — a component document object value, not a JSON string.
pub fn vec3_to_json(value: Float3) -> ComponentValue {
    ComponentValue::Array(vec![
        ComponentValue::Number(value.x as f64),
        ComponentValue::Number(value.y as f64),
        ComponentValue::Number(value.z as f64),
    ])
}

/// Swift `vec4ToJSON`.
pub fn vec4_to_json(value: Float4) -> ComponentValue {
    ComponentValue::Array(vec![
        ComponentValue::Number(value.x as f64),
        ComponentValue::Number(value.y as f64),
        ComponentValue::Number(value.z as f64),
        ComponentValue::Number(value.w as f64),
    ])
}

/// Swift `matrixToJSON` — flat, column-major, sixteen entries.
pub fn matrix_to_json(matrix: &Float4x4) -> ComponentValue {
    let mut values = Vec::with_capacity(16);
    for column in &matrix.columns {
        values.push(ComponentValue::Number(column.x as f64));
        values.push(ComponentValue::Number(column.y as f64));
        values.push(ComponentValue::Number(column.z as f64));
        values.push(ComponentValue::Number(column.w as f64));
    }
    ComponentValue::Array(values)
}

/// Swift `jsonToMatrix` — exactly sixteen values, otherwise `nil`.
pub fn json_to_matrix(values: &[f32]) -> Option<Float4x4> {
    if values.len() != 16 {
        return None;
    }
    Some(Float4x4::from_columns([
        Float4::new(values[0], values[1], values[2], values[3]),
        Float4::new(values[4], values[5], values[6], values[7]),
        Float4::new(values[8], values[9], values[10], values[11]),
        Float4::new(values[12], values[13], values[14], values[15]),
    ]))
}

/// Swift `jsonToVec3` — exactly three values, otherwise `nil`.
pub fn json_to_vec3(values: &[f32]) -> Option<Float3> {
    if values.len() == 3 {
        Some(Float3::new(values[0], values[1], values[2]))
    } else {
        None
    }
}

/// Swift `jsonToVec4` — exactly four values, otherwise `nil`.
pub fn json_to_vec4(values: &[f32]) -> Option<Float4> {
    if values.len() == 4 {
        Some(Float4::new(values[0], values[1], values[2], values[3]))
    } else {
        None
    }
}

/// Swift `jsonToFloat` — `(val as? NSNumber).map { Float(truncating: $0) }`.
///
/// A bridged boolean is an `NSNumber` in Swift, so it converts to `1` / `0`.
pub fn json_to_float(value: Option<&ComponentValue>) -> Option<f32> {
    match value? {
        ComponentValue::Number(number) => Some(*number as f32),
        ComponentValue::SignedInteger(number) => Some(*number as f32),
        ComponentValue::UnsignedInteger(number) => Some(*number as f32),
        ComponentValue::Bool(value) => Some(if *value { 1.0 } else { 0.0 }),
        ComponentValue::Null
        | ComponentValue::String(_)
        | ComponentValue::Array(_)
        | ComponentValue::Object(_) => None,
    }
}

/// Swift `jsonToDouble`.
pub fn json_to_double(value: Option<&ComponentValue>) -> Option<f64> {
    match value? {
        ComponentValue::Number(number) => Some(*number),
        ComponentValue::SignedInteger(number) => Some(*number as f64),
        ComponentValue::UnsignedInteger(number) => Some(*number as f64),
        ComponentValue::Bool(value) => Some(if *value { 1.0 } else { 0.0 }),
        ComponentValue::Null
        | ComponentValue::String(_)
        | ComponentValue::Array(_)
        | ComponentValue::Object(_) => None,
    }
}

/// Swift `jsonToBool` — strict: only a real boolean.
pub fn json_to_bool(value: Option<&ComponentValue>) -> Option<bool> {
    match value? {
        ComponentValue::Bool(value) => Some(*value),
        _ => None,
    }
}

/// Swift `jsonToString` — strict: only a real string.
pub fn json_to_string(value: Option<&ComponentValue>) -> Option<&str> {
    match value? {
        ComponentValue::String(value) => Some(value.as_str()),
        _ => None,
    }
}

/// Swift `jsonToInt` — `(val as? NSNumber).map { Int(truncating: $0) }`.
///
/// Rust's `as` conversion truncates toward zero and saturates where Swift traps;
/// every persisted caller writes in-range values.
pub fn json_to_int(value: Option<&ComponentValue>) -> Option<i64> {
    match value? {
        ComponentValue::Number(number) => Some(*number as i64),
        ComponentValue::SignedInteger(number) => Some(*number),
        ComponentValue::UnsignedInteger(number) => i64::try_from(*number).ok(),
        ComponentValue::Bool(value) => Some(if *value { 1 } else { 0 }),
        ComponentValue::Null
        | ComponentValue::String(_)
        | ComponentValue::Array(_)
        | ComponentValue::Object(_) => None,
    }
}

/// Swift `jsonToDict`.
pub fn json_to_dict(value: Option<&ComponentValue>) -> Option<&BTreeMap<String, ComponentValue>> {
    match value? {
        ComponentValue::Object(values) => Some(values),
        _ => None,
    }
}

/// Swift `jsonToArray`.
pub fn json_to_array(value: Option<&ComponentValue>) -> Option<&[ComponentValue]> {
    match value? {
        ComponentValue::Array(values) => Some(values.as_slice()),
        _ => None,
    }
}

/// Swift `jsonToStringFloatDict` — non-numeric entries are dropped, a non-object
/// is `nil`.
pub fn json_to_string_float_dict(
    value: Option<&ComponentValue>,
) -> Option<BTreeMap<String, f32>> {
    let values = json_to_dict(value)?;
    let mut result = BTreeMap::new();
    for (key, value) in values {
        if let Some(number) = json_to_float(Some(value)) {
            result.insert(key.clone(), number);
        }
    }
    Some(result)
}

/// Swift `jsonToFloatArray` — `nil` for a non-array, non-numbers dropped for an
/// array.
pub fn json_to_float_array(value: Option<&ComponentValue>) -> Option<Vec<f32>> {
    let values = json_to_array(value)?;
    Some(
        values
            .iter()
            .filter_map(|value| json_to_float(Some(value)))
            .collect(),
    )
}

/// Swift `encodeJSONValue(_:)` — `JSONEncoder` followed by `JSONSerialization`.
pub fn encode_json_value<T: Serialize>(value: &T) -> Option<ComponentValue> {
    let json = serde_json::to_value(value).ok()?;
    Some(ComponentValue::from_json_value(&json))
}

/// Swift `decodeJSONValue(_:as:)` — requires a valid top-level JSON object or
/// array, then decodes `T` from it.
pub fn decode_json_value<T: DeserializeOwned>(value: Option<&ComponentValue>) -> Option<T> {
    let value = value?;
    if !matches!(
        value,
        ComponentValue::Array(_) | ComponentValue::Object(_)
    ) || !value.is_finite_json()
    {
        return None;
    }
    let json = value.to_json_value();
    let data = serde_json::to_vec(&json).ok()?;
    serde_json::from_slice::<T>(&data).ok()
}

/// A component document object, used by the serializers in place of Swift's
/// `var d: [String: Any]`.
pub fn object(
    entries: impl IntoIterator<Item = (&'static str, ComponentValue)>,
) -> BTreeMap<String, ComponentValue> {
    entries
        .into_iter()
        .map(|(key, value)| (key.to_string(), value))
        .collect()
}

/// Swift `ComponentValue(jsonObject:)` for a `Float` value.
#[inline]
pub fn number(value: f32) -> ComponentValue {
    ComponentValue::Number(value as f64)
}

/// Swift `ComponentValue(jsonObject:)` for a `Double` value.
#[inline]
pub fn double(value: f64) -> ComponentValue {
    ComponentValue::Number(value)
}

/// Swift `ComponentValue(jsonObject:)` for an `Int` value — the document keeps it
/// as a number, exactly like `NSNumber`.
#[inline]
pub fn integer(value: i64) -> ComponentValue {
    ComponentValue::Number(value as f64)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn array(values: Vec<f32>) -> ComponentValue {
        ComponentValue::Array(values.into_iter().map(number).collect())
    }

    #[test]
    fn int_conversion_accepts_bridged_booleans() {
        assert_eq!(json_to_int(Some(&ComponentValue::Bool(true))), Some(1));
        assert_eq!(json_to_float(Some(&ComponentValue::Bool(false))), Some(0.0));
        assert_eq!(json_to_bool(Some(&ComponentValue::Number(1.0))), None);
        assert_eq!(json_to_string(Some(&ComponentValue::Number(1.0))), None);
    }

    #[test]
    fn float_array_drops_non_numbers_but_keeps_empty_arrays_distinct() {
        let mixed = ComponentValue::Array(vec![
            number(1.0),
            ComponentValue::String("x".to_string()),
            ComponentValue::Bool(true),
        ]);
        assert_eq!(json_to_float_array(Some(&mixed)), Some(vec![1.0, 1.0]));
        assert_eq!(
            json_to_float_array(Some(&ComponentValue::Array(Vec::new()))),
            Some(Vec::new())
        );
        assert_eq!(json_to_float_array(Some(&ComponentValue::Null)), None);
    }

    #[test]
    fn matrix_round_trips_column_major() {
        let matrix = Float4x4::from_columns([
            Float4::new(1.0, 2.0, 3.0, 4.0),
            Float4::new(5.0, 6.0, 7.0, 8.0),
            Float4::new(9.0, 10.0, 11.0, 12.0),
            Float4::new(13.0, 14.0, 15.0, 16.0),
        ]);
        let encoded = matrix_to_json(&matrix);
        let values = match &encoded {
            ComponentValue::Array(values) => values
                .iter()
                .map(|value| json_to_float(Some(value)).expect("number"))
                .collect::<Vec<_>>(),
            other => panic!("expected array, got {other:?}"),
        };
        assert_eq!(json_to_matrix(&values), Some(matrix));
        assert_eq!(json_to_matrix(&values[..15]), None);
    }

    #[test]
    fn vec3_and_vec4_require_exact_lengths() {
        assert_eq!(json_to_vec3(&[1.0, 2.0]), None);
        assert_eq!(json_to_vec4(&[1.0, 2.0, 3.0]), None);
        assert_eq!(
            json_to_vec3(&[1.0, 2.0, 3.0]),
            Some(Float3::new(1.0, 2.0, 3.0))
        );
        assert_eq!(json_to_vec4(&[1.0; 4]), Some(Float4::new(1.0, 1.0, 1.0, 1.0)));
    }

    #[test]
    fn encoded_values_round_trip_through_decode() {
        let encoded = encode_json_value(&vec![1.0f32, 2.5]).expect("encoded");
        let decoded: Vec<f32> = decode_json_value(Some(&encoded)).expect("decoded");
        assert_eq!(decoded, vec![1.0, 2.5]);
        assert_eq!(decode_json_value::<Vec<f32>>(Some(&array(vec![1.0]))), None);
    }

    #[test]
    fn string_float_dict_skips_non_numbers() {
        let mut dict = BTreeMap::new();
        dict.insert("speed".to_string(), number(2.0));
        dict.insert("name".to_string(), ComponentValue::String("x".to_string()));
        let value = ComponentValue::Object(dict);
        let decoded = json_to_string_float_dict(Some(&value)).expect("dict");
        assert_eq!(decoded.len(), 1);
        assert_eq!(decoded.get("speed"), Some(&2.0));
    }
}
