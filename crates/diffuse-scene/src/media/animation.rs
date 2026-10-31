//! `Media/Animation.swift` — clip playback, 1D blend spaces, animation graphs and
//! the per-entity joint palette.

use std::collections::BTreeMap;

use serde::{Deserialize, Deserializer, Serialize, Serializer};

use crate::entity_id::RuntimeComponent;

/// `AssetReferenceComponent`-driven clip playback on an entity.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct AnimationPlayer {
    /// Clip name; `None` selects the clip at index 0.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub clip_name: Option<String>,
    pub speed: f32,
    #[serde(rename = "loop")]
    pub loop_: bool,
    pub is_playing: bool,
    /// Playback time in seconds.
    pub time: f64,
}

impl AnimationPlayer {
    pub fn new(
        clip_name: Option<String>,
        speed: f32,
        loop_: bool,
        is_playing: bool,
        time: f64,
    ) -> Self {
        AnimationPlayer {
            clip_name,
            speed,
            loop_,
            is_playing,
            time,
        }
    }
}

impl Default for AnimationPlayer {
    fn default() -> Self {
        AnimationPlayer::new(None, 1.0, true, true, 0.0)
    }
}

impl RuntimeComponent for AnimationPlayer {}

/// A named 1D blend space. Samples are ordered by `threshold` at evaluation time.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct AnimationBlendSpace1D {
    pub name: String,
    pub parameter: String,
    pub samples: Vec<AnimationBlendSample1D>,
}

