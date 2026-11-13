//! Ported from `Editor/Tests/EditorCoreTests/Scripting/DynamicScriptManagerTests.swift`.

use std::path::PathBuf;

use diffuse_script::ScriptRuntime;

use crate::scripting::dynamic::dynamic_script_manager::{
    DynamicScriptManager, DynamicScriptManagerError, ScriptFileError,
};

fn temporary_root() -> PathBuf {
    std::env::temp_dir().join(format!(
        "diffuse-dynamic-script-manager-{}",
        diffuse_kernel::codable::new_uuid()
    ))
}

/// Creating a duplicate script never overwrites its source.
#[test]
fn duplicate_creation_does_not_overwrite() {
    let root = temporary_root();
    let manager = DynamicScriptManager::new(&root.to_string_lossy(), ScriptRuntime::new(), Vec::new());

    let url = manager
        .create_script("Player Controller", "first")
        .expect("creating the first script succeeds");
    assert_eq!(
        manager.read_source(&url).expect("reading source"),
        "first"
    );
    let error = manager
        .create_script("Player Controller", "second")
        .expect_err("a duplicate name must be rejected");
    assert!(matches!(
        error,
        DynamicScriptManagerError::ScriptFile(ScriptFileError::AlreadyExists(name))
            if name == "Player Controller"
    ));
    assert_eq!(
        manager.read_source(&url).expect("source is unchanged"),
        "first"
    );

    let _ = std::fs::remove_dir_all(&root);
}

/// Script names cannot escape the Scripts directory.
#[test]
fn rejects_path_separators_in_script_names() {
    let root = temporary_root();
    let manager = DynamicScriptManager::new(&root.to_string_lossy(), ScriptRuntime::new(), Vec::new());

    let error = manager
        .create_script("../Outside", "")
        .expect_err("a name with a path separator must be rejected");
    assert!(matches!(
        error,
        DynamicScriptManagerError::ScriptFile(ScriptFileError::InvalidName(name))
            if name == "../Outside"
    ));

    let _ = std::fs::remove_dir_all(&root);
}
