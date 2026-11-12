//! Ported from `Editor/Tests/EditorCoreTests/Inspector/GeneratedForms.swift`.

use std::collections::BTreeSet;

use cove_ui_compose::scene_core::Color;
use diffuse_math::simd::simd_compat::{Float3, Float4};
use diffuse_scene::components::core::registry::ComponentRegistry;
use diffuse_scene::entity_id::EntityID;
use diffuse_scene::media::animation::AnimationPlayer;
use diffuse_scene::rendering::render_extraction::{RenderMaterialComponent, RenderMeshComponent};
use diffuse_scene::rendering::render_scene::{MaterialAlphaMode, RenderMeshLOD};

use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
use crate::scene::editor_inspector_schema::{
    EditorInspectorFieldPresentation, EditorInspectorFieldValue, EditorInspectorSection,
};
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

fn section(adapter: &EditorSceneAdapter, id: u64, component: &str) -> EditorInspectorSection {
    assert!(
        adapter
            .inspector_renderers
            .borrow()
            .renderer(component)
            .is_none()
    );
    adapter
        .inspector_sections(Some(id))
        .into_iter()
        .find(|candidate| candidate.component_type_id.as_deref() == Some(component))
        .expect("generated form")
}

fn field(section: &EditorInspectorSection, id: &str) -> EditorInspectorFieldValue {
    section
        .fields
        .iter()
        .find(|candidate| candidate.id == id)
        .expect("generated field")
        .value
        .clone()
}

/// Mesh form retains asset and LOD data, clamps RGB and coalesces component
/// edits.
#[test]
fn mesh_form() {
    let adapter = adapter();
    let id = make_entity(&adapter);
    let entity = EntityID::from_raw_value(id);
    let original = RenderMeshComponent::new(
        7,
        true,
        Float3::new(0.2, 0.4, 0.6),
        Some("mesh.tree".to_string()),
        vec![RenderMeshLOD::new(9, 20.0)],
    );
    adapter.with_scene_mut(|scene| scene.set_component(original.clone(), entity));
    adapter.reset_edit_history();

    let form = section(&adapter, id, "renderMesh");
    assert_eq!(form.id, "render-mesh");
    assert_eq!(
        form.fields
            .iter()
            .filter(|field| field.presentation == EditorInspectorFieldPresentation::Standard)
            .map(|field| field.id.clone())
            .collect::<Vec<_>>(),
        ["mesh-visible", "mesh-color-tint"]
    );
    let EditorInspectorFieldValue::Bool(visible) = field(&form, "mesh-visible") else {
        panic!("expected visible");
    };
    let EditorInspectorFieldValue::Color(tint) = field(&form, "mesh-color-tint") else {
        panic!("expected tint");
    };
    assert!(matches!(
        field(&form, "meshIndex"),
        EditorInspectorFieldValue::ReadOnly(_)
    ));

    adapter.begin_interactive_edit_history_group();
    tint.set(Color {
        r: -1.0,
        g: 0.5,
        b: 2.0,
        a: 1.0,
    });
    visible.set(false);
    adapter.end_interactive_edit_history_group();
    let mut expected = original.clone();
    expected.color_tint = Float3::new(0.0, 0.5, 1.0);
    expected.is_visible = false;
    assert_eq!(
        adapter.scene().component::<RenderMeshComponent>(entity),
        Some(expected.clone())
    );

    let revision = adapter.revision();
    tint.set(Color {
        r: f32::NAN,
        g: 0.0,
        b: 0.0,
        a: 1.0,
    });
    assert_eq!(adapter.revision(), revision);
    assert!(adapter.undo_edit());
    assert_eq!(
        adapter.scene().component::<RenderMeshComponent>(entity),
        Some(original)
    );
    assert!(!adapter.can_undo_edit());
    assert!(adapter.redo_edit());
    assert_eq!(
        adapter.scene().component::<RenderMeshComponent>(entity),
        Some(expected)
    );
}

