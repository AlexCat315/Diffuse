//! Tests for the framed-RPC plugin host binary.
//!
//! Swift's `DiffusePluginHost` target had no test target, so these tests pin the
//! behaviour of the ported handlers directly. Every fixture is a minimal
//! `.coveplugin` directory built in the temp directory, mirroring the loader
//! fixture used by `diffuse-plugin`'s `plugin_manager_tests`.
//!
//! `prepare`'s success paths run the Bun runtime staged by
//! `cargo xtask plugins prepare`; those tests skip (rather than fail) when the
//! staged artifacts are absent, so a clean checkout without a prepare still
//! passes.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use diffuse_capability::capability_contract::CapabilityAccess;
use diffuse_capability::capability_registry::CapabilityRegistry;
use diffuse_capability::support::swift_date::SwiftDate;
use diffuse_plugin::PluginError;
use diffuse_plugin::Uuid;
use diffuse_plugin::base64_data::Data;
use diffuse_plugin::contract::plugin_manifest::{
    CovePluginManifest, PluginImportPermission, PluginResourceLimits,
};
use diffuse_plugin::contract::plugin_package::PluginPackageLoader;
use diffuse_plugin::contribution::registry::ContributionPointRegistry;
use diffuse_plugin::host::bun_runtime::{BunPluginRuntime, BunRuntimeError, PluginHostServiceCall};
use diffuse_plugin::host::plugin_host_rpc::{
    PluginHostFrameCodec, PluginHostMethod, PluginHostRequest, PluginHostResponse,
};
use diffuse_plugin::network::transfers::PluginHTTPService;
use diffuse_plugin::plugin_authorization::{
    PluginAuthorizationRecord, PluginContractDeriver, PluginInspection,
};
use diffuse_plugin::processes::service::PluginProcessService;

use crate::{Host, HostError, packages_match, staged_execution_copy};

const PLUGIN_ID: &str = "fixture.minimal";

const CONTRACT: &[u8] =
    br#"{"version":1,"entries":[{"name":"inspect","title":"Inspect","description":"","input":{"record":{"enabled":"bool"}}}]}"#;

const STALE_AUTHORIZATION: &str =
    "plugin code, static, permissions, or capability schemas changed; reauthorisation is required";

fn temporary(label: &str) -> PathBuf {
    let path = std::env::temp_dir().join(format!("plugin-host-{label}-{}", Uuid::new()));
    std::fs::create_dir_all(&path).expect("temp directory");
    path
}

/// Minimal runtime package: `plugin.json`, `plugin.js` and `capabilities.json`.
fn package(root: &Path) -> PathBuf {
    runtime_package(root, Vec::new(), "export default { inspect: () => ({}) }")
}

/// Same layout, but with a `plugin.js` the Bun runner accepts: `default.capabilities`
/// keyed by the contract's entry names.
fn runtime_package(root: &Path, imports: Vec<PluginImportPermission>, code: &str) -> PathBuf {
    let url = root.join(format!("{PLUGIN_ID}.coveplugin"));
    std::fs::create_dir_all(&url).expect("package directory");
    let mut manifest = CovePluginManifest::new(
        PLUGIN_ID,
        1,
        "Fixture",
        "Fixture",
        CapabilityAccess::Read,
        imports,
        Vec::new(),
        Vec::new(),
        Default::default(),
        Default::default(),
    );
    manifest.runtime = Some(Default::default());
    std::fs::write(
        url.join("plugin.json"),
        serde_json::to_vec(&manifest).expect("manifest encodes"),
    )
    .expect("writes manifest");
    std::fs::write(url.join("plugin.js"), code).expect("writes component");
    std::fs::write(url.join("capabilities.json"), CONTRACT).expect("writes contract");
    url
}

/// True when `cargo xtask plugins prepare` staged the Bun executable and runner.
fn runtime_ready() -> bool {
    let resources = Path::new(env!("CARGO_MANIFEST_DIR")).join("../diffuse-plugin/Resources");
    let executable = if cfg!(windows) {
        "bun/bun.exe"
    } else {
        "bun/bun"
    };
    resources.join(executable).is_file() && resources.join("bun-runner.js").is_file()
}

