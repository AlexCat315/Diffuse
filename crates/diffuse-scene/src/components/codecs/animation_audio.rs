//! `Codecs/AnimationAudio.swift` — audio clips and the animation playback model.
//!
//! Key spellings are the Swift dictionary keys, so documents produced by either
//! implementation decode identically. Optional fields (`clipName`, `activeState`,
//! `previousState`, a blend sample's `clipName`) are omitted from the document when
//! absent, exactly like Swift's `if let … { d[key] = … }`.
//!
//! The animation model itself lives in [`crate::media::animation`]; the codecs only
//! translate its snake_case Rust fields from and to the persisted shape, building
//! values through the clamping constructors so the decoded runtime state obeys the
//! same invariants as `AnimationTransition.init` (`duration >= 0`) and
//! `AnimationGraphPlayer.init` (`transitionDuration >= 0`).

use std::collections::BTreeMap;

use crate::components::codecs::builtin_component_codecs::BuiltinComponentCodecs;
use crate::components::component_json_helpers::{
    double, json_to_array, json_to_bool, json_to_dict, json_to_double, json_to_float,
    json_to_string, json_to_string_float_dict, number, object,
};
use crate::components::core::value::ComponentValue;
use crate::components::editing::ComponentEditError;
use crate::media::animation::{
    AnimationBlendSample1D, AnimationBlendSpace1D, AnimationGraph, AnimationGraphPlayer,
    AnimationMotion, AnimationPlayer, AnimationState, AnimationStateMachine, AnimationTransition,
    AnimationTransitionComparison,
};
use crate::media::audio::{AudioListener, AudioSource};

impl BuiltinComponentCodecs {
    /// Swift `serializeAudioSource`.
    pub fn serialize_audio_source(component: &AudioSource) -> BTreeMap<String, ComponentValue> {
        object([
            (
                "clipName",
                ComponentValue::String(component.clip_name.clone()),
            ),
            ("volume", number(component.volume)),
            ("pitch", number(component.pitch)),
            ("loop", ComponentValue::Bool(component.loop_)),
            ("playOnAwake", ComponentValue::Bool(component.play_on_awake)),
            ("spatialBlend", number(component.spatial_blend)),
        ])
    }

    /// Swift `deserializeAudioSource`.
    pub fn deserialize_audio_source(document: &BTreeMap<String, ComponentValue>) -> AudioSource {
        AudioSource::new(
            json_to_string(document.get("clipName")).unwrap_or(""),
            json_to_float(document.get("volume")).unwrap_or(1.0),
            json_to_float(document.get("pitch")).unwrap_or(1.0),
            json_to_bool(document.get("loop")).unwrap_or(false),
            json_to_bool(document.get("playOnAwake")).unwrap_or(true),
            json_to_float(document.get("spatialBlend")).unwrap_or(1.0),
        )
    }

    /// Swift `serializeAudioListener`.
    pub fn serialize_audio_listener(component: &AudioListener) -> BTreeMap<String, ComponentValue> {
        object([("masterVolume", number(component.master_volume))])
    }

    /// Swift `deserializeAudioListener`.
    pub fn deserialize_audio_listener(
        document: &BTreeMap<String, ComponentValue>,
    ) -> AudioListener {
        AudioListener::new(json_to_float(document.get("masterVolume")).unwrap_or(1.0))
    }

    /// Swift `serializeAnimationPlayer` — `clipName` is omitted when `nil`.
    pub fn serialize_animation_player(
        component: &AnimationPlayer,
    ) -> BTreeMap<String, ComponentValue> {
        let mut document = object([
            ("isPlaying", ComponentValue::Bool(component.is_playing)),
            ("loop", ComponentValue::Bool(component.loop_)),
            ("speed", number(component.speed)),
            ("time", double(component.time)),
        ]);
        if let Some(name) = &component.clip_name {
            document.insert("clipName".to_string(), ComponentValue::String(name.clone()));
        }
        document
    }

    /// Swift `deserializeAnimationPlayer`.
    pub fn deserialize_animation_player(
        document: &BTreeMap<String, ComponentValue>,
    ) -> AnimationPlayer {
        AnimationPlayer::new(
            json_to_string(document.get("clipName")).map(str::to_string),
            json_to_float(document.get("speed")).unwrap_or(1.0),
            json_to_bool(document.get("loop")).unwrap_or(true),
            json_to_bool(document.get("isPlaying")).unwrap_or(true),
            json_to_double(document.get("time")).unwrap_or(0.0),
        )
    }

