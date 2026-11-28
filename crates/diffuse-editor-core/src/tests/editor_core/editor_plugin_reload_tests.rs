//! Port of the editor-side reload checks in `EditorPluginReloadTests.swift`.

use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use diffuse_capability::capability_contract::CapabilityAccess;
use diffuse_capability::support::swift_date::SwiftDate;
use diffuse_plugin::Uuid;
use diffuse_plugin::contract::plugin_manifest::CovePluginManifest;
use diffuse_plugin::contribution::ai::tool::{AIToolContribution, AIToolContributionPoint};
use diffuse_plugin::contribution::languages::language::LanguageContribution;
use diffuse_plugin::contribution::languages::language_point::LanguageContributionPoint;
use serde_json::{Value, json};

use crate::ai::plugins::editor_plugin_host_locator::EditorPluginHostLocator;
use crate::ai::plugins::editor_plugin_management_state::EditorPluginManagementPhase;
use crate::application::editor_application::EditorApplication;
use crate::application::plugins::editor_plugin_capability_error::EditorPluginCapabilityError;

const ID: &str = "safe.reloadtest";

struct TestDirectory(PathBuf);

impl TestDirectory {
    fn new() -> Self {
        let root = std::env::temp_dir().join(Uuid::new().as_str());
        fs::create_dir_all(&root).expect("fixture root");
        Self(root)
    }

    fn package(&self) -> PathBuf {
        let root = self.0.join(format!("{ID}.coveplugin"));
        fs::create_dir_all(&root).expect("plugin package");
        root
    }
}

impl Drop for TestDirectory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn manifest() -> CovePluginManifest {
    CovePluginManifest::new(
        ID,
        1,
        "Reload test",
        "Editor reload integration fixture",
        CapabilityAccess::Read,
        Vec::new(),
        Vec::new(),
        Vec::new(),
        Default::default(),
        Default::default(),
    )
}

fn save(package: &Path, manifest: &CovePluginManifest) {
    fs::write(
        package.join("plugin.json"),
        serde_json::to_vec(manifest).unwrap(),
    )
    .unwrap();
}

#[test]
fn watch_surfaces_new_bytes_without_replacing_current_authorization() {
    let project = TestDirectory::new();
    let package = project.package();
    let mut manifest = manifest();
    manifest
        .contributes
        .set::<LanguageContributionPoint>(&[LanguageContribution::new(
            "fixture",
            "Fixture",
            vec!["fixture".into()],
        )])
        .unwrap();
    save(&package, &manifest);

    let app = EditorApplication::new(project.0.to_string_lossy().into_owned()).unwrap();
    let inspection = app.inspect_plugin(&package).unwrap();
    let authorization = app
        .make_plugin_authorization(&inspection, &SwiftDate::now())
        .unwrap();
    app.enable_plugin(&package, &authorization).unwrap();
    app.reload_plugin(ID)
        .expect("remount unchanged declaration");
    app.start_watching_plugin_packages(Duration::from_millis(250));

    manifest.version = 22;
    save(&package, &manifest);
    // Reproject the same package set between polls without resetting its file baseline.
    app.activate_plugins("onAIChat").unwrap();
    let deadline = Instant::now() + Duration::from_secs(3);
    while app.store.plugin_management().candidate.is_none() && Instant::now() < deadline {
        app.poll_watched_plugin_packages();
        std::thread::sleep(Duration::from_millis(10));
    }
    let management = app.store.plugin_management();
    assert_eq!(
        management.phase,
        EditorPluginManagementPhase::AwaitingAuthorization
    );
    let candidate = management.candidate.unwrap();
    assert_eq!(candidate.version, 22);
    assert!(!candidate.has_reusable_authorization);
    assert_eq!(app.enabled_plugin_inspections()[0].manifest.version, 1);
    assert_eq!(
        app.stored_plugin_authorization(&inspection),
        Some(authorization)
    );
    app.shutdown();
}

#[test]
fn mcp_activates_and_reads_a_real_plugin_and_rejects_changed_authority() {
    let resources = Path::new(env!("CARGO_MANIFEST_DIR")).join("../diffuse-plugin/Resources");
    let bun = resources.join(if cfg!(windows) {
        "bun/bun.exe"
    } else {
        "bun/bun"
    });
    if !bun.is_file()
        || !resources.join("bun-runner.js").is_file()
        || EditorPluginHostLocator::resolve(None).is_none()
    {
        return;
    }

    let project = TestDirectory::new();
    let package = project.package();
    let mut manifest = manifest();
    manifest.runtime = Some(Default::default());
    manifest
        .contributes
        .set::<AIToolContributionPoint>(&[AIToolContribution::new(
            "inspect",
            "Inspect",
            "Read fixture status.",
        )])
        .unwrap();
    save(&package, &manifest);
    fs::write(package.join("plugin.js"), "export default {capabilities:{inspect:{input:{record:{enabled:'bool'}},run:()=>({summary:'bounded'})}}}").unwrap();
    fs::write(package.join("capabilities.json"), br#"{"version":1,"entries":[{"name":"inspect","description":"Read fixture status.","input":{"record":{"enabled":"bool"}}}]}"#).unwrap();

    let app = EditorApplication::new(project.0.to_string_lossy().into_owned()).unwrap();
    let inspected = app.inspect_plugin(&package).unwrap();
    let authorization = app
        .make_plugin_authorization(&inspected, &SwiftDate::now())
        .unwrap();
    app.enable_plugin(&package, &authorization).unwrap();
    assert!(app.plugin_session.manager.active_bindings().is_empty());
    let session = Uuid::new();
    let call = |input: Value| {
        serde_json::from_slice::<Value>(
            &app.handle_mcp_message(&serde_json::to_vec(&input).unwrap()),
        )
        .unwrap()
    };
    let opened = call(json!({"action": "open_capability_session", "session_id": session.as_str()}));
    assert_eq!(opened["ok"], true, "{opened}");
    let tool = call(json!({
        "action": "search_capabilities", "session_id": session.as_str(), "query": "safe.reloadtest.inspect",
    }));
    assert_eq!(tool["ok"], true, "{tool}");
    let name = tool["capabilities"]
        .as_array()
        .unwrap()
        .iter()
        .find(|contract| contract["id"] == "safe.reloadtest.inspect")
        .expect("active plugin capability")["tool_name"]
        .as_str()
        .unwrap();
    let invocation = call(json!({
        "action": "invoke_capability", "session_id": session.as_str(), "tool_name": name,
        "arguments": {"enabled": true},
    }));
    assert_eq!(
        invocation,
        json!({"ok": true, "result": {"summary": "bounded"}})
    );

    let generation = app.plugin_session.manager.active_bindings()[ID].host_generation;
    let reload = || call(json!({"action": "reload_plugin", "plugin_id": ID}));
    assert_eq!(
        reload(),
        json!({"ok": true, "plugin_id": ID, "reloaded": true})
    );
    manifest.version = 2;
    save(&package, &manifest);
    let failure = reload();
    assert_eq!(failure["ok"], false);
    assert_eq!(
        failure["error"],
        EditorPluginCapabilityError::PluginAuthorizationStale(ID.into()).to_string()
    );
    assert_eq!(
        app.plugin_session.manager.active_bindings()[ID].host_generation,
        generation
    );
    app.shutdown();
}
