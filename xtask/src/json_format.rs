//! Number and string text formats the emitted JSON must reproduce.
//!
//! Two different Swift writers appear in this tool, and they disagree about
//! floats, so both are modelled here:
//!
//! - `JSONSerialization` (the `JSON` helpers in `Validation/`) prints a `Double`
//!   with 17 significant digits, `%g`-style: `1.5` → `1.5`, `0.1` →
//!   `0.10000000000000001`, `1e20` → `1e+20`, `1e-7` → `9.9999999999999995e-08`,
//!   `-0.0` → `-0`.
//! - `JSONEncoder` (`Codable`) writes the shortest round-tripping text with a
//!   two-digit signed exponent: `100.0` → `100`, `1e20` → `1e+20`, `1e-7` →
//!   `1e-07`, `-0.0` → `-0`.
//!
//! Both were measured with Swift 6.4.1; the unit tests below pin the samples.

/// `%g` with 17 significant digits, which is what `JSONSerialization` emits.
pub fn json_serialization_double(value: f64) -> String {
    if value.is_nan() || value.is_infinite() {
        // JSON cannot carry either; Swift throws, callers reject beforehand.
        return "null".to_string();
    }
    if value == 0.0 {
        return if value.is_sign_negative() { "-0" } else { "0" }.to_string();
    }
    let (negative, digits, exponent) = scientific_parts(value, 17);
    let text = if exponent < -4 || exponent >= 17 {
        // Scientific notation, exponent always signed and at least two digits.
        let (mantissa, rest) = digits.split_at(1);
        let fraction = rest.trim_end_matches('0');
        let mut out = String::new();
        if negative {
            out.push('-');
        }
        out.push_str(mantissa);
        if !fraction.is_empty() {
            out.push('.');
            out.push_str(fraction);
        }
        out.push('e');
        out.push(if exponent < 0 { '-' } else { '+' });
        let magnitude = exponent.unsigned_abs();
        if magnitude < 10 {
            out.push('0');
        }
        out.push_str(&magnitude.to_string());
        out
    } else {
        let mut out = String::new();
        if negative {
            out.push('-');
        }
        if exponent >= 0 {
            let integer_length = exponent as usize + 1;
            if digits.len() <= integer_length {
                out.push_str(&digits);
                out.push_str(&"0".repeat(integer_length - digits.len()));
            } else {
                out.push_str(&digits[..integer_length]);
                let fraction = digits[integer_length..].trim_end_matches('0');
                if !fraction.is_empty() {
                    out.push('.');
                    out.push_str(fraction);
                }
            }
        } else {
            out.push_str("0.");
            out.push_str(&"0".repeat(exponent.unsigned_abs() as usize - 1));
            out.push_str(digits.trim_end_matches('0'));
        }
        out
    };
    text
}

/// Shortest round-tripping text in the spelling Swift's `JSONEncoder` uses.
pub fn codable_double(value: f64) -> String {
    if value.is_nan() || value.is_infinite() {
        return "null".to_string();
    }
    if value == 0.0 {
        return if value.is_sign_negative() { "-0" } else { "0" }.to_string();
    }
    let shortest = shortest_round_trip(value);
    // Swift switches to scientific notation outside `1e-4 ..< 1e16` for a
    // `Double` and uses a two-digit exponent.
    let magnitude = value.abs();
    if magnitude >= 1e16 || magnitude < 1e-4 {
        let (mantissa, exponent) = format!("{value:e}")
            .split_once('e')
            .map(|(m, e)| (m.to_string(), e.parse::<i32>().unwrap_or(0)))
            .unwrap_or_else(|| (shortest.clone(), 0));
        let digits: String = mantissa.chars().filter(|c| c.is_ascii_digit()).collect();
        let mut out = String::new();
        if value.is_sign_negative() {
            out.push('-');
        }
        let (head, rest) = digits.split_at(1);
        out.push_str(head);
        let fraction = rest.trim_end_matches('0');
        if !fraction.is_empty() {
            out.push('.');
            out.push_str(fraction);
        }
        out.push('e');
        out.push(if exponent < 0 { '-' } else { '+' });
        let width = exponent.unsigned_abs();
        if width < 10 {
            out.push('0');
        }
        out.push_str(&width.to_string());
        return out;
    }
    shortest
}

/// `ryu`-style shortest representation without an exponent (used in the
/// non-scientific range, which Swift prints positionally).
fn shortest_round_trip(value: f64) -> String {
    let text = format!("{value}");
    if let Some((mantissa, exponent)) = text.split_once('e') {
        let exponent: i32 = exponent.parse().unwrap_or(0);
        let negative = mantissa.starts_with('-');
        let digits: String = mantissa.chars().filter(|c| c.is_ascii_digit()).collect();
        let _ = negative;
        return expand(digits, exponent);
    }
    text
}

fn expand(digits: String, exponent: i32) -> String {
    // `digits` is the significant sequence with the decimal point after the
    // first digit; `exponent` is that first digit's power of ten.
    let integer_length = exponent + 1;
    if integer_length <= 0 {
        let zeros = "0".repeat((-integer_length) as usize);
        format!("0.{zeros}{digits}")
    } else if integer_length as usize >= digits.len() {
        let zeros = "0".repeat(integer_length as usize - digits.len());
        format!("{digits}{zeros}")
    } else {
        let (head, tail) = digits.split_at(integer_length as usize);
        format!("{head}.{tail}")
    }
}

