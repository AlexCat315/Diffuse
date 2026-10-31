//! `Inspection/Physics/Deformables.swift` — soft body, cloth and soft-body mesh
//! forms, plus their shared bend-type options field.

use crate::components::core::value::ComponentValue;
use crate::components::inspection::builtin_inspection::{field, ComponentFieldSpec};
use crate::components::inspection::inspection::{
    ComponentFieldChoice, ComponentFieldDescriptor, ComponentFieldKind, ComponentInspection,
};
use crate::physics::soft_bodies::cloth::ClothBendType;

impl ComponentInspection {
    /// Swift `softBody`.
    pub fn soft_body() -> Self {
        ComponentInspection {
            section_id: Some("soft-body".to_string()),
            fields: vec![
                field(ComponentFieldSpec::new("isEnabled", "Enabled").id("soft-body-enabled")),
                field(
                    ComponentFieldSpec::new("vertexMass", "Vertex Mass")
                        .id("soft-body-vertex-mass")
                        .minimum(0.0001)
                        .step(0.05),
                ),
                field(
                    ComponentFieldSpec::new("pressure", "Pressure")
                        .id("soft-body-pressure")
                        .minimum(0.0)
                        .step(0.1),
                ),
                field(
                    ComponentFieldSpec::new("linearDamping", "Linear Damping")
                        .id("soft-body-damping")
                        .minimum(0.0)
                        .step(0.05),
                ),
                field(
                    ComponentFieldSpec::new("friction", "Friction")
                        .id("soft-body-friction")
                        .minimum(0.0)
                        .step(0.05),
                ),
                field(
                    ComponentFieldSpec::new("restitution", "Restitution")
                        .id("soft-body-restitution")
                        .minimum(0.0)
                        .maximum(1.0)
                        .step(0.05),
                ),
                field(
                    ComponentFieldSpec::new("gravityScale", "Gravity Scale")
                        .id("soft-body-gravity")
                        .step(0.1),
                ),
                field(
                    ComponentFieldSpec::new("vertexRadius", "Vertex Radius")
                        .id("soft-body-vertex-radius")
                        .minimum(0.0)
                        .step(0.005),
                ),
                field(
                    ComponentFieldSpec::new("solverIterations", "Solver Iterations")
                        .id("soft-body-iterations")
                        .minimum(1.0)
                        .maximum(128.0)
                        .step(1.0)
                        .kind(ComponentFieldKind::Integer),
                ),
                field(
                    ComponentFieldSpec::new("maxLinearVelocity", "Max Velocity")
                        .id("soft-body-max-velocity")
                        .minimum(0.0)
                        .step(1.0),
                ),
                field(
                    ComponentFieldSpec::new("layerID", "Layer")
                        .id("soft-body-layer")
                        .minimum(0.0)
                        .maximum(15.0)
                        .step(1.0)
                        .kind(ComponentFieldKind::Integer),
                ),
                field(
                    ComponentFieldSpec::new("layerMask", "Layer Mask")
                        .id("soft-body-layer-mask")
                        .minimum(0.0)
                        .maximum(65_535.0)
                        .step(1.0)
                        .kind(ComponentFieldKind::Integer),
                ),
                field(
                    ComponentFieldSpec::new("allowSleep", "Allow Sleep")
                        .id("soft-body-allow-sleep"),
                ),
                field(
                    ComponentFieldSpec::new("facesDoubleSided", "Double Sided")
                        .id("soft-body-double-sided"),
                ),
                field(
                    ComponentFieldSpec::new("selfCollision", "Self Collision")
                        .id("soft-body-self-collision"),
                ),
            ],
            ..ComponentInspection::default()
        }
    }

    /// Swift `cloth`.
    pub fn cloth() -> Self {
        ComponentInspection {
            section_id: Some("cloth".to_string()),
            fields: vec![
                field(
                    ComponentFieldSpec::new("gridSizeX", "Grid X")
                        .id("cloth-grid-x")
                        .minimum(2.0)
                        .maximum(512.0)
                        .step(1.0)
                        .kind(ComponentFieldKind::Integer),
                ),
                field(
                    ComponentFieldSpec::new("gridSizeZ", "Grid Z")
                        .id("cloth-grid-z")
                        .minimum(2.0)
                        .maximum(512.0)
                        .step(1.0)
                        .kind(ComponentFieldKind::Integer),
                ),
                field(
                    ComponentFieldSpec::new("spacing", "Spacing")
                        .id("cloth-spacing")
                        .minimum(0.001)
                        .step(0.01),
                ),
                field(
                    ComponentFieldSpec::new("fixedVertexIndices", "Fixed Vertex Indices")
                        .id("cloth-fixed-vertices")
                        .kind(ComponentFieldKind::Json),
                ),
                field(
                    ComponentFieldSpec::new("compliance", "Stretch Compliance")
                        .id("cloth-compliance")
                        .minimum(0.0)
                        .step(0.00001),
                ),
                field(
                    ComponentFieldSpec::new("shearCompliance", "Shear Compliance")
                        .id("cloth-shear-compliance")
                        .minimum(0.0)
                        .step(0.00001),
                ),
                field(
                    ComponentFieldSpec::new("bendCompliance", "Bend Compliance")
                        .id("cloth-bend-compliance")
                        .minimum(0.0)
                        .step(0.00001),
                ),
                bend_type_field("cloth-bend-type"),
            ],
            ..ComponentInspection::default()
        }
    }

