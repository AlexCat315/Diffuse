//! Ported from `Engine/Tests/AIRuntimeTests/WorkflowScopeTests.swift`.

use std::collections::{BTreeMap, BTreeSet};

use diffuse_capability::capability_contract::{CapabilityExposurePolicy, ReleasePhase};
use diffuse_capability::support::swift_date::SwiftDate;
use diffuse_intent::BuiltInTypedCapabilityCatalog;
use diffuse_plugin::uuid::Uuid;

use crate::context::asset_workflow_context::AssetWorkflowContext;
use crate::context::workflow_context::WorkflowContext;
use crate::planning::capability_draft_pipeline::CapabilityDraftStore;
use crate::tools::capability_exposure_session_store::{
    CapabilityExposureSessionError, CapabilityExposureSessionStore,
    CapabilityExposureSessionStoreError,
};

fn policy(domains: &[&str], ids: Option<BTreeSet<String>>) -> CapabilityExposurePolicy {
    let mut policy = CapabilityExposurePolicy::new(ReleasePhase::Stable);
    policy.allowed_domains = Some(domains.iter().map(|domain| domain.to_string()).collect());
    policy.allowed_capability_ids = ids;
    policy
}

fn store(policy: &CapabilityExposurePolicy) -> CapabilityExposureSessionStore {
    CapabilityExposureSessionStore::with_configuration(
        BuiltInTypedCapabilityCatalog::registry(),
        CapabilityDraftStore::DEFAULT_TTL,
        policy.clone(),
        BTreeMap::new(),
        None,
    )
}

fn misdirected(result: Result<impl Sized, CapabilityExposureSessionStoreError>) -> bool {
    matches!(
        result,
        Err(CapabilityExposureSessionStoreError::Session(
            CapabilityExposureSessionError::SessionNotFound
        ))
    )
}

/// `MCP capability search preserves workflow restrictions and never widens domains`
#[test]
fn bounded_discovery() {
    let ids: BTreeSet<String> = [
        "scene.get_entities",
        "scene.get_selection",
        "scene.find_entities",
        "scene.set_name",
    ]
    .iter()
    .map(|id| id.to_string())
    .collect();
    let policy = policy(&["scene"], Some(ids.clone()));
    let store = store(&policy);
    let document_id = Uuid::new();
    let session_id = Uuid::new().as_str().to_string();
    store.set_workflow_scope(&policy, &document_id);
    store
        .bootstrap(&session_id, 7, SwiftDate::now())
        .expect("the session bootstraps");

    let scripts = store
        .search(
            &session_id,
            "script",
            Some("scene"),
            None,
            7,
            SwiftDate::now(),
        )
        .expect("the search succeeds");
    assert!(scripts.contracts.is_empty());

    let renamed = store
        .search(
            &session_id,
            "set_name",
            Some("scene"),
            None,
            7,
            SwiftDate::now(),
        )
        .expect("the search succeeds");
    assert!(
        renamed
            .contracts
            .iter()
            .any(|contract| contract.id == "scene.set_name")
    );
    assert!(
        renamed
            .active_contracts
            .iter()
            .all(|contract| ids.contains(&contract.id))
    );

    let other_domain = store
        .search(&session_id, "", Some("asset"), None, 7, SwiftDate::now())
        .expect("the search succeeds");
    assert!(other_domain.contracts.is_empty());
}

/// `Changing workflow or replacing an equal-revision document invalidates old tools`
#[test]
fn invalidated_authority() {
    let policy = policy(&["scene"], None);
    let store = store(&policy);
    let document = Uuid::new();
    let id = Uuid::new().as_str().to_string();
    store.set_workflow_scope(&policy, &document);
    let initial = store
        .bootstrap(&id, 1, SwiftDate::now())
        .expect("the session bootstraps");

    store.set_workflow_scope(&policy, &document);
    assert_eq!(
        store
            .snapshot(&id, 1, SwiftDate::now())
            .expect("an unchanged scope keeps the session")
            .id,
        initial.snapshot_id
    );

    let mut restricted = policy;
    restricted.allowed_capability_ids =
        Some(["scene.get_entities".to_string()].into_iter().collect());
    store.set_workflow_scope(&restricted, &document);
    assert!(misdirected(store.snapshot(&id, 1, SwiftDate::now())));

    store
        .bootstrap(&id, 1, SwiftDate::now())
        .expect("the session bootstraps again");
    store.set_workflow_scope(&restricted, &Uuid::new());
    assert!(misdirected(store.snapshot(&id, 1, SwiftDate::now())));
}

/// `Asset creation context has its own serialization and no fabricated sequence`
#[test]
fn asset_workflow() {
    let context = WorkflowContext::Asset(AssetWorkflowContext::new(
        "Create a reusable prop".to_string(),
    ));
    let data = serde_json::to_vec(&context).expect("the context serializes");
    let decoded: WorkflowContext = serde_json::from_slice(&data).expect("the context decodes");
    assert_eq!(decoded, context);
    assert!(!String::from_utf8_lossy(&data).contains("activeSequenceID"));
}
