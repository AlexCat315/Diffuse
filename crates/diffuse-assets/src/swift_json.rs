//! Byte-compatible `JSONEncoder` emulation.
//!
//! MIGRATION.md §5.4 requires the persisted `.dmesh` files to be byte-identical
//! to what Swift writes. `GeometryDocument::save` uses
//! `JSONEncoder` with `outputFormatting = [.prettyPrinted, .sortedKeys]`, so
//! both the layout and the scalar rendering have to match Swift exactly.
//!
//! Measured against Swift 6.4.1 (`Foundation.JSONEncoder`):
//!
//! * Keys are sorted by UTF-8 code unit; the writer emits them in that order.
//! * Pretty printing indents two spaces per level, separates key and value with
//!   `" : "`, and writes an empty array/object as `[\n\n<indent>]`, i.e. a blank
//!   line between the brackets.
//! * `Float`/`Double` use decimal notation when the decimal exponent `A`
//!   (value = `0.<digits> * 10^A`) satisfies `-3 <= A <= 7` for `Float` and
//!   `-3 <= A <= 15` for `Double`, and scientific notation `d.dddde±NN`
//!   otherwise. Whole values never carry a `.0`, and `-0` keeps its sign.
//! * Strings escape `"`, `\\`, `/`, and the C0 controls (as `\n`, `\t`, `\r`,
//!   `\b`, `\f`, or `\u00XX`); every other scalar, including DEL, U+2028 and
//!   non-BMP characters, is written literally as UTF-8.
//! * Non-finite floats are an encoding failure, exactly as in Swift.
//!
//! `serde_json` is still used for decoding: Swift's output is ordinary JSON.

use serde::ser::{self, Serialize};
use std::collections::BTreeMap;
use std::fmt::Write as _;

/// Failure modes of the Swift-compatible encoder.
#[derive(Clone, Debug, PartialEq)]
pub enum SwiftJsonError {
    /// Swift's `EncodingError.invalidValue`: JSON cannot represent the value.
    InvalidValue(String),
    /// A key was serialized more than once in the same object.
    DuplicateKey(String),
    /// A map key was not a string.
    NonStringKey,
    /// The value produced an error from a custom `Serialize` implementation.
    Custom(String),
}

impl core::fmt::Display for SwiftJsonError {
    fn fmt(&self, formatter: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            SwiftJsonError::InvalidValue(message) => write!(formatter, "invalid value: {message}"),
            SwiftJsonError::DuplicateKey(key) => write!(formatter, "duplicate key: {key}"),
            SwiftJsonError::NonStringKey => formatter.write_str("non-string object key"),
            SwiftJsonError::Custom(message) => formatter.write_str(message),
        }
    }
}

impl std::error::Error for SwiftJsonError {}

impl ser::Error for SwiftJsonError {
    fn custom<T: core::fmt::Display>(message: T) -> Self {
        SwiftJsonError::Custom(message.to_string())
    }
}

/// One node of the intermediate tree.
#[derive(Clone, Debug, PartialEq)]
pub enum SwiftJsonValue {
    Null,
    Bool(bool),
    /// Integers keep their exact width; Swift writes them without a fraction.
    Integer(i128),
    /// A float tagged with the width it was serialized at, because Swift picks
    /// the notation threshold from the concrete type (`Float` vs `Double`).
    Float {
        value: f64,
        single: bool,
    },
    String(String),
    Array(Vec<SwiftJsonValue>),
    Object(BTreeMap<String, SwiftJsonValue>),
}

/// Serializes `value` the way Swift's `JSONEncoder` does with `.sortedKeys`.
pub fn to_compact<T: Serialize + ?Sized>(value: &T) -> Result<String, SwiftJsonError> {
    let tree = to_value(value)?;
    let mut out = String::new();
    write_compact(&tree, &mut out);
    Ok(out)
}

/// Serializes `value` the way Swift's `JSONEncoder` does with
/// `[.prettyPrinted, .sortedKeys]` — the formatting `GeometryDocument.save` uses.
pub fn to_sorted_pretty<T: Serialize + ?Sized>(value: &T) -> Result<String, SwiftJsonError> {
    let tree = to_value(value)?;
    let mut out = String::new();
    write_pretty(&tree, 0, &mut out);
    Ok(out)
}

