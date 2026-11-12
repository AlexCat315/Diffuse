//! Ported from `Editor/Tests/EditorCoreTests/EditorMultiSelectionInspectorTests.swift`.

use std::collections::BTreeSet;

use diffuse_scene::components::core::registry::ComponentRegistry;

use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
use crate::scene::adapter::spawn::EditorEntityTemplate;
use crate::scene::editor_inspector_schema::{EditorInspectorField, EditorInspectorFieldValue};
use crate::scene::inspector::rendering::renderers::EditorInspectorRendererRegistry;

fn adapter() -> EditorSceneAdapter {
    EditorSceneAdapter::new(
        false,
        ComponentRegistry::built_in(),
        EditorInspectorRendererRegistry::new(),
    )
}

fn selection(ids: &[u64]) -> BTreeSet<u64> {
    ids.iter().copied().collect()
}

fn field(
    adapter: &EditorSceneAdapter,
    ids: &BTreeSet<u64>,
    section: &str,
    field: &str,
    primary_id: Option<u64>,
) -> EditorInspectorField {
    adapter
        .inspector_sections_for_selection(ids, primary_id)
        .into_iter()
        .find(|candidate| candidate.id == section)
        .and_then(|section| {
            section
                .fields
                .into_iter()
                .find(|candidate| candidate.id == field)
        })
        .unwrap_or_else(|| panic!("missing {section}/{field}"))
}

/// Only fields of components shared by all selected entities are offered.
#[test]
fn intersection() {
    let adapter = adapter();
    let a = adapter
        .spawn_entity_default(EditorEntityTemplate::Empty)
        .expect("a");
    let b = adapter
        .spawn_entity_default(EditorEntityTemplate::Empty)
        .expect("b");
    assert!(adapter.add_component("light", a));
    assert!(
        !adapter
            .inspector_sections_for_selection(&selection(&[a, b]), None)
            .iter()
            .any(|section| section.id == "light")
    );
    assert!(adapter.add_component("light", b));
    assert!(
        adapter
            .inspector_sections_for_selection(&selection(&[a, b]), None)
            .iter()
            .any(|section| section.id == "light")
    );
}

/// Mixed names can be unified to the first value and undone together.
#[test]
fn mixed_names() {
    let adapter = adapter();
    let a = adapter
        .spawn_entity_default(EditorEntityTemplate::Empty)
        .expect("a");
    let b = adapter
        .spawn_entity_default(EditorEntityTemplate::Empty)
        .expect("b");
    let ids = selection(&[a, b]);
    let original: Vec<Option<String>> = ids
        .iter()
        .map(|id| {
            adapter
                .entity_summary(Some(*id))
                .map(|summary| summary.name)
        })
        .collect();
    let name = field(&adapter, &ids, "general", "name", None);
    assert!(name.is_mixed);
    let EditorInspectorFieldValue::Text(binding) = name.value else {
        panic!("expected text");
    };
    let first = binding.get();
    binding.set(first.clone());
    assert!(ids.iter().all(|id| {
        adapter
            .entity_summary(Some(*id))
            .map(|summary| summary.name)
            == Some(first.clone())
    }));
    let unified = field(&adapter, &ids, "general", "name", None);
    assert!(!unified.is_mixed);
    assert!(adapter.undo_edit());
    let restored: Vec<Option<String>> = ids
        .iter()
        .map(|id| {
            adapter
                .entity_summary(Some(*id))
                .map(|summary| summary.name)
        })
        .collect();
    assert_eq!(restored, original);
    assert!(adapter.redo_edit());
    assert!(ids.iter().all(|id| {
        adapter
            .entity_summary(Some(*id))
            .map(|summary| summary.name)
            == Some(first.clone())
    }));
}

/// A mixed checkbox can apply the already-selected primary value in one undo step.
#[test]
fn mixed_boolean() {
    let adapter = adapter();
    let a = adapter
        .spawn_entity_default(EditorEntityTemplate::Cube)
        .expect("a");
    let b = adapter
        .spawn_entity_default(EditorEntityTemplate::Cube)
        .expect("b");
    let single = field(
        &adapter,
        &selection(&[b]),
        "render-mesh",
        "mesh-visible",
        None,
    );
    let EditorInspectorFieldValue::Bool(visible) = single.value else {
        panic!("expected visibility binding");
    };
    visible.set(false);
    let shared = field(
        &adapter,
        &selection(&[a, b]),
        "render-mesh",
        "mesh-visible",
        Some(b),
    );
    assert!(shared.is_mixed);
    let apply = shared.apply_primary_value.expect("apply primary value");
    apply();
    let other = field(
        &adapter,
        &selection(&[a]),
        "render-mesh",
        "mesh-visible",
        None,
    );
    let EditorInspectorFieldValue::Bool(other_visible) = other.value else {
        panic!("expected visibility binding");
    };
    assert!(!other_visible.get());
    assert!(!visible.get());
    assert!(adapter.undo_edit());
    assert!(other_visible.get());
    assert!(!visible.get());
}

