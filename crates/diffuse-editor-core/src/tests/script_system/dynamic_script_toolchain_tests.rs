//! `Editor/Tests/ScriptSystemTests/DynamicScriptToolchainTests.swift`.
//!
//! D1 rewrite: the host compiler is `rustc` (selected through `COVE_RUSTC_PATH`)
//! instead of Apple's `swiftc` (`COVE_SWIFTC_PATH`). The selection semantics are
//! unchanged: an explicit host override always wins, then the environment
//! variable, then the default lookup; blank values are ignored so a stray
//! whitespace-only setting never masks the default.

use std::collections::BTreeMap;

use crate::scripting::dynamic::dynamic_script_manager::DynamicScriptManager;

#[test]
fn compiler_selection() {
    assert_eq!(
        DynamicScriptManager::resolved_compiler_path(None, &BTreeMap::new()),
        "rustc",
        "an empty environment keeps the default compiler lookup"
    );

    let environment = BTreeMap::from([(
        "COVE_RUSTC_PATH".to_string(),
        "/host/toolchain/rustc".to_string(),
    )]);
    assert_eq!(
        DynamicScriptManager::resolved_compiler_path(None, &environment),
        "/host/toolchain/rustc",
        "the host override environment variable selects the compiler"
    );
    assert_eq!(
        DynamicScriptManager::resolved_compiler_path(Some("/explicit/rustc"), &environment),
        "/explicit/rustc",
        "an explicit override wins over the environment variable"
    );

    let blank = BTreeMap::from([("COVE_RUSTC_PATH".to_string(), "  ".to_string())]);
    assert_eq!(
        DynamicScriptManager::resolved_compiler_path(None, &blank),
        "rustc",
        "a blank environment value does not mask the default lookup"
    );
}
