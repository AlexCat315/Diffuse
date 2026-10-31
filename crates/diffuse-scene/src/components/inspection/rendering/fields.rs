//! `Inspection/Rendering/Fields.swift` — the render mesh and material forms.
//!
//! Mesh and asset identifiers are read-only because they are resolved by the asset
//! reference; the emissive colour is unbounded (HDR) while base colour stays in the
//! default 0…1 range.

use crate::components::inspection::builtin_inspection::{field, ComponentFieldSpec};
use crate::components::inspection::inspection::{ComponentFieldKind, ComponentInspection};

impl ComponentInspection {
    /// Swift `renderMesh`.
    pub fn render_mesh() -> Self {
        let mut inspection = ComponentInspection {
            section_id: Some("render-mesh".to_string()),
            inferred_fields_are_advanced: true,
            fields: vec![
                field(ComponentFieldSpec::new("isVisible", "Visible").id("mesh-visible")),
                field(
                    ComponentFieldSpec::new("colorTint", "Color Tint")
                        .id("mesh-color-tint")
                        .kind(ComponentFieldKind::Color),
                ),
                field(ComponentFieldSpec::new("meshIndex", "Mesh Index")),
                field(
                    ComponentFieldSpec::new("assetID", "Asset ID")
                        .kind(ComponentFieldKind::String),
                ),
            ],
            ..ComponentInspection::default()
        };
        for index in [2, 3] {
            inspection.fields[index].is_read_only = true;
            inspection.fields[index].is_advanced = true;
        }
        inspection
    }

    /// Swift `renderMaterial` — "Emissive" opts out of the 0…1 colour limit.
    pub fn render_material() -> Self {
        let mut inspection = ComponentInspection {
            section_id: Some("render-material".to_string()),
            inferred_fields_are_advanced: true,
            fields: vec![
                field(
                    ComponentFieldSpec::new("baseColorFactor", "Base Color")
                        .id("mat-base-color")
                        .kind(ComponentFieldKind::Color),
                ),
                field(
                    ComponentFieldSpec::new("metallicFactor", "Metallic")
                        .id("mat-metallic")
                        .minimum(0.0)
                        .maximum(1.0)
                        .step(0.05),
                ),
                field(
                    ComponentFieldSpec::new("roughnessFactor", "Roughness")
                        .id("mat-roughness")
                        .minimum(0.0)
                        .maximum(1.0)
                        .step(0.05),
                ),
                field(
                    ComponentFieldSpec::new("emissiveFactor", "Emissive")
                        .id("mat-emissive")
                        .kind(ComponentFieldKind::Color),
                ),
            ],
            ..ComponentInspection::default()
        };
        inspection.fields[3].color.maximum = None;
        inspection
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mesh_identifiers_are_read_only_and_advanced() {
        let inspection = ComponentInspection::render_mesh();
        assert_eq!(inspection.section_id.as_deref(), Some("render-mesh"));
        for index in [2, 3] {
            assert!(inspection.fields[index].is_read_only);
            assert!(inspection.fields[index].is_advanced);
        }
        assert!(!inspection.fields[0].is_read_only);
    }

    #[test]
    fn emissive_color_has_no_upper_bound() {
        let inspection = ComponentInspection::render_material();
        assert_eq!(inspection.fields[0].color.maximum, Some(1.0));
        assert_eq!(inspection.fields[3].color.maximum, None);
        assert_eq!(inspection.fields[1].numeric.maximum, Some(1.0));
    }
}