/// Builds the intermediate tree from any `Serialize` value.
pub fn to_value<T: Serialize + ?Sized>(value: &T) -> Result<SwiftJsonValue, SwiftJsonError> {
    value.serialize(TreeSerializer)
}

fn write_compact(value: &SwiftJsonValue, out: &mut String) {
    match value {
        SwiftJsonValue::Null => out.push_str("null"),
        SwiftJsonValue::Bool(flag) => out.push_str(if *flag { "true" } else { "false" }),
        SwiftJsonValue::Integer(number) => {
            let _ = write!(out, "{number}");
        }
        SwiftJsonValue::Float { value, single } => write_float(*value, *single, out),
        SwiftJsonValue::String(text) => write_string(text, out),
        SwiftJsonValue::Array(items) => {
            out.push('[');
            for (index, item) in items.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                write_compact(item, out);
            }
            out.push(']');
        }
        SwiftJsonValue::Object(entries) => {
            out.push('{');
            for (index, (key, item)) in entries.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                write_string(key, out);
                out.push(':');
                write_compact(item, out);
            }
            out.push('}');
        }
    }
}

/// Swift's pretty layout. `depth` is the nesting level of `value`'s container,
/// so members of the root object are indented by one level.
fn write_pretty(value: &SwiftJsonValue, depth: usize, out: &mut String) {
    match value {
        SwiftJsonValue::Array(items) if items.is_empty() => {
            out.push('[');
            out.push('\n');
            out.push('\n');
            for _ in 0..depth {
                out.push_str("  ");
            }
            out.push(']');
        }
        SwiftJsonValue::Object(entries) if entries.is_empty() => {
            out.push('{');
            out.push('\n');
            out.push('\n');
            for _ in 0..depth {
                out.push_str("  ");
            }
            out.push('}');
        }
        SwiftJsonValue::Array(items) => {
            out.push('[');
            out.push('\n');
            for (index, item) in items.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                    out.push('\n');
                }
                for _ in 0..=depth {
                    out.push_str("  ");
                }
                write_pretty(item, depth + 1, out);
            }
            out.push('\n');
            for _ in 0..depth {
                out.push_str("  ");
            }
            out.push(']');
        }
        SwiftJsonValue::Object(entries) => {
            out.push('{');
            out.push('\n');
            for (index, (key, item)) in entries.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                    out.push('\n');
                }
                for _ in 0..=depth {
                    out.push_str("  ");
                }
                write_string(key, out);
                out.push_str(" : ");
                write_pretty(item, depth + 1, out);
            }
            out.push('\n');
            for _ in 0..depth {
                out.push_str("  ");
            }
            out.push('}');
        }
        scalar => write_compact(scalar, out),
    }
}

/// Swift's `JSONEncoder` string escaping: `"` + `\\` + `/` stay escaped, the C0
/// controls use the short forms where Swift has them, and everything else is
/// emitted literally as UTF-8.
fn write_string(text: &str, out: &mut String) {
    out.push('"');
    for character in text.chars() {
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
                let _ = write!(out, "\\u{:04x}", character as u32);
            }
            character => out.push(character),
        }
    }
    out.push('"');
}

/// Renders a float exactly as Swift does.
///
/// The shortest round-trip digits are computed with Rust's `{:e}` (which, like
/// Swift, produces the shortest representation that round-trips), then laid out
/// according to Swift's exponent thresholds.
fn write_float(value: f64, single: bool, out: &mut String) {
    let value = if single {
        f64::from(value as f32)
    } else {
        value
    };
    let digits_and_exponent = shortest_digits(value, single);
    let (digits, exponent) = digits_and_exponent;
    let negative = value.is_sign_negative() && (value != 0.0 || value.is_sign_negative());
    if negative {
        out.push('-');
    }
    let digits = digits.as_str();
    let max_exponent = if single { 7 } else { 15 };
    if exponent < -4 || exponent > max_exponent {
        out.push_str(&digits[..1]);
        if digits.len() > 1 {
            out.push('.');
            out.push_str(&digits[1..]);
        }
        out.push('e');
        if exponent < 0 {
            out.push('-');
        } else {
            out.push('+');
        }
        let magnitude = exponent.unsigned_abs();
        let _ = write!(out, "{magnitude:02}");
    } else if exponent < 0 {
        out.push_str("0.");
        for _ in 0..(-exponent - 1) {
            out.push('0');
        }
        out.push_str(digits);
    } else {
        let integer_digits = (exponent + 1) as usize;
        if digits.len() <= integer_digits {
            out.push_str(digits);
            for _ in digits.len()..integer_digits {
                out.push('0');
            }
        } else {
            out.push_str(&digits[..integer_digits]);
            out.push('.');
            out.push_str(&digits[integer_digits..]);
        }
    }
}