    /// Swift `mergeAnimationPlayer`.
    ///
    /// Switching clips restarts playback; other controls retain progress, and an
    /// explicitly supplied playhead is honored by transaction callers.
    pub fn merge_animation_player(
        previous: &ComponentValue,
        changes: &ComponentValue,
    ) -> Result<ComponentValue, ComponentEditError> {
        let merged = previous.merging(changes)?;
        let ComponentValue::Object(change_fields) = changes else {
            return Ok(merged);
        };
        let Some(clip) = change_fields.get("clipName") else {
            return Ok(merged);
        };
        let previous_clip = json_to_dict(Some(previous))
            .and_then(|fields| fields.get("clipName"))
            .cloned()
            .unwrap_or(ComponentValue::Null);
        if *clip == previous_clip || change_fields.contains_key("time") {
            return Ok(merged);
        }
        let mut fields = match merged {
            ComponentValue::Object(fields) => fields,
            other => return Ok(other),
        };
        fields.insert("time".to_string(), double(0.0));
        Ok(ComponentValue::Object(fields))
    }

    /// Swift `serializeAnimationGraphPlayer`.
    pub fn serialize_animation_graph_player(
        component: &AnimationGraphPlayer,
    ) -> BTreeMap<String, ComponentValue> {
        let parameters = component
            .parameters
            .iter()
            .map(|(key, value)| (key.clone(), number(*value)))
            .collect();
        let mut document = object([
            (
                "graph",
                ComponentValue::Object(Self::serialize_animation_graph(&component.graph)),
            ),
            ("parameters", ComponentValue::Object(parameters)),
            ("activeTime", double(component.active_time)),
            ("previousTime", double(component.previous_time)),
            ("transitionElapsed", double(component.transition_elapsed)),
            (
                "transitionDuration",
                double(component.transition_duration),
            ),
            ("speed", number(component.speed)),
            ("isPlaying", ComponentValue::Bool(component.is_playing)),
        ]);
        if let Some(active_state) = &component.active_state {
            document.insert(
                "activeState".to_string(),
                ComponentValue::String(active_state.clone()),
            );
        }
        if let Some(previous_state) = &component.previous_state {
            document.insert(
                "previousState".to_string(),
                ComponentValue::String(previous_state.clone()),
            );
        }
        document
    }

    /// Swift `deserializeAnimationGraphPlayer` — a missing or invalid graph falls
    /// back to an empty state machine rooted at `""`.
    pub fn deserialize_animation_graph_player(
        document: &BTreeMap<String, ComponentValue>,
    ) -> AnimationGraphPlayer {
        AnimationGraphPlayer::new(
            json_to_dict(document.get("graph"))
                .map(Self::deserialize_animation_graph)
                .unwrap_or_else(empty_animation_graph),
            json_to_string_float_dict(document.get("parameters")).unwrap_or_default(),
            json_to_string(document.get("activeState")).map(str::to_string),
            json_to_string(document.get("previousState")).map(str::to_string),
            json_to_double(document.get("activeTime")).unwrap_or(0.0),
            json_to_double(document.get("previousTime")).unwrap_or(0.0),
            json_to_double(document.get("transitionElapsed")).unwrap_or(0.0),
            json_to_double(document.get("transitionDuration")).unwrap_or(0.0),
            json_to_float(document.get("speed")).unwrap_or(1.0),
            json_to_bool(document.get("isPlaying")).unwrap_or(true),
        )
    }

    /// Swift `serializeAnimationGraph`.
    pub fn serialize_animation_graph(graph: &AnimationGraph) -> BTreeMap<String, ComponentValue> {
        let blend_spaces = graph
            .blend_spaces_1d
            .iter()
            .map(|blend_space| {
                ComponentValue::Object(Self::serialize_animation_blend_space_1d(blend_space))
            })
            .collect();
        object([
            ("blendSpaces1D", ComponentValue::Array(blend_spaces)),
            (
                "stateMachine",
                ComponentValue::Object(Self::serialize_animation_state_machine(
                    &graph.state_machine,
                )),
            ),
        ])
    }

