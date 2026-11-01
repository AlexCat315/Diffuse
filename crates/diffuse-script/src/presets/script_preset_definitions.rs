use super::script_preset_catalog::ScriptPresetKind;
use crate::core::script_definition::{
    ScriptDefinition, ScriptProperty, ScriptPropertyValue as Value,
};
use diffuse_math::simd::simd_compat::Float3;

impl ScriptPresetKind {
    pub fn definition(self) -> ScriptDefinition {
        let target = || {
            vec![
                property("targetEntityID", "Target", Value::Entity(0), None),
                property(
                    "targetEntityName",
                    "Target Name",
                    Value::String(String::new()),
                    None,
                ),
            ]
        };
        let number =
            |key, label, value, minimum| property(key, label, Value::Number(value), minimum);
        let vector = |key, label, value| property(key, label, Value::Vector3(value), None);
        let properties = match self {
            Self::Rotator => vec![vector(
                "speed",
                "Angular Speed",
                Float3::new(0.0, 1.57, 0.0),
            )],
            Self::Oscillator => vec![
                vector("axis", "Axis", Float3::new(0.0, 1.0, 0.0)),
                number("amplitude", "Amplitude", 1.0, Some(0.0)),
                number("frequency", "Frequency", 1.0, Some(0.0)),
            ],
            Self::Mover => vec![vector("velocity", "Velocity", Float3::ZERO)],
            Self::DestroyAfter => vec![number("seconds", "Lifetime", 1.0, Some(0.0))],
            Self::Follower => {
                let mut properties = target();
                properties.extend([
                    number("speed", "Move Speed", 5.0, Some(0.0)),
                    number("arrivalRadius", "Arrival Radius", 0.1, Some(0.0)),
                ]);
                properties
            }
            Self::LookAt => target(),
            Self::CharacterController => vec![
                number("moveSpeed", "Move Speed", 5.0, Some(0.0)),
                number("jumpSpeed", "Jump Speed", 8.0, Some(0.0)),
                property(
                    "crouchAction",
                    "Crouch Action",
                    Value::String("crouch".into()),
                    None,
                ),
            ],
            Self::FirstPersonCamera => vec![
                number("moveSpeed", "Move Speed", 5.0, Some(0.0)),
                number("lookSensitivity", "Look Sensitivity", 0.002, Some(0.0)),
            ],
            Self::OrbitCamera => vec![
                vector("target", "Target Position", Float3::ZERO),
                number("distance", "Distance", 10.0, Some(0.0)),
                number("orbitSpeed", "Orbit Speed", 0.005, None),
                number("zoomSpeed", "Zoom Speed", 1.0, Some(0.0)),
                number("minDistance", "Min Distance", 1.0, Some(0.0)),
                number("maxDistance", "Max Distance", 100.0, Some(0.0)),
            ],
        };
        ScriptDefinition::new(properties)
    }
}

fn property(key: &str, label: &str, value: Value, minimum: Option<f64>) -> ScriptProperty {
    ScriptProperty::new(
        key,
        Some(label.into()),
        None,
        None,
        value,
        minimum,
        None,
        None,
        Vec::new(),
    )
}