/// Skips (with an explanation) instead of failing on a checkout that has not run
/// `cargo xtask plugins prepare`.
fn require_runtime() -> bool {
    if runtime_ready() {
        return true;
    }
    eprintln!("skipping: run `cargo xtask plugins prepare` to stage Bun");
    false
}

fn loader() -> PluginPackageLoader {
    PluginPackageLoader::new(
        CapabilityRegistry::default_registry(),
        None,
        ContributionPointRegistry::standard(),
    )
}

fn host(staging_root: &Path) -> Host {
    let registry = CapabilityRegistry::default_registry();
    Host {
        runtime: BunPluginRuntime::new(PluginProcessService::new(), PluginHTTPService::new()),
        loader: PluginPackageLoader::new(
            registry.clone(),
            None,
            ContributionPointRegistry::standard(),
        ),
        registry,
        limits: PluginResourceLimits::secure_default(),
        staging_root: staging_root.to_path_buf(),
        loaded: BTreeMap::new(),
        current_request_id: Arc::new(Mutex::new(None)),
    }
}

fn authorization(url: &Path) -> PluginAuthorizationRecord {
    let package = loader().load(url).expect("loads package");
    PluginAuthorizationRecord::from_inspection(
        &PluginInspection::from_package(&package, PluginContractDeriver::contracts(&package)),
        SwiftDate(0.0),
    )
    .expect("authorizes")
}

fn request(method: PluginHostMethod, url: &Path) -> PluginHostRequest {
    let mut request = PluginHostRequest::new(method);
    request.plugin_path = Some(url.to_string_lossy().into_owned());
    request
}

/// Loads `url` into `host` and returns the authorization record it accepted.
fn load(host: &mut Host, url: &Path) -> PluginAuthorizationRecord {
    let authorization = authorization(url);
    let mut request = request(PluginHostMethod::Load, url);
    request.authorization = Some(authorization.clone());
    let response = host.respond(&request);
    assert!(response.ok, "load rejected: {:?}", response.error);
    authorization
}

fn prepare_request(
    url: &Path,
    capability_id: &str,
    input: &[u8],
    authorization: Option<PluginAuthorizationRecord>,
) -> PluginHostRequest {
    let mut request = request(PluginHostMethod::Prepare, url);
    request.capability_id = Some(capability_id.to_string());
    request.input = Some(Data::from_bytes(input.to_vec()));
    request.authorization = authorization;
    request
}

fn payload(response: &PluginHostResponse) -> serde_json::Value {
    let payload = response.payload.as_ref().expect("response payload");
    serde_json::from_slice(payload.as_slice()).expect("payload is JSON")
}

fn entries(path: &Path) -> usize {
    std::fs::read_dir(path).expect("staging directory").count()
}

// @Test("the handshake advertises protocol version 6 and an unsandboxed Bun runtime")
#[test]
fn handshake_reports_swift_fields() {
    let staging = temporary("handshake");
    let mut host = host(&staging);
    let request = PluginHostRequest::new(PluginHostMethod::Handshake);
    let id = request.id.clone();
    let response = host.respond(&request);

    assert!(response.ok);
    assert!(response.error.is_none());
    assert_eq!(response.id, id);
    let payload = payload(&response);
    assert_eq!(payload["protocol_version"], serde_json::json!(6));
    assert_eq!(payload["runtime"], serde_json::json!("bun"));
    assert_eq!(
        payload["runtime_mode"],
        serde_json::json!("trusted-extension-process")
    );
    assert_eq!(payload["runtime_version"], serde_json::json!("1.4.4"));
    assert_eq!(payload["sandboxed"], serde_json::json!(false));
    assert_eq!(
        payload["maximum_frame_bytes"],
        serde_json::json!(PluginHostFrameCodec::MAXIMUM_FRAME_BYTES)
    );
    assert_eq!(payload.as_object().map(serde_json::Map::len), Some(6));
    let _ = std::fs::remove_dir_all(&staging);
}

// @Test("hostResult arriving at the host is a protocol failure, not a rejection")
#[test]
fn respond_rejects_host_result() {
    let staging = temporary("host-result");
    let mut host = host(&staging);
    let request = PluginHostRequest::new(PluginHostMethod::HostResult);
    let id = request.id.clone();
    let response = host.respond(&request);

    assert!(!response.ok);
    assert_eq!(response.id, id);
    assert_eq!(
        response.error.as_deref(),
        Some("Bun plugin protocol failed")
    );
    assert!(response.payload.is_none());
    let _ = std::fs::remove_dir_all(&staging);
}

