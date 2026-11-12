//! Ported from `Editor/Tests/EditorAppTests/ProjectListTests.swift`.

use cove_ui_compose::app_storage::MemoryAppStorageStore;

use crate::projects::project_list::EditorProjectList;

/// Paths are normalized and deduplicated, and the front project must be one of
/// them.
#[test]
fn saved_projects_are_normalized_and_deduplicated() {
    let domain = format!(
        "CoveProjectListTests.{}",
        diffuse_kernel::codable::new_uuid()
    );
    let parent = std::env::temp_dir().join(&domain);
    std::fs::create_dir_all(&parent).expect("temporary parent");
    let parent_path = parent.to_string_lossy().into_owned();
    let child_round_trip = parent
        .join("child")
        .join("..")
        .to_string_lossy()
        .into_owned();
    let store = MemoryAppStorageStore::new();

    let canonical = EditorProjectList::canonical_path(&parent_path);
    EditorProjectList {
        paths: vec![parent_path.clone(), child_round_trip, String::new()],
        active: Some(parent_path.clone()),
    }
    .save_to(&store);
    let loaded = EditorProjectList::load_from(&store);
    assert_eq!(loaded.paths, vec![canonical.clone()]);
    assert_eq!(loaded.active, Some(canonical.clone()));

    EditorProjectList {
        paths: Vec::new(),
        active: Some(parent_path.clone()),
    }
    .save_to(&store);
    assert_eq!(EditorProjectList::load_from(&store).active, None);

    EditorProjectList {
        paths: vec![parent_path.clone()],
        active: None,
    }
    .save_to(&store);
    assert_eq!(
        EditorProjectList::load_from(&store),
        EditorProjectList {
            paths: vec![canonical],
            active: None,
        }
    );
    assert!(parent.is_dir());

    let _ = std::fs::remove_dir_all(&parent);
}