/// Shortest round-trip digits of `value` plus the decimal exponent `A` such that
/// `value == 0.<digits> * 10^A`.
fn shortest_digits(value: f64, single: bool) -> (String, i32) {
    if !value.is_finite() {
        // Callers reject non-finite values before reaching here.
        return ("0".to_string(), 0);
    }
    let absolute = value.abs();
    if absolute == 0.0 {
        return ("0".to_string(), 0);
    }
    let raw = if single {
        format!("{:e}", absolute as f32)
    } else {
        format!("{absolute:e}")
    };
    let (mantissa, exponent) = match raw.split_once('e') {
        Some((mantissa, exponent)) => (mantissa.to_string(), exponent.parse::<i32>().unwrap_or(0)),
        None => (raw, 0),
    };
    let digits: String = mantissa
        .chars()
        .filter(|character| *character != '.')
        .collect();
    let digits = digits.trim_end_matches('0').to_string();
    let digits = if digits.is_empty() {
        "0".to_string()
    } else {
        digits
    };
    // `{:e}` prints `d.dddd` with a single leading digit, so A is the printed
    // exponent directly.
    (digits, exponent)
}

/// `serde::Serializer` that builds a [`SwiftJsonValue`].
struct TreeSerializer;

impl ser::Serializer for TreeSerializer {
    type Ok = SwiftJsonValue;
    type Error = SwiftJsonError;
    type SerializeSeq = SequenceBuilder;
    type SerializeTuple = SequenceBuilder;
    type SerializeTupleStruct = SequenceBuilder;
    type SerializeTupleVariant = SequenceBuilder;
    type SerializeMap = ObjectBuilder;
    type SerializeStruct = ObjectBuilder;
    type SerializeStructVariant = ObjectBuilder;

    fn serialize_bool(self, value: bool) -> Result<Self::Ok, Self::Error> {
        Ok(SwiftJsonValue::Bool(value))
    }

    fn serialize_i8(self, value: i8) -> Result<Self::Ok, Self::Error> {
        Ok(SwiftJsonValue::Integer(i128::from(value)))
    }

    fn serialize_i16(self, value: i16) -> Result<Self::Ok, Self::Error> {
        Ok(SwiftJsonValue::Integer(i128::from(value)))
    }

    fn serialize_i32(self, value: i32) -> Result<Self::Ok, Self::Error> {
        Ok(SwiftJsonValue::Integer(i128::from(value)))
    }

    fn serialize_i64(self, value: i64) -> Result<Self::Ok, Self::Error> {
        Ok(SwiftJsonValue::Integer(i128::from(value)))
    }

    fn serialize_i128(self, value: i128) -> Result<Self::Ok, Self::Error> {
        Ok(SwiftJsonValue::Integer(value))
    }

    fn serialize_u8(self, value: u8) -> Result<Self::Ok, Self::Error> {
        Ok(SwiftJsonValue::Integer(i128::from(value)))
    }

    fn serialize_u16(self, value: u16) -> Result<Self::Ok, Self::Error> {
        Ok(SwiftJsonValue::Integer(i128::from(value)))
    }

    fn serialize_u32(self, value: u32) -> Result<Self::Ok, Self::Error> {
        Ok(SwiftJsonValue::Integer(i128::from(value)))
    }

    fn serialize_u64(self, value: u64) -> Result<Self::Ok, Self::Error> {
        Ok(SwiftJsonValue::Integer(i128::from(value)))
    }

    fn serialize_u128(self, value: u128) -> Result<Self::Ok, Self::Error> {
        Ok(SwiftJsonValue::Integer(value as i128))
    }

