//! Ported from `Editor/Tests/EditorAppTests/EditorAppResourceBundleTests.swift`.

use cove_platform::ResourceBundle;

use crate::resources_support::EditorAppResourceBundle;

/// Toolbar icons resolve through the packaged resource locator.
#[test]
fn toolbar_icon_resolves_through_packaged_locator() {
    let Some(bundle) = ResourceBundle::beside_executable(&[
        "DiffuseEditor_EditorUI",
        "DiffuseEditor_EditorUI.resources",
    ])
    .ok()
    .flatten() else {
        // Swift runs this in the packaged app; a development checkout has no
        // EditorUI bundle to resolve against.
        return;
    };
    let _ = EditorAppResourceBundle::bundle();
    assert!(bundle.root().join("ai-intent.svg").is_file());
}
