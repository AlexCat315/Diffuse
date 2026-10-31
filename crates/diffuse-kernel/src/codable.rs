//! Swift `Codable` JSON compatibility helpers (MIGRATION.md §5.4).
//!
//! Swift's `JSONEncoder` is not byte-identical to `serde_json` for floating point,
//! and the difference is not cosmetic — it changes persisted files. Measured on
//! Swift 6.4.1 / arm64 macOS:
//!
//! | value   | Swift `JSONEncoder` | `serde_json` |
//! |---------|---------------------|--------------|
//! | `100.0` | `100`               | `100.0`      |
//! | `1e20`  | `1e+20`             | `1e20`       |
//! | `1e-7`  | `1e-07`             | `1e-7`       |
//! | `-0.0`  | `-0`                | `-0.0`       |
//!
//! [Swift's rule][swift] is: emit exponent notation when the decimal exponent is
//! `< -4` or `>= 16`, otherwise plain; always keep the negative sign of `-0`;
//! and write non-finite values as an error rather than `null` or `NaN`.
//!
//! The upper bound differs per width, measured on Swift 6.4.1:
//!
//! * `Double`: exponent form at `>= 16` (`1e15` -> `1000000000000000`,
//!   `1e16` -> `1e+16`).
//! * `Float`: exponent form at `>= 8` (`1e7` -> `10000000`, `1e8` -> `1e+08`).
//!
//! Both use `1e-05` (exponent `-5`) as the lower switch, i.e. plain form while
//! `-4 <= exponent <= 15` for `Double` and `-4 <= exponent <= 7` for `Float`.
//!
//! [swift]: https://github.com/swiftlang/swift-corelibs-foundation

use serde::Serialize;
use serde::Serializer;

/// Formats a `Double` exactly as Swift's `JSONEncoder` does.
///
/// Returns `None` for NaN and the infinities, which Swift refuses to encode.
pub fn format_double(value: f64) -> Option<String> {
    if !value.is_finite() {
        return None;
    }
    // Swift keeps the sign of negative zero: `-0.0` encodes as `-0`.
    if value == 0.0 {
        return Some(if value.is_sign_negative() {
            "-0".to_string()
        } else {
            "0".to_string()
        });
    }

    let magnitude = value.abs();
    let exponent = magnitude.log10().floor() as i32;
    if !(-4..16).contains(&exponent) {
        Some(format_exponent(value, exponent))
    } else {
        Some(format_plain(value))
    }
}

/// Formats a `Float` (f32) exactly as Swift's `JSONEncoder` does.
///
/// Measured: `1e7` -> `10000000` but `1e8` -> `1e+08`; `1e-4` -> `0.0001` but
/// `1e-5` -> `1e-05`.
pub fn format_float(value: f32) -> Option<String> {
    if !value.is_finite() {
        return None;
    }
    if value == 0.0 {
        return Some(if value.is_sign_negative() {
            "-0".to_string()
        } else {
            "0".to_string()
        });
    }

    let magnitude = value.abs();
    let exponent = magnitude.log10().floor() as i32;
    if !(-4..8).contains(&exponent) {
        Some(format_exponent_f32(value, exponent))
    } else {
        Some(format_plain_f32(value))
    }
}

/// Swift's exponent form for a `Float`: two mantissa decimals' worth of digits at
/// most, and a two-digit signed exponent.
fn format_exponent_f32(value: f32, exponent: i32) -> String {
    let scientific = format!("{value:e}");
    let (mantissa, raw_exponent) = match scientific.split_once('e') {
        Some(parts) => parts,
        None => return scientific,
    };
    let exponent_value: i32 = raw_exponent.parse().unwrap_or(exponent);
    let sign = if exponent_value < 0 { '-' } else { '+' };
    format!("{mantissa}e{sign}{:02}", exponent_value.abs())
}

fn format_plain_f32(value: f32) -> String {
    let text = format!("{value}");
    if let Some(stripped) = text.strip_suffix(".0") {
        stripped.to_string()
    } else {
        text
    }
}

/// `Serialize` adapter for a `Float` field that Swift `Codable` writes.
pub fn serialize_float<S: Serializer>(value: &f32, serializer: S) -> Result<S::Ok, S::Error> {
    let Some(text) = format_float(*value) else {
        return Err(serde::ser::Error::custom(
            "Swift JSONEncoder rejects NaN and infinity in persisted documents",
        ));
    };
    match serde_json::value::RawValue::from_string(text) {
        Ok(raw) => raw.serialize(serializer),
        Err(_) => Err(serde::ser::Error::custom(
            "invalid number produced for a Float",
        )),
    }
}

