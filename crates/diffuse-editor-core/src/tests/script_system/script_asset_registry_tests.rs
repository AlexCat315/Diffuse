//! Ported from `Editor/Tests/ScriptSystemTests/ScriptAssetRegistryTests.swift`.

use std::path::{Path, PathBuf};

use crate::scripting::assets::script_asset_registry::ScriptAssetRegistry;
use crate::scripting::dynamic::script_project_trust::{
    ScriptProjectTrustState, ScriptProjectTrustStore,
};

fn temporary_root(prefix: &str) -> PathBuf {
    std::env::temp_dir().join(format!("{prefix}-{}", diffuse_kernel::codable::new_uuid()))
}

fn remove_temporary_root(url: &Path) {
    let _ = std::fs::remove_dir_all(url);
}

fn resolved_first(
    registry: &ScriptAssetRegistry,
    url: PathBuf,
) -> crate::scripting::assets::script_asset_registry::ResolvedScriptAsset {
    registry
        .resolve(vec![url])
        .expect("scan script files")
        .into_iter()
        .next()
        .expect("resolved script asset")
}

/// Renaming a source file preserves its asset identity and accumulates both
/// the old and the new legacy identifiers.
#[test]
fn rename_preserves_identity() {
    let project = temporary_root("cove-script-assets");
    let scripts = project.join("Scripts");
    std::fs::create_dir_all(&scripts).expect("scripts directory");
    let source = "import ScriptRuntime\nstruct GameScript: ScriptBehavior {}\n";
    let original_url = scripts.join("Player.swift");
    std::fs::write(&original_url, source).expect("write script");

    let registry = ScriptAssetRegistry::new(&project.to_string_lossy());
    let original = resolved_first(&registry, original_url.clone());
    let renamed_url = scripts.join("Runner.swift");
    std::fs::rename(&original_url, &renamed_url).expect("rename script");
    let renamed = resolved_first(&registry, renamed_url);

    assert_eq!(renamed.id, original.id);
    assert_eq!(
        renamed.id.runtime_identifier(),
        original.id.runtime_identifier()
    );
    assert!(
        renamed
            .legacy_identifiers
            .iter()
            .any(|identifier| identifier == "scripts.player")
    );
    assert!(
        renamed
            .legacy_identifiers
            .iter()
            .any(|identifier| identifier == "scripts.runner")
    );

    remove_temporary_root(&project);
}

/// Workspace trust is fail-closed, explicit and persisted outside the project.
#[test]
fn workspace_trust_is_fail_closed_and_stored_outside_project_state() {
    let project = temporary_root("cove-script-trust-project");
    std::fs::create_dir_all(&project).expect("project directory");
    let user_store = std::env::temp_dir().join(format!(
        "cove-script-trust-user-{}.json",
        diffuse_kernel::codable::new_uuid()
    ));
    let project_directory = project.to_string_lossy().into_owned();

    let first = ScriptProjectTrustStore::with_storage_url(user_store.clone());
    assert_eq!(
        first.state(&project_directory),
        ScriptProjectTrustState::Untrusted
    );

    first
        .set_trusted(true, &project_directory)
        .expect("store trust");
    let reopened = ScriptProjectTrustStore::with_storage_url(user_store.clone());
    assert_eq!(
        reopened.state(&project_directory),
        ScriptProjectTrustState::Trusted
    );

    reopened
        .set_trusted(false, &project_directory)
        .expect("revoke trust");
    assert_eq!(
        reopened.state(&project_directory),
        ScriptProjectTrustState::Untrusted
    );

    remove_temporary_root(&project);
    let _ = std::fs::remove_file(&user_store);
}
