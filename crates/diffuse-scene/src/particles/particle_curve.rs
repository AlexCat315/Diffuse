//! Authoring curves and their keyframe evaluation.
//!
//! Ported from `Engine/Sources/SceneRuntime/Particles/ParticleCurve.swift`.

// Swift's `!(a > b)` predicates also reject NaN. Keep the negated form instead
// of rewriting to `a <= b`, which would change behaviour on NaN inputs.
#![allow(clippy::neg_cmp_op_on_partial_ord)]

use diffuse_math::simd::simd_compat::simd_clamp_scalar;
use serde::de::{MapAccess, Visitor};
use serde::{Deserialize, Deserializer, Serialize, Serializer};

/// Swift's `min` is `y < x ? y : x`, so a NaN operand yields the first argument.
#[inline]
fn swift_min(x: f32, y: f32) -> f32 {
    if y < x { y } else { x }
}

/// Swift's `max` is `y >= x ? y : x`, so a NaN operand yields the first argument.
#[inline]
fn swift_max(x: f32, y: f32) -> f32 {
    if y >= x { y } else { x }
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct ParticleCurveKeyframe {
    pub time: f32,
    pub value: f32,
}

impl ParticleCurveKeyframe {
    pub fn new(time: f32, value: f32) -> Self {
        ParticleCurveKeyframe {
            time: simd_clamp_scalar(time, 0.0, 1.0),
            value,
        }
    }
}

/// `RawRepresentable` over `String`, with the `constant`/`keyframes` payloads
/// encoded as a keyed object like Swift's custom `encode(to:)`.
#[derive(Clone, Debug, PartialEq)]
pub enum ParticleCurve {
    Constant(f32),
    Linear,
    EaseIn,
    EaseOut,
    EaseInOut,
    Keyframes(Vec<ParticleCurveKeyframe>),
}

impl ParticleCurve {
    pub const ALL: [ParticleCurve; 5] = [
        ParticleCurve::Constant(1.0),
        ParticleCurve::Linear,
        ParticleCurve::EaseIn,
        ParticleCurve::EaseOut,
        ParticleCurve::EaseInOut,
    ];

    pub fn from_raw_value(raw_value: &str) -> Option<ParticleCurve> {
        match raw_value {
            "constant" => Some(ParticleCurve::Constant(1.0)),
            "linear" => Some(ParticleCurve::Linear),
            "easeIn" => Some(ParticleCurve::EaseIn),
            "easeOut" => Some(ParticleCurve::EaseOut),
            "easeInOut" => Some(ParticleCurve::EaseInOut),
            "keyframes" => Some(ParticleCurve::Keyframes(Vec::new())),
            _ => None,
        }
    }

    pub fn raw_value(&self) -> &'static str {
        match self {
            ParticleCurve::Constant(_) => "constant",
            ParticleCurve::Linear => "linear",
            ParticleCurve::EaseIn => "easeIn",
            ParticleCurve::EaseOut => "easeOut",
            ParticleCurve::EaseInOut => "easeInOut",
            ParticleCurve::Keyframes(_) => "keyframes",
        }
    }

    pub fn evaluate(&self, t: f32) -> f32 {
        let x = simd_clamp_scalar(t, 0.0, 1.0);
        match self {
            ParticleCurve::Constant(value) => *value,
            ParticleCurve::Linear => x,
            ParticleCurve::EaseIn => x * x,
            ParticleCurve::EaseOut => 1.0 - (1.0 - x) * (1.0 - x),
            ParticleCurve::EaseInOut => {
                if x < 0.5 {
                    return 2.0 * x * x;
                }
                let inverse = 1.0 - x;
                1.0 - 2.0 * inverse * inverse
            }
            ParticleCurve::Keyframes(keyframes) => Self::evaluate_keyframes(keyframes, x),
        }
    }

    /// Conservative `(min, max)` value range used by render bounds estimation.
    pub fn conservative_value_range(&self) -> (f32, f32) {
        match self {
            ParticleCurve::Constant(value) => (*value, *value),
            ParticleCurve::Linear
            | ParticleCurve::EaseIn
            | ParticleCurve::EaseOut
            | ParticleCurve::EaseInOut => (0.0, 1.0),
            ParticleCurve::Keyframes(keyframes) => {
                if keyframes.is_empty() {
                    return (0.0, 1.0);
                }
                let mut minimum = keyframes[0].value;
                let mut maximum = keyframes[0].value;
                for keyframe in &keyframes[1..] {
                    minimum = swift_min(minimum, keyframe.value);
                    maximum = swift_max(maximum, keyframe.value);
                }
                (minimum, maximum)
            }
        }
    }

    fn evaluate_keyframes(keyframes: &[ParticleCurveKeyframe], t: f32) -> f32 {
        if keyframes.is_empty() {
            return t;
        }
        // Swift sorts by `time`, breaking ties by the original offset (stable).
        let mut sorted: Vec<(usize, &ParticleCurveKeyframe)> = keyframes.iter().enumerate().collect();
        for index in 1..sorted.len() {
            let mut cursor = index;
            while cursor > 0 && keyframe_comes_before(sorted[cursor], sorted[cursor - 1]) {
                sorted.swap(cursor, cursor - 1);
                cursor -= 1;
            }
        }
        let Some(first) = sorted.first() else {
            return t;
        };
        let first = first.1;
        let Some(last) = sorted.last() else {
            return first.value;
        };
        let last = last.1;
        if t <= first.time {
            return first.value;
        }
        if t >= last.time {
            return last.value;
        }
        for index in 1..sorted.len() {
            let lower = sorted[index - 1].1;
            let upper = sorted[index].1;
            if !(t <= upper.time) {
                continue;
            }
            let span = upper.time - lower.time;
            if !(span > 0.0001) {
                return upper.value;
            }
            let local_t = (t - lower.time) / span;
            return lower.value + (upper.value - lower.value) * local_t;
        }
        last.value
    }
}