// @Test("frame decoding keeps Swift's error cases, UUID spelling and method names")
#[test]
fn frame_errors_keep_swift_case_names() {
    let incomplete = PluginHostFrameCodec::decode::<PluginHostRequest>(&[0, 0, 0, 8, b'{', b'}'])
        .expect_err("incomplete frame");
    assert_eq!(incomplete.to_string(), "plugin host frame is incomplete");

    let mut oversized = ((PluginHostFrameCodec::MAXIMUM_FRAME_BYTES + 1) as u32)
        .to_be_bytes()
        .to_vec();
    oversized.extend_from_slice(b"{}");
    let too_large =
        PluginHostFrameCodec::decode::<PluginHostRequest>(&oversized).expect_err("oversized frame");
    assert_eq!(too_large.to_string(), "plugin host frame is too large");

    let trailing =
        PluginHostFrameCodec::decode::<PluginHostRequest>(&[0, 0, 0, 2, b'{', b'}', b' '])
            .expect_err("trailing bytes");
    assert_eq!(trailing.to_string(), "plugin host frame has trailing bytes");

    let request = PluginHostRequest::new(PluginHostMethod::Handshake);
    let frame = PluginHostFrameCodec::encode(&request).expect("encodes frame");
    let length = u32::from_be_bytes([frame[0], frame[1], frame[2], frame[3]]);
    assert_eq!(length as usize, frame.len() - 4);
    assert_eq!(
        PluginHostFrameCodec::decode::<PluginHostRequest>(&frame).expect("decodes frame"),
        request
    );

    let framed = |value: serde_json::Value| {
        let payload = serde_json::to_vec(&value).expect("encodes JSON");
        let mut frame = (payload.len() as u32).to_be_bytes().to_vec();
        frame.extend_from_slice(&payload);
        frame
    };
    let bad_id = PluginHostFrameCodec::decode::<PluginHostRequest>(&framed(serde_json::json!({
        "id": "not-a-uuid",
        "method": "handshake",
    })))
    .expect_err("bad id");
    assert!(
        bad_id
            .to_string()
            .contains("invalid UUID string: not-a-uuid"),
        "{bad_id}"
    );
    let unknown = PluginHostFrameCodec::decode::<PluginHostRequest>(&framed(serde_json::json!({
        "id": Uuid::new().to_string(),
        "method": "explode",
    })))
    .expect_err("unknown method");
    assert!(
        unknown.to_string().contains("unknown variant `explode`"),
        "{unknown}"
    );
}

// @Test("every method answers a missing pluginPath with its own message")
#[test]
fn respond_requires_plugin_path() {
    let staging = temporary("missing-path");
    let mut host = host(&staging);
    for (method, expected) in [
        (PluginHostMethod::ValidatePackage, "missing pluginPath"),
        (PluginHostMethod::Load, "missing pluginPath"),
        (PluginHostMethod::Discover, "missing pluginPath"),
        (PluginHostMethod::Prepare, "missing prepare arguments"),
    ] {
        let request = PluginHostRequest::new(method);
        let id = request.id.clone();
        let response = host.respond(&request);
        assert!(!response.ok);
        assert_eq!(response.id, id);
        assert_eq!(response.error.as_deref(), Some(expected));
        assert!(response.payload.is_none());
    }
    assert!(host.loaded.is_empty());
    let _ = std::fs::remove_dir_all(&staging);
}

