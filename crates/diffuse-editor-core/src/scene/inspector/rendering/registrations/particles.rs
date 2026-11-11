//! Translation of
//! Editor/Sources/EditorCore/Scene/Inspector/Rendering/Registrations/Particles.swift.

use std::rc::Rc;

use crate::scene::editor_inspector_schema::EditorInspectorSectionLayout;
use crate::scene::inspector::rendering::renderers::{
    EditorInspectorRendererRegistrationError, EditorInspectorRendererRegistry,
};

impl EditorInspectorRendererRegistry {
    /// Particle modules are authored as a fixed stack of groups, so the section
    /// needs the module layout rather than a flat field list.
    pub fn register_particle_renderers(
        &mut self,
    ) -> Result<(), EditorInspectorRendererRegistrationError> {
        self.register_renderer(
            "particleEmitter",
            EditorInspectorSectionLayout::ParticleModules,
            None,
            Rc::new(|adapter, entity| adapter.particle_emitter_section(entity)),
        )
    }
}