impl AnimationBlendSpace1D {
    pub fn new(
        name: impl Into<String>,
        parameter: impl Into<String>,
        samples: Vec<AnimationBlendSample1D>,
    ) -> Self {
        AnimationBlendSpace1D {
            name: name.into(),
            parameter: parameter.into(),
            samples,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct AnimationBlendSample1D {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub clip_name: Option<String>,
    pub threshold: f32,
}

impl AnimationBlendSample1D {
    pub fn new(clip_name: Option<String>, threshold: f32) -> Self {
        AnimationBlendSample1D {
            clip_name,
            threshold,
        }
    }
}

/// Swift hand-writes `Codable` for this enum: a `type` discriminator plus either
/// `clipName` (omitted when nil) or `name`.
#[derive(Clone, Debug, PartialEq)]
pub enum AnimationMotion {
    Clip(Option<String>),
    BlendSpace1D(String),
}

impl Serialize for AnimationMotion {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        use serde::ser::SerializeMap;

        let mut map = serializer.serialize_map(None)?;
        match self {
            AnimationMotion::Clip(clip_name) => {
                map.serialize_entry("type", "clip")?;
                if let Some(clip_name) = clip_name {
                    map.serialize_entry("clipName", clip_name)?;
                }
            }
            AnimationMotion::BlendSpace1D(name) => {
                map.serialize_entry("type", "blendSpace1D")?;
                map.serialize_entry("name", name)?;
            }
        }
        map.end()
    }
}

#[derive(Deserialize)]
struct AnimationMotionDocument {
    #[serde(rename = "type")]
    motion_type: String,
    #[serde(rename = "clipName", default)]
    clip_name: Option<String>,
    #[serde(default)]
    name: Option<String>,
}

impl<'de> Deserialize<'de> for AnimationMotion {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let document = AnimationMotionDocument::deserialize(deserializer)?;
        match document.motion_type.as_str() {
            "clip" => Ok(AnimationMotion::Clip(document.clip_name)),
            "blendSpace1D" => document
                .name
                .map(AnimationMotion::BlendSpace1D)
                .ok_or_else(|| {
                    serde::de::Error::custom(
                        "missing field `name` for animation motion type 'blendSpace1D'",
                    )
                }),
            other => Err(serde::de::Error::custom(format!(
                "Unknown animation motion type '{other}'"
            ))),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct AnimationState {
    pub name: String,
    pub motion: AnimationMotion,
    pub speed: f32,
    #[serde(rename = "loop")]
    pub loop_: bool,
}

impl AnimationState {
    pub fn new(
        name: impl Into<String>,
        motion: AnimationMotion,
        speed: f32,
        loop_: bool,
    ) -> Self {
        AnimationState {
            name: name.into(),
            motion,
            speed,
            loop_,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum AnimationTransitionComparison {
    #[serde(rename = "greaterThan")]
    GreaterThan,
    #[serde(rename = "greaterThanOrEqual")]
    GreaterThanOrEqual,
    #[serde(rename = "lessThan")]
    LessThan,
    #[serde(rename = "lessThanOrEqual")]
    LessThanOrEqual,
    #[serde(rename = "equal")]
    Equal,
    #[serde(rename = "notEqual")]
    NotEqual,
}

impl AnimationTransitionComparison {
    pub const fn raw_value(&self) -> &'static str {
        match self {
            AnimationTransitionComparison::GreaterThan => "greaterThan",
            AnimationTransitionComparison::GreaterThanOrEqual => "greaterThanOrEqual",
            AnimationTransitionComparison::LessThan => "lessThan",
            AnimationTransitionComparison::LessThanOrEqual => "lessThanOrEqual",
            AnimationTransitionComparison::Equal => "equal",
            AnimationTransitionComparison::NotEqual => "notEqual",
        }
    }

    pub fn from_raw_value(value: &str) -> Option<Self> {
        match value {
            "greaterThan" => Some(AnimationTransitionComparison::GreaterThan),
            "greaterThanOrEqual" => Some(AnimationTransitionComparison::GreaterThanOrEqual),
            "lessThan" => Some(AnimationTransitionComparison::LessThan),
            "lessThanOrEqual" => Some(AnimationTransitionComparison::LessThanOrEqual),
            "equal" => Some(AnimationTransitionComparison::Equal),
            "notEqual" => Some(AnimationTransitionComparison::NotEqual),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct AnimationTransition {
    pub from: String,
    pub to: String,
    pub parameter: String,
    pub comparison: AnimationTransitionComparison,
    pub threshold: f32,
    pub duration: f64,
}

impl AnimationTransition {
    pub fn new(
        from: impl Into<String>,
        to: impl Into<String>,
        parameter: impl Into<String>,
        comparison: AnimationTransitionComparison,
        threshold: f32,
        duration: f64,
    ) -> Self {
        AnimationTransition {
            from: from.into(),
            to: to.into(),
            parameter: parameter.into(),
            comparison,
            threshold,
            duration: duration.max(0.0),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct AnimationStateMachine {
    pub initial_state: String,
    pub states: Vec<AnimationState>,
    pub transitions: Vec<AnimationTransition>,
}

impl AnimationStateMachine {
    pub fn new(
        initial_state: impl Into<String>,
        states: Vec<AnimationState>,
        transitions: Vec<AnimationTransition>,
    ) -> Self {
        AnimationStateMachine {
            initial_state: initial_state.into(),
            states,
            transitions,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct AnimationGraph {
    pub blend_spaces_1d: Vec<AnimationBlendSpace1D>,
    pub state_machine: AnimationStateMachine,
}

impl AnimationGraph {
    pub fn new(
        blend_spaces_1d: Vec<AnimationBlendSpace1D>,
        state_machine: AnimationStateMachine,
    ) -> Self {
        AnimationGraph {
            blend_spaces_1d,
            state_machine,
        }
    }
}

/// Runtime state for an animation graph; `AnimationRuntime` mutates the playback
/// fields.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct AnimationGraphPlayer {
    pub graph: AnimationGraph,
    pub parameters: BTreeMap<String, f32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub active_state: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub previous_state: Option<String>,
    pub active_time: f64,
    pub previous_time: f64,
    pub transition_elapsed: f64,
    pub transition_duration: f64,
    pub speed: f32,
    pub is_playing: bool,
}

impl AnimationGraphPlayer {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        graph: AnimationGraph,
        parameters: BTreeMap<String, f32>,
        active_state: Option<String>,
        previous_state: Option<String>,
        active_time: f64,
        previous_time: f64,
        transition_elapsed: f64,
        transition_duration: f64,
        speed: f32,
        is_playing: bool,
    ) -> Self {
        AnimationGraphPlayer {
            graph,
            parameters,
            active_state,
            previous_state,
            active_time,
            previous_time,
            transition_elapsed,
            transition_duration: transition_duration.max(0.0),
            speed,
            is_playing,
        }
    }
}

impl AnimationGraphPlayer {
    /// Swift's defaults: no parameters, no active state, zero times, speed 1, playing.
    pub fn from_graph(graph: AnimationGraph) -> Self {
        AnimationGraphPlayer::new(
            graph,
            BTreeMap::new(),
            None,
            None,
            0.0,
            0.0,
            0.0,
            0.0,
            1.0,
            true,
        )
    }
}

impl RuntimeComponent for AnimationGraphPlayer {}

/// One skeleton's joint matrices, in palette order.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct JointPalette {
    pub matrices: Vec<diffuse_math::simd::simd_compat::Float4x4>,
}

impl JointPalette {
    pub fn new(matrices: Vec<diffuse_math::simd::simd_compat::Float4x4>) -> Self {
        JointPalette { matrices }
    }

    /// Swift's `JointPalette.identity`: a single identity matrix.
    pub fn identity() -> Self {
        JointPalette {
            matrices: vec![diffuse_math::simd::simd_compat::MATRIX_IDENTITY_FLOAT4X4],
        }
    }
}

/// Scene-level resource mapping an entity to its joint palette.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct JointPaletteMap {
    pub palettes: std::collections::BTreeMap<crate::entity_id::EntityID, JointPalette>,
}

impl JointPaletteMap {
    pub fn new(
        palettes: std::collections::BTreeMap<crate::entity_id::EntityID, JointPalette>,
    ) -> Self {
        JointPaletteMap { palettes }
    }

    /// The palette for `entity`, or `None` when the entity has none.
    #[inline]
    pub fn palette(&self, entity: crate::entity_id::EntityID) -> Option<&JointPalette> {
        self.palettes.get(&entity)
    }
}

#[cfg(test)]
mod joint_palette_tests {
    use super::*;
    use crate::entity_id::EntityID;

    #[test]
    fn an_identity_palette_holds_one_identity_matrix() {
        let palette = JointPalette::identity();
        assert_eq!(palette.matrices.len(), 1);
        assert_eq!(
            palette.matrices[0],
            diffuse_math::simd::simd_compat::MATRIX_IDENTITY_FLOAT4X4
        );
    }

    #[test]
    fn a_missing_palette_is_none() {
        let map = JointPaletteMap::default();
        assert!(map.palette(EntityID::new(1, 0)).is_none());
    }
}
