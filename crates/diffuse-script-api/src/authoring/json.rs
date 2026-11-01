//! Minimal JSON value/parser for the script ABI.
//!
//! `diffuse-script-api` is std-only (MIGRATION.md §4 D1: it is the single
//! dependency user scripts take), so it cannot use serde_json. This parser is a
//! faithful subset of what Swift's `JSONSerialization` accepted for parameters:
//! objects, arrays, strings, numbers, booleans and null, with sorted-key output
//! to match `JSONSerialization.data(withJSONObject:options: [.sortedKeys])`.

use std::collections::BTreeMap;

pub type JsonObject = BTreeMap<String, JsonValue>;

#[derive(Clone, Debug, PartialEq)]
pub enum JsonValue {
    Null,
    Bool(bool),
    Integer(i64),
    Unsigned(u64),
    Number(f64),
    Float(f32),
    String(String),
    Array(Vec<JsonValue>),
    Object(JsonObject),
}

impl JsonValue {
    pub fn same_json_kind(&self, other: &JsonValue) -> bool {
        matches!(
            (self, other),
            (JsonValue::Bool(_), JsonValue::Bool(_))
                | (JsonValue::Null, JsonValue::Null)
                | (JsonValue::Integer(_), JsonValue::Integer(_))
                | (JsonValue::Unsigned(_), JsonValue::Unsigned(_))
                | (JsonValue::Float(_), JsonValue::Float(_))
                | (JsonValue::Number(_), JsonValue::Number(_))
                | (JsonValue::String(_), JsonValue::String(_))
                | (JsonValue::Array(_), JsonValue::Array(_))
                | (JsonValue::Object(_), JsonValue::Object(_))
        )
    }

    pub fn json_equals(&self, other: &JsonValue) -> bool {
        self == other
    }

    /// Numeric view used by `floatParameter`/`doubleParameter`.
    pub fn as_f64(&self) -> Option<f64> {
        match self {
            JsonValue::Integer(value) => Some(*value as f64),
            JsonValue::Unsigned(value) => Some(*value as f64),
            JsonValue::Number(value) => Some(*value),
            JsonValue::Float(value) => Some(f64::from(*value)),
            _ => None,
        }
    }

    pub fn as_str(&self) -> Option<&str> {
        match self {
            JsonValue::String(value) => Some(value),
            _ => None,
        }
    }

    /// Foundation's NSNumber bridge also accepts JSON booleans.
    pub fn nsnumber_double_value(&self) -> Option<f64> {
        match self {
            Self::Bool(value) => Some(if *value { 1.0 } else { 0.0 }),
            _ => self.as_f64(),
        }
    }

    pub fn nsnumber_uint64_value(&self) -> Option<u64> {
        match self {
            Self::Bool(value) => Some(u64::from(*value)),
            Self::Integer(value) => Some(*value as u64),
            Self::Unsigned(value) => Some(*value),
            Self::Number(value) => Some(truncating_uint64(*value)),
            Self::Float(value) => Some(truncating_uint64(f64::from(*value))),
            _ => None,
        }
    }

    pub fn as_array(&self) -> Option<&[JsonValue]> {
        match self {
            JsonValue::Array(values) => Some(values),
            _ => None,
        }
    }

    pub fn as_object(&self) -> Option<&JsonObject> {
        match self {
            JsonValue::Object(values) => Some(values),
            _ => None,
        }
    }

    pub fn as_u64(&self) -> Option<u64> {
        match self {
            JsonValue::Integer(value) if *value >= 0 => Some(*value as u64),
            JsonValue::Unsigned(value) => Some(*value),
            JsonValue::Number(value)
                if value.is_finite()
                    && *value >= 0.0
                    && *value < 18_446_744_073_709_551_616.0
                    && value.fract() == 0.0 =>
            {
                Some(*value as u64)
            }
            JsonValue::Float(value)
                if value.is_finite()
                    && *value >= 0.0
                    && f64::from(*value) < 18_446_744_073_709_551_616.0
                    && value.fract() == 0.0 =>
            {
                Some(*value as u64)
            }
            _ => None,
        }
    }

    /// Serializes with sorted object keys, matching Swift's `.sortedKeys`.
    pub fn to_json(&self) -> String {
        self.try_to_json()
            .expect("Swift JSON serialization rejects NaN and infinity")
    }

    pub fn try_to_json(&self) -> Option<String> {
        if !self.is_finite() {
            return None;
        }
        let mut out = String::new();
        self.write_json(&mut out);
        Some(out)
    }

    fn is_finite(&self) -> bool {
        match self {
            Self::Number(value) => value.is_finite(),
            Self::Float(value) => value.is_finite(),
            Self::Array(values) => values.iter().all(Self::is_finite),
            Self::Object(values) => values.values().all(Self::is_finite),
            _ => true,
        }
    }