/// `1e+20`, `1e-07`, `1.2345678901234568e+20` — Swift's exponent form.
fn format_exponent(value: f64, exponent: i32) -> String {
    // Rust's `{:e}` already produces the shortest round-tripping mantissa.
    let scientific = format!("{value:e}");
    let (mantissa, raw_exponent) = match scientific.split_once('e') {
        Some(parts) => parts,
        None => return scientific,
    };
    let exponent_value: i32 = raw_exponent.parse().unwrap_or(exponent);
    // Swift writes at least two exponent digits and an explicit sign.
    let sign = if exponent_value < 0 { '-' } else { '+' };
    format!("{mantissa}e{sign}{:02}", exponent_value.abs())
}

/// `100`, `0.5`, `999999999999999.9` — Swift's plain form, with no trailing `.0`.
fn format_plain(value: f64) -> String {
    let text = format!("{value}");
    if let Some(stripped) = text.strip_suffix(".0") {
        stripped.to_string()
    } else {
        text
    }
}

/// `Serialize` adapter for a `Double` field that Swift `Codable` writes.
///
/// ```ignore
/// #[serde(serialize_with = "diffuse_kernel::codable::serialize_double")]
/// pub exposure: f64,
/// ```
pub fn serialize_double<S: Serializer>(value: &f64, serializer: S) -> Result<S::Ok, S::Error> {
    let Some(text) = format_double(*value) else {
        return Err(serde::ser::Error::custom(
            "Swift JSONEncoder rejects NaN and infinity in persisted documents",
        ));
    };
    // `serialize_f64` would let serde_json re-format the number (writing `100.0`
    // where Swift writes `100`). A `RawValue` keeps both the value and its exact
    // spelling.
    match serde_json::value::RawValue::from_string(text) {
        Ok(raw) => raw.serialize(serializer),
        Err(_) => Err(serde::ser::Error::custom(
            "invalid number produced for a Double",
        )),
    }
}

/// Serializes an optional `Double`, preserving `null` for `None`.
pub fn serialize_optional_double<S: Serializer>(
    value: &Option<f64>,
    serializer: S,
) -> Result<S::Ok, S::Error> {
    match value {
        Some(value) => serialize_double(value, serializer),
        None => serializer.serialize_none(),
    }
}

#[cfg(test)]
mod tests {
    use super::{format_double, format_float};

    // These pairs were captured by running Swift 6.4.1's JSONEncoder; see the
    // module doc comment for the table they come from.
    #[test]
    fn matches_swift_integer_valued_doubles() {
        assert_eq!(format_double(0.0).as_deref(), Some("0"));
        assert_eq!(format_double(1.0).as_deref(), Some("1"));
        assert_eq!(format_double(-1.0).as_deref(), Some("-1"));
        assert_eq!(format_double(100.0).as_deref(), Some("100"));
        assert_eq!(format_double(1000.0).as_deref(), Some("1000"));
        assert_eq!(format_double(1e15).as_deref(), Some("1000000000000000"));
    }

    #[test]
    fn matches_swift_fractional_doubles() {
        assert_eq!(format_double(0.5).as_deref(), Some("0.5"));
        assert_eq!(format_double(1.5).as_deref(), Some("1.5"));
        assert_eq!(format_double(0.1).as_deref(), Some("0.1"));
        assert_eq!(format_double(1234.5678).as_deref(), Some("1234.5678"));
        assert_eq!(format_double(0.0001).as_deref(), Some("0.0001"));
        assert_eq!(
            format_double(999_999_999_999_999.9).as_deref(),
            Some("999999999999999.9")
        );
        assert_eq!(
            format_double(core::f64::consts::PI).as_deref(),
            Some("3.141592653589793")
        );
    }

    #[test]
    fn uses_exponent_notation_at_swifts_boundaries() {
        // 1e16 is the first power that switches to exponent form.
        assert_eq!(format_double(1e16).as_deref(), Some("1e+16"));
        assert_eq!(format_double(1e20).as_deref(), Some("1e+20"));
        assert_eq!(format_double(1e21).as_deref(), Some("1e+21"));
        assert_eq!(format_double(1e300).as_deref(), Some("1e+300"));
        // 1e-5 is the first power below the plain-form window.
        assert_eq!(format_double(1e-5).as_deref(), Some("1e-05"));
        assert_eq!(format_double(1e-6).as_deref(), Some("1e-06"));
        assert_eq!(format_double(1e-7).as_deref(), Some("1e-07"));
        assert_eq!(format_double(1e-300).as_deref(), Some("1e-300"));
        assert_eq!(format_double(2.5e-10).as_deref(), Some("2.5e-10"));
        assert_eq!(
            format_double(1.2345678901234568e20).as_deref(),
            Some("1.2345678901234568e+20")
        );
        assert_eq!(format_double(5e-324).as_deref(), Some("5e-324"));
    }