    fn serialize_f32(self, value: f32) -> Result<Self::Ok, Self::Error> {
        if !value.is_finite() {
            return Err(SwiftJsonError::InvalidValue(format!("{value}")));
        }
        Ok(SwiftJsonValue::Float {
            value: f64::from(value),
            single: true,
        })
    }

    fn serialize_f64(self, value: f64) -> Result<Self::Ok, Self::Error> {
        if !value.is_finite() {
            return Err(SwiftJsonError::InvalidValue(format!("{value}")));
        }
        Ok(SwiftJsonValue::Float {
            value,
            single: false,
        })
    }

    fn serialize_char(self, value: char) -> Result<Self::Ok, Self::Error> {
        Ok(SwiftJsonValue::String(value.to_string()))
    }

    fn serialize_str(self, value: &str) -> Result<Self::Ok, Self::Error> {
        Ok(SwiftJsonValue::String(value.to_string()))
    }

    fn serialize_bytes(self, value: &[u8]) -> Result<Self::Ok, Self::Error> {
        // Swift encodes `Data` as base64.
        Ok(SwiftJsonValue::String(base64(value)))
    }

    fn serialize_none(self) -> Result<Self::Ok, Self::Error> {
        Ok(SwiftJsonValue::Null)
    }

    fn serialize_some<T: Serialize + ?Sized>(self, value: &T) -> Result<Self::Ok, Self::Error> {
        value.serialize(self)
    }

    fn serialize_unit(self) -> Result<Self::Ok, Self::Error> {
        Ok(SwiftJsonValue::Null)
    }

    fn serialize_unit_struct(self, _name: &'static str) -> Result<Self::Ok, Self::Error> {
        Ok(SwiftJsonValue::Null)
    }

    fn serialize_unit_variant(
        self,
        _name: &'static str,
        _variant_index: u32,
        variant: &'static str,
    ) -> Result<Self::Ok, Self::Error> {
        Ok(SwiftJsonValue::String(variant.to_string()))
    }

    fn serialize_newtype_struct<T: Serialize + ?Sized>(
        self,
        _name: &'static str,
        value: &T,
    ) -> Result<Self::Ok, Self::Error> {
        value.serialize(self)
    }

    fn serialize_newtype_variant<T: Serialize + ?Sized>(
        self,
        _name: &'static str,
        _variant_index: u32,
        variant: &'static str,
        value: &T,
    ) -> Result<Self::Ok, Self::Error> {
        let mut entries = BTreeMap::new();
        entries.insert(variant.to_string(), value.serialize(TreeSerializer)?);
        Ok(SwiftJsonValue::Object(entries))
    }

    fn serialize_seq(self, _len: Option<usize>) -> Result<Self::SerializeSeq, Self::Error> {
        Ok(SequenceBuilder::default())
    }

    fn serialize_tuple(self, _len: usize) -> Result<Self::SerializeTuple, Self::Error> {
        Ok(SequenceBuilder::default())
    }

    fn serialize_tuple_struct(
        self,
        _name: &'static str,
        _len: usize,
    ) -> Result<Self::SerializeTupleStruct, Self::Error> {
        Ok(SequenceBuilder::default())
    }

    fn serialize_tuple_variant(
        self,
        _name: &'static str,
        _variant_index: u32,
        variant: &'static str,
        _len: usize,
    ) -> Result<Self::SerializeTupleVariant, Self::Error> {
        Ok(SequenceBuilder {
            variant: Some(variant.to_string()),
            ..SequenceBuilder::default()
        })
    }

    fn serialize_map(self, _len: Option<usize>) -> Result<Self::SerializeMap, Self::Error> {
        Ok(ObjectBuilder::default())
    }

    fn serialize_struct(
        self,
        _name: &'static str,
        _len: usize,
    ) -> Result<Self::SerializeStruct, Self::Error> {
        Ok(ObjectBuilder::default())
    }

    fn serialize_struct_variant(
        self,
        _name: &'static str,
        _variant_index: u32,
        variant: &'static str,
        _len: usize,
    ) -> Result<Self::SerializeStructVariant, Self::Error> {
        Ok(ObjectBuilder {
            variant: Some(variant.to_string()),
            ..ObjectBuilder::default()
        })
    }

