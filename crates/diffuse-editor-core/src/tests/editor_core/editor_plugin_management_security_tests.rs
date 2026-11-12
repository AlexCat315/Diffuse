//! Ported from `Editor/Tests/EditorCoreTests/EditorPluginManagementSecurityTests.swift`.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

use diffuse_capability::capability_contract::{
    CapabilityAccess, CapabilityContract, CapabilitySource, ReleasePhase,
};
use diffuse_capability::capability_registry::CapabilityRegistry;
use diffuse_capability::capsule_schema::JsonSchema;
use diffuse_plugin::contract::host_permissions::PluginHostPermissions;
use diffuse_plugin::contract::plugin_manifest::PluginImportPermission;
use diffuse_plugin::contract::plugin_manifest::{
    CovePluginManifest, PluginManifestValidationError, PluginManifestValidator,
};
use diffuse_plugin::contract::plugin_package::PluginPackageLoader;
use diffuse_plugin::contribution::registry::{ContributionDescriptor, ContributionPointRegistry};
use diffuse_plugin::plugin_authorization::PluginInspection;
use serde_json::json;

use crate::ai::plugins::editor_plugin_host_locator::EditorPluginHostLocator;
use crate::ai::plugins::editor_plugin_management_state::{
    EditorPluginInspectionSummary, EditorPluginLifecycle, EditorPluginManagementPhase,
    EditorPluginManagementState,
};
use crate::state::editor_reducer::EditorAction;
use crate::state::editor_state::EditorState;
use crate::state::editor_store::EditorStore;

static NEXT_ROOT: AtomicU64 = AtomicU64::new(0);

fn temporary_directory(extension: Option<&str>) -> PathBuf {
    let unique = NEXT_ROOT.fetch_add(1, Ordering::Relaxed);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or(0);
    let mut root = std::env::temp_dir().join(format!(
        "cove-plugin-security-{}-{nanos}-{unique}",
        std::process::id()
    ));
    if let Some(extension) = extension {
        root.set_extension(extension);
    }
    std::fs::create_dir_all(&root).expect("temporary directory");
    root
}

/// Injected plugin host must be a regular executable and rejects symlinks.
#[test]
fn injected_plugin_host_must_be_a_regular_executable() {
    let directory = temporary_directory(None);
    let non_executable = directory.join("not-executable");
    std::fs::write(&non_executable, b"host").expect("write");
    assert!(EditorPluginHostLocator::resolve(Some(&non_executable)).is_none());
    assert!(EditorPluginHostLocator::resolve(Some(&directory)).is_none());

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;

        let executable = directory.join("DiffusePluginHost");
        std::fs::write(&executable, b"#!/bin/sh\nexit 0\n").expect("write executable");
        std::fs::set_permissions(&executable, std::fs::Permissions::from_mode(0o700))
            .expect("mode");
        let resolved = EditorPluginHostLocator::resolve(Some(&executable)).expect("host");
        assert_eq!(
            resolved,
            std::fs::canonicalize(&executable).expect("canonical")
        );

        let symbolic_link = directory.join("linked-host");
        std::os::unix::fs::symlink(&executable, &symbolic_link).expect("symlink");
        assert!(EditorPluginHostLocator::resolve(Some(&symbolic_link)).is_none());
    }
    let _ = std::fs::remove_dir_all(directory);
}

/// Pending approval and enabled state are never restored from coding.
#[test]
fn pending_approval_and_enabled_state_are_never_restored_from_coding() {
    let summary = make_summary();
    let mut state = EditorState::default();
    state.assistant.plugin_management = EditorPluginManagementState::new(
        EditorPluginManagementPhase::AwaitingAuthorization,
        Some(summary.clone()),
        vec![summary],
        Some("approve me".to_string()),
    );

    let data = serde_json::to_vec(&state).expect("encode");
    let object: serde_json::Value = serde_json::from_slice(&data).expect("json");
    assert!(object.get("pluginManagement").is_none());
    let restored: EditorState = serde_json::from_slice(&data).expect("decode");
    assert_eq!(
        restored.assistant.plugin_management,
        EditorPluginManagementState::idle()
    );
}

/// Store publishes plugin management changes.
#[test]
fn store_publishes_plugin_management_changes() {
    let store = EditorStore::new();
    let notifications = std::rc::Rc::new(std::cell::Cell::new(0));
    {
        let notifications = notifications.clone();
        let _ = store.subscribe(std::rc::Rc::new(move |_| {
            notifications.set(notifications.get() + 1);
        }));
    }

    let next = EditorPluginManagementState::new(
        EditorPluginManagementPhase::Failed,
        None,
        Vec::new(),
        Some("rejected".to_string()),
    );
    store.dispatch(EditorAction::SetPluginManagementState(next.clone()));

    assert_eq!(store.plugin_management(), next);
    assert_eq!(notifications.get(), 1);
}

