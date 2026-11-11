//! Translation of
//! Editor/Sources/EditorCore/Scene/Inspector/Rendering/Registrations/ScriptForm.swift.

use std::rc::Rc;

use crate::scene::editor_inspector_schema::EditorInspectorSectionLayout;
use crate::scene::inspector::rendering::renderers::{
    EditorInspectorRendererRegistrationError, EditorInspectorRendererRegistry,
};

impl EditorInspectorRendererRegistry {
    /// Script bindings are one collapsible sub-form per binding, each carrying
    /// its own header actions.
    pub fn register_script_renderers(
        &mut self,
    ) -> Result<(), EditorInspectorRendererRegistrationError> {
        self.register_renderer(
            "script",
            EditorInspectorSectionLayout::ScriptBindings,
            None,
            Rc::new(|adapter, entity| adapter.script_section(entity)),
        )
    }
}
