//! `Editor/Sources/EditorCore/Scene/Inspector/Rendering/Renderers.swift`.
//!
//! Editor-session UI factories, keyed by the component registry's stable type
//! ID. Factories receive the adapter at render time so built-ins do not retain
//! an owning scene adapter.

use std::collections::BTreeMap;

use diffuse_scene::entity_id::EntityID;

use crate::scene::editor_inspector_schema::{EditorInspectorSection, EditorInspectorSectionLayout};
use crate::scene::inspector::rendering::registration::{
    EditorInspectorRendererRegistration, InspectorPresentation, InspectorRenderer,
};

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum EditorInspectorRendererRegistrationError {
    #[error("component type ID must not be empty")]
    EmptyComponentTypeID,
    #[error("a renderer is already registered for {0}")]
    DuplicateRenderer(String),
}

/// Swift's `Renderer` and `Presentation` aliases, re-exported here so callers
/// name the registry's types.
pub type Renderer = InspectorRenderer;
pub type Presentation = InspectorPresentation;

#[derive(Default)]
pub struct EditorInspectorRendererRegistry {
    registrations: BTreeMap<String, EditorInspectorRendererRegistration>,
}

impl Clone for EditorInspectorRendererRegistry {
    fn clone(&self) -> Self {
        EditorInspectorRendererRegistry {
            registrations: self.registrations.clone(),
        }
    }
}

impl EditorInspectorRendererRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn component_type_ids(&self) -> Vec<String> {
        self.registrations.keys().cloned().collect()
    }

    pub fn renderer(&self, component_type_id: &str) -> Option<Renderer> {
        self.registrations
            .get(component_type_id)
            .map(|registration| registration.render.clone())
    }

    pub fn registration(
        &self,
        component_type_id: &str,
    ) -> Option<&EditorInspectorRendererRegistration> {
        self.registrations.get(component_type_id)
    }

    /// Layout the property grid uses for this component's section. Generated
    /// forms, scene settings and unregistered components keep `.standard`.
    pub fn layout_for(&self, component_type_id: &str) -> EditorInspectorSectionLayout {
        self.registrations
            .get(component_type_id)
            .map(|registration| registration.layout)
            .unwrap_or(EditorInspectorSectionLayout::Standard)
    }

    /// Applies the registered presentation pass, if the component declared one.
    /// Sections other components own are returned unchanged.
    pub fn presented_section(&self, section: EditorInspectorSection) -> EditorInspectorSection {
        let Some(component_type_id) = section.component_type_id.clone() else {
            return section;
        };
        let Some(presentation) = self
            .registrations
            .get(&component_type_id)
            .and_then(|registration| registration.presentation.clone())
        else {
            return section;
        };
        presentation(section)
    }

    /// Remove an existing renderer explicitly before replacing it. Returning nil
    /// from a renderer delegates to the schema's generated field form.
    pub fn register(
        &mut self,
        registration: EditorInspectorRendererRegistration,
    ) -> Result<(), EditorInspectorRendererRegistrationError> {
        let component_type_id = registration.component_type_id.clone();
        if component_type_id.is_empty() {
            return Err(EditorInspectorRendererRegistrationError::EmptyComponentTypeID);
        }
        if self.registrations.contains_key(&component_type_id) {
            return Err(EditorInspectorRendererRegistrationError::DuplicateRenderer(
                component_type_id,
            ));
        }
        self.registrations.insert(component_type_id, registration);
        Ok(())
    }

    /// Swift's convenience overload with `layout: .standard` and no presentation.
    pub fn register_renderer(
        &mut self,
        component_type_id: impl Into<String>,
        layout: EditorInspectorSectionLayout,
        presentation: Option<Presentation>,
        render: Renderer,
    ) -> Result<(), EditorInspectorRendererRegistrationError> {
        self.register(EditorInspectorRendererRegistration::with_options(
            component_type_id,
            layout,
            presentation,
            render,
        ))
    }

    /// Swift's convenience overload's default arguments spelled out.
    pub fn register_standard(
        &mut self,
        component_type_id: impl Into<String>,
        render: Renderer,
    ) -> Result<(), EditorInspectorRendererRegistrationError> {
        self.register(EditorInspectorRendererRegistration::new(
            component_type_id,
            render,
        ))
    }

    pub fn remove(&mut self, component_type_id: &str) -> Option<Renderer> {
        self.registrations
            .remove(component_type_id)
            .map(|registration| registration.render)
    }

    /// The renderer for `entity`, if this component type registers one.
    pub fn render_section(
        &self,
        component_type_id: &str,
        adapter: &crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter,
        entity: EntityID,
    ) -> Option<EditorInspectorSection> {
        self.renderer(component_type_id)
            .and_then(|renderer| renderer(adapter, entity))
    }
}
