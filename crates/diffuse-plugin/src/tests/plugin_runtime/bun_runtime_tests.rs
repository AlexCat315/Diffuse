//! Ported from `Engine/Tests/PluginRuntimeTests/BunRuntimeTests.swift`.
//!
//! Both tests need prerequisites that are not always present, exactly as in
//! Swift: the first needs a Bun-buildable package (pure decoding, so it always
//! runs), the second needs a packaged `DiffusePluginHost` **and** the real
//! `AI.coveplugin` package. The second returns early when the executable is
//! absent — that is a skip, not a pass.

use std::path::PathBuf;

use diffuse_capability::capability_registry::CapabilityRegistry;
use diffuse_capability::capsule_schema::JsonSchemaValidator;

use crate::contract::bun_plugin_contract::BunPluginContract;

/// The repository root, three levels above this crate, as Swift's `#filePath`
/// reached it through `Engine/Tests/PluginRuntimeTests`.
fn repository() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
}

// @Test("the public Bun contract supplies strict input schemas without executing code")
#[test]
fn contract() {
    let contract = BunPluginContract::decode(
        br#"{"version":1,"entries":[{"name":"inspect","title":"Inspect","description":"","input":{"record":{"enabled":"bool","name":"string"}}}]}"#,
        &[],
    )
    .expect("contract decodes");
    let schema = contract
        .capability_inputs
        .first()
        .expect("one capability")
        .input_schema
        .clone();
    let valid: serde_json::Value =
        serde_json::from_slice(r#"{"enabled":true,"name":"你好"}"#.as_bytes()).expect("json");
    JsonSchemaValidator::validate(&valid, &schema).expect("valid input accepted");
    for invalid in [
        r#"{"enabled":1,"name":"x"}"#,
        r#"{"enabled":true,"name":"x","extra":1}"#,
    ] {
        let value: serde_json::Value = serde_json::from_slice(invalid.as_bytes()).expect("json");
        assert!(
            JsonSchemaValidator::validate(&value, &schema).is_err(),
            "{invalid} must be rejected"
        );
    }
    // The registry is only needed by the host, but the Swift test built a
    // contract without one; asserting the import list keeps that visible.
    assert!(contract.imports.is_empty());
    let _ = CapabilityRegistry::default_registry();
}

// @Test("the packaged native broker executes the actual AI plugin and serves host calls")
// Environment-dependent: needs `Editor/.build/**/DiffusePluginHost` and the
// packaged `AI.coveplugin`; returns early (a skip) when either is absent.
#[cfg(any(target_os = "macos", target_os = "linux", target_os = "windows"))]
#[test]
fn packaged_broker() {
    let repository = repository();
    let executable = if cfg!(target_os = "macos") {
        repository.join("Editor/.build/mac/debug/EditorApp.app/Contents/Helpers/DiffusePluginHost")
    } else if cfg!(target_os = "windows") {
        repository.join("Editor/.build/debug/DiffusePluginHost.exe")
    } else {
        repository.join("Editor/.build/debug/DiffusePluginHost")
    };
    let package = repository.join("Editor/Sources/EditorCore/Resources/Plugins/AI.coveplugin");
    if !executable.is_file() || !package.is_dir() {
        return;
    }
    let storage = std::env::temp_dir().join(format!("bun-ai-{}", crate::uuid::Uuid::new()));
    let mut client = crate::host::plugin_host_process_client::PluginHostProcessClient::new(
        executable,
        Vec::new(),
        None,
    );
    // The packaged view asks the host for its service data; the Swift test
    // answered with an empty list and asserted the synchronous generation read.
    client.on_host_call = Some(Box::new(|call| {
        assert_eq!(call.permission, "cove:service/host");
        Ok(b"[]".to_vec())
    }));
    let inspection = client.inspect_plugin(&package).expect("inspects package");
    let authorization = crate::plugin_authorization::PluginAuthorizationRecord::from_inspection(
        &inspection,
        diffuse_capability::support::swift_date::SwiftDate::now(),
    )
    .expect("authorizes");
    let binding = client
        .load_plugin(&package, &authorization, None)
        .expect("loads plugin");
    let context = serde_json::to_vec(&serde_json::json!({
        "storage": storage.to_string_lossy(),
        "workspace": "",
        "projects": [],
        "content": "files",
    }))
    .expect("encodes context");
    let input = serde_json::to_vec(&serde_json::json!({
        "view": "assistant",
        "state": "",
        "event": "",
        "context": String::from_utf8_lossy(&context),
    }))
    .expect("encodes input");
    let result = client
        .prepare_capability(&binding, "studio.ai.view", &input, None)
        .expect("prepares capability");
    let crate::host::plugin_host_rpc::PluginPreparedCapabilityResult::Read(payload) = result else {
        panic!("Expected view result");
    };
    let view = crate::contribution::workbench::view::PluginViewResult::from_json(
        &payload,
        &std::collections::BTreeSet::from(["assistant".to_string()]),
    )
    .expect("view decodes");
    assert!(view.ui.is_valid());
    assert_eq!(view.refresh_after_milliseconds, Some(500));
    client.unload_plugin(&package).expect("unloads");
    client.stop();
    let _ = std::fs::remove_dir_all(&storage);
}
