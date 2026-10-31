//! Ported from `Engine/Tests/PluginRuntimeTests/PluginRuntimeTests.swift`.

use std::collections::{BTreeMap, BTreeSet};

use diffuse_capability::capability_contract::{CapabilityAccess, CapabilityContract};
use diffuse_capability::capability_descriptor::CapabilityDescriptor;
use diffuse_capability::capability_registry::CapabilityRegistry;
use diffuse_capability::capsule_schema;

use crate::PluginError;
use crate::base64_data::Data;
use crate::contract::plugin_contract::{PluginContract, PluginEntryContract, PluginInputType};
use crate::contract::plugin_manifest::{
    CovePluginManifest, PluginImportPermission, PluginManifestValidationError,
    PluginManifestValidator, PluginResourceLimits,
};
use crate::contract::plugin_package::ValidatedPluginPackage;
use crate::contribution::registry::ContributionPointRegistry;
use crate::host::host_capability_call::{
    HostCapabilityCall, PluginCompositionError, PluginCompositionValidator,
};
use crate::host::plugin_host_rpc::{
    PluginHostFrameCodec, PluginHostFrameError, PluginHostMethod, PluginHostRequest,
    PluginQuerySnapshot, PluginQuerySnapshotError,
};
use crate::plugin_authorization::{
    PluginAuthorizationRecord, PluginContractDeriver, PluginInspection,
};
use diffuse_capability::support::swift_date::SwiftDate;

// @Test("length-prefixed RPC rejects trailing and oversized frames")
#[test]
fn frame_codec_is_strict() {
    let request = PluginHostRequest::new(PluginHostMethod::Handshake);
    let frame = PluginHostFrameCodec::encode(&request).expect("encodes");
    let decoded: PluginHostRequest = PluginHostFrameCodec::decode(&frame).expect("decodes");
    assert_eq!(decoded, request);

    let mut trailing = frame.clone();
    trailing.push(0);
    assert!(matches!(
        PluginHostFrameCodec::decode::<PluginHostRequest>(&trailing),
        Err(PluginError::HostFrame(PluginHostFrameError::TrailingBytes))
    ));

    let length = (PluginHostFrameCodec::MAXIMUM_FRAME_BYTES as u32).wrapping_add(1);
    let mut oversized = vec![
        (length >> 24) as u8,
        ((length >> 16) & 0xFF) as u8,
        ((length >> 8) & 0xFF) as u8,
        (length & 0xFF) as u8,
    ];
    oversized.extend_from_slice(&[0; 4]);
    assert!(matches!(
        PluginHostFrameCodec::decode::<PluginHostRequest>(&oversized),
        Err(PluginError::HostFrame(PluginHostFrameError::FrameTooLarge))
    ));
}

// @Test("plugin metadata is sanitised before authority validation")
#[test]
fn metadata_sanitisation_fails_closed() {
    let manifest = r#"
    {
      "id": "safe.reader",
      "version": 1,
      "name": "\u0001\u0002",
      "description": "untrusted\u0000text",
      "access": "read",
      "imports": [],
      "composable_host_capabilities": []
    }
    "#;
    assert_eq!(
        PluginManifestValidator::decode_and_validate(
            manifest.as_bytes(),
            &CapabilityRegistry::default_registry(),
            &ContributionPointRegistry::standard(),
        ),
        Err(PluginManifestValidationError::EmptyName)
    );
}

// @Test("plugin composition cannot call an ungranted primitive")
#[test]
fn composition_requires_exact_grant() {
    let contract = CapabilityRegistry::default_registry()
        .descriptor("scene.set_transform")
        .expect("built-in transform capability")
        .contract();
    let arguments = serde_json::to_vec(&serde_json::json!({
        "entity_id": "scene:1",
        "position": [0, 1, 2],
    }))
    .expect("encodes");
    let call = HostCapabilityCall::new(contract.id.clone(), contract.version, arguments);
    let manifest = CovePluginManifest::new(
        "safe.layout",
        1,
        "Safe layout",
        "Layout helper",
        CapabilityAccess::ReversibleWrite,
        Vec::new(),
        Vec::new(),
        Vec::new(),
        Default::default(),
        Default::default(),
    );
    assert!(matches!(
        PluginCompositionValidator::validate(
            std::slice::from_ref(&call),
            &manifest,
            &CapabilityRegistry::default_registry(),
            &PluginResourceLimits::secure_default(),
        ),
        Err(PluginError::Composition(
            PluginCompositionError::CapabilityNotGranted(id)
        )) if id == contract.id
    ));

    let understated = CovePluginManifest::new(
        "safe.layout",
        1,
        "Safe layout",
        "Layout helper",
        CapabilityAccess::ReversibleWrite,
        Vec::new(),
        vec!["scene.delete_entity".to_string()],
        Vec::new(),
        Default::default(),
        Default::default(),
    );
    assert_eq!(
        PluginManifestValidator::validate(
            &understated,
            &CapabilityRegistry::default_registry(),
            &ContributionPointRegistry::standard(),
        ),
        Err(PluginManifestValidationError::AccessUnderstatement(
            "scene.delete_entity".to_string()
        ))
    );
}

