//! Ported from
//! `Editor/Tests/EditorCoreTests/Scripting/ScriptProjectTrustStoreTests.swift`.

use std::collections::BTreeMap;
use std::path::PathBuf;

use crate::scripting::dynamic::script_project_trust::{
    ScriptProjectTrustState, ScriptProjectTrustStore,
};

/// Isolated editor state persists trust outside the project and keeps explicit
/// storage precedence.
#[test]
fn isolated_editor_state_persists_trust_outside_the_project() {
    let root: PathBuf = std::env::temp_dir().join(format!(
        "cove-trust-state-{}",
        diffuse_kernel::codable::new_uuid()
    ));
    let project = root.join("project");
    std::fs::create_dir_all(&project).expect("project directory");
    let state = root.join("state");
    let mut environment = BTreeMap::new();
    environment.insert(
        "COVE_EDITOR_STATE_DIRECTORY".to_string(),
        state.to_string_lossy().into_owned(),
    );
    let project_path = project.to_string_lossy().into_owned();

    let store = ScriptProjectTrustStore::with_environment(&environment);
    assert_eq!(
        store.state(&project_path),
        ScriptProjectTrustState::Untrusted
    );
    store
        .set_trusted(true, &project_path)
        .expect("persist trust");
    assert!(
        state.join("script-workspace-trust.json").is_file(),
        "trust file must live in the isolated state directory"
    );
    assert_eq!(
        std::fs::read_dir(&project)
            .expect("project directory")
            .count(),
        0,
        "trust must not write into the project"
    );
    assert_eq!(
        ScriptProjectTrustStore::with_environment(&environment).state(&project_path),
        ScriptProjectTrustState::Trusted
    );

    let explicit_url = root.join("explicit-trust.json");
    let separate = ScriptProjectTrustStore::with_storage_url(explicit_url.clone());
    assert_eq!(
        separate.state(&project_path),
        ScriptProjectTrustState::Untrusted
    );
    separate
        .set_trusted(true, &project_path)
        .expect("persist explicit trust");
    assert!(explicit_url.is_file());

    let _ = std::fs::remove_dir_all(&root);
}