    fn write_json(&self, out: &mut String) {
        match self {
            JsonValue::Null => out.push_str("null"),
            JsonValue::Bool(true) => out.push_str("true"),
            JsonValue::Bool(false) => out.push_str("false"),
            JsonValue::Integer(value) => out.push_str(&value.to_string()),
            JsonValue::Unsigned(value) => out.push_str(&value.to_string()),
            JsonValue::Number(value) => out.push_str(&format_number(*value)),
            JsonValue::Float(value) => out.push_str(&format_float(*value)),
            JsonValue::String(value) => write_string(value, out),
            JsonValue::Array(values) => {
                out.push('[');
                for (index, value) in values.iter().enumerate() {
                    if index > 0 {
                        out.push(',');
                    }
                    value.write_json(out);
                }
                out.push(']');
            }
            JsonValue::Object(values) => {
                out.push('{');
                for (index, (key, value)) in values.iter().enumerate() {
                    if index > 0 {
                        out.push(',');
                    }
                    write_string(key, out);
                    out.push(':');
                    value.write_json(out);
                }
                out.push('}');
            }
        }
    }
}

fn truncating_uint64(value: f64) -> u64 {
    if !value.is_finite() {
        return 0;
    }
    if value < 0.0 && value >= i64::MIN as f64 {
        (value as i64) as u64
    } else {
        value.trunc().rem_euclid(18_446_744_073_709_551_616.0) as u64
    }
}

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
            '\u{0C}' => out.push_str("\\f"),
            character if (character as u32) < 0x20 => {
                out.push_str(&format!("\\u{:04x}", character as u32));
            }
            character => out.push(character),
        }
    }
    out.push('"');
}

/// Swift wrote whole doubles without a trailing `.0` in JSON.
fn format_number(value: f64) -> String {
    if value == 0.0 {
        return if value.is_sign_negative() { "-0" } else { "0" }.to_string();
    }
    let exponent = value.abs().log10().floor() as i32;
    if !(-4..16).contains(&exponent) {
        normalized_exponent(&format!("{value:e}"), exponent)
    } else {
        value.to_string().trim_end_matches(".0").to_string()
    }
}

fn format_float(value: f32) -> String {
    if value == 0.0 {
        return if value.is_sign_negative() { "-0" } else { "0" }.to_string();
    }
    let exponent = value.abs().log10().floor() as i32;
    if !(-4..8).contains(&exponent) {
        normalized_exponent(&format!("{value:e}"), exponent)
    } else {
        value.to_string().trim_end_matches(".0").to_string()
    }
}

fn normalized_exponent(scientific: &str, fallback: i32) -> String {
    let Some((mantissa, raw_exponent)) = scientific.split_once('e') else {
        return scientific.to_string();
    };
    let exponent = raw_exponent.parse::<i32>().unwrap_or(fallback);
    format!(
        "{mantissa}e{}{:02}",
        if exponent < 0 { '-' } else { '+' },
        exponent.abs()
    )
}

/// Parses a JSON object; anything else (invalid text, a non-object root) yields
/// an empty object, matching Swift's `decodeParameters` fallback.
pub fn parse_object(text: &str) -> JsonObject {
    match parse(text) {
        Some(JsonValue::Object(values)) => values,
        _ => JsonObject::new(),
    }
}

/// Parses one JSON value.
pub fn parse(text: &str) -> Option<JsonValue> {
    let text = text.strip_prefix('\u{feff}').unwrap_or(text);
    let chars: Vec<char> = text.chars().collect();
    let mut parser = Parser { chars, index: 0 };
    parser.skip_whitespace();
    let value = parser.parse_value()?;
    parser.skip_whitespace();
    if parser.index == parser.chars.len() {
        Some(value)
    } else {
        None
    }
}

struct Parser {
    chars: Vec<char>,
    index: usize,
}

impl Parser {
    fn peek(&self) -> Option<char> {
        self.chars.get(self.index).copied()
    }

    fn next(&mut self) -> Option<char> {
        let value = self.chars.get(self.index).copied();
        if value.is_some() {
            self.index += 1;
        }
        value
    }

    fn skip_whitespace(&mut self) {
        while matches!(
            self.peek(),
            Some(' ') | Some('\t') | Some('\n') | Some('\r')
        ) {
            self.index += 1;
        }
    }

    fn parse_value(&mut self) -> Option<JsonValue> {
        self.skip_whitespace();
        match self.peek()? {
            '{' => self.parse_object(),
            '[' => self.parse_array(),
            '"' => self.parse_string().map(JsonValue::String),
            't' => self.expect_literal("true", JsonValue::Bool(true)),
            'f' => self.expect_literal("false", JsonValue::Bool(false)),
            'n' => self.expect_literal("null", JsonValue::Null),
            _ => self.parse_number(),
        }
    }