// @Test("plugin writes require non-empty strict AI-exposed host primitives")
#[test]
fn composition_requires_safe_write_primitive() {
    let mut primitive = CapabilityDescriptor::new("scene.safe_rename");
    primitive.domain = "scene".to_string();
    primitive.version = 1;
    primitive.access = CapabilityAccess::ReversibleWrite;
    primitive.input_schema = capsule_schema::object(
        BTreeMap::from([("name".to_string(), capsule_schema::string(None, None, None))]),
        vec!["name".to_string()],
        None,
        false,
    );
    primitive.source = diffuse_capability::capability_contract::CapabilitySource::BUILTIN;
    primitive.is_ai_exposed = true;
    primitive.capability_description = "Safe".to_string();
    let registry = CapabilityRegistry::new(vec![primitive.clone()]);
    let manifest = CovePluginManifest::new(
        "safe.layout",
        1,
        "Layout",
        "Safe composition",
        CapabilityAccess::ReversibleWrite,
        Vec::new(),
        vec![primitive.verb.clone()],
        Vec::new(),
        Default::default(),
        Default::default(),
    );
    assert_eq!(
        PluginCompositionValidator::validate(
            &[],
            &manifest,
            &registry,
            &PluginResourceLimits::secure_default(),
        )
        .unwrap_err()
        .to_string(),
        PluginCompositionError::EmptyWriteComposition.to_string()
    );
    let call = HostCapabilityCall::new(
        primitive.verb.clone(),
        primitive.version,
        br#"{"name":"Safe"}"#.to_vec(),
    );
    assert_eq!(
        PluginCompositionValidator::validate(
            std::slice::from_ref(&call),
            &manifest,
            &registry,
            &PluginResourceLimits::secure_default(),
        )
        .expect("composes"),
        vec![call]
    );

    let mut unsafe_primitive = primitive.clone();
    unsafe_primitive.is_ai_exposed = false;
    let unsafe_registry = CapabilityRegistry::new(vec![unsafe_primitive]);
    assert_eq!(
        PluginManifestValidator::validate(
            &manifest,
            &unsafe_registry,
            &ContributionPointRegistry::standard(),
        ),
        Err(PluginManifestValidationError::UnsafeHostPrimitive(
            primitive.verb.clone()
        ))
    );
}

// @Test("query snapshots require granted structured payloads and an exact request")
#[test]
fn query_snapshot_is_strict() {
    let scene = br#"{"entities":[]}"#.to_vec();
    let mut snapshot = PluginQuerySnapshot::new(42);
    snapshot.scene = Some(Data::from_bytes(scene.clone()));
    snapshot
        .validate(&BTreeSet::from([PluginImportPermission::SceneQuery]))
        .expect("valid snapshot");

    let response = snapshot
        .response(
            PluginImportPermission::SceneQuery.raw_value(),
            br#"{"operation":"snapshot"}"#,
            &BTreeSet::from([PluginImportPermission::SceneQuery]),
        )
        .expect("responds");
    assert_eq!(response, scene);
    assert!(matches!(
        snapshot.response(
            PluginImportPermission::SceneQuery.raw_value(),
            br#"{"operation":"snapshot","extra":true}"#,
            &BTreeSet::from([PluginImportPermission::SceneQuery]),
        ),
        Err(PluginQuerySnapshotError::InvalidRequest)
    ));
    assert_eq!(
        snapshot.validate(&BTreeSet::from([
            PluginImportPermission::SceneQuery,
            PluginImportPermission::SelectionQuery,
        ])),
        Err(PluginQuerySnapshotError::MissingPayload(
            PluginImportPermission::SelectionQuery
        ))
    );
}