    fn is_human_readable(&self) -> bool {
        true
    }
}

#[derive(Default)]
struct SequenceBuilder {
    items: Vec<SwiftJsonValue>,
    /// Set for `SerializeTupleVariant`: the case name wrapping `{"_0": …}`.
    variant: Option<String>,
}

impl ser::SerializeSeq for SequenceBuilder {
    type Ok = SwiftJsonValue;
    type Error = SwiftJsonError;

    fn serialize_element<T: Serialize + ?Sized>(&mut self, value: &T) -> Result<(), Self::Error> {
        self.items.push(value.serialize(TreeSerializer)?);
        Ok(())
    }

    fn end(self) -> Result<Self::Ok, Self::Error> {
        Ok(SwiftJsonValue::Array(self.items))
    }
}

impl ser::SerializeTuple for SequenceBuilder {
    type Ok = SwiftJsonValue;
    type Error = SwiftJsonError;

    fn serialize_element<T: Serialize + ?Sized>(&mut self, value: &T) -> Result<(), Self::Error> {
        ser::SerializeSeq::serialize_element(self, value)
    }

    fn end(self) -> Result<Self::Ok, Self::Error> {
        ser::SerializeSeq::end(self)
    }
}

impl ser::SerializeTupleStruct for SequenceBuilder {
    type Ok = SwiftJsonValue;
    type Error = SwiftJsonError;

    fn serialize_field<T: Serialize + ?Sized>(&mut self, value: &T) -> Result<(), Self::Error> {
        ser::SerializeSeq::serialize_element(self, value)
    }

    fn end(self) -> Result<Self::Ok, Self::Error> {
        ser::SerializeSeq::end(self)
    }
}

impl ser::SerializeTupleVariant for SequenceBuilder {
    type Ok = SwiftJsonValue;
    type Error = SwiftJsonError;

    fn serialize_field<T: Serialize + ?Sized>(&mut self, value: &T) -> Result<(), Self::Error> {
        ser::SerializeSeq::serialize_element(self, value)
    }

    /// Swift writes an associated-value case as `{"case": {"_0": …}}`, with
    /// `_0`, `_1`, … for positional payloads.
    fn end(self) -> Result<Self::Ok, Self::Error> {
        let tag = self
            .variant
            .expect("tuple variants always carry their case name");
        let mut payload = BTreeMap::new();
        for (index, item) in self.items.into_iter().enumerate() {
            payload.insert(format!("_{index}"), item);
        }
        let mut entries = BTreeMap::new();
        entries.insert(tag, SwiftJsonValue::Object(payload));
        Ok(SwiftJsonValue::Object(entries))
    }
}

#[derive(Default)]
struct ObjectBuilder {
    entries: BTreeMap<String, SwiftJsonValue>,
    pending_key: Option<String>,
    /// Set for `SerializeStructVariant`: the case name wrapping the payload.
    variant: Option<String>,
}

impl ser::SerializeMap for ObjectBuilder {
    type Ok = SwiftJsonValue;
    type Error = SwiftJsonError;

    fn serialize_key<T: Serialize + ?Sized>(&mut self, key: &T) -> Result<(), Self::Error> {
        match key.serialize(TreeSerializer)? {
            SwiftJsonValue::String(text) => {
                self.pending_key = Some(text);
                Ok(())
            }
            _ => Err(SwiftJsonError::NonStringKey),
        }
    }

    fn serialize_value<T: Serialize + ?Sized>(&mut self, value: &T) -> Result<(), Self::Error> {
        let key = self
            .pending_key
            .take()
            .ok_or_else(|| SwiftJsonError::Custom("value without key".to_string()))?;
        let value = value.serialize(TreeSerializer)?;
        if self.entries.insert(key.clone(), value).is_some() {
            return Err(SwiftJsonError::DuplicateKey(key));
        }
        Ok(())
    }

    fn end(self) -> Result<Self::Ok, Self::Error> {
        Ok(SwiftJsonValue::Object(self.entries))
    }
}

impl ser::SerializeStruct for ObjectBuilder {
    type Ok = SwiftJsonValue;
    type Error = SwiftJsonError;