    fn expect_literal(&mut self, literal: &str, value: JsonValue) -> Option<JsonValue> {
        for expected in literal.chars() {
            if self.next()? != expected {
                return None;
            }
        }
        Some(value)
    }

    fn parse_object(&mut self) -> Option<JsonValue> {
        self.next(); // '{'
        let mut values = JsonObject::new();
        self.skip_whitespace();
        if self.peek() == Some('}') {
            self.next();
            return Some(JsonValue::Object(values));
        }
        loop {
            self.skip_whitespace();
            let key = self.parse_string()?;
            self.skip_whitespace();
            if self.next()? != ':' {
                return None;
            }
            let value = self.parse_value()?;
            values.insert(key, value);
            self.skip_whitespace();
            match self.next()? {
                ',' => continue,
                '}' => return Some(JsonValue::Object(values)),
                _ => return None,
            }
        }
    }

    fn parse_array(&mut self) -> Option<JsonValue> {
        self.next(); // '['
        let mut values = Vec::new();
        self.skip_whitespace();
        if self.peek() == Some(']') {
            self.next();
            return Some(JsonValue::Array(values));
        }
        loop {
            values.push(self.parse_value()?);
            self.skip_whitespace();
            match self.next()? {
                ',' => continue,
                ']' => return Some(JsonValue::Array(values)),
                _ => return None,
            }
        }
    }

    fn parse_string(&mut self) -> Option<String> {
        if self.next()? != '"' {
            return None;
        }
        let mut out = String::new();
        loop {
            match self.next()? {
                '"' => return Some(out),
                '\\' => match self.next()? {
                    '"' => out.push('"'),
                    '\\' => out.push('\\'),
                    '/' => out.push('/'),
                    'b' => out.push('\u{08}'),
                    'f' => out.push('\u{0C}'),
                    'n' => out.push('\n'),
                    'r' => out.push('\r'),
                    't' => out.push('\t'),
                    'u' => {
                        let mut code = 0u32;
                        for _ in 0..4 {
                            let digit = self.next()?.to_digit(16)?;
                            code = code * 16 + digit;
                        }
                        // Surrogate pairs are decoded when the high half leads.
                        if (0xD800..0xDC00).contains(&code) {
                            if self.next()? != '\\' || self.next()? != 'u' {
                                return None;
                            }
                            let mut low = 0u32;
                            for _ in 0..4 {
                                let digit = self.next()?.to_digit(16)?;
                                low = low * 16 + digit;
                            }
                            if !(0xDC00..0xE000).contains(&low) {
                                return None;
                            }
                            let combined =
                                0x10000 + ((code - 0xD800) << 10) + (low.wrapping_sub(0xDC00));
                            out.push(char::from_u32(combined)?);
                        } else {
                            out.push(char::from_u32(code)?);
                        }
                    }
                    _ => return None,
                },
                character if (character as u32) < 0x20 => return None,
                character => out.push(character),
            }
        }
    }

    fn parse_number(&mut self) -> Option<JsonValue> {
        let start = self.index;
        if self.peek() == Some('-') {
            self.index += 1;
        }
        match self.peek()? {
            '0' => {
                self.index += 1;
                if matches!(self.peek(), Some('0'..='9')) {
                    return None;
                }
            }
            '1'..='9' => {
                while matches!(self.peek(), Some('0'..='9')) {
                    self.index += 1;
                }
            }
            _ => return None,
        }
        let mut has_fraction = false;
        if self.peek() == Some('.') {
            has_fraction = true;
            self.index += 1;
            let digits = self.index;
            while matches!(self.peek(), Some('0'..='9')) {
                self.index += 1;
            }
            if digits == self.index {
                return None;
            }
        }
        if matches!(self.peek(), Some('e' | 'E')) {
            has_fraction = true;
            self.index += 1;
            if matches!(self.peek(), Some('+' | '-')) {
                self.index += 1;
            }
            let digits = self.index;
            while matches!(self.peek(), Some('0'..='9')) {
                self.index += 1;
            }
            if digits == self.index {
                return None;
            }
        }
        let text: String = self.chars[start..self.index].iter().collect();
        if !has_fraction {
            if text == "-0" {
                return Some(JsonValue::Number(-0.0));
            }
            if let Ok(value) = text.parse::<i64>() {
                return Some(JsonValue::Integer(value));
            }
            if let Ok(value) = text.parse::<u64>() {
                return Some(JsonValue::Unsigned(value));
            }
        }
        text.parse::<f64>()
            .ok()
            .filter(|value| value.is_finite())
            .map(JsonValue::Number)
    }
}
