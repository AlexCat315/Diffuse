//! Boolean identity for decoded JSON values.
//!
//! Swift needed `NSNumber.isBoolean` because `JSONSerialization` boxes both
//! booleans and numbers as `NSNumber`. A `serde_json::Value` already keeps the
//! distinction, so this module exposes the same predicate over that model.

use serde_json::Value;

/// Whether the value wraps a boolean rather than a numeric value.
pub fn is_boolean(value: &Value) -> bool {
    matches!(value, Value::Bool(_))
}

/// Reads the boolean payload without treating `0`/`1` as `false`/`true`.
pub fn boolean_value(value: &Value) -> Option<bool> {
    match value {
        Value::Bool(value) => Some(*value),
        _ => None,
    }
}

/// Swift's `NSNumber.boolValue` equivalent for decoded values: only booleans are
/// accepted, numbers are rejected.
pub trait BooleanNumber {
    fn is_boolean(&self) -> bool;
}

impl BooleanNumber for Value {
    fn is_boolean(&self) -> bool {
        is_boolean(self)
    }
}