// @Test("plugin authorization binds code, WIT, permissions, and schemas")
#[test]
fn plugin_authorization_invalidates_every_authority_change() {
    let manifest = CovePluginManifest::new(
        "safe.reader",
        1,
        "Reader",
        "Read a bounded snapshot",
        CapabilityAccess::Read,
        vec![PluginImportPermission::SceneQuery],
        Vec::new(),
        Vec::new(),
        Default::default(),
        Default::default(),
    );
    let contract = PluginContract::new(
        vec!["cove:scene/query".to_string()],
        vec![PluginEntryContract::new(
            "inspect",
            "Inspect",
            "Returns bounded findings",
            capsule_schema::object(BTreeMap::new(), Vec::new(), None, false),
            PluginInputType::Record(Vec::new()),
        )],
    );
    let mut package = ValidatedPluginPackage::new(
        std::path::PathBuf::from("/safe.reader.coveplugin"),
        manifest,
        Some(crate::contract::plugin_package::ValidatedPluginRuntime {
            entry_url: std::path::PathBuf::from("/safe.reader.coveplugin/component.wasm"),
            contract_url: std::path::PathBuf::from("/safe.reader.coveplugin/capabilities.wit"),
            contract,
            code_hash: "component-a".to_string(),
            contract_hash: "wit-a".to_string(),
        }),
    );
    package.resource_hashes = BTreeMap::new();
    let contracts = PluginContractDeriver::contracts(&package);
    assert_eq!(contracts.len(), 1);
    let inspection = PluginInspection::from_package(&package, contracts);
    let base = CapabilityContract::new(
        inspection.contracts[0].id.clone(),
        inspection.contracts[0].version,
        inspection.contracts[0].title.clone(),
        inspection.contracts[0].description.clone(),
        inspection.contracts[0].domain.clone(),
        inspection.contracts[0].access,
        inspection.contracts[0].release_phase,
        inspection.contracts[0].input_schema.clone(),
        inspection.contracts[0].source.clone(),
        Some(inspection.contracts[0].schema_hash.clone()),
    );
    let authorization = PluginAuthorizationRecord::from_inspection(&inspection, SwiftDate(1.0))
        .expect("authorizes");
    assert!(authorization.is_still_valid(&inspection));

    let mut changed_code = inspection.clone();
    changed_code.code_hash = Some("component-b".to_string());
    assert!(!authorization.is_still_valid(&changed_code));

    let mut changed_wit = inspection.clone();
    changed_wit.contract_hash = Some("wit-b".to_string());
    assert!(!authorization.is_still_valid(&changed_wit));

    let mut changed_imports = inspection.clone();
    changed_imports.manifest.imports = vec![PluginImportPermission::SelectionQuery];
    assert!(!authorization.is_still_valid(&changed_imports));

    let mut changed_access = inspection.clone();
    changed_access.manifest.access = CapabilityAccess::ReversibleWrite;
    assert!(!authorization.is_still_valid(&changed_access));

    let mut changed_schema = inspection.clone();
    changed_schema.contracts[0] = CapabilityContract::new(
        base.id.clone(),
        base.version,
        base.title.clone(),
        base.description.clone(),
        base.domain.clone(),
        base.access,
        base.release_phase,
        capsule_schema::object(
            BTreeMap::from([(
                "query".to_string(),
                capsule_schema::string(None, None, None),
            )]),
            Vec::new(),
            None,
            false,
        ),
        base.source.clone(),
        None,
    );
    assert!(!authorization.is_still_valid(&changed_schema));
}

// @Test("Editor RPC client restarts a PluginHost that misses its deadline")
// Platform-guarded exactly as Swift was: a POSIX shell script on Unix, `cmd.exe`
// on Windows. When the prerequisite binary is absent the test returns early,
// which is a skip, not a pass.
#[cfg(any(target_os = "macos", target_os = "linux", target_os = "windows"))]
#[test]
fn process_client_deadline_restarts_host() {
    let (executable, launch_arguments) = host_fixture();
    let client = crate::host::plugin_host_process_client::PluginHostProcessClient::new(
        executable.clone(),
        launch_arguments,
        None,
    );
    let started = std::time::Instant::now();
    assert_eq!(
        client
            .call(&PluginHostRequest::new(PluginHostMethod::Handshake), 50)
            .unwrap_err()
            .to_string(),
        crate::host::plugin_host_process_client::PluginHostClientError::HostRestarted(1)
            .to_string()
    );
    assert_eq!(client.generation(), 1);
    assert!(started.elapsed() < std::time::Duration::from_secs(1));
    // Exhausting the one immediate restart must not stop invalidation.
    assert_eq!(
        client
            .call(&PluginHostRequest::new(PluginHostMethod::Handshake), 50)
            .unwrap_err()
            .to_string(),
        crate::host::plugin_host_process_client::PluginHostClientError::HostRestarted(2)
            .to_string()
    );
    assert_eq!(client.generation(), 2);
    client.stop();
}

#[cfg(target_os = "windows")]
fn host_fixture() -> (std::path::PathBuf, Vec<String>) {
    let executable = std::env::var("ComSpec")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| std::path::PathBuf::from(r"C:\Windows\System32\cmd.exe"));
    // A built-in loop stays in the host process, matching `exec sleep` on Unix;
    // an external ping child would keep inherited pipes open.
    (
        executable,
        vec![
            "/d".to_string(),
            "/s".to_string(),
            "/c".to_string(),
            "for /l %n in (0,0,1) do @rem".to_string(),
        ],
    )
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
fn host_fixture() -> (std::path::PathBuf, Vec<String>) {
    let root = std::env::temp_dir().join(crate::uuid::Uuid::new().to_string());
    std::fs::create_dir_all(&root).expect("temp dir");
    let executable = root.join("unresponsive-plugin-host");
    std::fs::write(&executable, "#!/bin/sh\nexec sleep 5\n").expect("script");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&executable, std::fs::Permissions::from_mode(0o700))
            .expect("chmod");
    }
    (executable, Vec::new())
}
