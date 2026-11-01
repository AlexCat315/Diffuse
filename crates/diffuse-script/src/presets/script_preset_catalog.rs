use crate::core::{
    script_component::ScriptHandle, script_lifecycle::Script, script_runtime::ScriptRuntime,
};
use diffuse_math::simd::simd_compat::Float3;
use diffuse_scene::entity_id::EntityID;
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ScriptPresetKind {
    Rotator,
    Oscillator,
    Mover,
    DestroyAfter,
    Follower,
    LookAt,
    CharacterController,
    FirstPersonCamera,
    OrbitCamera,
}

impl ScriptPresetKind {
    pub const ALL: [Self; 9] = [
        Self::Rotator,
        Self::Oscillator,
        Self::Mover,
        Self::DestroyAfter,
        Self::Follower,
        Self::LookAt,
        Self::CharacterController,
        Self::FirstPersonCamera,
        Self::OrbitCamera,
    ];
    pub const fn raw_value(self) -> &'static str {
        match self {
            Self::Rotator => "rotator",
            Self::Oscillator => "oscillator",
            Self::Mover => "mover",
            Self::DestroyAfter => "destroy-after",
            Self::Follower => "follower",
            Self::LookAt => "look-at",
            Self::CharacterController => "character-controller",
            Self::FirstPersonCamera => "first-person-camera",
            Self::OrbitCamera => "orbit-camera",
        }
    }
    pub fn from_raw_value(value: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|kind| kind.raw_value() == value)
    }
}

impl ScriptRuntime {
    pub fn register_preset(
        &self,
        preset: ScriptPresetKind,
        identifier: &str,
        default_parameters_json: &str,
    ) -> ScriptHandle {
        self.register_factory(
            Some(identifier),
            default_parameters_json,
            preset.definition(),
            move || match preset {
                ScriptPresetKind::Rotator => Script::rotator(Float3::new(0.0, 1.57, 0.0)),
                ScriptPresetKind::Oscillator => {
                    Script::oscillator(Float3::new(0.0, 1.0, 0.0), 1.0, 1.0)
                }
                ScriptPresetKind::Mover => Script::mover(Float3::ZERO),
                ScriptPresetKind::DestroyAfter => Script::destroy_after(1.0),
                ScriptPresetKind::Follower => {
                    Script::follower(EntityID::from_raw_value(0), 5.0, 0.1)
                }
                ScriptPresetKind::LookAt => {
                    Script::look_at_target(EntityID::from_raw_value(0), Float3::new(0.0, 0.0, -1.0))
                }
                ScriptPresetKind::CharacterController => Script::character_input_controller(),
                ScriptPresetKind::FirstPersonCamera => Script::first_person_camera(5.0, 0.002),
                ScriptPresetKind::OrbitCamera => {
                    Script::orbit_camera(Float3::ZERO, 10.0, 0.005, 1.0, 1.0, 100.0)
                }
            },
        )
    }
}
