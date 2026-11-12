//! Ported from `Editor/Tests/EditorCoreTests/Inspector/Renderers.swift`.

use std::rc::Rc;

use diffuse_scene::components::core::registry::ComponentRegistry;

use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
use crate::scene::editor_inspector_schema::{
    EditorInspectorField, EditorInspectorFieldValue, EditorInspectorSection,
    EditorInspectorSectionLayout,
};
use crate::scene::inspector::rendering::registration::EditorInspectorRendererRegistration;
use crate::scene::inspector::rendering::renderers::{
    EditorInspectorRendererRegistrationError, EditorInspectorRendererRegistry,
};

fn adapter(registry: EditorInspectorRendererRegistry) -> EditorSceneAdapter {
    EditorSceneAdapter::new(false, ComponentRegistry::built_in(), registry)
}

fn make_entity(adapter: &EditorSceneAdapter) -> u64 {
    adapter
        .with_scene_mut(|scene| scene.create_entity())
        .raw_value()
}

fn section(id: &str) -> EditorInspectorSection {
    EditorInspectorSection::new(id, id, Vec::new())
}

/// Invalid registrations preserve the installed renderer; copies can replace it
/// independently.
#[test]
fn registration_and_isolation() {
    let mut registry = EditorInspectorRendererRegistry::new();
    registry
        .register_standard(
            "light",
            Rc::new(|_, _| {
                Some(EditorInspectorSection::new(
                    "original",
                    "Original",
                    Vec::new(),
                ))
            }),
        )
        .expect("register light");
    assert!(matches!(
        registry.register_standard("", Rc::new(|_, _| None)),
        Err(EditorInspectorRendererRegistrationError::EmptyComponentTypeID)
    ));
    assert!(matches!(
        registry.register_standard("light", Rc::new(|_, _| None)),
        Err(EditorInspectorRendererRegistrationError::DuplicateRenderer(id)) if id == "light"
    ));

    let first = adapter(registry.clone());
    let second = adapter(registry.clone());
    assert_eq!(
        first.inspector_renderers.borrow().component_type_ids(),
        ["light"]
    );
    assert!(
        first
            .inspector_renderers
            .borrow_mut()
            .remove("light")
            .is_some()
    );
    first
        .inspector_renderers
        .borrow_mut()
        .register_standard("light", Rc::new(|_, _| None))
        .expect("replace light");

    let a = make_entity(&first);
    let b = make_entity(&second);
    assert!(first.add_component("light", a));
    assert!(second.add_component("light", b));
    assert!(
        first
            .inspector_sections(Some(a))
            .iter()
            .any(|section| section.id == "light")
    );
    assert!(
        second
            .inspector_sections(Some(b))
            .iter()
            .any(|section| section.id == "original")
    );
    assert_eq!(registry.component_type_ids(), ["light"]);
}

/// Renderer configuration survives undo, document loading and scene reset
/// without persisting.
#[test]
fn session_lifecycle() {
    let adapter = adapter(EditorInspectorRendererRegistry::built_in());
    let entity = make_entity(&adapter);
    assert!(adapter.add_component("light", entity));
    adapter.reset_edit_history();
    let manifest = adapter.manifest_for_selection(Some(entity));
    let revision = adapter.revision();

    adapter
        .inspector_renderers
        .borrow_mut()
        .register_standard(
            "light",
            Rc::new(|_, _| {
                Some(EditorInspectorSection::new(
                    "module-light",
                    "Module Light",
                    Vec::new(),
                ))
            }),
        )
        .expect("register module light");
    assert_eq!(adapter.revision(), revision);
    assert_eq!(adapter.manifest_for_selection(Some(entity)), manifest);
    assert!(!adapter.can_undo_edit());

    assert!(adapter.remove_component("light", entity));
    assert!(adapter.undo_edit());
    assert!(
        adapter
            .inspector_sections(Some(entity))
            .iter()
            .any(|section| section.id == "module-light")
    );

    let loaded = adapter.load(&manifest);
    assert!(loaded.succeeded());
    let restored = loaded.selected_entity_id.expect("restored selection");
    assert!(
        adapter
            .inspector_sections(Some(restored))
            .iter()
            .any(|section| section.id == "module-light")
    );

    adapter.reset_to_preview_scene();
    let fresh = make_entity(&adapter);
    assert!(adapter.add_component("light", fresh));
    assert!(
        adapter
            .inspector_sections(Some(fresh))
            .iter()
            .any(|section| section.id == "module-light")
    );
    assert!(
        EditorInspectorRendererRegistry::built_in()
            .renderer("light")
            .is_none()
    );
}