// @Test("validatePackage returns the inspection and removes the staged copy")
#[test]
fn validate_package_reports_inspection() {
    let staging = temporary("validate-staging");
    let root = temporary("validate-source");
    let url = package(&root);
    let mut host = host(&staging);
    let response = host.respond(&request(PluginHostMethod::ValidatePackage, &url));

    assert!(response.ok, "validate rejected: {:?}", response.error);
    let payload = payload(&response);
    assert_eq!(payload["manifest"]["id"], serde_json::json!(PLUGIN_ID));
    assert_eq!(payload["manifest"]["version"], serde_json::json!(1));
    assert_eq!(payload["manifest"]["access"], serde_json::json!("read"));
    assert_eq!(
        payload["manifest"]["runtime"]["engine"],
        serde_json::json!("bun")
    );
    let code_hash = payload["codeHash"].as_str().expect("code hash");
    assert_eq!(code_hash.len(), 64);
    assert!(
        code_hash
            .chars()
            .all(|character| character.is_ascii_hexdigit())
    );
    assert_eq!(
        payload["contractHash"].as_str().map(str::len),
        Some(64),
        "contract hash is a SHA-256 digest"
    );
    assert_eq!(payload["resourceHashes"], serde_json::json!({}));
    let contracts = payload["contracts"].as_array().expect("contracts");
    assert_eq!(contracts.len(), 1);
    assert_eq!(
        contracts[0]["id"],
        serde_json::json!("fixture.minimal.inspect")
    );
    assert_eq!(contracts[0]["access"], serde_json::json!("read"));
    assert_eq!(contracts[0]["domain"], serde_json::json!("plugin"));
    // The inspection is built from a staging copy that validatePackage removes.
    assert_eq!(entries(&staging), 0);
    assert!(host.loaded.is_empty());
    let _ = std::fs::remove_dir_all(&root);
    let _ = std::fs::remove_dir_all(&staging);
}

// @Test("validatePackage reports the loader's package error for a missing directory")
#[test]
fn validate_package_rejects_missing_package() {
    let staging = temporary("missing-package-staging");
    let root = temporary("missing-package-source");
    let mut host = host(&staging);
    let response = host.respond(&request(
        PluginHostMethod::ValidatePackage,
        &root.join("absent.coveplugin"),
    ));

    assert!(!response.ok);
    assert_eq!(
        response.error.as_deref(),
        Some("plugin package is not a directory")
    );
    assert!(response.payload.is_none());
    let _ = std::fs::remove_dir_all(&root);
    let _ = std::fs::remove_dir_all(&staging);
}

// @Test("validatePackage enforces maximum_output_bytes after staging")
#[test]
fn validate_package_enforces_output_limit() {
    let staging = temporary("limit-staging");
    let root = temporary("limit-source");
    let url = package(&root);
    let mut host = host(&staging);
    host.limits.maximum_output_bytes = 64;
    let response = host.respond(&request(PluginHostMethod::ValidatePackage, &url));

    assert!(!response.ok);
    assert_eq!(response.error.as_deref(), Some("frameTooLarge"));
    assert_eq!(entries(&staging), 0);
    let _ = std::fs::remove_dir_all(&root);
    let _ = std::fs::remove_dir_all(&staging);
}

// @Test("load without an authorization record is refused before staging")
#[test]
fn load_requires_authorization() {
    let staging = temporary("load-unauthorized-staging");
    let root = temporary("load-unauthorized-source");
    let url = package(&root);
    let mut host = host(&staging);
    let response = host.respond(&request(PluginHostMethod::Load, &url));

    assert!(!response.ok);
    assert_eq!(
        response.error.as_deref(),
        Some("plugin must be explicitly authorised before loading")
    );
    assert!(host.loaded.is_empty());
    assert_eq!(entries(&staging), 0);
    let _ = std::fs::remove_dir_all(&root);
    let _ = std::fs::remove_dir_all(&staging);
}

// @Test("load, discover and unload move one package in and out of the host")
#[test]
fn load_discover_unload_round_trip() {
    let staging = temporary("round-trip-staging");
    let root = temporary("round-trip-source");
    let url = package(&root);
    let mut host = host(&staging);
    let authorization = load(&mut host, &url);

    assert_eq!(host.loaded.len(), 1);
    assert!(host.loaded.contains_key(PLUGIN_ID));
    assert_eq!(entries(&staging), 1);

    let mut discover = request(PluginHostMethod::Discover, &url);
    discover.authorization = Some(authorization.clone());
    let response = host.respond(&discover);
    assert!(response.ok, "discover rejected: {:?}", response.error);
    assert_eq!(
        payload(&response),
        serde_json::json!({"capability_ids": ["fixture.minimal.inspect"]})
    );

    // Discovery without the load-time authorization is a stale record.
    let response = host.respond(&request(PluginHostMethod::Discover, &url));
    assert!(!response.ok);
    assert_eq!(response.error.as_deref(), Some(STALE_AUTHORIZATION));

    let response = host.respond(&request(PluginHostMethod::Unload, &url));
    assert!(response.ok);
    assert!(response.error.is_none());
    assert!(host.loaded.is_empty());
    assert_eq!(entries(&staging), 0);
    let _ = std::fs::remove_dir_all(&root);
    let _ = std::fs::remove_dir_all(&staging);
}