/// Material form retains HDR RGB and coverage overrides while normalizing
/// bounded channels.
#[test]
fn material_form() {
    let adapter = adapter();
    let id = make_entity(&adapter);
    let entity = EntityID::from_raw_value(id);
    let original = RenderMaterialComponent::new(
        Float4::new(0.2, 0.4, 0.6, 0.5),
        Some(3),
        Some(4),
        0.2,
        0.8,
        Float3::new(2.0, 4.0, 8.0),
        Some(MaterialAlphaMode::Mask),
        Some(0.25),
        Some(true),
    );
    adapter.with_scene_mut(|scene| scene.set_component(original.clone(), entity));
    adapter.reset_edit_history();

    let form = section(&adapter, id, "renderMaterial");
    assert_eq!(form.id, "render-material");
    let EditorInspectorFieldValue::Color(base) = field(&form, "mat-base-color") else {
        panic!("expected base color");
    };
    let EditorInspectorFieldValue::Color(emissive) = field(&form, "mat-emissive") else {
        panic!("expected emissive");
    };
    let EditorInspectorFieldValue::ConstrainedNumber {
        binding: metallic, ..
    } = field(&form, "mat-metallic")
    else {
        panic!("expected metallic");
    };
    let EditorInspectorFieldValue::ConstrainedNumber {
        binding: roughness, ..
    } = field(&form, "mat-roughness")
    else {
        panic!("expected roughness");
    };
    assert_eq!(emissive.get().g, 4.0);

    adapter.begin_interactive_edit_history_group();
    // A color picker edits a single channel through a read-modify-write.
    let mut emissive_value = emissive.get();
    emissive_value.r = 0.5;
    emissive.set(emissive_value);
    assert_eq!(
        adapter
            .scene()
            .component::<RenderMaterialComponent>(entity)
            .expect("material")
            .emissive_factor,
        Float3::new(0.5, 4.0, 8.0)
    );
    emissive.set(Color {
        r: 4.0,
        g: -1.0,
        b: 8.0,
        a: 0.5,
    });
    base.set(Color {
        r: -1.0,
        g: 0.3,
        b: 2.0,
        a: 5.0,
    });
    metallic.set(12.0);
    roughness.set(-2.0);
    adapter.end_interactive_edit_history_group();

    let mut expected = original.clone();
    expected.emissive_factor = Float3::new(4.0, 0.0, 8.0);
    expected.base_color_factor = Float4::new(0.0, 0.3, 1.0, 1.0);
    expected.metallic_factor = 1.0;
    expected.roughness_factor = 0.0;
    assert_eq!(
        adapter.scene().component::<RenderMaterialComponent>(entity),
        Some(expected)
    );

    let revision = adapter.revision();
    emissive.set(Color {
        r: f32::INFINITY,
        g: 0.0,
        b: 0.0,
        a: 1.0,
    });
    assert_eq!(adapter.revision(), revision);
    assert!(adapter.undo_edit());
    assert_eq!(
        adapter.scene().component::<RenderMaterialComponent>(entity),
        Some(original)
    );
    assert!(!adapter.can_undo_edit());
}