/// Built-in registrations declare the property-grid layout their fields are
/// shaped for.
#[test]
fn built_in_layouts() {
    let renderers = EditorInspectorRendererRegistry::built_in();
    assert_eq!(
        renderers.layout_for("script"),
        EditorInspectorSectionLayout::ScriptBindings
    );
    assert_eq!(
        renderers.layout_for("particleEmitter"),
        EditorInspectorSectionLayout::ParticleModules
    );
    assert_eq!(
        renderers.layout_for("collider"),
        EditorInspectorSectionLayout::Standard
    );
    assert_eq!(
        renderers.layout_for("rigidbody"),
        EditorInspectorSectionLayout::Standard
    );
}

/// A registration value installs layout, presentation and renderer together.
#[test]
fn registration_value() {
    let mut registry = EditorInspectorRendererRegistry::new();
    let mut section = section("terrain");
    section.component_type_id = Some("module.terrain".to_string());
    section.fields = vec![EditorInspectorField::new(
        "height",
        "Height",
        EditorInspectorFieldValue::ReadOnly("0".to_string()),
    )];
    let rendered = section.clone();
    let registration = EditorInspectorRendererRegistration::with_options(
        "module.terrain",
        EditorInspectorSectionLayout::ParticleModules,
        Some(Rc::new(|presented| {
            let mut result = presented;
            result.fields.retain(|field| field.id != "height");
            result
        })),
        Rc::new(move |_, _| Some(rendered.clone())),
    );
    registry
        .register(registration.clone())
        .expect("register terrain");
    assert_eq!(registry.component_type_ids(), ["module.terrain"]);
    assert_eq!(
        registry.layout_for("module.terrain"),
        EditorInspectorSectionLayout::ParticleModules
    );
    assert!(
        registry
            .presented_section(section.clone())
            .fields
            .is_empty()
    );

    let mut untyped = section;
    untyped.component_type_id = None;
    assert_eq!(registry.presented_section(untyped).fields.len(), 1);
    assert!(matches!(
        registry.register(registration),
        Err(EditorInspectorRendererRegistrationError::DuplicateRenderer(id))
            if id == "module.terrain"
    ));
}

/// Presentations apply to their own component only.
#[test]
fn presentation_scope() {
    let adapter = adapter(EditorInspectorRendererRegistry::built_in());
    let entity = make_entity(&adapter);
    assert!(adapter.add_component("collider", entity));
    let section = adapter
        .inspector_sections(Some(entity))
        .into_iter()
        .find(|section| section.component_type_id.as_deref() == Some("collider"))
        .expect("collider section");
    assert!(section.fields.iter().any(|field| field.id == "shape-kind"));

    let presented = adapter
        .inspector_renderers
        .borrow()
        .presented_section(section.clone());
    assert!(
        !presented
            .fields
            .iter()
            .any(|field| field.id == "shape-kind")
    );
    assert!(
        presented
            .fields
            .iter()
            .any(|field| field.id == "shape-instances")
    );

    assert!(
        adapter
            .inspector_renderers
            .borrow_mut()
            .remove("collider")
            .is_some()
    );
    assert_eq!(
        adapter
            .inspector_renderers
            .borrow()
            .presented_section(section.clone())
            .fields
            .len(),
        section.fields.len()
    );
}

/// Built-in rich controls can be removed and fall back to schema fields.
#[test]
fn rich_control_fallback() {
    let adapter = adapter(EditorInspectorRendererRegistry::built_in());
    let registry = adapter.scene().component_registry().clone();
    assert!(
        adapter
            .inspector_renderers
            .borrow()
            .component_type_ids()
            .iter()
            .all(|id| registry.schema_named(id).is_some())
    );

    let entity = make_entity(&adapter);
    assert!(adapter.add_component("collider", entity));
    let rich = adapter
        .inspector_sections(Some(entity))
        .into_iter()
        .find(|section| section.component_type_id.as_deref() == Some("collider"))
        .expect("collider section");
    assert!(rich.fields.iter().any(|field| matches!(
        field.value,
        EditorInspectorFieldValue::ColliderShapeInstances(_)
    )));

    assert!(
        adapter
            .inspector_renderers
            .borrow_mut()
            .remove("collider")
            .is_some()
    );
    let generated = adapter
        .inspector_sections(Some(entity))
        .into_iter()
        .find(|section| section.component_type_id.as_deref() == Some("collider"))
        .expect("generated collider section");
    assert!(!generated.fields.is_empty());
    assert!(!generated.fields.iter().any(|field| matches!(
        field.value,
        EditorInspectorFieldValue::ColliderShapeInstances(_)
    )));
    assert!(
        adapter
            .inspector_renderers
            .borrow_mut()
            .remove("collider")
            .is_none()
    );
}