    /// Swift `deserializeAnimationGraph` — non-object entries are dropped.
    pub fn deserialize_animation_graph(
        document: &BTreeMap<String, ComponentValue>,
    ) -> AnimationGraph {
        let blend_spaces = json_to_array(document.get("blendSpaces1D"))
            .unwrap_or(&[])
            .iter()
            .filter_map(|value| {
                json_to_dict(Some(value)).map(Self::deserialize_animation_blend_space_1d)
            })
            .collect();
        AnimationGraph::new(
            blend_spaces,
            json_to_dict(document.get("stateMachine"))
                .map(Self::deserialize_animation_state_machine)
                .unwrap_or_else(empty_animation_state_machine),
        )
    }

    /// Swift `serializeAnimationBlendSpace1D`.
    pub fn serialize_animation_blend_space_1d(
        blend_space: &AnimationBlendSpace1D,
    ) -> BTreeMap<String, ComponentValue> {
        let samples = blend_space
            .samples
            .iter()
            .map(|sample| {
                ComponentValue::Object(Self::serialize_animation_blend_sample_1d(sample))
            })
            .collect();
        object([
            ("name", ComponentValue::String(blend_space.name.clone())),
            (
                "parameter",
                ComponentValue::String(blend_space.parameter.clone()),
            ),
            ("samples", ComponentValue::Array(samples)),
        ])
    }

    /// Swift `deserializeAnimationBlendSpace1D`.
    pub fn deserialize_animation_blend_space_1d(
        document: &BTreeMap<String, ComponentValue>,
    ) -> AnimationBlendSpace1D {
        let samples = json_to_array(document.get("samples"))
            .unwrap_or(&[])
            .iter()
            .filter_map(|value| {
                json_to_dict(Some(value)).map(Self::deserialize_animation_blend_sample_1d)
            })
            .collect();
        AnimationBlendSpace1D::new(
            json_to_string(document.get("name")).unwrap_or(""),
            json_to_string(document.get("parameter")).unwrap_or(""),
            samples,
        )
    }

    /// Swift `serializeAnimationBlendSample1D` — `clipName` is omitted when `nil`.
    pub fn serialize_animation_blend_sample_1d(
        sample: &AnimationBlendSample1D,
    ) -> BTreeMap<String, ComponentValue> {
        let mut document = object([("threshold", number(sample.threshold))]);
        if let Some(clip_name) = &sample.clip_name {
            document.insert(
                "clipName".to_string(),
                ComponentValue::String(clip_name.clone()),
            );
        }
        document
    }

    /// Swift `deserializeAnimationBlendSample1D`.
    pub fn deserialize_animation_blend_sample_1d(
        document: &BTreeMap<String, ComponentValue>,
    ) -> AnimationBlendSample1D {
        AnimationBlendSample1D::new(
            json_to_string(document.get("clipName")).map(str::to_string),
            json_to_float(document.get("threshold")).unwrap_or(0.0),
        )
    }

    /// Swift `serializeAnimationStateMachine`.
    pub fn serialize_animation_state_machine(
        state_machine: &AnimationStateMachine,
    ) -> BTreeMap<String, ComponentValue> {
        let states = state_machine
            .states
            .iter()
            .map(|state| ComponentValue::Object(Self::serialize_animation_state(state)))
            .collect();
        let transitions = state_machine
            .transitions
            .iter()
            .map(|transition| {
                ComponentValue::Object(Self::serialize_animation_transition(transition))
            })
            .collect();
        object([
            (
                "initialState",
                ComponentValue::String(state_machine.initial_state.clone()),
            ),
            ("states", ComponentValue::Array(states)),
            ("transitions", ComponentValue::Array(transitions)),
        ])
    }

