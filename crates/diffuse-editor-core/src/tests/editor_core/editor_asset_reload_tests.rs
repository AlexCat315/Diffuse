//! `Editor/Tests/EditorCoreTests/EditorAssetReloadTests.swift`.

use std::path::PathBuf;

use crate::application::editor_application::{EditorApplication, EditorApplicationOptions};

fn temporary_project(label: &str) -> PathBuf {
    let directory = std::env::temp_dir().join(format!(
        "cove-asset-reload-{}-{label}",
        diffuse_kernel::codable::new_uuid()
    ));
    std::fs::create_dir_all(&directory).expect("create temporary project");
    directory
}

#[test]
fn reload_invalidates_ui() {
    let project = temporary_project("ui");
    let application = EditorApplication::with_options(
        project.to_string_lossy().into_owned(),
        EditorApplicationOptions {
            seed_preview_scene: true,
            ..EditorApplicationOptions::default()
        },
    )
    .expect("launch editor");
    let before = application.store.ui_refresh_revision();

    assert_eq!(application.reload_assets(), Some(0));
    assert!(application.store.ui_refresh_revision() > before);

    application.shutdown();
    let _ = std::fs::remove_dir_all(&project);
}
