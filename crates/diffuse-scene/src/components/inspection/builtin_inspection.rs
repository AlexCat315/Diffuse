//! `Inspection/BuiltinInspection.swift` — the hand-tuned editor forms for the
//! joint, camera, light, audio and character-controller components.
//!
//! Swift declares these as static computed properties on `ComponentInspection`;
//! Rust exposes them as argument-less constructors. Every field descriptor
//! addresses a codec document path, so the forms stay in sync with the persisted
//! key spellings.
//!
//! [`ComponentFieldSpec`] mirrors Swift's `field(_:id:label:min:max:step:scale:kind:choices:)`
//! helper, which the other built-in inspection files share.

use diffuse_math::simd::simd_compat::Float3;

use crate::components::codecs::builtin_component_codecs::BuiltinComponentCodecs;
use crate::components::core::value::ComponentValue;
use crate::components::inspection::inspection::{
    ComponentFieldChoice, ComponentFieldDescriptor, ComponentFieldKind, ComponentFieldVisibility,
    ComponentInspection, ComponentNumericPresentation,
};
use crate::entity_id::EntityID;
use crate::physics::joints::physics_joint::{Constraint, PhysicsJoint};
use crate::physics::joints::physics_joint_configuration::{PhysicsJointConfiguration, PhysicsJointKind};
use crate::rendering::render_extraction::LightType;

impl ComponentInspection {
    /// Swift `constraint` — endpoints are required, so there is no add-menu
    /// default; the common fields come from the codec's document.
    pub fn constraint() -> Self {
        let endpoint = EntityID::new(0, 0);
        let example = Constraint::new(
            PhysicsJointConfiguration::Point,
            endpoint,
            endpoint,
            Float3::ZERO,
            Float3::ZERO,
            true,
            PhysicsJoint::DEFAULT_BREAK_LIMIT,
            PhysicsJoint::DEFAULT_BREAK_LIMIT,
        );
        let document = ComponentValue::Object(BuiltinComponentCodecs::serialize_constraint(
            &example, 0, 1,
        ));
        let mut fields = ComponentInspection::default().resolved_fields(&document);
        for field in &mut fields {
            if field.path == ["type"] {
                field.kind = ComponentFieldKind::Options;
                field.choices = PhysicsJointKind::ALL
                    .iter()
                    .map(|kind| ComponentFieldChoice::new(kind.raw_value()))
                    .collect();
            } else if field.path == ["entityA"] || field.path == ["entityB"] {
                field.kind = ComponentFieldKind::Integer;
                field.documentation = Some(
                    "Document-local entity index; transaction edits use generation-qualified entity IDs."
                        .to_string(),
                );
            }
        }
        ComponentInspection {
            fields,
            ..ComponentInspection::default()
        }
    }

    /// Swift `camera`.
    pub fn camera() -> Self {
        ComponentInspection {
            fields: vec![
                field(ComponentFieldSpec::new("isActive", "Active").id("camera-active")),
                field(
                    ComponentFieldSpec::new("fovYRadians", "Field of View")
                        .id("camera-fov")
                        .minimum(1.0)
                        .maximum(179.0)
                        .step(1.0)
                        .scale(180.0 / std::f64::consts::PI),
                ),
                field(
                    ComponentFieldSpec::new("aspectRatio", "Aspect Ratio")
                        .id("camera-aspect")
                        .minimum(0.1)
                        .maximum(10.0)
                        .step(0.01),
                ),
                field(
                    ComponentFieldSpec::new("near", "Near")
                        .minimum(0.0001)
                        .step(0.01),
                ),
                field(
                    ComponentFieldSpec::new("far", "Far")
                        .minimum(0.1)
                        .step(1.0),
                ),
            ],
            ..ComponentInspection::default()
        }
    }

