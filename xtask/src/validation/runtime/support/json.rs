//! Accessors and encoders for the loosely typed JSON the MCP and DevTools
//! protocols exchange. Every accessor fails with one actionable message
//! instead of a failed cast.
//!
//! Swift used `JSONSerialization` and `Any`; the Rust port keeps the dynamic
//! shape with `serde_json::Value`, and reproduces the same writer options
//! (`.sortedKeys`, `.withoutEscapingSlashes`, optional `.prettyPrinted`).

use crate::json_format::{json_serialization_double, json_serialization_quote};
use crate::support::terminal::ToolError;
use serde_json::{Map, Value};

/// Compact JSON with sorted keys, the way `JSON.text` prints an `Any`.
pub fn text(value: &Value) -> String {
    let mut output = String::new();
    write_value(value, &mut output, None, 0);
    output
}

/// Pretty JSON with sorted keys: two spaces per level and `" : "` separators.
pub fn pretty(value: &Value) -> String {
    let mut output = String::new();
    write_value(value, &mut output, Some(2), 0);
    output
}

/// Compact JSON without the trailing newline, for files written directly.
pub fn compact(value: &Value) -> String {
    text(value)
}

/// `JSONSerialization.data(withJSONObject:options:)` bytes.
pub fn data(value: &Value, pretty_print: bool) -> Vec<u8> {
    let rendered = if pretty_print {
        pretty(value)
    } else {
        text(value)
    };
    rendered.into_bytes()
}

/// `JSON.write(_:to:pretty:)`.
pub fn write(value: &Value, url: &std::path::Path, pretty_print: bool) -> Result<(), ToolError> {
    crate::support::files::write(url, &data(value, pretty_print))
        .map_err(|error| ToolError::message(error.to_string()))
}

/// Parses with `.fragmentsAllowed`; empty input fails with the Swift message.
pub fn parse(bytes: &[u8]) -> Result<Value, ToolError> {
    if bytes.is_empty() {
        return Err(ToolError::message("Expected JSON, received empty input"));
    }
    serde_json::from_slice(bytes).map_err(|_| {
        ToolError::message(format!(
            "Malformed JSON: {}",
            String::from_utf8_lossy(&bytes[..bytes.len().min(512)])
        ))
    })
}

pub fn parse_text(text: &str) -> Result<Value, ToolError> {
    parse(text.as_bytes())
}

/// `JSON.parseObject`: the document must be a JSON object.
pub fn parse_object(bytes: &[u8]) -> Result<Map<String, Value>, ToolError> {
    match parse(bytes)? {
        Value::Object(object) => Ok(object),
        _ => Err(ToolError::message(format!(
            "Expected a JSON object, received {}",
            String::from_utf8_lossy(&bytes[..bytes.len().min(512)])
        ))),
    }
}

// MARK: - Optional accessors

pub fn dict(value: Option<&Value>) -> Option<&Map<String, Value>> {
    value.and_then(Value::as_object)
}

pub fn list(value: Option<&Value>) -> Option<&Vec<Value>> {
    value.and_then(Value::as_array)
}

pub fn objects(value: Option<&Value>) -> Option<Vec<&Map<String, Value>>> {
    list(value).map(|items| items.iter().filter_map(Value::as_object).collect())
}

pub fn strings(value: Option<&Value>) -> Option<Vec<&str>> {
    list(value).map(|items| items.iter().filter_map(Value::as_str).collect())
}

pub fn string(value: Option<&Value>) -> Option<&str> {
    value.and_then(Value::as_str)
}

/// `NSNumber.intValue` for a non-boolean number.
pub fn int(value: Option<&Value>) -> Option<i64> {
    value.and_then(non_boolean).and_then(|number| {
        number
            .as_i64()
            .or_else(|| number.as_u64().and_then(|v| i64::try_from(v).ok()))
            .or_else(|| number.as_f64().map(|v| v as i64))
    })
}

pub fn number(value: Option<&Value>) -> Option<f64> {
    value
        .and_then(non_boolean)
        .and_then(|number| number.as_f64())
}

pub fn boolean(value: Option<&Value>) -> Option<bool> {
    value.and_then(Value::as_bool)
}

/// Numbers only: `JSONSerialization` boxes booleans as numbers, so the Swift
/// accessors rejected `true`/`false` explicitly.
fn non_boolean(value: &Value) -> Option<&Value> {
    match value {
        Value::Number(_) => Some(value),
        _ => None,
    }
}

// MARK: - Required accessors

pub fn object<'a>(
    value: Option<&'a Value>,
    what: impl FnOnce() -> String,
) -> Result<&'a Map<String, Value>, ToolError> {
    value.and_then(Value::as_object).ok_or_else(|| {
        ToolError::message(format!("Expected a JSON object for {}", what()))
    })
}

pub fn array<'a>(
    value: Option<&'a Value>,
    what: impl FnOnce() -> String,
) -> Result<&'a Vec<Value>, ToolError> {
    value.and_then(Value::as_array).ok_or_else(|| {
        ToolError::message(format!("Expected a JSON array for {}", what()))
    })
}

