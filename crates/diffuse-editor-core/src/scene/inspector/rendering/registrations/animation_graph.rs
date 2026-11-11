//! Translation of
//! Editor/Sources/EditorCore/Scene/Inspector/Rendering/Registrations/AnimationGraph.swift.

use std::rc::Rc;

use crate::scene::inspector::rendering::renderers::{
    EditorInspectorRendererRegistrationError, EditorInspectorRendererRegistry,
};

impl EditorInspectorRendererRegistry {
    pub fn register_animation_renderers(
        &mut self,
    ) -> Result<(), EditorInspectorRendererRegistrationError> {
        self.register_standard(
            "animationGraphPlayer",
            Rc::new(|adapter, entity| adapter.animation_graph_player_section(entity)),
        )
    }
}