    /// Swift `light` — range is point/spot only, the angles are spot only, and the
    /// inner angle is capped by the authored outer angle.
    pub fn light() -> Self {
        let mut inspection = ComponentInspection {
            fields: vec![
                field(
                    ComponentFieldSpec::new("type", "Type")
                        .kind(ComponentFieldKind::Options)
                        .choices(LightType::ALL.iter().map(|value| value.raw_value().to_string())),
                ),
                field(ComponentFieldSpec::new("color", "Color").kind(ComponentFieldKind::Color)),
                field(
                    ComponentFieldSpec::new("intensity", "Intensity")
                        .minimum(0.0)
                        .step(0.1),
                ),
                field(
                    ComponentFieldSpec::new("range", "Range")
                        .minimum(0.0)
                        .step(0.1),
                ),
                field(
                    ComponentFieldSpec::new("spotInnerAngleDegrees", "Inner Angle")
                        .id("spot-inner-angle")
                        .minimum(0.0)
                        .maximum(179.0)
                        .step(1.0),
                ),
                field(
                    ComponentFieldSpec::new("spotOuterAngleDegrees", "Outer Angle")
                        .id("spot-outer-angle")
                        .minimum(1.0)
                        .maximum(179.0)
                        .step(1.0),
                ),
            ],
            ..ComponentInspection::default()
        };
        inspection.fields[3].visibility = Some(ComponentFieldVisibility::new(
            vec!["type".to_string()],
            vec![
                ComponentValue::String("point".to_string()),
                ComponentValue::String("spot".to_string()),
            ],
        ));
        for index in [4, 5] {
            inspection.fields[index].visibility = Some(ComponentFieldVisibility::new(
                vec!["type".to_string()],
                vec![ComponentValue::String("spot".to_string())],
            ));
        }
        inspection.fields[4].numeric.maximum_path =
            Some(vec!["spotOuterAngleDegrees".to_string()]);
        inspection
    }

    /// Swift `audioSource`.
    pub fn audio_source() -> Self {
        ComponentInspection {
            section_id: Some("audio-source".to_string()),
            fields: vec![
                field(ComponentFieldSpec::new("clipName", "Clip").id("audio-clip")),
                field(
                    ComponentFieldSpec::new("volume", "Volume")
                        .id("audio-volume")
                        .minimum(0.0)
                        .maximum(1.0)
                        .step(0.05),
                ),
                field(
                    ComponentFieldSpec::new("pitch", "Pitch")
                        .id("audio-pitch")
                        .minimum(0.1)
                        .maximum(3.0)
                        .step(0.1),
                ),
                field(ComponentFieldSpec::new("loop", "Loop").id("audio-loop")),
                field(
                    ComponentFieldSpec::new("playOnAwake", "Play on Awake")
                        .id("audio-play-on-awake"),
                ),
                field(
                    ComponentFieldSpec::new("spatialBlend", "Spatial Blend")
                        .id("audio-spatial-blend")
                        .minimum(0.0)
                        .maximum(1.0)
                        .step(0.1),
                ),
            ],
            ..ComponentInspection::default()
        }
    }

    /// Swift `audioListener`.
    pub fn audio_listener() -> Self {
        ComponentInspection {
            section_id: Some("audio-listener".to_string()),
            fields: vec![field(
                ComponentFieldSpec::new("masterVolume", "Master Volume")
                    .id("audio-listener-volume")
                    .minimum(0.0)
                    .maximum(1.0)
                    .step(0.05),
            )],
            ..ComponentInspection::default()
        }
    }

    /// Swift `characterController`.
    pub fn character_controller() -> Self {
        ComponentInspection {
            section_id: Some("character-controller".to_string()),
            fields: vec![
                field(
                    ComponentFieldSpec::new("radius", "Radius")
                        .id("character-radius")
                        .minimum(0.01)
                        .step(0.05),
                ),
                field(
                    ComponentFieldSpec::new("standingHalfHeight", "Standing Half Height")
                        .id("character-standing-height")
                        .minimum(0.01)
                        .step(0.05),
                ),
                field(
                    ComponentFieldSpec::new("crouchingHalfHeight", "Crouching Half Height")
                        .id("character-crouching-height")
                        .minimum(0.01)
                        .step(0.05),
                ),
                field(
                    ComponentFieldSpec::new("center", "Center").id("character-center"),
                ),
                field(
                    ComponentFieldSpec::new("maxSlopeDegrees", "Max Slope")
                        .id("character-slope")
                        .minimum(0.0)
                        .maximum(89.9)
                        .step(1.0),
                ),
                field(
                    ComponentFieldSpec::new("stepHeight", "Step Height")
                        .id("character-step")
                        .minimum(0.0)
                        .step(0.05),
                ),
                field(
                    ComponentFieldSpec::new("skinWidth", "Skin Width")
                        .id("character-skin")
                        .minimum(0.001)
                        .step(0.005),
                ),
                field(
                    ComponentFieldSpec::new("mass", "Mass")
                        .id("character-mass")
                        .minimum(0.01)
                        .step(1.0),
                ),
                field(
                    ComponentFieldSpec::new("maxStrength", "Push Strength")
                        .id("character-strength")
                        .minimum(0.0)
                        .step(10.0),
                ),
                field(
                    ComponentFieldSpec::new("gravityScale", "Gravity Scale")
                        .id("character-gravity")
                        .step(0.1),
                ),
            ],
            ..ComponentInspection::default()
        }
    }
}