    fn serialize_field<T: Serialize + ?Sized>(
        &mut self,
        key: &'static str,
        value: &T,
    ) -> Result<(), Self::Error> {
        let value = value.serialize(TreeSerializer)?;
        if self.entries.insert(key.to_string(), value).is_some() {
            return Err(SwiftJsonError::DuplicateKey(key.to_string()));
        }
        Ok(())
    }

    fn end(self) -> Result<Self::Ok, Self::Error> {
        Ok(SwiftJsonValue::Object(self.entries))
    }
}

impl ser::SerializeStructVariant for ObjectBuilder {
    type Ok = SwiftJsonValue;
    type Error = SwiftJsonError;

    fn serialize_field<T: Serialize + ?Sized>(
        &mut self,
        key: &'static str,
        value: &T,
    ) -> Result<(), Self::Error> {
        ser::SerializeStruct::serialize_field(self, key, value)
    }

    /// Swift writes a labelled case as `{"case": {"label": …}}`.
    fn end(self) -> Result<Self::Ok, Self::Error> {
        let tag = self
            .variant
            .expect("struct variants always carry their case name");
        let mut entries = BTreeMap::new();
        entries.insert(tag, SwiftJsonValue::Object(self.entries));
        Ok(SwiftJsonValue::Object(entries))
    }
}

/// Standard base64 (RFC 4648) with padding, which is what Swift's `Data` uses.
fn base64(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let first = chunk[0];
        let second = chunk.get(1).copied().unwrap_or(0);
        let third = chunk.get(2).copied().unwrap_or(0);
        out.push(ALPHABET[usize::from(first >> 2)] as char);
        out.push(ALPHABET[usize::from((first & 0x03) << 4 | second >> 4)] as char);
        if chunk.len() > 1 {
            out.push(ALPHABET[usize::from((second & 0x0f) << 2 | third >> 6)] as char);
        } else {
            out.push('=');
        }
        if chunk.len() > 2 {
            out.push(ALPHABET[usize::from(third & 0x3f)] as char);
        } else {
            out.push('=');
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::Serialize;

    #[derive(Serialize)]
    struct Scalars {
        #[serde(rename = "f")]
        floats: Vec<f32>,
        #[serde(rename = "d")]
        doubles: Vec<f64>,
    }

    #[test]
    fn float_notation_matches_swift_float_thresholds() {
        let value = Scalars {
            floats: vec![0.0, 1.0, -0.0, 0.15, 1.0e-4, 1.0e-5, 1.0e7, 1.0e8],
            doubles: vec![1.0e15, 1.0e16, 1.0e-4, 1.0e-5],
        };
        let encoded = to_compact(&value).expect("encode");
        assert_eq!(
            encoded,
            "{\"d\":[1000000000000000,1e+16,0.0001,1e-05],\
             \"f\":[0,1,-0,0.15,0.0001,1e-05,10000000,1e+08]}"
        );
    }

    #[test]
    fn strings_escape_like_swift() {
        let encoded = to_compact(&"a/b\"c\\d\ne\tf\u{1}g\u{7f}日").expect("encode");
        assert_eq!(encoded, "\"a\\/b\\\"c\\\\d\\ne\\tf\\u0001g\u{7f}日\"");
    }

    #[test]
    fn empty_containers_get_a_blank_line_when_pretty() {
        #[derive(Serialize)]
        struct Wrapper {
            items: Vec<u8>,
            object: BTreeMap<String, u8>,
        }
        let wrapper = Wrapper {
            items: Vec::new(),
            object: BTreeMap::new(),
        };
        let encoded = to_sorted_pretty(&wrapper).expect("encode");
        assert_eq!(
            encoded,
            "{\n  \"items\" : [\n\n  ],\n  \"object\" : {\n\n  }\n}"
        );
    }

    #[test]
    fn nested_objects_indent_two_spaces_and_separate_with_space_colon() {
        #[derive(Serialize)]
        struct Inner {
            z: u8,
        }
        #[derive(Serialize)]
        struct Outer {
            inner: Inner,
        }
        let encoded = to_sorted_pretty(&Outer {
            inner: Inner { z: 1 },
        })
        .expect("encode");
        assert_eq!(encoded, "{\n  \"inner\" : {\n    \"z\" : 1\n  }\n}");
    }
}
