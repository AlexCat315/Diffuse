//! Rewritten from `Engine/Tests/EngineCoreTests/PackageResourceBundleTests.swift`.
//!
//! The Swift helper resolved package resource bundles itself. Rust uses Cove's
//! `ResourceBundle`, which owns the same `<name>.bundle` / `<name>.resources`
//! lookup, so the suite now verifies that contract directly.

use std::path::{Path, PathBuf};

use cove_platform::ResourceBundle;

fn temporary_root() -> PathBuf {
    let root = std::env::temp_dir().join(format!(
        "cove-package-resources-{}",
        diffuse_kernel::codable::new_uuid()
    ));
    std::fs::create_dir_all(&root).expect("create temporary root");
    root
}

fn make_bundle(name: &str, suffix: &str, root: &Path) -> PathBuf {
    let bundle = root.join(format!("{name}.{suffix}"));
    std::fs::create_dir_all(&bundle).expect("create bundle");
    std::fs::write(
        bundle.join("Info.plist"),
        format!(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\"><dict><key>CFBundleName</key><string>{name}</string></dict></plist>"
        ),
    )
    .expect("write plist");
    bundle
}

/// Locates resource bundles in an explicit application resources root.
#[test]
fn locates_application_resource_bundle() {
    let root = temporary_root();
    let resources = root.join("Contents").join("Resources");
    std::fs::create_dir_all(&resources).expect("create resources");
    let expected = make_bundle("Example", "bundle", &resources);

    let located =
        ResourceBundle::locate(&["Example"], std::slice::from_ref(&resources)).expect("located");

    assert_eq!(located.root(), expected.as_path());
    let _ = std::fs::remove_dir_all(&root);
}

/// Supports SwiftPM `resources` directories and reports missing bundles.
#[test]
fn locates_resources_directory() {
    let root = temporary_root();
    let expected = make_bundle("Example", "resources", &root);

    assert!(ResourceBundle::locate(&["Missing"], std::slice::from_ref(&root)).is_none());
    let located =
        ResourceBundle::locate(&["Example"], std::slice::from_ref(&root)).expect("located");
    assert_eq!(located.root(), expected.as_path());
    let _ = std::fs::remove_dir_all(&root);
}

/// Supports target bundles renamed by an aggregate package.
#[test]
fn locates_first_available_bundle_name() {
    let root = temporary_root();
    let expected = make_bundle("Workspace_EditorApp", "bundle", &root);

    let located = ResourceBundle::locate(
        &["Standalone_EditorApp", "Workspace_EditorApp"],
        std::slice::from_ref(&root),
    )
    .expect("located");

    assert_eq!(located.root(), expected.as_path());
    let _ = std::fs::remove_dir_all(&root);
}
