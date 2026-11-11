//! `Editor/Sources/EditorCore/Scene/Adapter/Inspector/Inspector.swift`.

use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
use crate::scene::editor_inspector_schema::EditorInspectorSection;

impl EditorSceneAdapter {
    pub fn scene_settings_sections(&self) -> Vec<EditorInspectorSection> {
        vec![
            self.physics_settings_section(),
            self.particle_scalability_section(),
        ]
    }

    pub fn inspector_sections(&self, raw_id: Option<u64>) -> Vec<EditorInspectorSection> {
        let Some(entity) = self.entity_from(raw_id) else {
            return Vec::new();
        };
        if !self.scene().contains(entity) {
            return Vec::new();
        }

        let mut sections: Vec<EditorInspectorSection> = vec![
            self.general_section(entity),
            self.hierarchy_section(entity),
            self.physics_settings_section(),
            self.particle_scalability_section(),
        ];

        if let Some(transform_section) = self.transform_section(entity) {
            sections.push(transform_section);
        }
        let scene = self.scene();
        for schema in scene.component_registry().component_schemas() {
            if !scene.has_component_by_type_id(&schema.type_id, entity) {
                continue;
            }
            let rendered = {
                let renderers = self.inspector_renderers.borrow();
                renderers
                    .renderer(&schema.type_id)
                    .and_then(|renderer| renderer(self, entity))
            };
            let Some(mut section) =
                rendered.or_else(|| self.registry_inspector_section(&schema, entity))
            else {
                continue;
            };
            section.component_type_id = Some(schema.type_id.clone());
            sections.push(section);
        }

        let additional = self
            .additional_inspector_sections
            .borrow()
            .as_ref()
            .map(|provider| provider(entity.raw_value()))
            .unwrap_or_default();
        sections.extend(additional);
        sections
    }
}
