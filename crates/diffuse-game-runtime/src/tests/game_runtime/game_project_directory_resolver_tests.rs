//! Ported from `Editor/Tests/GameRuntimeTests/GameProjectDirectoryResolverTests.swift`.

use std::collections::BTreeMap;
use std::path::Path;

use crate::game_project_directory_resolver::GameProjectDirectoryResolver;

fn temporary_root(prefix: &str) -> std::path::PathBuf {
    let root =
        std::env::temp_dir().join(format!("{prefix}-{}", diffuse_kernel::codable::new_uuid()));
    std::fs::create_dir_all(&root).expect("temporary root");
    root
}

/// A portable Player directory resolves its parent export.
#[test]
fn resolves_portable_player_parent() {
    let root = temporary_root("cove-player-resolver");
    let player_directory = root.join("Player");
    std::fs::create_dir_all(&player_directory).expect("player directory");
    std::fs::write(root.join("build.json"), b"{}").expect("build descriptor");

    let resolved = GameProjectDirectoryResolver::resolve(
        &["CovePlayer".to_string()],
        &BTreeMap::new(),
        None,
        Some(&player_directory.join("CovePlayer")),
        &std::env::temp_dir(),
    );

    assert_eq!(resolved.as_deref(), root.to_str());
    let _ = std::fs::remove_dir_all(&root);
}

/// Explicit project arguments take priority over discovered layouts.
#[test]
fn explicit_project_takes_priority() {
    let mut environment = BTreeMap::new();
    environment.insert(
        "COVE_PROJECT_DIR".to_string(),
        "/environment/project".to_string(),
    );
    let resolved = GameProjectDirectoryResolver::resolve(
        &[
            "CovePlayer".to_string(),
            "--project".to_string(),
            "/explicit/project".to_string(),
        ],
        &environment,
        Some(Path::new("/bundle")),
        Some(Path::new("/export/Player/CovePlayer")),
        Path::new("/working"),
    );

    assert_eq!(resolved.as_deref(), Some("/explicit/project"));
}

/// argv zero discovers a portable export when no executable URL is supplied.
#[test]
fn resolves_portable_parent_from_argument_zero() {
    let root = temporary_root("cove-player-argv0");
    let player = root.join("Player").join("CovePlayer");
    std::fs::create_dir_all(player.parent().expect("player directory")).expect("player directory");
    std::fs::write(root.join("build.json"), b"{}").expect("build descriptor");

    let resolved = GameProjectDirectoryResolver::resolve(
        &[player.to_string_lossy().into_owned()],
        &BTreeMap::new(),
        None,
        None,
        &std::env::temp_dir(),
    );

    assert_eq!(resolved.as_deref(), root.to_str());
    let _ = std::fs::remove_dir_all(&root);
}
