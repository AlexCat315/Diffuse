//! `Editor/Sources/EditorCore/Scene/Inspector/Rendering/Registration.swift`.
//!
//! One explicit component → UI entry: the section factory, the property-grid
//! layout its fields are shaped for, and an optional presentation pass applied
//! to the produced section.

use std::rc::Rc;

use crate::scene::editor_inspector_schema::{EditorInspectorSection, EditorInspectorSectionLayout};

/// Swift's `EditorInspectorRendererRegistry.Renderer`.
pub type InspectorRenderer = Rc<
    dyn Fn(
        &crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter,
        diffuse_scene::entity_id::EntityID,
    ) -> Option<EditorInspectorSection>,
>;
/// Swift's `EditorInspectorRendererRegistration.Presentation`.
pub type InspectorPresentation = Rc<dyn Fn(EditorInspectorSection) -> EditorInspectorSection>;

/// Registrations are values, not a string-keyed dispatch table, so native modules
/// and, later, plugin hosts can build and register them from data.
#[derive(Clone)]
pub struct EditorInspectorRendererRegistration {
    pub component_type_id: String,
    pub layout: EditorInspectorSectionLayout,
    pub render: InspectorRenderer,
    pub presentation: Option<InspectorPresentation>,
}

impl EditorInspectorRendererRegistration {
    /// Swift's initializer with its default arguments.
    pub fn new(component_type_id: impl Into<String>, render: InspectorRenderer) -> Self {
        EditorInspectorRendererRegistration {
            component_type_id: component_type_id.into(),
            layout: EditorInspectorSectionLayout::Standard,
            render,
            presentation: None,
        }
    }

    /// The full memberwise initializer.
    pub fn with_options(
        component_type_id: impl Into<String>,
        layout: EditorInspectorSectionLayout,
        presentation: Option<InspectorPresentation>,
        render: InspectorRenderer,
    ) -> Self {
        EditorInspectorRendererRegistration {
            component_type_id: component_type_id.into(),
            layout,
            render,
            presentation,
        }
    }
}