// @Test("discovering after plugin.js changed reports the unchanged-package rule")
#[test]
fn discover_rejects_code_changed_after_load() {
    let staging = temporary("changed-code-staging");
    let root = temporary("changed-code-source");
    let url = package(&root);
    let mut host = host(&staging);
    let authorization = load(&mut host, &url);

    std::fs::write(
        url.join("plugin.js"),
        "export default { inspect: () => ({ changed: true }) }",
    )
    .expect("rewrites component");
    let mut discover = request(PluginHostMethod::Discover, &url);
    discover.authorization = Some(authorization);
    let response = host.respond(&discover);

    assert!(!response.ok);
    assert_eq!(
        response.error.as_deref(),
        Some("plugin must be loaded and unchanged before discovery")
    );
    assert!(host.loaded.contains_key(PLUGIN_ID));
    let _ = std::fs::remove_dir_all(&root);
    let _ = std::fs::remove_dir_all(&staging);
}

// @Test("packagesMatch ignores nothing but the authorization, including contract hashes")
#[test]
fn packages_match_detects_changed_contract() {
    let root = temporary("match-source");
    let url = package(&root);
    let loader = loader();
    let source = loader.load(&url).expect("loads source");
    assert!(packages_match(
        &source,
        &loader.load(&url).expect("reloads unchanged")
    ));

    std::fs::write(
        url.join("capabilities.json"),
        br#"{"version":1,"entries":[{"name":"inspect","title":"Inspect v2","description":"","input":{"record":{"enabled":"bool"}}}]}"#,
    )
    .expect("rewrites contract");
    let changed = loader.load(&url).expect("loads changed");
    assert_eq!(changed.root_url, source.root_url);
    assert_eq!(changed.manifest, source.manifest);
    assert_eq!(
        changed.runtime.as_ref().map(|runtime| &runtime.code_hash),
        source.runtime.as_ref().map(|runtime| &runtime.code_hash)
    );
    assert_ne!(
        changed
            .runtime
            .as_ref()
            .map(|runtime| &runtime.contract_hash),
        source
            .runtime
            .as_ref()
            .map(|runtime| &runtime.contract_hash)
    );
    assert!(!packages_match(&source, &changed));
    let _ = std::fs::remove_dir_all(&root);
}

// @Test("re-hashing the staged copy reports packageChangedDuringStaging and cleans up")
#[test]
fn staged_execution_copy_reports_package_changed() {
    let staging = temporary("staged-staging");
    let root = temporary("staged-source");
    let url = package(&root);
    let loader = loader();
    let mut source = loader.load(&url).expect("loads source");
    // Simulate plugin.js having been replaced between validation and staging.
    source.runtime.as_mut().expect("package runtime").code_hash = "0".repeat(64);

    let error = staged_execution_copy(&loader, &staging, &source).expect_err("changed package");
    assert!(matches!(error, HostError::PackageChangedDuringStaging));
    assert_eq!(error.to_string(), "packageChangedDuringStaging");
    assert_eq!(entries(&staging), 0);
    let _ = std::fs::remove_dir_all(&root);
    let _ = std::fs::remove_dir_all(&staging);
}

// @Test("prepare rejects missing arguments and packages that are not loaded")
#[test]
fn prepare_rejects_unloaded_package() {
    let staging = temporary("prepare-unloaded-staging");
    let root = temporary("prepare-unloaded-source");
    let url = package(&root);
    let mut host = host(&staging);

    let response = host.respond(&request(PluginHostMethod::Prepare, &url));
    assert!(!response.ok);
    assert_eq!(response.error.as_deref(), Some("missing prepare arguments"));

    let prepare = prepare_request(&url, "fixture.minimal.inspect", b"{}", None);
    let response = host.respond(&prepare);
    assert!(!response.ok);
    assert_eq!(
        response.error.as_deref(),
        Some("plugin package changed after loading")
    );
    let _ = std::fs::remove_dir_all(&root);
    let _ = std::fs::remove_dir_all(&staging);
}

