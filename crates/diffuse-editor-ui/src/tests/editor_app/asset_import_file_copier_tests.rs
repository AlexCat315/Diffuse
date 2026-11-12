//! Ported from `Editor/Tests/EditorAppTests/AssetImportFileCopierTests.swift`.

use std::path::{Path, PathBuf};

use crate::panels::asset_browser::asset_import_file_copier::AssetImportFileCopier;

fn temporary_directory(prefix: &str) -> PathBuf {
    let directory =
        std::env::temp_dir().join(format!("{prefix}-{}", diffuse_kernel::codable::new_uuid()));
    std::fs::create_dir_all(&directory).expect("temporary directory");
    directory
}

fn write(path: &Path, bytes: &[u8]) {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).expect("parent directory");
    }
    std::fs::write(path, bytes).expect("destination file");
}

/// Re-import replaces an existing asset only after staging succeeds.
#[test]
fn reimport_replaces_existing_asset() {
    let directory = temporary_directory("cove-asset-reimport");
    let source = directory.join("source").join("model.glb");
    let destination = directory.join("project").join("model.glb");
    write(&source, b"new asset");
    write(&destination, b"old asset");

    AssetImportFileCopier::copy_replacing(&source, &destination).expect("replace asset");

    assert_eq!(
        std::fs::read(&destination).expect("new asset"),
        b"new asset"
    );
    let siblings =
        std::fs::read_dir(destination.parent().expect("destination parent")).expect("siblings");
    assert!(
        !siblings
            .flatten()
            .any(|entry| { entry.file_name().to_string_lossy().contains(".import-") })
    );

    let _ = std::fs::remove_dir_all(&directory);
}

/// A failed re-import preserves the existing asset.
#[test]
fn failed_reimport_preserves_existing_asset() {
    let directory = temporary_directory("cove-asset-reimport-failure");
    let missing_source = directory.join("missing").join("model.glb");
    let destination = directory.join("project").join("model.glb");
    let original = b"last known good asset";
    write(&destination, original);

    assert!(AssetImportFileCopier::copy_replacing(&missing_source, &destination).is_err());
    assert_eq!(
        std::fs::read(&destination).expect("original asset"),
        original
    );

    let _ = std::fs::remove_dir_all(&directory);
}

/// First import creates nested destination directories.
#[test]
fn first_import_creates_nested_destination() {
    let directory = temporary_directory("cove-asset-first-import");
    let source = directory.join("source.png");
    let destination = directory
        .join("project")
        .join("textures")
        .join("ui")
        .join("source.png");
    std::fs::write(&source, [0_u8, 1, 2, 3]).expect("source file");

    AssetImportFileCopier::copy_replacing(&source, &destination).expect("first import");
    assert_eq!(
        std::fs::read(&destination).expect("imported file"),
        [0_u8, 1, 2, 3]
    );

    let _ = std::fs::remove_dir_all(&directory);
}
