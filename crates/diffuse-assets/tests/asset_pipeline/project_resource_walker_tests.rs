//! Ported from `Engine/Tests/AssetPipelineTests/ProjectResourceWalkerTests.swift`.

use diffuse_assets::project_resource_walker::files;

fn temp_root(tag: &str) -> std::path::PathBuf {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or(0);
    let root = std::env::temp_dir().join(format!("cove-walk-{tag}-{nanos}"));
    std::fs::create_dir_all(&root).unwrap();
    root
}

fn write(root: &std::path::Path, relative: &str, byte: u8) {
    let path = root.join(relative);
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, [byte]).unwrap();
}

fn names(paths: &[std::path::PathBuf]) -> Vec<String> {
    let mut values: Vec<String> = paths
        .iter()
        .map(|path| {
            path.file_name()
                .map(|name| name.to_string_lossy().into_owned())
                .unwrap_or_default()
        })
        .collect();
    values.sort();
    values
}

// Pruning generated folders preserves every unrelated nested resource.
#[test]
fn sibling_directories() {
    let root = temp_root("siblings");
    for path in [
        "Build/Generated/ignored.png",
        "Assets/Audio/theme.wav",
        "Textures/kept.png",
    ] {
        write(&root, path, 1);
    }
    let found = files(&root, false, |path| {
        path.file_name()
            .map(|name| name.to_string_lossy().to_lowercase() == "build")
            .unwrap_or(false)
    })
    .unwrap();
    assert_eq!(names(&found), vec!["kept.png", "theme.wav"]);
    let _ = std::fs::remove_dir_all(&root);
}

// Directory symlinks do not import resources outside the project or form cycles.
#[test]
fn symlink_boundary() {
    let root = temp_root("symlink");
    let project = root.join("Project");
    let outside = root.join("Outside");
    std::fs::create_dir_all(&project).unwrap();
    std::fs::create_dir_all(&outside).unwrap();
    write(&project, "kept.png", 1);
    write(&outside, "private.png", 2);
    #[cfg(unix)]
    {
        std::os::unix::fs::symlink(&outside, project.join("Alias")).unwrap();
        std::os::unix::fs::symlink(&project, project.join("Loop")).unwrap();
    }
    let found = files(&project, false, |_| false).unwrap();
    assert_eq!(names(&found), vec!["kept.png"]);
    let _ = std::fs::remove_dir_all(&root);
}

// Hidden entries are skipped before any other classification.
#[test]
fn hidden_entries_are_skipped() {
    let root = temp_root("hidden");
    write(&root, "visible.png", 1);
    write(&root, ".hidden.png", 2);
    write(&root, ".git/config", 3);
    let found = files(&root, false, |_| false).unwrap();
    assert_eq!(names(&found), vec!["visible.png"]);
    let _ = std::fs::remove_dir_all(&root);
}

// A missing root aborts unless the caller opts into continuing.
#[test]
fn missing_root_reports_error_unless_continuing() {
    let root = std::env::temp_dir().join("cove-walk-does-not-exist");
    assert!(files(&root, false, |_| false).is_err());
    assert!(files(&root, true, |_| false).unwrap().is_empty());
}
