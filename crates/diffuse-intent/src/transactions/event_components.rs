//! Project a component document into semantic world events.
//!
//! The semantic view still exposes *named* fields to AI, so that projection happens here
//! at the event boundary; component execution itself only knows the registry. The name
//! mapping below is a published contract — an AI consumer keys off these strings — so it
//! is written out explicitly rather than derived.

use std::collections::BTreeMap;

use diffuse_scene::components::core::value::ComponentValue;

use crate::transactions::world_event::{WorldEvent, entity_ref_of};

/// The property prefix a component's generic fields inherit.
fn component_prefix(type_id: &str) -> Option<&'static str> {
    match type_id {
        "rigidbody" => Some("rigidBody"),
        "collider" => Some("collider"),
        "light" => Some("light"),
        "camera" => Some("camera"),
        "audioSource" => Some("audio"),
        "animationPlayer" => Some("animation"),
        _ => None,
    }
}

/// Fields whose semantic name is not `prefix + Capitalised(field)`.
fn special_property(type_id: &str, field: &str) -> Option<&'static str> {
    Some(match (type_id, field) {
        ("renderMesh", "colorTint") => "meshColor",
        ("renderMesh", "isVisible") => "meshIsVisible",
        ("renderMaterial", "baseColorFactor") => "materialBaseColor",
        ("renderMaterial", "metallicFactor") => "materialMetallic",
        ("renderMaterial", "roughnessFactor") => "materialRoughness",
        ("renderMaterial", "emissiveFactor") => "materialEmissive",
        ("light", "spotInnerAngleDegrees") => "lightSpotInner",
        ("light", "spotOuterAngleDegrees") => "lightSpotOuter",
        ("collider", "layerID") => "colliderLayerID",
        ("collider", "layerMask") => "colliderLayerMask",
        ("constraint", "isEnabled") => "constraintEnabled",
        ("audioSource", "clipName") => "audioClip",
        ("audioListener", "masterVolume") => "audioListenerMasterVolume",
        ("animationPlayer", "clipName") => "animationClip",
        ("animationGraphPlayer", "speed") => "animationGraphSpeed",
        ("animationGraphPlayer", "isPlaying") => "animationGraphIsPlaying",
        _ => return None,
    })
}

/// Reduce a component value to a scalar event value, if it is one.
///
/// Arrays of exactly 3 or 4 numbers become vectors; any other array is not a scalar and
/// produces no event.
fn scalar_value(
    value: &ComponentValue,
) -> Option<crate::transactions::world_event::WorldPropertyValue> {
    use crate::transactions::world_event::WorldPropertyValue;

    match value {
        ComponentValue::Bool(flag) => Some(WorldPropertyValue::Bool(*flag)),
        ComponentValue::Number(number) => Some(WorldPropertyValue::Float(*number as f32)),
        ComponentValue::SignedInteger(number) => Some(WorldPropertyValue::Float(*number as f32)),
        ComponentValue::UnsignedInteger(number) => Some(WorldPropertyValue::Float(*number as f32)),
        ComponentValue::String(text) => Some(WorldPropertyValue::String(text.clone())),
        ComponentValue::Array(values) => {
            let numbers: Vec<f32> = values
                .iter()
                .filter_map(|entry| match entry {
                    ComponentValue::Number(number) => Some(*number as f32),
                    ComponentValue::SignedInteger(number) => Some(*number as f32),
                    ComponentValue::UnsignedInteger(number) => Some(*number as f32),
                    _ => None,
                })
                .collect();
            match numbers.len() {
                3 => Some(WorldPropertyValue::Vec3(numbers[0], numbers[1], numbers[2])),
                4 => Some(WorldPropertyValue::Vec4(
                    numbers[0], numbers[1], numbers[2], numbers[3],
                )),
                _ => None,
            }
        }
        _ => None,
    }
}