/// Swift's `field(_:id:label:min:max:step:scale:kind:choices:)` arguments.
#[derive(Clone, Debug)]
pub struct ComponentFieldSpec {
    key: &'static str,
    id: Option<String>,
    label: String,
    minimum: Option<f64>,
    maximum: Option<f64>,
    step: Option<f64>,
    scale: f64,
    kind: ComponentFieldKind,
    choices: Vec<String>,
}

impl ComponentFieldSpec {
    pub fn new(key: &'static str, label: impl Into<String>) -> Self {
        ComponentFieldSpec {
            key,
            id: None,
            label: label.into(),
            minimum: None,
            maximum: None,
            step: None,
            scale: 1.0,
            kind: ComponentFieldKind::Automatic,
            choices: Vec::new(),
        }
    }

    pub fn id(mut self, id: impl Into<String>) -> Self {
        self.id = Some(id.into());
        self
    }

    pub fn minimum(mut self, minimum: f64) -> Self {
        self.minimum = Some(minimum);
        self
    }

    pub fn maximum(mut self, maximum: f64) -> Self {
        self.maximum = Some(maximum);
        self
    }

    pub fn step(mut self, step: f64) -> Self {
        self.step = Some(step);
        self
    }

    pub fn scale(mut self, scale: f64) -> Self {
        self.scale = scale;
        self
    }

    pub fn kind(mut self, kind: ComponentFieldKind) -> Self {
        self.kind = kind;
        self
    }

    pub fn choices(mut self, choices: impl IntoIterator<Item = String>) -> Self {
        self.choices = choices.into_iter().collect();
        self
    }
}

/// Swift `ComponentInspection.field(_:_:)` — the shared descriptor factory used by
/// every built-in inspection.
pub fn field(spec: ComponentFieldSpec) -> ComponentFieldDescriptor {
    let mut descriptor = ComponentFieldDescriptor::new(vec![spec.key.to_string()]);
    descriptor.id = spec.id.unwrap_or_else(|| spec.key.to_string());
    descriptor.label = spec.label;
    descriptor.kind = spec.kind;
    descriptor.choices = spec
        .choices
        .into_iter()
        .map(ComponentFieldChoice::new)
        .collect();
    descriptor.numeric = ComponentNumericPresentation {
        minimum: spec.minimum,
        maximum: spec.maximum,
        step: spec.step,
        maximum_path: None,
        scale: spec.scale,
    };
    descriptor
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn field_defaults_match_the_swift_helper() {
        let descriptor = field(ComponentFieldSpec::new("clipName", "Clip").id("audio-clip"));
        assert_eq!(descriptor.path, vec!["clipName".to_string()]);
        assert_eq!(descriptor.id, "audio-clip");
        assert_eq!(descriptor.label, "Clip");
        assert_eq!(descriptor.kind, ComponentFieldKind::Automatic);
        assert_eq!(descriptor.numeric.scale, 1.0);
        assert_eq!(descriptor.numeric.minimum, None);
    }

    #[test]
    fn light_visibility_and_maximum_path_follow_the_type() {
        let inspection = ComponentInspection::light();
        let range = &inspection.fields[3];
        let visibility = range.visibility.as_ref().expect("visibility");
        assert_eq!(visibility.values.len(), 2);
        assert_eq!(
            inspection.fields[4].numeric.maximum_path,
            Some(vec!["spotOuterAngleDegrees".to_string()])
        );
        let type_field = &inspection.fields[0];
        assert_eq!(type_field.choices.len(), 3);
        assert_eq!(type_field.id, "type");
    }

    #[test]
    fn constraint_derives_its_fields_from_the_codec_document() {
        let inspection = ComponentInspection::constraint();
        let type_field = inspection
            .fields
            .iter()
            .find(|field| field.path == ["type"])
            .expect("type");
        assert_eq!(type_field.kind, ComponentFieldKind::Options);
        assert_eq!(type_field.choices.len(), 7);
        let entity_a = inspection
            .fields
            .iter()
            .find(|field| field.path == ["entityA"])
            .expect("entityA");
        assert_eq!(entity_a.kind, ComponentFieldKind::Integer);
        assert!(entity_a.documentation.is_some());
    }
}