// @Test("prepare rejects a capability absent from the static contract")
#[test]
fn prepare_rejects_unknown_capability() {
    let staging = temporary("prepare-unknown-staging");
    let root = temporary("prepare-unknown-source");
    let url = package(&root);
    let mut host = host(&staging);
    let authorization = load(&mut host, &url);

    let response = host.respond(&prepare_request(
        &url,
        "fixture.minimal.absent",
        b"{}",
        Some(authorization),
    ));
    assert!(!response.ok);
    assert_eq!(
        response.error.as_deref(),
        Some(
            "plugin capability 'fixture.minimal.absent' is absent from its validated static contract"
        )
    );
    let _ = std::fs::remove_dir_all(&root);
    let _ = std::fs::remove_dir_all(&staging);
}

// @Test("prepare rejects a request whose authorization is not the load-time record")
#[test]
fn prepare_rejects_stale_authorization() {
    let staging = temporary("prepare-stale-staging");
    let root = temporary("prepare-stale-source");
    let url = package(&root);
    let mut host = host(&staging);
    let _ = load(&mut host, &url);

    let response = host.respond(&prepare_request(
        &url,
        "fixture.minimal.inspect",
        br#"{"enabled":true}"#,
        None,
    ));
    assert!(!response.ok);
    assert_eq!(response.error.as_deref(), Some(STALE_AUTHORIZATION));
    let _ = std::fs::remove_dir_all(&root);
    let _ = std::fs::remove_dir_all(&staging);
}

// @Test("read plugins validate input before the runtime is invoked")
#[test]
fn prepare_rejects_invalid_read_input() {
    let staging = temporary("prepare-input-staging");
    let root = temporary("prepare-input-source");
    let url = package(&root);
    let mut host = host(&staging);
    let authorization = load(&mut host, &url);

    let response = host.respond(&prepare_request(
        &url,
        "fixture.minimal.inspect",
        br#"{"enabled":1}"#,
        Some(authorization),
    ));
    assert!(!response.ok);
    assert_eq!(
        response.error.as_deref(),
        Some("$.enabled: expected boolean")
    );
    let _ = std::fs::remove_dir_all(&root);
    let _ = std::fs::remove_dir_all(&staging);
}

// @Test("prepare rejects a package whose files changed after load")
#[test]
fn prepare_rejects_changed_package() {
    let staging = temporary("prepare-changed-staging");
    let root = temporary("prepare-changed-source");
    let url = package(&root);
    let mut host = host(&staging);
    let authorization = load(&mut host, &url);

    std::fs::write(
        url.join("plugin.js"),
        "export default { inspect: () => ({ changed: true }) }",
    )
    .expect("rewrites component");
    let response = host.respond(&prepare_request(
        &url,
        "fixture.minimal.inspect",
        br#"{"enabled":true}"#,
        Some(authorization),
    ));
    assert!(!response.ok);
    assert_eq!(
        response.error.as_deref(),
        Some("plugin package changed after loading")
    );
    let _ = std::fs::remove_dir_all(&root);
    let _ = std::fs::remove_dir_all(&staging);
}

// @Test("unload ignores a path that was never loaded")
#[test]
fn unload_ignores_unknown_package() {
    let staging = temporary("unload-staging");
    let root = temporary("unload-source");
    let url = package(&root);
    let mut host = host(&staging);
    let _ = load(&mut host, &url);
    assert_eq!(entries(&staging), 1);

    let response = host.respond(&request(
        PluginHostMethod::Unload,
        &root.join("other.coveplugin"),
    ));
    assert!(response.ok);
    assert!(response.error.is_none());
    assert_eq!(host.loaded.len(), 1);
    assert_eq!(entries(&staging), 1);
    let _ = std::fs::remove_dir_all(&root);
    let _ = std::fs::remove_dir_all(&staging);
}

