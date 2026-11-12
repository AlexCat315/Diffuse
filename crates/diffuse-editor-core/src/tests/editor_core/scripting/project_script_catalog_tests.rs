//! Ported from `Editor/Tests/EditorCoreTests/Scripting/ProjectScriptCatalogTests.swift`.

use std::path::{Path, PathBuf};

use diffuse_scene::components::core::registry::ComponentRegistry;
use diffuse_scene::input_action::{InputActionMap, InputBinding};
use diffuse_script::ScriptPresetKind;
use diffuse_script::core::script_component::{ScriptBinding, ScriptBindingID, ScriptComponent};

use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
use crate::scene::inspector::rendering::renderers::EditorInspectorRendererRegistry;
use crate::scripting::dynamic::project_script_catalog::{
    ProjectScriptCatalog, ProjectScriptCatalogDiagnosticSeverity, ProjectScriptCatalogMonitor,
};

fn adapter(seed_preview_scene: bool) -> EditorSceneAdapter {
    EditorSceneAdapter::new(
        seed_preview_scene,
        ComponentRegistry::built_in(),
        EditorInspectorRendererRegistry::built_in(),
    )
}

fn temporary_directory() -> PathBuf {
    let root = std::env::temp_dir().join(format!(
        "cove-script-catalog-{}",
        diffuse_kernel::codable::new_uuid()
    ));
    std::fs::create_dir_all(&root).expect("temporary directory");
    root
}

fn write_catalog(root: &Path, json: &str) {
    let url = root.join(ProjectScriptCatalog::RELATIVE_PATH);
    std::fs::create_dir_all(url.parent().expect("catalog parent")).expect("catalog directory");
    std::fs::write(url, json).expect("catalog file");
}

/// Missing project catalog still exposes runnable built-in scripts.
#[test]
fn built_ins_without_manifest() {
    let root = temporary_directory();
    let catalog = ProjectScriptCatalog::load(&root).expect("catalog");

    assert!(catalog.source_url.is_none());
    assert_eq!(catalog.entries.len(), ScriptPresetKind::ALL.len());
    assert!(
        catalog
            .entries
            .iter()
            .any(|entry| entry.identifier == "cove.rotator")
    );
    std::fs::remove_dir_all(&root).ok();
}

/// Valid aliases load while invalid entries produce actionable diagnostics.
#[test]
fn partial_catalog_validation() {
    let root = temporary_directory();
    write_catalog(
        &root,
        r#"{"schemaVersion":1,"scripts":[{"id":"project.spin","displayName":"Spin","preset":"rotator","defaultParameters":{"speed":[0,3,0]}},{"id":"bad id","preset":"mover"},{"id":"project.unknown","preset":"not-real"},{"id":"project.spin","preset":"mover"}]}"#,
    );

    let catalog = ProjectScriptCatalog::load(&root).expect("catalog");
    let custom = catalog
        .entries
        .iter()
        .find(|entry| entry.identifier == "project.spin")
        .expect("project script");
    assert_eq!(custom.display_name, "Spin");
    assert!(custom.default_parameters_json.contains("\"speed\""));
    assert_eq!(catalog.diagnostics.len(), 3);
    assert!(
        catalog
            .diagnostics
            .iter()
            .all(|diagnostic| diagnostic.severity == ProjectScriptCatalogDiagnosticSeverity::Error)
    );
    std::fs::remove_dir_all(&root).ok();
}