/// Project a whole component document into events.
///
/// Always emits the whole-document event first, then one event per recognised scalar
/// field in **sorted field order** so a consumer sees a deterministic stream.
pub fn component_changes(entity_id: u64, type_id: &str, value: &ComponentValue) -> Vec<WorldEvent> {
    use crate::transactions::world_event::WorldPropertyValue;

    let ref_ = entity_ref_of(entity_id);
    let mut events: Vec<WorldEvent> = vec![WorldEvent::EntityAuthoredChanged {
        ref_: ref_.clone(),
        property: format!("components.{type_id}"),
        value: WorldPropertyValue::Json(value.clone()),
    }];

    let Some(document) = value.object_value() else {
        return events;
    };

    let prefix = component_prefix(type_id);
    for (field, raw) in document.iter() {
        let property = special_property(type_id, field)
            .map(str::to_string)
            .or_else(|| {
                let prefix = prefix?;
                let mut name = String::from(prefix);
                // Capitalise the first character, as Swift's `prefix + key.prefix(1).uppercased()`.
                let mut characters = field.chars();
                if let Some(first) = characters.next() {
                    name.push_str(&first.to_uppercase().to_string());
                    name.push_str(characters.as_str());
                }
                Some(name)
            });
        let (Some(property), Some(scalar)) = (property, scalar_value(raw)) else {
            continue;
        };
        events.push(WorldEvent::EntityAuthoredChanged {
            ref_: ref_.clone(),
            property,
            value: scalar,
        });
    }

    // Camera FOV is authored in radians but reported in degrees.
    if type_id == "camera"
        && let Some(ComponentValue::Number(radians)) = document.get("fovYRadians")
    {
        events.push(WorldEvent::EntityAuthoredChanged {
            ref_: ref_.clone(),
            property: "cameraFovYDegrees".to_string(),
            value: WorldPropertyValue::Float((*radians as f32) * 180.0 / core::f32::consts::PI),
        });
    }

    // Collider shape sub-fields are reported under shape-specific names.
    if type_id == "collider"
        && let Some(ComponentValue::String(shape)) = document.get("shape")
    {
        if let Some(ComponentValue::Number(radius)) = document.get("radius")
            && (shape == "sphere" || shape == "capsule")
        {
            let property = if shape == "sphere" {
                "colliderSphereRadius"
            } else {
                "colliderCapsuleRadius"
            };
            events.push(WorldEvent::EntityAuthoredChanged {
                ref_: ref_.clone(),
                property: property.to_string(),
                value: WorldPropertyValue::Float(*radius as f32),
            });
        }
        if let Some(half_extents) = document.get("halfExtents")
            && let Some(scalar) = scalar_value(half_extents)
            && shape == "box"
        {
            events.push(WorldEvent::EntityAuthoredChanged {
                ref_: ref_.clone(),
                property: "colliderBoxHalfExtents".to_string(),
                value: scalar,
            });
        }
        if let Some(ComponentValue::Number(half_height)) = document.get("halfHeight")
            && shape == "capsule"
        {
            events.push(WorldEvent::EntityAuthoredChanged {
                ref_: ref_.clone(),
                property: "colliderCapsuleHalfHeight".to_string(),
                value: WorldPropertyValue::Float(*half_height as f32),
            });
        }
    }

    // Script bindings are flattened to a deterministic JSON string.
    if type_id == "script"
        && let Some(ComponentValue::Array(bindings)) = document.get("bindings")
    {
        let records: Vec<ComponentValue> = bindings
            .iter()
            .filter_map(|binding| {
                let mut record: BTreeMap<String, ComponentValue> =
                    binding.object_value().cloned()?;
                // Swift renamed the stored `scriptHandle` to `handle` on the way out.
                if let Some(handle) = record.remove("scriptHandle") {
                    record.insert("handle".to_string(), handle);
                } else {
                    record.insert("handle".to_string(), ComponentValue::Number(0.0));
                }
                Some(ComponentValue::Object(record))
            })
            .collect();
        let json = serde_json::to_string(&ComponentValue::Array(records).to_json_value())
            .unwrap_or_else(|_| "[]".to_string());
        events.push(WorldEvent::EntityAuthoredChanged {
            ref_: ref_.clone(),
            property: "scriptBindings".to_string(),
            value: WorldPropertyValue::String(json),
        });
    }

    events
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::transactions::world_event::WorldPropertyValue;

    fn document(pairs: Vec<(&str, ComponentValue)>) -> ComponentValue {
        ComponentValue::Object(
            pairs
                .into_iter()
                .map(|(key, value)| (key.to_string(), value))
                .collect(),
        )
    }

    fn authored<'a>(events: &'a [WorldEvent], property: &str) -> Option<&'a WorldPropertyValue> {
        events.iter().find_map(|event| match event {
            WorldEvent::EntityAuthoredChanged {
                property: name,
                value,
                ..
            } if name == property => Some(value),
            _ => None,
        })
    }

    #[test]
    fn the_whole_document_is_always_emitted_first() {
        let events = component_changes(
            1,
            "rigidbody",
            &document(vec![("mass", ComponentValue::Number(2.0))]),
        );
        match &events[0] {
            WorldEvent::EntityAuthoredChanged {
                ref_,
                property,
                value,
            } => {
                assert_eq!(ref_, "scene:1");
                assert_eq!(property, "components.rigidbody");
                assert!(matches!(value, WorldPropertyValue::Json(_)));
            }
            other => panic!("expected the document event first, got {other:?}"),
        }
    }

    #[test]
    fn a_prefixed_component_names_its_fields() {
        let events = component_changes(
            2,
            "rigidbody",
            &document(vec![("mass", ComponentValue::Number(3.0))]),
        );
        assert_eq!(
            authored(&events, "rigidBodyMass").and_then(WorldPropertyValue::as_float),
            Some(3.0)
        );
    }

    #[test]
    fn a_special_field_uses_its_published_name() {
        let events = component_changes(
            3,
            "renderMesh",
            &document(vec![(
                "colorTint",
                ComponentValue::Array(vec![
                    ComponentValue::Number(1.0),
                    ComponentValue::Number(0.5),
                    ComponentValue::Number(0.25),
                ]),
            )]),
        );
        assert!(authored(&events, "meshColor").is_some(), "got {events:?}");
    }

    #[test]
    fn a_camera_reports_fov_in_degrees() {
        let events = component_changes(
            4,
            "camera",
            &document(vec![(
                "fovYRadians",
                ComponentValue::Number(core::f64::consts::FRAC_PI_2),
            )]),
        );
        let degrees = authored(&events, "cameraFovYDegrees")
            .and_then(WorldPropertyValue::as_float)
            .expect("degrees");
        assert!((degrees - 90.0).abs() < 1e-4, "got {degrees}");
    }

    #[test]
    fn a_sphere_collider_reports_its_radius_under_the_sphere_name() {
        let events = component_changes(
            5,
            "collider",
            &document(vec![
                ("shape", ComponentValue::String("sphere".to_string())),
                ("radius", ComponentValue::Number(2.5)),
            ]),
        );
        assert_eq!(
            authored(&events, "colliderSphereRadius").and_then(WorldPropertyValue::as_float),
            Some(2.5)
        );
        assert!(authored(&events, "colliderCapsuleRadius").is_none());
    }

    #[test]
    fn a_non_object_document_yields_only_the_whole_document_event() {
        let events = component_changes(6, "rigidbody", &ComponentValue::Number(1.0));
        assert_eq!(events.len(), 1);
    }

    #[test]
    fn script_bindings_become_a_handle_keyed_json_string() {
        let binding = document(vec![("scriptHandle", ComponentValue::Number(9.0))]);
        let events = component_changes(
            7,
            "script",
            &document(vec![("bindings", ComponentValue::Array(vec![binding]))]),
        );
        let json = authored(&events, "scriptBindings")
            .and_then(WorldPropertyValue::as_string)
            .expect("bindings json");
        assert!(json.contains("\"handle\":9"), "got {json}");
        assert!(!json.contains("scriptHandle"));
    }
}