    /// Swift `softBodyMesh`.
    pub fn soft_body_mesh() -> Self {
        let mut resource = field(
            ComponentFieldSpec::new("resourceID", "Geometry Resource")
                .id("soft-body-mesh-resource")
                .kind(ComponentFieldKind::String),
        );
        resource.is_nullable = true;
        ComponentInspection {
            section_id: Some("soft-body-mesh".to_string()),
            fields: vec![
                resource,
                field(
                    ComponentFieldSpec::new("fixedVertexIndices", "Fixed Vertex Indices")
                        .id("soft-body-mesh-fixed")
                        .kind(ComponentFieldKind::Json),
                ),
                field(
                    ComponentFieldSpec::new("compliance", "Stretch Compliance")
                        .id("soft-body-mesh-compliance")
                        .minimum(0.0)
                        .step(0.00001),
                ),
                field(
                    ComponentFieldSpec::new("shearCompliance", "Shear Compliance")
                        .id("soft-body-mesh-shear")
                        .minimum(0.0)
                        .step(0.00001),
                ),
                field(
                    ComponentFieldSpec::new("bendCompliance", "Bend Compliance")
                        .id("soft-body-mesh-bend")
                        .minimum(0.0)
                        .step(0.00001),
                ),
                field(
                    ComponentFieldSpec::new("volumeCompliance", "Volume Compliance")
                        .id("soft-body-mesh-volume")
                        .minimum(0.0)
                        .step(0.00001),
                ),
                bend_type_field("soft-body-mesh-bend-type"),
            ],
            ..ComponentInspection::default()
        }
    }
}

/// Swift `bendTypeField(id:)` — the choice ID is the case name, the stored value is
/// the raw `UInt8` (the codec writes a number, not a string).
fn bend_type_field(id: &str) -> ComponentFieldDescriptor {
    let mut descriptor = ComponentFieldDescriptor::new(vec!["bendType".to_string()]);
    descriptor.id = id.to_string();
    descriptor.label = "Bend Type".to_string();
    descriptor.kind = ComponentFieldKind::Options;
    descriptor.choices = ClothBendType::ALL
        .iter()
        .map(|bend_type| {
            ComponentFieldChoice::new(bend_type_name(bend_type))
                .with_value(ComponentValue::UnsignedInteger(bend_type.raw_value() as u64))
        })
        .collect();
    descriptor
}

/// Swift `String(describing:)` for a `ClothBendType` case.
fn bend_type_name(bend_type: &ClothBendType) -> &'static str {
    match bend_type {
        ClothBendType::None => "none",
        ClothBendType::Distance => "distance",
        ClothBendType::Dihedral => "dihedral",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bend_type_choices_use_case_names_and_raw_values() {
        let inspection = ComponentInspection::cloth();
        let bend_type = &inspection.fields[7];
        assert_eq!(bend_type.id, "cloth-bend-type");
        assert_eq!(bend_type.kind, ComponentFieldKind::Options);
        assert_eq!(bend_type.choices.len(), 3);
        assert_eq!(bend_type.choices[0].id, "none");
        assert_eq!(
            bend_type.choices[2].value,
            ComponentValue::UnsignedInteger(2)
        );
        assert_eq!(bend_type.choices[2].label, "Dihedral");
    }

    #[test]
    fn soft_body_mesh_resource_is_nullable() {
        let inspection = ComponentInspection::soft_body_mesh();
        assert_eq!(inspection.section_id.as_deref(), Some("soft-body-mesh"));
        assert!(inspection.fields[0].is_nullable);
        assert_eq!(inspection.fields[0].kind, ComponentFieldKind::String);
        assert_eq!(inspection.fields.len(), 7);
    }

    #[test]
    fn soft_body_integer_fields_are_marked_integer() {
        let inspection = ComponentInspection::soft_body();
        assert_eq!(inspection.fields[8].kind, ComponentFieldKind::Integer);
        assert_eq!(inspection.fields[10].numeric.maximum, Some(15.0));
        assert_eq!(inspection.fields[11].numeric.maximum, Some(65_535.0));
        assert_eq!(inspection.fields.len(), 15);
    }
}
