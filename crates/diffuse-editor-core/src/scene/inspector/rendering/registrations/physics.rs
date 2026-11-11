//! Translation of
//! Editor/Sources/EditorCore/Scene/Inspector/Rendering/Registrations/Physics.swift.

use std::rc::Rc;

use crate::scene::adapter::inspector::physics::collider::collider_section_presentation;
use crate::scene::editor_inspector_schema::EditorInspectorSectionLayout;
use crate::scene::inspector::rendering::renderers::{
    EditorInspectorRendererRegistrationError, EditorInspectorRendererRegistry,
};

impl EditorInspectorRendererRegistry {
    /// Physics components own bespoke forms: compound colliders edit shape
    /// instances, joints and deformables expose authored sub-objects.
    pub fn register_physics_renderers(
        &mut self,
    ) -> Result<(), EditorInspectorRendererRegistrationError> {
        self.register_renderer(
            "collider",
            EditorInspectorSectionLayout::Standard,
            Some(Rc::new(collider_section_presentation)),
            Rc::new(|adapter, entity| adapter.collider_section(entity)),
        )?;
        self.register_standard(
            "destructible",
            Rc::new(|adapter, entity| adapter.destructible_section(entity)),
        )?;
        self.register_standard(
            "vehicle",
            Rc::new(|adapter, entity| adapter.vehicle_section(entity)),
        )?;
        self.register_standard(
            "softBody",
            Rc::new(|adapter, entity| adapter.soft_body_section(entity)),
        )?;
        self.register_standard(
            "cloth",
            Rc::new(|adapter, entity| adapter.cloth_section(entity)),
        )?;
        self.register_standard(
            "softBodyMesh",
            Rc::new(|adapter, entity| adapter.soft_body_mesh_section(entity)),
        )?;
        self.register_standard(
            "ragdoll",
            Rc::new(|adapter, entity| adapter.ragdoll_section(entity)),
        )?;
        self.register_standard(
            "constraint",
            Rc::new(|adapter, entity| adapter.constraint_section(entity)),
        )?;
        Ok(())
    }
}