/// A missing clip is editable, clearing restores nil, and unrelated controls
/// preserve playback.
#[test]
fn playback_form() {
    let adapter = adapter();
    let id = make_entity(&adapter);
    let entity = EntityID::from_raw_value(id);
    adapter.with_scene_mut(|scene| {
        let _ = scene.set_component(AnimationPlayer::new(None, 1.0, true, true, 4.25), entity);
    });
    adapter.reset_edit_history();

    let form = section(&adapter, id, "animationPlayer");
    assert_eq!(form.id, "animation-player");
    let EditorInspectorFieldValue::Text(clip) = field(&form, "anim-clip") else {
        panic!("expected clip");
    };
    let EditorInspectorFieldValue::ConstrainedNumber { binding: speed, .. } =
        field(&form, "anim-speed")
    else {
        panic!("expected speed");
    };
    let EditorInspectorFieldValue::Bool(loop_) = field(&form, "anim-loop") else {
        panic!("expected loop");
    };
    let EditorInspectorFieldValue::Bool(playing) = field(&form, "anim-playing") else {
        panic!("expected playing");
    };
    assert!(matches!(
        field(&form, "time"),
        EditorInspectorFieldValue::ReadOnly(_)
    ));
    assert!(clip.get().is_empty());

    speed.set(2.0);
    loop_.set(false);
    playing.set(false);
    assert_eq!(
        adapter.scene().component::<AnimationPlayer>(entity),
        Some(AnimationPlayer::new(None, 2.0, false, false, 4.25))
    );
    clip.set("Run".to_string());
    assert_eq!(
        adapter
            .scene()
            .component::<AnimationPlayer>(entity)
            .expect("player")
            .time,
        0.0
    );
    adapter.with_scene_mut(|scene| {
        let _ = scene.update_component::<AnimationPlayer>(entity, |player| player.time = 3.5);
    });
    adapter.reset_edit_history();
    clip.set(String::new());
    let player = adapter
        .scene()
        .component::<AnimationPlayer>(entity)
        .expect("player");
    assert!(player.clip_name.is_none());
    assert_eq!(player.time, 0.0);
    assert!(
        adapter
            .scene()
            .component_data("animationPlayer", entity)
            .and_then(|value| value.value_at(&["clipName".to_string()]).cloned())
            .is_none()
    );

    assert!(adapter.undo_edit());
    let player = adapter
        .scene()
        .component::<AnimationPlayer>(entity)
        .expect("player");
    assert_eq!(player.clip_name.as_deref(), Some("Run"));
    assert_eq!(player.time, 3.5);
    assert!(adapter.redo_edit());
    assert!(clip.get().is_empty());

    adapter.set_authoring_enabled(false);
    let revision = adapter.revision();
    clip.set("Locked".to_string());
    assert_eq!(adapter.revision(), revision);
}

/// Clearing a mixed optional clip changes only non-empty members and undoes
/// as one group.
#[test]
fn mixed_optional_clips() {
    let adapter = adapter();
    let a = make_entity(&adapter);
    let b = make_entity(&adapter);
    let a_entity = EntityID::from_raw_value(a);
    let b_entity = EntityID::from_raw_value(b);
    adapter.with_scene_mut(|scene| {
        let _ = scene.set_component(AnimationPlayer::new(None, 1.0, true, true, 2.0), a_entity);
        let _ = scene.set_component(
            AnimationPlayer::new(Some("Walk".to_string()), 1.0, true, true, 5.0),
            b_entity,
        );
    });
    adapter.reset_edit_history();

    let selection = BTreeSet::from([a, b]);
    let form = adapter
        .inspector_sections_for_selection(&selection, Some(a))
        .into_iter()
        .find(|candidate| candidate.component_type_id.as_deref() == Some("animationPlayer"))
        .expect("playback form");
    let field = form
        .fields
        .iter()
        .find(|candidate| candidate.id == "anim-clip")
        .expect("clip field");
    assert!(field.is_mixed);
    let EditorInspectorFieldValue::Text(clip) = field.value.clone() else {
        panic!("expected optional clip");
    };

    clip.set(String::new());
    let first = adapter
        .scene()
        .component::<AnimationPlayer>(a_entity)
        .expect("player a");
    assert_eq!(first.time, 2.0);
    let second = adapter
        .scene()
        .component::<AnimationPlayer>(b_entity)
        .expect("player b");
    assert_eq!(second.time, 0.0);
    assert!(second.clip_name.is_none());

    assert!(adapter.undo_edit());
    let second = adapter
        .scene()
        .component::<AnimationPlayer>(b_entity)
        .expect("player b");
    assert_eq!(second.clip_name.as_deref(), Some("Walk"));
    assert_eq!(second.time, 5.0);
    assert!(!adapter.can_undo_edit());
}
