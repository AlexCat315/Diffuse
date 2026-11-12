//! Ported from `Editor/Tests/EditorCoreTests/EditorEntityCreationTests.swift`.

use diffuse_scene::components::core::registry::ComponentRegistry;
use diffuse_scene::rendering::render_extraction::{CameraComponent, LightComponent, LightType};

use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
use crate::scene::adapter::spawn::EditorEntityTemplate;
use crate::scene::inspector::rendering::renderers::EditorInspectorRendererRegistry;

fn adapter() -> EditorSceneAdapter {
    EditorSceneAdapter::new(
        false,
        ComponentRegistry::built_in(),
        EditorInspectorRendererRegistry::new(),
    )
}

/// Built-in templates create usable SceneRuntime entities.
#[test]
fn creates_built_in_template() {
    use diffuse_scene::rendering::render_extraction::RenderMeshComponent;
    use diffuse_scene::scene_bootstrap::SceneNameComponent;

    for template in EditorEntityTemplate::ALL {
        let adapter = adapter();
        let raw_id = adapter
            .spawn_entity_default(template)
            .unwrap_or_else(|| panic!("Expected {} to create an entity", template.raw_value()));
        let scene = adapter.scene();
        let entity = diffuse_scene::entity_id::EntityID::from_raw_value(raw_id);

        assert!(scene.contains(entity), "{}", template.raw_value());
        assert!(
            scene.component::<SceneNameComponent>(entity).is_some(),
            "{}",
            template.raw_value()
        );
        assert!(
            scene.local_transform(entity).is_some(),
            "{}",
            template.raw_value()
        );

        match template {
            EditorEntityTemplate::Empty => {
                assert!(scene.component::<RenderMeshComponent>(entity).is_none());
            }
            EditorEntityTemplate::Cube => {
                assert_eq!(
                    scene
                        .component::<RenderMeshComponent>(entity)
                        .map(|mesh| mesh.mesh_index),
                    Some(0)
                );
            }
            EditorEntityTemplate::DirectionalLight => {
                assert_eq!(
                    scene
                        .component::<LightComponent>(entity)
                        .map(|light| light.light_type),
                    Some(LightType::Directional)
                );
            }
            EditorEntityTemplate::PointLight => {
                assert_eq!(
                    scene
                        .component::<LightComponent>(entity)
                        .map(|light| light.light_type),
                    Some(LightType::Point)
                );
            }
            EditorEntityTemplate::SpotLight => {
                assert_eq!(
                    scene
                        .component::<LightComponent>(entity)
                        .map(|light| light.light_type),
                    Some(LightType::Spot)
                );
            }
            EditorEntityTemplate::Camera => {
                assert!(scene.component::<CameraComponent>(entity).is_some());
            }
        }
    }
}

/// Repeated templates receive unique names and can be undone.
#[test]
fn unique_names_and_undo() {
    let adapter = adapter();
    let first = adapter.spawn_entity_default(EditorEntityTemplate::Cube);
    let second = adapter.spawn_entity_default(EditorEntityTemplate::Cube);

    assert!(first.is_some());
    assert!(second.is_some());
    assert_ne!(first, second);
    assert_eq!(
        adapter.entity_summary(first).map(|summary| summary.name),
        Some("Cube".to_string())
    );
    assert_eq!(
        adapter.entity_summary(second).map(|summary| summary.name),
        Some("Cube 2".to_string())
    );
    assert!(adapter.can_undo_edit());
    assert!(adapter.undo_edit());
    assert!(adapter.entity_summary(second).is_none());
    assert_eq!(
        adapter.entity_summary(first).map(|summary| summary.name),
        Some("Cube".to_string())
    );
}

/// Locked parents reject child creation without creating an orphan.
#[test]
fn locked_parent_rejects_child_creation() {
    use std::collections::BTreeSet;

    let adapter = adapter();
    let parent_id = adapter
        .spawn_entity_default(EditorEntityTemplate::Empty)
        .expect("parent");
    adapter.set_entity_locked(true, &BTreeSet::from([parent_id]));
    let original_count = adapter.entity_count();

    assert!(
        adapter
            .spawn_entity(EditorEntityTemplate::Cube, None, Some(parent_id))
            .is_none()
    );
    assert_eq!(adapter.entity_count(), original_count);
}
