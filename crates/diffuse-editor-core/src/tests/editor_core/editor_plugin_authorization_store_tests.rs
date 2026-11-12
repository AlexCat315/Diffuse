//! Ported from `Editor/Tests/EditorCoreTests/EditorPluginAuthorizationStoreTests.swift`.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

use diffuse_capability::capability_contract::{
    CapabilityAccess, CapabilityContract, CapabilitySource, ReleasePhase,
};
use diffuse_capability::capsule_schema::JsonSchema;
use diffuse_capability::support::swift_date::SwiftDate;
use diffuse_plugin::contract::host_permissions::PluginHostPermissions;
use diffuse_plugin::contract::plugin_manifest::CovePluginManifest;
use diffuse_plugin::contribution::registry::ContributionDescriptor;
use diffuse_plugin::plugin_authorization::{PluginAuthorizationRecord, PluginInspection};

use crate::ai::plugins::editor_plugin_authorization_store::EditorPluginAuthorizationStore;

static NEXT_DIRECTORY: AtomicU64 = AtomicU64::new(0);

fn temporary_directory() -> PathBuf {
    let unique = NEXT_DIRECTORY.fetch_add(1, Ordering::Relaxed);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or(0);
    let directory = std::env::temp_dir().join(format!(
        "cove-plugin-auth-{}-{nanos}-{unique}",
        std::process::id()
    ));
    std::fs::create_dir_all(&directory).expect("temporary directory");
    directory
}

fn make_inspection(maximum_length: i64) -> PluginInspection {
    let plugin_id = "safe.persisted";
    let manifest = CovePluginManifest::new(
        plugin_id,
        1,
        "Persisted",
        "Test",
        CapabilityAccess::Read,
        Vec::new(),
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
        JsonSchema::object(
            BTreeMap::from([(
                "query".to_string(),
                JsonSchema::string(None, Some(maximum_length as usize)),
            )]),
            vec!["query".to_string()],
        ),
        CapabilitySource::plugin(plugin_id),
        None,
    );
    PluginInspection {
        manifest,
        code_hash: Some("component".to_string()),
        contract_hash: Some("wit".to_string()),
        resource_hashes: BTreeMap::new(),
        contracts: vec![contract],
    }
}

/// Records only the exact inspection and never treats a changed schema as authorized.
#[test]
fn records_only_exact_inspection() {
    let directory = temporary_directory();
    let inspection = make_inspection(32);
    let authorization =
        PluginAuthorizationRecord::from_inspection(&inspection, SwiftDate(5.0 - 978_307_200.0))
            .expect("authorization");
    let store = EditorPluginAuthorizationStore::new(&directory);
    assert!(store.authorization(&inspection).is_none());

    store.record(&authorization).expect("record");
    assert_eq!(
        store.authorization(&inspection),
        Some(authorization.clone())
    );
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(&store.storage_url)
            .expect("storage")
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(mode, 0o600);
    }

    let reopened = EditorPluginAuthorizationStore::new(&directory);
    assert_eq!(reopened.authorization(&inspection), Some(authorization));
    assert!(reopened.authorization(&make_inspection(64)).is_none());
    let _ = std::fs::remove_dir_all(directory);
}

/// Corrupt or preseeded duplicate storage fails closed.
#[test]
fn corrupt_or_duplicate_storage_fails_closed() {
    let directory = temporary_directory();
    let cove = directory.join(".cove");
    std::fs::create_dir_all(&cove).expect("cove directory");
    let inspection = make_inspection(32);
    let authorization = PluginAuthorizationRecord::from_inspection(&inspection, SwiftDate::now())
        .expect("authorization");
    let value = serde_json::to_value(&authorization).expect("record value");
    let document = serde_json::json!({
        "format_version": 1,
        "records": [value.clone(), value],
    });
    std::fs::write(
        cove.join("plugin_authorizations.json"),
        serde_json::to_vec(&document).expect("document"),
    )
    .expect("write storage");

    let store = EditorPluginAuthorizationStore::new(&directory);
    assert!(store.all_records().is_empty());
    assert!(store.authorization(&inspection).is_none());
    assert!(store.load_warning.is_some());
    assert!(!store.storage_url.exists());
    let quarantined: Vec<PathBuf> = std::fs::read_dir(&cove)
        .expect("cove entries")
        .filter_map(|entry| entry.ok().map(|entry| entry.path()))
        .collect();
    assert!(quarantined.iter().any(|path| {
        path.file_name()
            .map(|name| {
                name.to_string_lossy()
                    .starts_with("plugin_authorizations.corrupt-")
            })
            .unwrap_or(false)
            && path
                .extension()
                .is_some_and(|extension| extension == "json")
    }));
    let _ = std::fs::remove_dir_all(directory);
}

/// Unknown storage format is quarantined instead of silently discarded.
#[test]
fn unknown_storage_format_is_quarantined() {
    let directory = temporary_directory();
    let cove = directory.join(".cove");
    std::fs::create_dir_all(&cove).expect("cove directory");
    let storage_url = cove.join("plugin_authorizations.json");
    std::fs::write(&storage_url, r#"{"format_version":2,"records":[]}"#).expect("storage");

    let store = EditorPluginAuthorizationStore::new(&directory);

    assert!(store.all_records().is_empty());
    assert!(
        store
            .load_warning
            .as_deref()
            .is_some_and(|warning| warning.contains("unsupported format version 2"))
    );
    assert!(!storage_url.exists());
    let _ = std::fs::remove_dir_all(directory);
}
