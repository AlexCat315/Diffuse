//! Authored defaults used when an inspector switches a collider's primary shape.
//!
//! Ported from `SceneRuntime/Physics/ColliderShapeDefaults.swift`. The returned
//! fields carry only the shape dimensions; the centre and compound instance
//! transform are retained by the generic field merge.

use std::collections::BTreeMap;

use crate::components::core::value::ComponentValue;
use crate::physics::collider::ColliderShapeKind;

impl ColliderShapeKind {
    /// Authored dimensions when changing the primary shape.
    pub fn default_component_fields(&self) -> BTreeMap<String, ComponentValue> {
        let mut fields: BTreeMap<String, ComponentValue> = BTreeMap::new();
        fields.insert(
            "shape".to_string(),
            ComponentValue::String(self.raw_value().to_string()),
        );
        match self {
            ColliderShapeKind::Box => {
                fields.insert(
                    "halfExtents".to_string(),
                    ComponentValue::Array(vec![ComponentValue::Number(0.5); 3]),
                );
            }
            ColliderShapeKind::Sphere => {
                fields.insert("radius".to_string(), ComponentValue::Number(0.5));
            }
            ColliderShapeKind::Capsule | ColliderShapeKind::Cylinder => {
                fields.insert("radius".to_string(), ComponentValue::Number(0.5));
                fields.insert("halfHeight".to_string(), ComponentValue::Number(0.5));
            }
            ColliderShapeKind::HeightField
            | ColliderShapeKind::Mesh
            | ColliderShapeKind::Convex => {
                fields.insert(
                    "resourceID".to_string(),
                    ComponentValue::String(String::new()),
                );
            }
        }
        fields
    }
}