/// Monitor notices same-size content replacements and suppresses unchanged
/// polls.
#[test]
fn monitor_content_signature() {
    let root = temporary_directory();
    let monitor = ProjectScriptCatalogMonitor::new(root.display().to_string());
    write_catalog(
        &root,
        r#"{"schemaVersion":1,"scripts":[{"id":"project.one","preset":"mover"}]}"#,
    );

    assert!(
        monitor
            .load_if_changed_with_default()
            .expect("first poll")
            .is_some()
    );
    assert!(
        monitor
            .load_if_changed_with_default()
            .expect("unchanged poll")
            .is_none()
    );
    write_catalog(
        &root,
        r#"{"schemaVersion":1,"scripts":[{"id":"project.two","preset":"mover"}]}"#,
    );
    let reloaded = monitor
        .load_if_changed_with_default()
        .expect("content replacement")
        .expect("reloaded catalog");
    assert!(
        reloaded
            .entries
            .iter()
            .any(|entry| entry.identifier == "project.two")
    );
    std::fs::remove_dir_all(&root).ok();
}

/// Adapter runs named bindings and reports missing identifiers.
#[test]
fn adapter_catalog_application() {
    let adapter = adapter(true);
    let _ = adapter.apply_project_script_catalog(&ProjectScriptCatalog::built_in());
    let entity = adapter.scene().roots().first().copied().expect("root");

    adapter.with_scene_mut(|scene| {
        scene.set_component(
            ScriptComponent::new(vec![
                ScriptBinding::from_identifier(
                    "cove.rotator",
                    ScriptBindingID::new(),
                    true,
                    r#"{"speed":[0,1,0]}"#,
                ),
                ScriptBinding::from_identifier(
                    "project.missing",
                    ScriptBindingID::new(),
                    true,
                    "{}",
                ),
            ]),
            entity,
        )
    });

    let report = adapter.apply_project_script_catalog(&ProjectScriptCatalog::built_in());
    let before = adapter
        .scene()
        .local_transform(entity)
        .expect("transform")
        .rotation();
    let _ = adapter.tick_scene(0.5, 0, Vec::new(), false);
    let after = adapter
        .scene()
        .local_transform(entity)
        .expect("transform")
        .rotation();

    assert_eq!(report.unresolved_bindings.len(), 1);
    assert!(report.unresolved_bindings[0].contains("project.missing"));
    assert!(before != after);
}

/// Stable script identifiers survive scene JSON round trips.
#[test]
fn manifest_round_trip() {
    let source = adapter(true);
    let _ = source.apply_project_script_catalog(&ProjectScriptCatalog::built_in());
    let entity = source.scene().roots().first().copied().expect("root");
    let binding_id = ScriptBindingID::new();
    source.with_scene_mut(|scene| {
        scene.set_component(
            ScriptComponent::new(vec![ScriptBinding::from_identifier(
                "cove.mover",
                binding_id.clone(),
                true,
                r#"{"velocity":[2,0,0]}"#,
            )]),
            entity,
        )
    });

    let manifest = source.manifest();
    let data = serde_json::to_vec(&manifest).expect("encode manifest");
    let decoded: crate::scene::manifest::editor_scene_manifest::EditorSceneManifest =
        serde_json::from_slice(&data).expect("decode manifest");

    let restored = adapter(true);
    let _ = restored.apply_project_script_catalog(&ProjectScriptCatalog::built_in());
    let _ = restored.load_with_notify(&decoded, false);
    let restored_entity = restored.scene().roots().first().copied().expect("root");

    let binding = restored
        .scene()
        .component::<ScriptComponent>(restored_entity)
        .expect("script component")
        .bindings
        .first()
        .cloned()
        .expect("binding");
    assert_eq!(binding.identifier.as_deref(), Some("cove.mover"));
    assert_eq!(binding.id, binding_id);
    let input = restored
        .scene()
        .resource::<InputActionMap>()
        .expect("input action map");
    assert!(
        input
            .bindings
            .get("jump")
            .is_some_and(|bindings| bindings.contains(&InputBinding::Key(44)))
    );

    let before = restored
        .scene()
        .local_transform(restored_entity)
        .expect("transform")
        .translation()
        .x;
    let _ = restored.tick_scene(0.5, 0, Vec::new(), false);
    let after = restored
        .scene()
        .local_transform(restored_entity)
        .expect("transform")
        .translation()
        .x;
    assert_eq!(after, before + 1.0);
}