    #[test]
    fn float_uses_swifts_narrower_boundary() {
        // f32 switches to exponent form one decade earlier than f64.
        assert_eq!(format_float(1e7).as_deref(), Some("10000000"));
        assert_eq!(format_float(1e8).as_deref(), Some("1e+08"));
        assert_eq!(format_float(1e9).as_deref(), Some("1e+09"));
        assert_eq!(format_float(1e-4).as_deref(), Some("0.0001"));
        assert_eq!(format_float(1e-5).as_deref(), Some("1e-05"));
        assert_eq!(format_float(1e-6).as_deref(), Some("1e-06"));
        assert_eq!(format_float(100.0).as_deref(), Some("100"));
        assert_eq!(format_float(0.5).as_deref(), Some("0.5"));
        assert_eq!(format_float(-0.0).as_deref(), Some("-0"));
        assert_eq!(format_float(f32::NAN), None);
    }

    #[test]
    fn keeps_the_sign_of_negative_zero() {
        assert_eq!(format_double(-0.0).as_deref(), Some("-0"));
        assert_eq!(format_double(-0.0001).as_deref(), Some("-0.0001"));
    }

    #[test]
    fn rejects_non_finite_values_like_swift() {
        assert_eq!(format_double(f64::NAN), None);
        assert_eq!(format_double(f64::INFINITY), None);
        assert_eq!(format_double(f64::NEG_INFINITY), None);
    }

    #[test]
    fn extreme_doubles_round_trip_through_the_text() {
        for value in [
            1.7976931348623157e308_f64,
            5e-324,
            1e-300,
            1e300,
            1234.5678,
            999_999_999_999_999.9,
        ] {
            let text = format_double(value).expect("finite");
            let parsed: f64 = text.parse().expect("round-trips");
            assert_eq!(parsed, value, "text {text} lost precision");
        }
    }
}

#[cfg(test)]
mod serde_tests {
    use super::*;

    #[derive(serde::Serialize)]
    struct DoubleField {
        #[serde(serialize_with = "serialize_double")]
        exposure: f64,
    }

    #[test]
    fn serializing_through_the_adapter_matches_swift_bytes() {
        // Swift writes {"exposure":1e+20} for this value, not 1e20.
        let encoded = serde_json::to_string(&DoubleField { exposure: 1e20 }).expect("encode");
        assert_eq!(encoded, "{\"exposure\":1e+20}");

        // And {"exposure":100}, not 100.0.
        let encoded = serde_json::to_string(&DoubleField { exposure: 100.0 }).expect("encode");
        assert_eq!(encoded, "{\"exposure\":100}");

        // And {"exposure":-0}.
        let encoded = serde_json::to_string(&DoubleField { exposure: -0.0 }).expect("encode");
        assert_eq!(encoded, "{\"exposure\":-0}");
    }

    #[test]
    fn non_finite_values_fail_instead_of_encoding_null() {
        let result = serde_json::to_string(&DoubleField { exposure: f64::NAN });
        assert!(
            result.is_err(),
            "Swift rejects NaN; the adapter must not silently pass it"
        );
    }
}

/// Golden-file conformance: the exact byte strings Swift 6.4.1 writes, captured
/// into `.migration/baseline/formats/` by compiling the Swift sources
/// (MIGRATION.md §7.1).
#[cfg(test)]
mod golden_tests {
    use super::{format_double, format_float};

    /// `.migration/baseline/formats/scalars.json`, produced by Swift's
    /// `JSONEncoder(outputFormatting: [.sortedKeys])`.
    const SWIFT_SCALARS: &str = "{\"bigE\":1e+20,\"f32\":1e+08,\"frac\":0.5,\"hundred\":100,\"negZero\":-0,\"pi\":3.141592653589793,\"smallE\":1e-07,\"zero\":0}";

    #[test]
    fn scalar_formatters_reproduce_swifts_golden_file_byte_for_byte() {
        let rebuilt = format!(
            "{{\"bigE\":{},\"f32\":{},\"frac\":{},\"hundred\":{},\"negZero\":{},\"pi\":{},\"smallE\":{},\"zero\":{}}}",
            format_double(1e20).expect("bigE"),
            format_float(1e8).expect("f32"),
            format_double(0.5).expect("frac"),
            format_double(100.0).expect("hundred"),
            format_double(-0.0).expect("negZero"),
            format_double(core::f64::consts::PI).expect("pi"),
            format_double(1e-7).expect("smallE"),
            format_double(0.0).expect("zero"),
        );
        assert_eq!(rebuilt, SWIFT_SCALARS);
    }