    /// Swift `deserializeAnimationStateMachine`.
    pub fn deserialize_animation_state_machine(
        document: &BTreeMap<String, ComponentValue>,
    ) -> AnimationStateMachine {
        let states = json_to_array(document.get("states"))
            .unwrap_or(&[])
            .iter()
            .filter_map(|value| {
                json_to_dict(Some(value)).map(Self::deserialize_animation_state)
            })
            .collect();
        let transitions = json_to_array(document.get("transitions"))
            .unwrap_or(&[])
            .iter()
            .filter_map(|value| {
                json_to_dict(Some(value)).map(Self::deserialize_animation_transition)
            })
            .collect();
        AnimationStateMachine::new(
            json_to_string(document.get("initialState")).unwrap_or(""),
            states,
            transitions,
        )
    }

    /// Swift `serializeAnimationState`.
    pub fn serialize_animation_state(
        state: &AnimationState,
    ) -> BTreeMap<String, ComponentValue> {
        object([
            ("name", ComponentValue::String(state.name.clone())),
            (
                "motion",
                ComponentValue::Object(Self::serialize_animation_motion(&state.motion)),
            ),
            ("speed", number(state.speed)),
            ("loop", ComponentValue::Bool(state.loop_)),
        ])
    }

    /// Swift `deserializeAnimationState` — an unknown motion defaults to `.clip(nil)`.
    pub fn deserialize_animation_state(
        document: &BTreeMap<String, ComponentValue>,
    ) -> AnimationState {
        AnimationState::new(
            json_to_string(document.get("name")).unwrap_or(""),
            json_to_dict(document.get("motion"))
                .map(Self::deserialize_animation_motion)
                .unwrap_or(AnimationMotion::Clip(None)),
            json_to_float(document.get("speed")).unwrap_or(1.0),
            json_to_bool(document.get("loop")).unwrap_or(true),
        )
    }

    /// Swift `serializeAnimationMotion`.
    pub fn serialize_animation_motion(
        motion: &AnimationMotion,
    ) -> BTreeMap<String, ComponentValue> {
        match motion {
            AnimationMotion::Clip(clip_name) => {
                let mut document = object([("type", ComponentValue::String("clip".to_string()))]);
                if let Some(clip_name) = clip_name {
                    document.insert(
                        "clipName".to_string(),
                        ComponentValue::String(clip_name.clone()),
                    );
                }
                document
            }
            AnimationMotion::BlendSpace1D(name) => object([
                ("type", ComponentValue::String("blendSpace1D".to_string())),
                ("name", ComponentValue::String(name.clone())),
            ]),
        }
    }

    /// Swift `deserializeAnimationMotion` — only `"blendSpace1D"` is special-cased.
    pub fn deserialize_animation_motion(
        document: &BTreeMap<String, ComponentValue>,
    ) -> AnimationMotion {
        match json_to_string(document.get("type")) {
            Some("blendSpace1D") => {
                AnimationMotion::BlendSpace1D(json_to_string(document.get("name")).unwrap_or("").to_string())
            }
            _ => AnimationMotion::Clip(
                json_to_string(document.get("clipName")).map(str::to_string),
            ),
        }
    }

    /// Swift `serializeAnimationTransition`.
    pub fn serialize_animation_transition(
        transition: &AnimationTransition,
    ) -> BTreeMap<String, ComponentValue> {
        object([
            ("from", ComponentValue::String(transition.from.clone())),
            ("to", ComponentValue::String(transition.to.clone())),
            (
                "parameter",
                ComponentValue::String(transition.parameter.clone()),
            ),
            (
                "comparison",
                ComponentValue::String(transition.comparison.raw_value().to_string()),
            ),
            ("threshold", number(transition.threshold)),
            ("duration", double(transition.duration)),
        ])
    }

    /// Swift `deserializeAnimationTransition` — an unknown comparison becomes
    /// `.greaterThan`, and the constructor clamps `duration` to `>= 0`.
    pub fn deserialize_animation_transition(
        document: &BTreeMap<String, ComponentValue>,
    ) -> AnimationTransition {
        AnimationTransition::new(
            json_to_string(document.get("from")).unwrap_or(""),
            json_to_string(document.get("to")).unwrap_or(""),
            json_to_string(document.get("parameter")).unwrap_or(""),
            json_to_string(document.get("comparison"))
                .and_then(AnimationTransitionComparison::from_raw_value)
                .unwrap_or(AnimationTransitionComparison::GreaterThan),
            json_to_float(document.get("threshold")).unwrap_or(0.0),
            json_to_double(document.get("duration")).unwrap_or(0.0),
        )
    }
}