fn keyframe_comes_before(
    lhs: (usize, &ParticleCurveKeyframe),
    rhs: (usize, &ParticleCurveKeyframe),
) -> bool {
    if lhs.1.time == rhs.1.time {
        return lhs.0 < rhs.0;
    }
    lhs.1.time < rhs.1.time
}

impl Serialize for ParticleCurve {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        use serde::ser::SerializeStruct;
        match self {
            ParticleCurve::Constant(value) => {
                let mut state = serializer.serialize_struct("ParticleCurve", 2)?;
                state.serialize_field("type", self.raw_value())?;
                state.serialize_field("value", value)?;
                state.end()
            }
            ParticleCurve::Linear
            | ParticleCurve::EaseIn
            | ParticleCurve::EaseOut
            | ParticleCurve::EaseInOut => serializer.serialize_str(self.raw_value()),
            ParticleCurve::Keyframes(keyframes) => {
                let mut state = serializer.serialize_struct("ParticleCurve", 2)?;
                state.serialize_field("type", self.raw_value())?;
                state.serialize_field("keyframes", keyframes)?;
                state.end()
            }
        }
    }
}

impl<'de> Deserialize<'de> for ParticleCurve {
    /// Reproduces Swift's fallback chain: a plain raw-value string first, then a
    /// keyed object with a `type` discriminator defaulting to `"linear"`.
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct ParticleCurveVisitor;

        impl<'de> Visitor<'de> for ParticleCurveVisitor {
            type Value = ParticleCurve;

            fn expecting(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                formatter.write_str("a particle curve string or object")
            }

            fn visit_str<E: serde::de::Error>(self, value: &str) -> Result<Self::Value, E> {
                ParticleCurve::from_raw_value(value).ok_or_else(|| {
                    E::custom(format!("Unknown particle curve raw value: {value}"))
                })
            }

            fn visit_map<A: MapAccess<'de>>(self, map: A) -> Result<Self::Value, A::Error> {
                #[derive(Deserialize)]
                struct Raw {
                    #[serde(rename = "type")]
                    curve_type: Option<String>,
                    value: Option<f32>,
                    keyframes: Option<Vec<ParticleCurveKeyframe>>,
                }

                let raw = Raw::deserialize(serde::de::value::MapAccessDeserializer::new(map))?;
                let curve_type = raw.curve_type.unwrap_or_else(|| "linear".to_string());
                if curve_type == "constant" {
                    Ok(ParticleCurve::Constant(raw.value.unwrap_or(1.0)))
                } else if curve_type == "keyframes" {
                    Ok(ParticleCurve::Keyframes(raw.keyframes.unwrap_or_default()))
                } else {
                    Ok(ParticleCurve::from_raw_value(&curve_type).unwrap_or(ParticleCurve::Linear))
                }
            }
        }

        deserializer.deserialize_any(ParticleCurveVisitor)
    }
}
