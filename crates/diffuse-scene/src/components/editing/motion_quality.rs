//! CCD/motion-quality coupling for authored edits.
//!
//! `Components/Editing/MotionQuality.swift` extends `BuiltinComponentCodecs` with
//! `mergeRigidBody`. That merge is a pure document transformation: it needs no
//! runtime world, so it is exposed here as a free function over
//! [`ComponentValue`] and is consumed by the rigid-body codec once that lands.

use std::collections::BTreeMap;

use crate::components::core::value::ComponentValue;
use crate::components::editing::ComponentEditError;

/// Enabling continuous collision detection raises motion quality to `linearCast`.
///
/// Swift only rewrites the sibling field when the flag actually changed and the
/// edit did not also address `motionQuality` itself.
pub fn merge_rigid_body(
    previous: &ComponentValue,
    changes: &ComponentValue,
) -> Result<ComponentValue, ComponentEditError> {
    let merged = previous.merging(changes)?;
    let ComponentValue::Object(change_fields) = changes else {
        return Ok(merged);
    };
    let enabled = match change_fields.get("continuousCollisionDetection") {
        Some(ComponentValue::Bool(value)) => *value,
        _ => return Ok(merged),
    };
    let path = [String::from("continuousCollisionDetection")];
    if previous.value_at(&path) == Some(&ComponentValue::Bool(enabled)) {
        return Ok(merged);
    }
    if change_fields.contains_key("motionQuality") {
        return Ok(merged);
    }
    let ComponentValue::Object(mut fields) = merged else {
        return Ok(merged);
    };
    fields.insert(
        String::from("motionQuality"),
        ComponentValue::String(if enabled { "linearCast" } else { "discrete" }.to_string()),
    );
    Ok(ComponentValue::Object(fields))
}

/// Convenience for callers that already hold an object document.
pub fn merge_rigid_body_fields(
    previous: &BTreeMap<String, ComponentValue>,
    changes: &BTreeMap<String, ComponentValue>,
) -> Result<ComponentValue, ComponentEditError> {
    merge_rigid_body(
        &ComponentValue::Object(previous.clone()),
        &ComponentValue::Object(changes.clone()),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    fn map(entries: Vec<(&str, ComponentValue)>) -> ComponentValue {
        ComponentValue::Object(
            entries
                .into_iter()
                .map(|(key, value)| (key.to_string(), value))
                .collect::<BTreeMap<_, _>>(),
        )
    }

    #[test]
    fn enabling_ccd_sets_linear_cast() {
        let previous = map(vec![(
            "continuousCollisionDetection",
            ComponentValue::Bool(false),
        )]);
        let changes = map(vec![(
            "continuousCollisionDetection",
            ComponentValue::Bool(true),
        )]);
        let merged = merge_rigid_body(&previous, &changes).expect("merge");
        assert_eq!(
            merged.value_at(&["motionQuality".to_string()]),
            Some(&ComponentValue::String("linearCast".to_string()))
        );
    }

    #[test]
    fn explicit_motion_quality_wins() {
        let previous = map(vec![(
            "continuousCollisionDetection",
            ComponentValue::Bool(false),
        )]);
        let changes = map(vec![
            ("continuousCollisionDetection", ComponentValue::Bool(true)),
            (
                "motionQuality",
                ComponentValue::String("discrete".to_string()),
            ),
        ]);
        let merged = merge_rigid_body(&previous, &changes).expect("merge");
        assert_eq!(
            merged.value_at(&["motionQuality".to_string()]),
            Some(&ComponentValue::String("discrete".to_string()))
        );
    }

    #[test]
    fn unchanged_flag_does_not_touch_motion_quality() {
        let previous = map(vec![(
            "continuousCollisionDetection",
            ComponentValue::Bool(true),
        )]);
        let changes = map(vec![(
            "continuousCollisionDetection",
            ComponentValue::Bool(true),
        )]);
        let merged = merge_rigid_body(&previous, &changes).expect("merge");
        assert_eq!(merged.value_at(&["motionQuality".to_string()]), None);
    }
}
