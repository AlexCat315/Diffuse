//! Swift-compatible compact JSON for the values whose digest is persisted.
//!
//! `PluginAuthorizationRecord.manifest_hash` is `sha256` of
//! `JSONEncoder().outputFormatting = [.sortedKeys]` output, so the digest only
//! matches Swift when the *text* matches, not merely the JSON value. Two things
//! differ from a plain `#[derive(Serialize)]` (MIGRATION.md §5.4 and §10):
//!
//! * **Numbers.** Swift writes `100` for `100.0`, `1e+20`, `1e-07` and `-0`;
//!   serde_json writes `100.0`, `1e20`, `1e-7` and `-0.0`. The text comes from
//!   `diffuse_kernel::codable::format_double`.
//! * **Key order** is alphabetical under `.sortedKeys`, which `serde_json`
//!   produces for a `BTreeMap`-backed object.
//!
//! `diffuse-assets::swift_json` already implements the *pretty* layout Swift
//! uses elsewhere, but this crate must not depend on `diffuse-assets` (it pulls
//! in `diffuse-scene`, which `diffuse-plugin` does not depend on in Swift
//! either). Digests need only the compact form, so this module composes the
//! number rule with serde_json's sorted object emission.

use serde::Serialize;
use serde_json::Value;

/// Serialises `value` the way Swift's `JSONEncoder(.sortedKeys)` does.
pub fn encode_sorted<T: Serialize + ?Sized>(value: &T) -> Result<Vec<u8>, serde_json::Error> {
    let tree = serde_json::to_value(value)?;
    let mut out = String::new();
    write_value(&tree, &mut out);
    Ok(out.into_bytes())
}

fn write_value(value: &Value, out: &mut String) {
    match value {
        Value::Null => out.push_str("null"),
        Value::Bool(flag) => out.push_str(if *flag { "true" } else { "false" }),
        Value::Number(number) => write_number(number, out),
        Value::String(text) => write_string(text, out),
        Value::Array(values) => {
            out.push('[');
            for (index, item) in values.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                write_value(item, out);
            }
            out.push(']');
        }
        // `serde_json::Map` is a `BTreeMap` unless the `preserve_order` feature is
        // on, which this workspace does not enable, so iteration is already
        // alphabetical — the `.sortedKeys` order.
        Value::Object(fields) => {
            out.push('{');
            for (index, (key, item)) in fields.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                write_string(key, out);
                out.push(':');
                write_value(item, out);
            }
            out.push('}');
        }
    }
}

fn write_number(number: &serde_json::Number, out: &mut String) {
    if let Some(value) = number.as_i64() {
        out.push_str(&value.to_string());
        return;
    }
    if let Some(value) = number.as_u64() {
        out.push_str(&value.to_string());
        return;
    }
    match number.as_f64() {
        // Swift refuses to encode non-finite values; there is nothing to write.
        Some(value) => match diffuse_kernel::codable::format_double(value) {
            Some(text) => out.push_str(&text),
            None => out.push_str("null"),
        },
        None => out.push_str("null"),
    }
}

/// Swift's string escaping: `"`, `\`, `/`, and the C0 controls; every other
/// scalar is written literally as UTF-8.
fn write_string(value: &str, out: &mut String) {
    out.push('"');
    for character in value.chars() {
        match character {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '/' => out.push_str("\\/"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{08}' => out.push_str("\\b"),
            '\u{0c}' => out.push_str("\\f"),
            character if (character as u32) < 0x20 => {
                out.push_str(&format!("\\u{:04x}", character as u32));
            }
            character => out.push(character),
        }
    }
    out.push('"');
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    #[test]
    fn numbers_use_swifts_text_not_serde_jsons() {
        #[derive(Serialize)]
        struct Sample {
            whole: f64,
            large: f64,
            tiny: f64,
        }
        let encoded = encode_sorted(&Sample {
            whole: 100.0,
            large: 1e20,
            tiny: 1e-7,
        })
        .expect("encode");
        // serde_json alone would write 100.0, 1e20 and 1e-7.
        assert_eq!(
            String::from_utf8(encoded).expect("utf8"),
            r#"{"large":1e+20,"tiny":1e-07,"whole":100}"#
        );
    }

    #[test]
    fn keys_are_alphabetical_and_integers_stay_integral() {
        let mut map: BTreeMap<String, i64> = BTreeMap::new();
        map.insert("zulu".to_string(), 1);
        map.insert("alpha".to_string(), 2);
        let encoded = encode_sorted(&map).expect("encode");
        assert_eq!(
            String::from_utf8(encoded).expect("utf8"),
            r#"{"alpha":2,"zulu":1}"#
        );
    }

    #[test]
    fn strings_escape_slashes_like_swift() {
        let encoded = encode_sorted(&"a/b\\c\"d\ne\u{1}").expect("encode");
        assert_eq!(
            String::from_utf8(encoded).expect("utf8"),
            "\"a\\/b\\\\c\\\"d\\ne\\u0001\""
        );
    }
}
