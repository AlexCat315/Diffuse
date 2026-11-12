//! Ported from `Editor/Tests/EditorCoreTests/ProjectFilePathTests.swift`.

use std::path::{Path, PathBuf};

use cove_system::paths::PathIdentity;

fn temporary_root(prefix: &str) -> PathBuf {
    let root =
        std::env::temp_dir().join(format!("{prefix}-{}", diffuse_kernel::codable::new_uuid()));
    std::fs::create_dir_all(&root).expect("temporary root");
    root
}

/// Creates a directory symlink; the Windows API needs permission that CI may
/// not grant, so a refusal skips the case instead of reporting a false failure.
fn try_symlink_dir(target: &Path, link: &Path) -> bool {
    #[cfg(unix)]
    {
        std::os::unix::fs::symlink(target, link).is_ok()
    }
    #[cfg(windows)]
    {
        std::os::windows::fs::symlink_dir(target, link).is_ok()
    }
}

fn try_symlink_file(target: &Path, link: &Path) -> bool {
    #[cfg(unix)]
    {
        std::os::unix::fs::symlink(target, link).is_ok()
    }
    #[cfg(windows)]
    {
        std::os::windows::fs::symlink_file(target, link).is_ok()
    }
}

/// New paths inherit their canonical parent without accepting prefix siblings.
#[test]
fn nonexistent_paths_inherit_the_canonical_parent() {
    let root = temporary_root("cove-path");
    let project = root.join("Project");
    std::fs::create_dir_all(&project).expect("project");
    let alias = root.join("Alias");
    if !try_symlink_dir(&project, &alias) {
        let _ = std::fs::remove_dir_all(&root);
        return;
    }
    let candidate = alias.join("Scripts").join("New.swift");
    assert!(PathIdentity::contains(&candidate, &project, false));
    assert!(PathIdentity::same_location(
        &candidate,
        &project.join("Scripts").join("New.swift")
    ));
    assert!(!PathIdentity::contains(
        &root.join("ProjectOther").join("New.swift"),
        &project,
        false
    ));
    let _ = std::fs::remove_dir_all(&root);
}

/// Dangling script symlinks cannot redirect a future write outside the project.
#[test]
fn dangling_script_symlink_is_rejected() {
    let root = temporary_root("cove-path");
    let project = root.join("Project");
    std::fs::create_dir_all(&project).expect("project");
    let link = project.join("Escape.swift");
    if !try_symlink_file(&root.join("Outside").join("Missing.swift"), &link) {
        let _ = std::fs::remove_dir_all(&root);
        return;
    }
    assert!(!PathIdentity::contains(&link, &project, false));
    let _ = std::fs::remove_dir_all(&root);
}
