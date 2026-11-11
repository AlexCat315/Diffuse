//! Translation of Editor/Sources/EditorCore/Scene/Inspector/Rendering/Builtins.swift.

use crate::scene::inspector::rendering::renderers::{
    EditorInspectorRendererRegistrationError, EditorInspectorRendererRegistry,
};

impl EditorInspectorRendererRegistry {
    /// Creates an independent set of optional rich controls for each editor.
    pub fn built_in() -> Self {
        let mut registry = Self::new();
        // The built-in set is fixed: an invalid entry is a programming error here,
        // not a runtime condition the caller can recover from.
        registry
            .register_built_in_renderers()
            .expect("built-in inspector renderer registration");
        registry
    }

    /// Installs every built-in rich control, grouped by the domain that owns the form.
    pub fn register_built_in_renderers(
        &mut self,
    ) -> Result<(), EditorInspectorRendererRegistrationError> {
        self.register_physics_renderers()?;
        self.register_particle_renderers()?;
        self.register_script_renderers()?;
        self.register_animation_renderers()?;
        Ok(())
    }
}