/// Language formatting contributions are validated.
#[test]
fn language_formatting_contributions_are_validated() {
    let registry = CapabilityRegistry::default_registry();
    let contributions = ContributionPointRegistry::standard();
    let mut grammar = vec![
        json!({"pattern": "%.*$", "token": "comment"}),
        json!({"pattern": "\\\\section\\{([^}]*)\\}", "token": "keyword"}),
    ];
    let mut outline = vec![json!({"pattern": "\\\\section\\{([^}]*)\\}", "level": 2})];
    let mut language = json!({
        "id": "latex",
        "title": "LaTeX",
        "extensions": ["tex"],
        "grammar": {"rules": grammar},
        "outline": {"rules": outline},
        "format": {"entryPoint": "format"},
    });
    let validate = |language: &serde_json::Value| {
        PluginManifestValidator::decode_and_validate(
            &valid_manifest(language),
            &registry,
            &contributions,
        )
    };
    validate(&language).expect("valid language");

    grammar[0]["token"] = json!("colour");
    language["grammar"] = json!({"rules": grammar});
    assert!(matches!(
        validate(&language),
        Err(PluginManifestValidationError::InvalidContribution(point))
            if point == "cove.language/v1"
    ));

    grammar[0] = json!({"pattern": "(", "token": "comment"});
    language["grammar"] = json!({"rules": grammar});
    assert!(matches!(
        validate(&language),
        Err(PluginManifestValidationError::InvalidContribution(point))
            if point == "cove.language/v1"
    ));

    language["grammar"] = json!({"rules": [{"pattern": "%.*$", "token": "comment"}]});
    for level in [0, 7] {
        outline[0] = json!({"pattern": "\\\\section\\{([^}]*)\\}", "level": level});
        language["outline"] = json!({"rules": outline});
        assert!(matches!(
            validate(&language),
            Err(PluginManifestValidationError::InvalidContribution(point))
                if point == "cove.language/v1"
        ));
    }

    language["outline"] = json!({"rules": [{"pattern": "\\\\section\\{([^}]*)\\}", "level": 2}]});
    for entry_point in ["Format", "-format", "format_1"] {
        language["format"] = json!({"entryPoint": entry_point});
        assert!(matches!(
            validate(&language),
            Err(PluginManifestValidationError::InvalidContribution(point))
                if point == "cove.language/v1"
        ));
    }
}

/// Format entry point must match the document input contract.
#[test]
fn format_entry_point_must_match_the_document_input_contract() {
    let loader = PluginPackageLoader::new(
        CapabilityRegistry::default_registry(),
        None,
        ContributionPointRegistry::standard(),
    );
    let valid_root = make_formatting_package(
        r#"{"version":1,"entries":[{"name":"format","input":{"record":{"text":"string"}}}]}"#,
    );
    loader.load(&valid_root).expect("valid package");

    let missing_root = make_formatting_package(
        r#"{"version":1,"entries":[{"name":"formatter","input":{"record":{"text":"string"}}}]}"#,
    );
    assert!(matches!(
        loader.load(&missing_root),
        Err(diffuse_plugin::PluginError::Manifest(
            PluginManifestValidationError::InvalidContribution(point)
        )) if point == "cove.language/v1"
    ));

    let wrong_input_root = make_formatting_package(
        r#"{"version":1,"entries":[{"name":"format","input":{"record":{"document":"string"}}}]}"#,
    );
    assert!(matches!(
        loader.load(&wrong_input_root),
        Err(diffuse_plugin::PluginError::Manifest(
            PluginManifestValidationError::InvalidContribution(point)
        )) if point == "cove.language/v1"
    ));
    let _ = std::fs::remove_dir_all(valid_root);
    let _ = std::fs::remove_dir_all(missing_root);
    let _ = std::fs::remove_dir_all(wrong_input_root);
}

fn valid_manifest(language: &serde_json::Value) -> Vec<u8> {
    serde_json::to_vec(&json!({
        "id": "safe.formatter",
        "version": 1,
        "name": "Formatter",
        "description": "Formatting fixture",
        "access": "read",
        "imports": [],
        "composable_host_capabilities": [],
        "contributes": {"cove.language/v1": [language]},
    }))
    .expect("manifest json")
}

fn make_formatting_package(contract: &str) -> PathBuf {
    let root = temporary_directory(Some("coveplugin"));
    let language = json!({
        "id": "latex",
        "title": "LaTeX",
        "extensions": ["tex"],
        "format": {"entryPoint": "format"},
    });
    let mut manifest: serde_json::Value =
        serde_json::from_slice(&valid_manifest(&language)).expect("manifest");
    manifest["runtime"] = json!({"engine": "bun", "entry": "plugin.js", "compatibility": 1});
    std::fs::write(
        root.join("plugin.json"),
        serde_json::to_vec(&manifest).expect("manifest bytes"),
    )
    .expect("plugin.json");
    std::fs::write(root.join("plugin.js"), b"export default {capabilities:{}}").expect("plugin.js");
    std::fs::write(root.join("capabilities.json"), contract.as_bytes()).expect("capabilities.json");
    root
}

fn make_summary() -> EditorPluginInspectionSummary {
    let plugin_id = "safe.management";
    let manifest = CovePluginManifest::new(
        plugin_id,
        1,
        "Management",
        "Test",
        CapabilityAccess::Read,
        vec![PluginImportPermission::SceneQuery],
        Vec::new(),
        Vec::new(),
        PluginHostPermissions::default(),
        ContributionDescriptor::new(),
    );
    let contract = CapabilityContract::new(
        format!("{plugin_id}.inspect"),
        1,
        "Inspect",
        "Inspect safely",
        "plugin",
        CapabilityAccess::Read,
        ReleasePhase::Stable,
        JsonSchema::object(BTreeMap::new(), Vec::new()),
        CapabilitySource::plugin(plugin_id),
        None,
    );
    EditorPluginInspectionSummary::new(
        &PluginInspection {
            manifest,
            code_hash: Some("component".to_string()),
            contract_hash: Some("wit".to_string()),
            resource_hashes: BTreeMap::new(),
            contracts: vec![contract],
        },
        false,
        EditorPluginLifecycle::default(),
    )
}
