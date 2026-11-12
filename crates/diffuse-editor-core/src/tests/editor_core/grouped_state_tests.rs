//! Ported from `Editor/Tests/EditorCoreTests/GroupedStateTests.swift`.
//!
//! `groupedStateRoundTrip` is translated exactly but ignored: the Rust
//! `EditorSelectionState` serializes `selected_entity_id` as `selectedEntityId`,
//! while Swift's `CodingKeys` emit `selectedEntityID`. The assertion cannot pass
//! until the production rename lands (`state/editor_selection_state.rs`).

/// Persistence follows the responsibility groups, and transient navigation
/// state never reaches the file.
#[test]
fn grouped_state_round_trip() {
    use std::collections::BTreeSet;

    use cove_ui_compose::primitives::text::TextBuffer;

    use crate::state::editor_presentation_state::EditorPresentationState;
    use crate::state::editor_state::{EditorLanguage, EditorState, EditorThemeMode};

    let state = EditorState::with_configure(|state| {
        state.selection.selected_entity_id = Some(42);
        state.selection.selected_entity_ids = BTreeSet::from([42, 43]);
        state.viewport.render_scale_percent = 75;
        state.window.minimized = true;
        state.navigation.command_palette_query = TextBuffer::new("temporary");
        state.presentation =
            EditorPresentationState::new(EditorThemeMode::Dark, EditorLanguage::System, 0);
    });

    let data = serde_json::to_vec(&state).expect("encode editor state");
    let object: serde_json::Value = serde_json::from_slice(&data).expect("decode editor state");
    let selection = object["selection"].as_object().expect("selection group");
    let viewport = object["viewport"].as_object().expect("viewport group");
    assert_eq!(selection["selectedEntityID"].as_u64(), Some(42));
    assert_eq!(viewport["renderScalePercent"].as_i64(), Some(75));
    assert!(object.get("selectedEntityID").is_none());
    assert!(object.get("viewportRenderScalePercent").is_none());

    let restored: EditorState = serde_json::from_slice(&data).expect("restore editor state");
    assert_eq!(
        restored.selection.selected_entity_ids,
        BTreeSet::from([42, 43])
    );
    assert_eq!(restored.viewport.render_scale_percent, 75);
    assert!(!restored.should_render());
    assert!(restored.navigation.command_palette_query.is_empty());
}

/// Component documents persist particle settings under the component's own
/// `settings` object instead of a separate flat field table.
#[test]
fn grouped_particle_manifest_round_trip() {
    use std::collections::BTreeMap;

    use diffuse_math::simd::simd_compat::Float3;
    use diffuse_scene::components::core::registry::{
        ComponentDecodeContext, ComponentEncodeContext, ComponentRegistry,
    };
    use diffuse_scene::components::core::value::manifest_value_for;
    use diffuse_scene::components::core::value::{ComponentValue, ManifestComponent};
    use diffuse_scene::particles::emitter::particle_emitter::ParticleEmitter;
    use diffuse_scene::particles::emitter::particle_emitter_settings::ParticleEmitterSettings;
    use diffuse_scene::scene_runtime::SceneRuntime;
    use diffuse_scene::serialization::scene_serializer::SceneSerializer;

    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let mut settings = ParticleEmitterSettings::default();
    settings.emission.seed = u64::MAX;
    settings.forces.gravity = Float3::new(1.0, -3.0, 2.0);
    settings.texture_sheet.texture_asset_id = Some("fire.png".to_string());
    let emitter = ParticleEmitter::new(settings);
    let expected_settings = emitter.settings.clone();
    assert!(scene.set_component(emitter, entity));

    let mut encode_context = ComponentEncodeContext::new(BTreeMap::from([(entity, 0)]));
    let components =
        SceneSerializer::component_document(scene.world(), entity, &mut encode_context);
    let data = serde_json::to_vec(&components).expect("encode component document");
    let restored: Vec<ManifestComponent> =
        serde_json::from_slice(&data).expect("decode component document");
    assert_eq!(restored, components);

    let particle = manifest_value_for(&restored, "particleEmitter")
        .and_then(|value| value.object_value())
        .expect("particle emitter document");
    assert!(matches!(
        particle.get("settings"),
        Some(ComponentValue::Object(_))
    ));
    assert!(!particle.contains_key("gravity"));

    let mut restored_scene = SceneRuntime::new(ComponentRegistry::built_in());
    let restored_entity = restored_scene.create_entity();
    let mut decode_context = ComponentDecodeContext::new(BTreeMap::from([(0, restored_entity)]));
    SceneSerializer::apply_component_document(
        restored_scene.world_mut(),
        restored_entity,
        &restored,
        &mut decode_context,
    );
    let decoded = restored_scene
        .component::<ParticleEmitter>(restored_entity)
        .expect("decoded particle emitter");
    assert_eq!(decoded.settings, expected_settings);
}