/// `runner.ts` requires `default.capabilities` keyed by the contract entries, and
/// validates the input against the per-entry `input` schema before `run`.
const INSPECT_CODE: &str = r#"export default {
  capabilities: {
    inspect: {
      input: { record: { enabled: "bool" } },
      run(input) { return { ok: input.enabled } }
    }
  }
};"#;

// @Test("prepare runs the staged Bun runtime and reuses its session")
#[test]
fn prepare_invokes_the_staged_bun_runtime() {
    if !require_runtime() {
        return;
    }
    let staging = temporary("prepare-bun-staging");
    let root = temporary("prepare-bun-source");
    let url = runtime_package(&root, Vec::new(), INSPECT_CODE);
    let mut host = host(&staging);
    let authorization = load(&mut host, &url);

    let response = host.respond(&prepare_request(
        &url,
        "fixture.minimal.inspect",
        br#"{"enabled":true}"#,
        Some(authorization.clone()),
    ));
    assert!(response.ok, "prepare rejected: {:?}", response.error);
    assert_eq!(payload(&response), serde_json::json!({"ok": true}));

    // The second invocation reuses the Bun session created by the first.
    let response = host.respond(&prepare_request(
        &url,
        "fixture.minimal.inspect",
        br#"{"enabled":false}"#,
        Some(authorization),
    ));
    assert!(response.ok, "prepare rejected: {:?}", response.error);
    assert_eq!(payload(&response), serde_json::json!({"ok": false}));

    let response = host.respond(&request(PluginHostMethod::Unload, &url));
    assert!(response.ok);
    assert!(host.loaded.is_empty());
    assert_eq!(entries(&staging), 0);
    let _ = std::fs::remove_dir_all(&root);
    let _ = std::fs::remove_dir_all(&staging);
}

/// Invokes `context.query` with the granted editor permission.
const HOST_CALL_CODE: &str = r#"export default {
  capabilities: {
    inspect: {
      input: { record: { enabled: "bool" } },
      async run(input, context) {
        const reply = await context.query("diffuse:editor/host", { ping: input.enabled });
        return { host: reply };
      }
    }
  }
};"#;

// @Test("host calls round-trip through the Bun runner and surface host rejections")
#[test]
fn prepare_round_trips_host_calls() {
    if !require_runtime() {
        return;
    }
    let staging = temporary("host-call-staging");
    let root = temporary("host-call-source");
    let url = runtime_package(&root, vec![PluginImportPermission::Editor], HOST_CALL_CODE);
    let mut host = host(&staging);
    let authorization = load(&mut host, &url);

    let seen: Arc<Mutex<Vec<(String, Vec<u8>)>>> = Arc::new(Mutex::new(Vec::new()));
    let observed = Arc::clone(&seen);
    host.runtime.host_call = Some(Box::new(move |call: PluginHostServiceCall| {
        observed
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .push((call.permission, call.request));
        Ok(br#"{"pong":true}"#.to_vec())
    }));

    let response = host.respond(&prepare_request(
        &url,
        "fixture.minimal.inspect",
        br#"{"enabled":true}"#,
        Some(authorization.clone()),
    ));
    assert!(response.ok, "prepare rejected: {:?}", response.error);
    assert_eq!(
        payload(&response),
        serde_json::json!({"host": {"pong": true}})
    );
    let seen = seen.lock().unwrap_or_else(|error| error.into_inner());
    assert_eq!(seen.len(), 1);
    assert_eq!(seen[0].0, "diffuse:editor/host");
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&seen[0].1).expect("host request JSON"),
        serde_json::json!({"ping": true})
    );
    drop(seen);

    // A rejected host call reaches the caller as the runtime's rejection.
    host.runtime.host_call = Some(Box::new(|_| {
        Err(PluginError::from(BunRuntimeError::Rejected(
            "host denied the call".to_string(),
        )))
    }));
    let response = host.respond(&prepare_request(
        &url,
        "fixture.minimal.inspect",
        br#"{"enabled":true}"#,
        Some(authorization),
    ));
    assert!(!response.ok);
    // The runner relays the host closure's message, and the runtime prefixes its
    // own rejection, so both prefixes stack.
    assert_eq!(
        response.error.as_deref(),
        Some("Bun plugin: Bun plugin: host denied the call")
    );
    let _ = std::fs::remove_dir_all(&root);
    let _ = std::fs::remove_dir_all(&staging);
}
