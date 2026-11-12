//! Ported from `Editor/Tests/EditorCoreTests/ProjectRuntimeResourcesTests.swift`.

use std::path::PathBuf;

use cove_system::paths::PathIdentity;

use crate::assets::project_runtime_resources::ProjectRuntimeResources;

/// Audio discovery ignores build directory case variants.
#[test]
fn audio_discovery_ignores_build_directories() {
    let root: PathBuf = std::env::temp_dir().join(format!(
        "cove-runtime-resources-{}",
        diffuse_kernel::codable::new_uuid()
    ));
    let audio = root.join("Assets").join("Audio");
    let generated = root.join("Build").join("Audio");
    std::fs::create_dir_all(&audio).expect("audio directory");
    std::fs::create_dir_all(&generated).expect("build audio directory");
    std::fs::write(audio.join("theme.wav"), [1_u8]).expect("audio clip");
    std::fs::write(generated.join("stale.wav"), [2_u8]).expect("stale clip");

    let dirs = ProjectRuntimeResources::discover_audio_search_paths(&root.to_string_lossy());
    assert!(
        dirs.iter()
            .any(|dir| PathIdentity::same_location(dir, &root))
    );
    assert!(
        dirs.iter()
            .any(|dir| PathIdentity::same_location(dir, &audio))
    );
    assert!(
        !dirs
            .iter()
            .any(|dir| PathIdentity::same_location(dir, &generated))
    );

    let _ = std::fs::remove_dir_all(&root);
}