/// Editing one mixed vector axis preserves each object's other axes.
#[test]
fn vector_axes() {
    let adapter = adapter();
    let a = adapter
        .spawn_entity_default(EditorEntityTemplate::Empty)
        .expect("a");
    let b = adapter
        .spawn_entity_default(EditorEntityTemplate::Empty)
        .expect("b");
    let single = field(
        &adapter,
        &selection(&[b]),
        "transform",
        "local-position",
        None,
    );
    let EditorInspectorFieldValue::Vector3 { x: bx, y: by, .. } = single.value else {
        panic!("expected vector");
    };
    bx.set(3.0);
    by.set(7.0);
    let shared = field(
        &adapter,
        &selection(&[a, b]),
        "transform",
        "local-position",
        None,
    );
    assert_eq!(
        shared.mixed_axes,
        BTreeSet::from(["x".to_string(), "y".to_string()])
    );
    let EditorInspectorFieldValue::Vector3 { x, .. } = shared.value else {
        panic!("expected vector");
    };
    x.set(12.0);
    assert_eq!(
        adapter.entity_world_position(a).map(|position| position.x),
        Some(12.0)
    );
    assert_eq!(
        adapter.entity_world_position(b).map(|position| position.x),
        Some(12.0)
    );
    assert_eq!(
        adapter.entity_world_position(a).map(|position| position.y),
        Some(0.0)
    );
    assert_eq!(
        adapter.entity_world_position(b).map(|position| position.y),
        Some(7.0)
    );
    assert!(adapter.undo_edit());
    assert_eq!(
        adapter.entity_world_position(a).map(|position| position.x),
        Some(0.0)
    );
    assert_eq!(
        adapter.entity_world_position(b).map(|position| position.x),
        Some(3.0)
    );
}

/// A lock added after presenting the fields rejects the entire batch.
#[test]
fn lock_at_commit() {
    let adapter = adapter();
    let a = adapter
        .spawn_entity_default(EditorEntityTemplate::Empty)
        .expect("a");
    let b = adapter
        .spawn_entity_default(EditorEntityTemplate::Empty)
        .expect("b");
    let name = field(&adapter, &selection(&[a, b]), "general", "name", None);
    let EditorInspectorFieldValue::Text(binding) = name.value else {
        panic!("expected text");
    };
    adapter.set_entity_locked(true, &BTreeSet::from([b]));
    let original: Vec<Option<String>> = [a, b]
        .iter()
        .map(|id| {
            adapter
                .entity_summary(Some(*id))
                .map(|summary| summary.name)
        })
        .collect();
    let revision = adapter.revision();
    binding.set("Batch rename".to_string());
    let names: Vec<Option<String>> = [a, b]
        .iter()
        .map(|id| {
            adapter
                .entity_summary(Some(*id))
                .map(|summary| summary.name)
        })
        .collect();
    assert_eq!(names, original);
    assert_eq!(adapter.revision(), revision);
}

/// Removing a common component before commit does not partially edit the remaining objects.
#[test]
fn component_removed_at_commit() {
    let adapter = adapter();
    let a = adapter
        .spawn_entity_default(EditorEntityTemplate::PointLight)
        .expect("a");
    let b = adapter
        .spawn_entity_default(EditorEntityTemplate::PointLight)
        .expect("b");
    let intensity = field(&adapter, &selection(&[a, b]), "light", "intensity", None);
    let EditorInspectorFieldValue::ConstrainedNumber { binding, .. } = intensity.value else {
        panic!("expected intensity binding");
    };
    let original = binding.get();
    assert!(adapter.remove_component("light", b));
    let revision = adapter.revision();
    binding.set(original + 10.0);
    assert_eq!(binding.get(), original);
    assert_eq!(adapter.revision(), revision);
}

/// Scene settings are available in a scene with zero entities.
#[test]
fn empty_scene_settings() {
    let adapter = adapter();
    assert_eq!(adapter.entity_count(), 0);
    let ids: Vec<String> = adapter
        .scene_settings_sections()
        .into_iter()
        .map(|section| section.id)
        .collect();
    assert_eq!(ids, ["physics-settings", "particle-scalability"]);
}