/// Splits `value` into sign, `significant` decimal digits and the power of ten
/// of the first digit.
fn scientific_parts(value: f64, precision: usize) -> (bool, String, i32) {
    let negative = value.is_sign_negative();
    let magnitude = value.abs();
    // `{:.*e}` yields `d.dddddddddddddddde<exp>` with `precision` digits after
    // the point, i.e. `precision + 1` significant digits.
    let formatted = format!("{:.*e}", precision - 1, magnitude);
    let (mantissa, exponent) = formatted
        .split_once('e')
        .unwrap_or((formatted.as_str(), "0"));
    let exponent: i32 = exponent.parse().unwrap_or(0);
    let digits: String = mantissa.chars().filter(|c| c.is_ascii_digit()).collect();
    (negative, digits, exponent)
}

/// `JSONSerialization` string escaping with `.withoutEscapingSlashes`: control
/// scalars use the short escapes where JSON has them, otherwise `\u00XX`;
/// everything else, including non-ASCII, is written literally.
pub fn json_serialization_quote(value: &str) -> String {
    let mut out = String::with_capacity(value.len() + 2);
    out.push('"');
    for character in value.chars() {
        match character {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{08}' => out.push_str("\\b"),
            '\u{0C}' => out.push_str("\\f"),
            other if (other as u32) < 0x20 => {
                out.push_str(&format!("\\u{:04x}", other as u32));
            }
            other => out.push(other),
        }
    }
    out.push('"');
    out
}

/// Python `json.dumps(..., ensure_ascii: bool)` string escaping.
pub fn python_quote(value: &str, ensure_ascii: bool) -> String {
    let mut out = String::with_capacity(value.len() + 2);
    out.push('"');
    for character in value.chars() {
        match character {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{08}' => out.push_str("\\b"),
            '\u{0C}' => out.push_str("\\f"),
            other => {
                let code = other as u32;
                if code < 0x20 || (ensure_ascii && code > 0x7E) {
                    if code > 0xFFFF {
                        let supplementary = code - 0x1_0000;
                        out.push_str(&format!("\\u{:04x}", 0xD800 + (supplementary >> 10)));
                        out.push_str(&format!("\\u{:04x}", 0xDC00 + (supplementary & 0x3FF)));
                    } else {
                        out.push_str(&format!("\\u{code:04x}"));
                    }
                } else {
                    out.push(other);
                }
            }
        }
    }
    out.push('"');
    out
}

/// Swift's `String(format: "\\u%04x", …)` equivalent for a JavaScript literal,
/// where `U+2028`/`U+2029` must also be escaped.
pub fn javascript_quote(value: &str) -> String {
    let mut out = String::with_capacity(value.len() + 2);
    out.push('"');
    for character in value.chars() {
        match character {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{08}' => out.push_str("\\b"),
            '\u{0C}' => out.push_str("\\f"),
            other
                if (other as u32) < 0x20
                    || other == '\u{2028}'
                    || other == '\u{2029}' =>
            {
                out.push_str(&format!("\\u{:04x}", other as u32));
            }
            other => out.push(other),
        }
    }
    out.push('"');
    out
}

#[cfg(test)]
mod tests {
    use super::{
        codable_double, javascript_quote, json_serialization_double, json_serialization_quote,
        python_quote,
    };

    // Measured with Swift 6.4.1 `JSONSerialization.data(withJSONObject:options:
    // [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])`.
    #[test]
    fn json_serialization_doubles_match_swift() {
        assert_eq!(json_serialization_double(1.5), "1.5");
        assert_eq!(json_serialization_double(0.1), "0.10000000000000001");
        assert_eq!(json_serialization_double(1.0), "1");
        assert_eq!(json_serialization_double(-2.25), "-2.25");
        assert_eq!(json_serialization_double(1e20), "1e+20");
        assert_eq!(json_serialization_double(1e-7), "9.9999999999999995e-08");
        assert_eq!(json_serialization_double(-0.0), "-0");
        assert_eq!(json_serialization_double(0.0), "0");
        assert_eq!(
            json_serialization_double(123_456_789_012_345_678.0),
            "1.2345678901234568e+17"
        );
        assert_eq!(json_serialization_double(0.0001), "0.0001");
    }

    // Measured with Swift 6.4.1 `JSONEncoder` (the Codable spelling recorded in
    // MIGRATION.md §10).
    #[test]
    fn codable_doubles_match_swift() {
        assert_eq!(codable_double(100.0), "100");
        assert_eq!(codable_double(1e20), "1e+20");
        assert_eq!(codable_double(1e-7), "1e-07");
        assert_eq!(codable_double(-0.0), "-0");
        assert_eq!(codable_double(1e15), "1000000000000000");
        assert_eq!(codable_double(1e16), "1e+16");
        assert_eq!(codable_double(0.0001), "0.0001");
        assert_eq!(codable_double(1e-5), "1e-05");
    }

    #[test]
    fn json_serialization_strings_keep_unicode_and_slashes() {
        assert_eq!(
            json_serialization_quote("a/b"),
            "\"a/b\""
        );
        assert_eq!(json_serialization_quote("a\tb"), "\"a\\tb\"");
        assert_eq!(json_serialization_quote("a\u{1}b"), "\"a\\u0001b\"");
        assert_eq!(json_serialization_quote("你好"), "\"你好\"");
    }

    #[test]
    fn python_quoting_can_force_ascii() {
        assert_eq!(python_quote("你好", false), "\"你好\"");
        assert_eq!(python_quote("你好", true), "\"\\u4f60\\u597d\"");
        assert_eq!(python_quote("🙂", true), "\"\\ud83d\\ude42\"");
    }

    #[test]
    fn javascript_quoting_escapes_line_separators() {
        assert_eq!(javascript_quote("a\u{2028}b"), "\"a\\u2028b\"");
        assert_eq!(javascript_quote("你好"), "\"你好\"");
    }
}
