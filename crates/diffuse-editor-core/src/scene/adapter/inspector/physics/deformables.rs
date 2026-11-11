//! `Editor/Sources/EditorCore/Scene/Adapter/Inspector/Physics/Deformables.swift`.

use diffuse_scene::entity_id::EntityID;
use diffuse_scene::physics::queries::spatial_queries::MeshColliderGeometryResource;
use diffuse_scene::physics::soft_bodies::cloth::Cloth;
use diffuse_scene::physics::soft_bodies::soft_body::SoftBodyMesh;

use crate::localization::localized;
use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
use crate::scene::editor_inspector_schema::{EditorInspectorField, EditorInspectorFieldValue};

impl EditorSceneAdapter {
    // Authored controls come from the schema. These renderers only append
    // computed/resource diagnostics, which never enter component documents.
    pub(crate) fn soft_body_section(
        &self,
        entity: EntityID,
    ) -> Option<crate::scene::editor_inspector_schema::EditorInspectorSection> {
        let schema = self.scene().component_registry().get("softBody")?.clone();
        let mut section = self.registry_inspector_section(&schema, entity)?;
        let state = self
            .scene()
            .soft_body_state_frame()
            .states
            .get(&entity)
            .cloned();
        section.fields.push(EditorInspectorField::new(
            "soft-body-streamed-vertices",
            localized("Streamed Vertices"),
            EditorInspectorFieldValue::ReadOnly(
                state
                    .as_ref()
                    .map(|state| state.positions.len())
                    .unwrap_or(0)
                    .to_string(),
            ),
        ));
        section.fields.push(EditorInspectorField::new(
            "soft-body-sleeping",
            localized("Sleeping"),
            EditorInspectorFieldValue::ReadOnly(
                if state
                    .as_ref()
                    .map(|state| state.is_sleeping)
                    .unwrap_or(false)
                {
                    localized("Yes")
                } else {
                    localized("No")
                },
            ),
        ));
        Some(section)
    }

    pub(crate) fn cloth_section(
        &self,
        entity: EntityID,
    ) -> Option<crate::scene::editor_inspector_schema::EditorInspectorSection> {
        let schema = self.scene().component_registry().get("cloth")?.clone();
        let mut section = self.registry_inspector_section(&schema, entity)?;
        let cloth = self.scene().component::<Cloth>(entity)?;
        section.fields.push(EditorInspectorField::new(
            "cloth-vertex-count",
            localized("Vertices"),
            EditorInspectorFieldValue::ReadOnly(
                (cloth.grid_size_x * cloth.grid_size_z).to_string(),
            ),
        ));
        Some(section)
    }

    pub(crate) fn soft_body_mesh_section(
        &self,
        entity: EntityID,
    ) -> Option<crate::scene::editor_inspector_schema::EditorInspectorSection> {
        let schema = self
            .scene()
            .component_registry()
            .get("softBodyMesh")?
            .clone();
        let mut section = self.registry_inspector_section(&schema, entity)?;
        let mesh = self.scene().component::<SoftBodyMesh>(entity)?;
        let scene = self.scene();
        let geometry = scene
            .resource::<MeshColliderGeometryResource>()
            .and_then(|resource| resource.geometry_for(mesh.resource_id.as_deref()).cloned());
        section.fields.push(EditorInspectorField::new(
            "soft-body-mesh-vertices",
            localized("Vertices"),
            EditorInspectorFieldValue::ReadOnly(
                geometry
                    .as_ref()
                    .map(|geometry| geometry.positions.len())
                    .unwrap_or(0)
                    .to_string(),
            ),
        ));
        section.fields.push(EditorInspectorField::new(
            "soft-body-mesh-triangles",
            localized("Triangles"),
            EditorInspectorFieldValue::ReadOnly(
                geometry
                    .as_ref()
                    .map(|geometry| geometry.triangle_indices.len() / 3)
                    .unwrap_or(0)
                    .to_string(),
            ),
        ));
        section.fields.push(EditorInspectorField::new(
            "soft-body-mesh-tetrahedra",
            localized("Tetrahedra"),
            EditorInspectorFieldValue::ReadOnly(
                geometry
                    .as_ref()
                    .map(|geometry| geometry.tetrahedron_indices.len() / 4)
                    .unwrap_or(0)
                    .to_string(),
            ),
        ));
        section.fields.push(EditorInspectorField::new(
            "soft-body-mesh-revision",
            localized("Geometry Revision"),
            EditorInspectorFieldValue::ReadOnly(
                geometry
                    .map(|geometry| geometry.revision.to_string())
                    .unwrap_or_else(|| localized("Missing")),
            ),
        ));
        Some(section)
    }
}
