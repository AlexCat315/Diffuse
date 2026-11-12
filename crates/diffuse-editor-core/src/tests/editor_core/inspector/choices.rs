//! Ported from `Editor/Tests/EditorCoreTests/Inspector/Choices.swift`.

use diffuse_scene::components::core::registry::ComponentRegistry;
use diffuse_scene::entity_id::EntityID;
use diffuse_scene::particles::emitter::particle_emitter::ParticleEmitter;
use diffuse_scene::particles::particle_types::ParticleBlendMode;

use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
use crate::scene::editor_inspector_schema::{EditorInspectorFieldValue, EditorInspectorSection};
use crate::scene::inspector::enum_options::EditorInspectorEnumOption;
use crate::scene::inspector::rendering::renderers::EditorInspectorRendererRegistry;

fn adapter() -> EditorSceneAdapter {
    EditorSceneAdapter::new(
        false,
        ComponentRegistry::built_in(),
        EditorInspectorRendererRegistry::built_in(),
    )
}

fn make_entity(adapter: &EditorSceneAdapter) -> u64 {
    adapter
        .with_scene_mut(|scene| scene.create_entity())
        .raw_value()
}

fn section(adapter: &EditorSceneAdapter, raw_id: u64, component: &str) -> EditorInspectorSection {
    adapter
        .inspector_sections(Some(raw_id))
        .into_iter()
        .find(|candidate| candidate.id == component)
        .expect("component inspector section")
}

fn field(section: &EditorInspectorSection, id: &str) -> EditorInspectorFieldValue {
    section
        .fields
        .iter()
        .find(|candidate| candidate.id == id)
        .expect("inspector field")
        .value
        .clone()
}

/// Typed enum fields present through the shared choices control.
#[test]
fn enum_field_uses_shared_choices() {
    let adapter = adapter();
    let id = make_entity(&adapter);
    assert!(adapter.add_component("particleEmitter", id));
    let section = section(&adapter, id, "particle-emitter");
    let EditorInspectorFieldValue::StringOptions { binding, options } =
        field(&section, "particle-blend-mode")
    else {
        panic!("expected the blend mode to use the shared choices control");
    };

    let expected_ids = ParticleBlendMode::ALL
        .iter()
        .map(EditorInspectorEnumOption::inspector_option_id)
        .collect::<Vec<_>>();
    let expected_labels = ParticleBlendMode::ALL
        .iter()
        .map(EditorInspectorEnumOption::inspector_option_label)
        .collect::<Vec<_>>();
    assert_eq!(
        options
            .iter()
            .map(|option| option.value.clone())
            .collect::<Vec<_>>(),
        expected_ids
    );
    assert_eq!(
        options
            .iter()
            .map(|option| option.label.clone())
            .collect::<Vec<_>>(),
        expected_labels
    );

    binding.set(ParticleBlendMode::Additive.inspector_option_id());
    let emitter = adapter
        .scene()
        .component::<ParticleEmitter>(EntityID::from_raw_value(id))
        .expect("particle emitter");
    assert_eq!(
        emitter.settings.appearance.blend_mode,
        ParticleBlendMode::Additive
    );
}

/// Collider shape kind edits through choices and keeps the compound editor
/// registered.
#[test]
fn collider_shape_kind_choices() {
    use diffuse_scene::physics::collider::{Collider, ColliderShapeKind};

    let adapter = adapter();
    let id = make_entity(&adapter);
    assert!(adapter.add_component("collider", id));
    let section = section(&adapter, id, "collider");
    let EditorInspectorFieldValue::StringOptions { binding, options } =
        field(&section, "shape-kind")
    else {
        panic!("expected the shape kind to use the shared choices control");
    };
    assert_eq!(options.len(), ColliderShapeKind::ALL.len());

    binding.set(ColliderShapeKind::Sphere.inspector_option_id());
    let collider = adapter
        .scene()
        .component::<Collider>(EntityID::from_raw_value(id))
        .expect("collider");
    assert_eq!(collider.shape().kind(), ColliderShapeKind::Sphere);
    assert!(section.fields.iter().any(|field| matches!(
        field.value,
        EditorInspectorFieldValue::ColliderShapeInstances(_)
    )));
}