    /// The scalars embedded in `.migration/baseline/formats/component-registry-sorted.json`.
    #[test]
    fn float_array_formats_inside_a_document_exactly_as_swift_did() {
        // Swift wrote: "position":[1,2.5,-0]  and  "position":[1e+20,1e-07,0.5]
        let first = format!(
            "[{},{},{}]",
            format_double(1.0).unwrap(),
            format_double(2.5).unwrap(),
            format_double(-0.0).unwrap()
        );
        assert_eq!(first, "[1,2.5,-0]");

        let second = format!(
            "[{},{},{}]",
            format_double(1e20).unwrap(),
            format_double(1e-7).unwrap(),
            format_double(0.5).unwrap()
        );
        assert_eq!(second, "[1e+20,1e-07,0.5]");

        // Integers that were Swift `Int` stay bare.
        assert_eq!(format_double(3.0).unwrap(), "3");
        assert_eq!(format_double(100.0).unwrap(), "100");
    }
}

/// A random v4 UUID formatted exactly as Swift's `UUID().uuidString`: uppercase,
/// hyphenated, groups of 8-4-4-4-12, i.e. 36 characters.
///
/// This is the single implementation for the whole workspace. Three crates
/// (`diffuse-capability`, `diffuse-sequence`, `diffuse-observation`) previously
/// carried private copies that formatted the node as two fields (`{a:04X}{b:06X}`),
/// which produced **34**-character strings whenever the masked node value was
/// small — invalid UUIDs that `Uuid::parse` correctly rejected.
pub fn new_uuid() -> String {
    use std::sync::atomic::{AtomicU64, Ordering};

    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_nanos() as u64)
        .unwrap_or(0);
    let counter = COUNTER.fetch_add(1, Ordering::Relaxed);
    let mixed = nanos ^ counter.wrapping_mul(0x9E37_79B9_7F4A_7C15);

    let time_low = (mixed & 0xFFFF_FFFF) as u32;
    let time_mid = ((mixed >> 32) & 0xFFFF) as u16;
    // Version 4 in the high nibble of the third group.
    let time_hi = (((mixed >> 48) & 0x0FFF) as u16) | 0x4000;
    // RFC 4122 variant in the two high bits of the fourth group.
    let clock = ((counter & 0x3FFF) as u16) | 0x8000;
    // The node is one 48-bit value, written as 12 hex digits.
    let node: u64 = (mixed >> 8) & 0x0000_FFFF_FFFF_FFFF;

    format!("{time_low:08X}-{time_mid:04X}-{time_hi:04X}-{clock:04X}-{node:012X}")
}

#[cfg(test)]
mod uuid_tests {
    use super::new_uuid;
    use std::collections::BTreeSet;

    /// Swift's `UUID().uuidString` is always 36 characters: 8-4-4-4-12.
    #[test]
    fn shape_matches_swift_uuid_string() {
        for _ in 0..512 {
            let value = new_uuid();
            assert_eq!(value.len(), 36, "wrong length for {value}");
            let groups: Vec<usize> = value.split('-').map(str::len).collect();
            assert_eq!(groups, vec![8, 4, 4, 4, 12], "wrong grouping for {value}");
            assert!(value.chars().all(|c| c.is_ascii_hexdigit() || c == '-'));
            assert_eq!(value, value.to_uppercase(), "Swift uppercases the string");
            // Version 4 and the RFC 4122 variant.
            assert_eq!(&value[14..15], "4", "not a v4 UUID: {value}");
            let variant = value.as_bytes()[19];
            assert!(
                matches!(variant, b'8' | b'9' | b'A' | b'B'),
                "variant nibble wrong: {value}"
            );
        }
    }

    /// The 34-character regression: a small masked node used to print short.
    #[test]
    fn node_never_prints_short() {
        let mut seen = BTreeSet::new();
        for _ in 0..512 {
            let value = new_uuid();
            let node = value.rsplit('-').next().expect("node").to_string();
            assert_eq!(node.len(), 12, "short node in {value}");
            seen.insert(node);
        }
        // Distinct calls must not collide on the node alone.
        assert!(
            seen.len() > 400,
            "node values are not varying: {}",
            seen.len()
        );
    }
}