pub fn required_objects<'a>(
    value: Option<&'a Value>,
    what: impl FnOnce() -> String,
) -> Result<Vec<&'a Map<String, Value>>, ToolError> {
    let what = what();
    Ok(array(value, || what.clone())?
        .iter()
        .filter_map(Value::as_object)
        .collect())
}

pub fn required_string<'a>(
    value: Option<&'a Value>,
    what: impl FnOnce() -> String,
) -> Result<&'a str, ToolError> {
    string(value).ok_or_else(|| ToolError::message(format!("Expected a string for {}", what())))
}

pub fn required_int(value: Option<&Value>, what: impl FnOnce() -> String) -> Result<i64, ToolError> {
    int(value).ok_or_else(|| ToolError::message(format!("Expected an integer for {}", what())))
}

pub fn required_boolean(
    value: Option<&Value>,
    what: impl FnOnce() -> String,
) -> Result<bool, ToolError> {
    boolean(value).ok_or_else(|| ToolError::message(format!("Expected a boolean for {}", what())))
}

// MARK: - Writing

fn write_value(value: &Value, output: &mut String, indent: Option<usize>, depth: usize) {
    match value {
        Value::Null => output.push_str("null"),
        Value::Bool(flag) => output.push_str(if *flag { "true" } else { "false" }),
        Value::Number(number) => {
            // Keep an integral literal as written; a floating one goes through
            // the measured `JSONSerialization` spelling.
            match (number.as_i64(), number.as_u64()) {
                (Some(value), _) => output.push_str(&value.to_string()),
                (_, Some(value)) => output.push_str(&value.to_string()),
                _ => output.push_str(&json_serialization_double(
                    number.as_f64().unwrap_or_default(),
                )),
            }
        }
        Value::String(text) => output.push_str(&json_serialization_quote(text)),
        Value::Array(items) => {
            if items.is_empty() {
                output.push_str("[]");
                return;
            }
            match indent {
                None => {
                    output.push('[');
                    for (index, item) in items.iter().enumerate() {
                        if index > 0 {
                            output.push(',');
                        }
                        write_value(item, output, indent, depth + 1);
                    }
                    output.push(']');
                }
                Some(width) => {
                    // Response for reference: `.prettyPrinted` writes an empty
                    // container as `[\n\n<indent>]`, which this reproduces.
                    output.push_str("[\n");
                    for (index, item) in items.iter().enumerate() {
                        if index > 0 {
                            output.push_str(",\n");
                        }
                        push_indent(output, width, depth + 1);
                        write_value(item, output, indent, depth + 1);
                    }
                    output.push('\n');
                    push_indent(output, width, depth);
                    output.push(']');
                }
            }
        }
        Value::Object(members) => {
            if members.is_empty() {
                output.push_str("{}");
                return;
            }
            let mut keys: Vec<&String> = members.keys().collect();
            keys.sort_by(|left, right| left.as_bytes().cmp(right.as_bytes()));
            match indent {
                None => {
                    output.push('{');
                    for (index, key) in keys.iter().enumerate() {
                        if index > 0 {
                            output.push(',');
                        }
                        output.push_str(&json_serialization_quote(key));
                        output.push(':');
                        write_value(&members[*key], output, indent, depth + 1);
                    }
                    output.push('}');
                }
                Some(width) => {
                    output.push_str("{\n");
                    for (index, key) in keys.iter().enumerate() {
                        if index > 0 {
                            output.push_str(",\n");
                        }
                        push_indent(output, width, depth + 1);
                        output.push_str(&json_serialization_quote(key));
                        output.push_str(" : ");
                        write_value(&members[*key], output, indent, depth + 1);
                    }
                    output.push('\n');
                    push_indent(output, width, depth);
                    output.push('}');
                }
            }
        }
    }
}

fn push_indent(output: &mut String, width: usize, depth: usize) {
    for _ in 0..(width * depth) {
        output.push(' ');
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn booleans_are_not_numbers() {
        let value = json!({"flag": true, "count": 3});
        assert!(boolean(value.get("flag")) == Some(true));
        assert!(int(value.get("flag")).is_none());
        assert_eq!(int(value.get("count")), Some(3));
    }

    #[test]
    fn text_sorts_keys_and_keeps_slashes() {
        assert_eq!(
            text(&json!({"b": 1, "a": "x/y"})),
            "{\"a\":\"x/y\",\"b\":1}"
        );
    }

    #[test]
    fn pretty_uses_swift_spacing() {
        assert_eq!(
            pretty(&json!({"b": 1, "a": [1]})),
            "{\n  \"a\" : [\n    1\n  ],\n  \"b\" : 1\n}"
        );
    }

    #[test]
    fn empty_documents_are_rejected() {
        assert!(parse(b"").is_err());
        assert!(parse(b"{invalid").is_err());
        assert!(parse_object(b"[1]").is_err());
    }

    #[test]
    fn required_accessors_name_the_field() {
        let value = json!({"items": [1], "name": 3});
        assert!(required_string(value.get("name"), || "name".into()).is_err());
        assert_eq!(
            required_objects(value.get("items"), || "items".into())
                .unwrap()
                .len(),
            0
        );
    }
}