/// Swift `AnimationStateMachine(initialState: "", states: [])`.
fn empty_animation_state_machine() -> AnimationStateMachine {
    AnimationStateMachine::new("", Vec::new(), Vec::new())
}

/// Swift `AnimationGraph(stateMachine: AnimationStateMachine(initialState: "", states: []))`.
fn empty_animation_graph() -> AnimationGraph {
    AnimationGraph::new(Vec::new(), empty_animation_state_machine())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn audio_source_defaults_match_the_swift_decoder() {
        let document = BTreeMap::new();
        let source = BuiltinComponentCodecs::deserialize_audio_source(&document);
        assert_eq!(source.clip_name, "");
        assert_eq!(source.volume, 1.0);
        assert_eq!(source.pitch, 1.0);
        assert!(!source.loop_);
        assert!(source.play_on_awake);
        assert_eq!(source.spatial_blend, 1.0);

        let listener = BuiltinComponentCodecs::deserialize_audio_listener(&document);
        assert_eq!(listener.master_volume, 1.0);
    }

    #[test]
    fn animation_player_omits_a_missing_clip_name() {
        let player = AnimationPlayer::new(None, 2.0, false, false, 1.5);
        let document = BuiltinComponentCodecs::serialize_animation_player(&player);
        assert!(!document.contains_key("clipName"));
        assert_eq!(document.get("time"), Some(&ComponentValue::Number(1.5)));

        let decoded = BuiltinComponentCodecs::deserialize_animation_player(&document);
        assert_eq!(decoded.clip_name, None);
        assert_eq!(decoded.speed, 2.0);
        assert!(!decoded.loop_);
        assert!(!decoded.is_playing);
        assert_eq!(decoded.time, 1.5);
    }

    #[test]
    fn switching_clips_restarts_the_playhead() {
        let previous = ComponentValue::Object(object([
            ("clipName", ComponentValue::String("walk".to_string())),
            ("time", double(3.0)),
        ]));
        let changes = ComponentValue::Object(object([(
            "clipName",
            ComponentValue::String("run".to_string()),
        )]));
        let merged = BuiltinComponentCodecs::merge_animation_player(&previous, &changes)
            .expect("merged");
        let fields = json_to_dict(Some(&merged)).expect("object");
        assert_eq!(fields.get("time"), Some(&ComponentValue::Number(0.0)));

        let same_clip = ComponentValue::Object(object([(
            "clipName",
            ComponentValue::String("walk".to_string()),
        )]));
        let merged =
            BuiltinComponentCodecs::merge_animation_player(&previous, &same_clip).expect("merged");
        let fields = json_to_dict(Some(&merged)).expect("object");
        assert_eq!(fields.get("time"), Some(&ComponentValue::Number(3.0)));
    }

    #[test]
    fn graph_player_round_trips_through_its_nested_graph() {
        let state = AnimationState::new(
            "idle",
            AnimationMotion::BlendSpace1D("locomotion".to_string()),
            1.0,
            true,
        );
        let machine = AnimationStateMachine::new("idle", vec![state], Vec::new());
        let graph = AnimationGraph::new(
            vec![AnimationBlendSpace1D::new(
                "locomotion",
                "speed",
                vec![AnimationBlendSample1D::new(Some("walk".to_string()), 0.0)],
            )],
            machine,
        );
        let mut parameters = BTreeMap::new();
        parameters.insert("speed".to_string(), 2.5);
        let player = AnimationGraphPlayer::new(
            graph,
            parameters,
            Some("idle".to_string()),
            None,
            0.5,
            0.0,
            0.0,
            0.25,
            1.5,
            true,
        );
        let document = BuiltinComponentCodecs::serialize_animation_graph_player(&player);
        assert!(!document.contains_key("previousState"));
        let decoded = BuiltinComponentCodecs::deserialize_animation_graph_player(&document);
        assert_eq!(decoded.active_state.as_deref(), Some("idle"));
        assert_eq!(decoded.previous_state, None);
        assert_eq!(decoded.parameters.get("speed"), Some(&2.5));
        assert_eq!(decoded.graph.blend_spaces_1d.len(), 1);
        assert_eq!(decoded.graph.state_machine.states.len(), 1);
    }
}
