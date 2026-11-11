//! Ported from `Engine/Tests/AIRuntimeTests/CapabilityExposureTests.swift`.
//!
//! Swift's `URLProtocol` mocks become the loopback `FixtureHttpServer`; the
//! request assertions that lived in the protocol subclass run on the test
//! thread against the recorded bodies so a failed expectation surfaces as a
//! test failure rather than a client-side transport error.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;

use diffuse_capability::capability_contract::{
    CapabilityAccess, CapabilityContract, CapabilityExposurePolicy, CapabilityExposureSnapshot,
    CapabilitySource, PluginCapabilityAuthority, ReleasePhase,
};
use diffuse_capability::capability_registry::CapabilityRegistry;
use diffuse_capability::capsule_schema::{
    self, validate_capability_input, JsonSchemaScalar, JsonSchemaType,
};
use diffuse_capability::contracts::exports::SessionApiFormat;
use diffuse_capability::support::swift_date::SwiftDate;
use diffuse_intent::capabilities::built_in_typed_capabilities::{
    SetNameCapability, SetTransformCapability,
};
use diffuse_intent::planning::intent_ir::IntentSource;
use diffuse_intent::transactions::transaction_executor::{
    TransactionExecutionContext, TransactionExecutor,
};
use diffuse_intent::transactions::transaction_ir::{
    SceneMutation, TransactionApprovalPolicy, TransactionOperation,
    TransactionVerificationAssertion,
};
use diffuse_intent::{BuiltInTypedCapabilityCatalog, CapabilityInvocationContext, CoveCapability};
use diffuse_math::simd::simd_compat::{Float3, Float4, Float4x4};
use diffuse_plugin::base64_data::Data;
use diffuse_plugin::contract::plugin_manifest::CovePluginManifest;
use diffuse_plugin::contribution::ai::tool::{AIToolContribution, AIToolContributionPoint};
use diffuse_plugin::contribution::registry::ContributionDescriptor;
use diffuse_plugin::host::host_capability_call::HostCapabilityCall;
use diffuse_plugin::host::plugin_host_rpc::{
    PluginCapabilityInvoking, PluginPreparedCapabilityResult, PluginQuerySnapshot,
};
use diffuse_plugin::plugin_authorization::{
    PluginAuthorizationRecord, PluginExecutionBinding, PluginInspection,
};
use diffuse_scene::components::core::registry::{
    ComponentCategory, ComponentDecodeContext, ComponentEncodeContext, ComponentRegistry,
    ComponentSchema,
};
use diffuse_scene::components::core::value::ComponentValue;
use diffuse_scene::components::editing::ComponentWriteMode;
use diffuse_scene::components::inspection::inspection::{ComponentDescription, ComponentFieldKind};
use diffuse_scene::entity_id::{EntityID, RuntimeComponent};
use diffuse_scene::media::animation::AnimationPlayer;
use diffuse_scene::media::audio::AudioSource;
use diffuse_scene::physics::collider::{Collider, ColliderShape};
use diffuse_scene::physics::rigid_body::{RigidBody, RigidBodyMotionType};
use diffuse_scene::rendering::render_extraction::{
    CameraComponent, LightComponent, LightType, RenderMaterialComponent, RenderMeshComponent,
};
use diffuse_scene::runtime_world::{LocalTransform, RuntimeWorld};
use diffuse_scene::scene_runtime::SceneRuntime;
use diffuse_script::core::script_component::{
    ScriptBinding, ScriptBindingID, ScriptComponent, ScriptHandle,
};
use serde_json::Value;

use crate::planning::capability_draft_pipeline::{CapabilityDraftError, CapabilityDraftStore};
use crate::planning::scene_edit_plan::{SceneEditOp, SceneEditPlan};
use crate::planning::scene_edit_plan_executor::{
    SceneEditPlanExecutor, SceneEditPlanExecutorError,
};
use crate::session::session::Session;
use crate::session::session_config::SessionConfig;
use crate::session::signal::Signal;
use crate::tests::ai_runtime::component_mutation_test_support::DecodedComponent;
use crate::tests::ai_runtime::fixture_http::{FixtureHttpServer, FixtureResponse};
use crate::tools::capability_exposure_session_store::{
    CapabilityExposureSessionError, CapabilityExposureSessionStore,
    CapabilityExposureSessionStoreError,
};
use crate::tools::capability_toolset::CapabilityToolset;
use crate::tools::plugin_capability_executor::{
    PluginCapabilityExecutionFailure, PluginCapabilityExecutor, PluginCapabilityExecutorError,
};

// MARK: - Helpers

/// Swift's `Set(someStrings)` for the exposure APIs' `Set<String>` parameter.
fn included_ids(values: &[&str]) -> BTreeSet<String> {
    values.iter().map(|value| (*value).to_string()).collect()
}

fn no_authorities() -> BTreeMap<String, PluginCapabilityAuthority> {
    BTreeMap::new()
}

/// `CapabilityRegistry.exposureSnapshot(sceneRevision:includedCapabilityIDs:)`
/// with the registry's default policy.
fn exposure_snapshot(
    registry: &CapabilityRegistry,
    policy: &CapabilityExposurePolicy,
    scene_revision: Option<u64>,
    included: Option<&BTreeSet<String>>,
    authorities: &BTreeMap<String, PluginCapabilityAuthority>,
) -> CapabilityExposureSnapshot {
    let preferred: Vec<String> = included
        .map(|ids| ids.iter().cloned().collect())
        .unwrap_or_default();
    registry.exposure_snapshot(policy, scene_revision, 0, &preferred, included, authorities)
}

/// `CapabilityRegistry.aiDefault.exposureSnapshot(…)`.
fn ai_exposure_snapshot(
    scene_revision: Option<u64>,
    capabilities: &[&str],
) -> CapabilityExposureSnapshot {
    let ids = included_ids(capabilities);
    exposure_snapshot(
        &BuiltInTypedCapabilityCatalog::registry(),
        &CapabilityExposurePolicy::default(),
        scene_revision,
        Some(&ids),
        &no_authorities(),
    )
}

/// Swift's `LocalTransform(translation:)` — identity rotation and scale.
fn translation_transform(translation: Float3) -> LocalTransform {
    let mut matrix = Float4x4::from_scalar(1.0);
    matrix.set_column(
        3,
        Float4::new(translation.x, translation.y, translation.z, 1.0),
    );
    LocalTransform::new(matrix)
}

fn entity_ref(entity: EntityID) -> String {
    format!("scene:{}", entity.raw_value())
}

fn decode_plan(json: &str) -> SceneEditPlan {
    serde_json::from_str(json).expect("decode scene edit plan")
}

fn try_build(
    plan: &SceneEditPlan,
    scene: &SceneRuntime,
    snapshot: &CapabilityExposureSnapshot,
) -> Result<diffuse_intent::transactions::transaction_ir::TransactionIR, SceneEditPlanExecutorError>
{
    SceneEditPlanExecutor::new().build_transaction(
        plan,
        scene,
        None,
        TransactionApprovalPolicy::Automatic,
        Some(snapshot),
        &BuiltInTypedCapabilityCatalog::registry(),
    )
}

fn build_with_exposure(
    plan: &SceneEditPlan,
    scene: &SceneRuntime,
    snapshot: &CapabilityExposureSnapshot,
) -> diffuse_intent::transactions::transaction_ir::TransactionIR {
    try_build(plan, scene, snapshot).expect("build transaction")
}

fn draft_error(error: CapabilityExposureSessionStoreError) -> CapabilityDraftError {
    match error {
        CapabilityExposureSessionStoreError::Draft(error) => error,
        other => panic!("expected a capability draft error, got {other:?}"),
    }
}

fn new_session_id() -> String {
    diffuse_kernel::codable::new_uuid()
}

// MARK: - Tests

#[test]
fn open_ai_responses_uses_generated_contracts() {
    let server = FixtureHttpServer::start_with(|_, body| {
        let body: Value = serde_json::from_slice(body).expect("decode request body");
        assert!(body["instructions"].is_string());
        let input = body["input"].as_array().expect("input array");
        assert!(input.iter().all(Value::is_object));
        let tools = body["tools"].as_array().expect("tools array");
        assert!(tools.iter().all(|tool| tool["type"] == "function"));
        assert!(tools
            .iter()
            .any(|tool| tool["name"] == CapabilityToolset::SEARCH_TOOL_NAME));
        FixtureResponse::json(
            serde_json::json!({
                "output": [{
                    "type": "function_call",
                    "call_id": "call_responses_1",
                    "name": "execute_edit_plan",
                    "arguments": "{\"summary\":\"No changes\",\"steps\":[]}",
                }],
            })
            .to_string()
            .into_bytes(),
        )
    });
    let session = Session::new(
        None,
        SessionConfig::new_with_defaults(
            "test",
            "fixture",
            server.base_url(),
            SessionApiFormat::OpenAiResponses,
        ),
        None,
        None,
        None,
        None,
        None,
        None,
        None,
    );

    let proposal = session
        .process_with_defaults(&Signal::NaturalLanguage {
            text: "Inspect the scene".to_string(),
            locale: "en".to_string(),
        })
        .expect("proposal");

    assert_eq!(proposal.plan.summary, "No changes");
    assert_eq!(server.request_path(0), "/v1/responses");
}

#[test]
fn all_scene_operations_have_contracts() {
    let registry = BuiltInTypedCapabilityCatalog::registry();
    for operation in SceneEditOp::ALL {
        let descriptor = registry
            .descriptor(operation.capability_id())
            .unwrap_or_else(|| {
                panic!("missing capability for {}", operation.raw_value());
            });
        assert!(descriptor.is_ai_exposed);
        assert_eq!(
            descriptor.contract().input_schema.additional_properties,
            Some(false)
        );
        assert!(
            !descriptor.access.is_write()
                || descriptor
                    .contract()
                    .input_schema
                    .is_strict_capability_input()
        );
        assert!(!descriptor.contract().schema_hash.is_empty());
        if descriptor.access.is_write() {
            let registration =
                BuiltInTypedCapabilityCatalog::registration(operation.capability_id())
                    .unwrap_or_else(|| {
                        panic!(
                            "AI write capability {} has no typed preparation",
                            operation.capability_id()
                        )
                    });
            assert_eq!(registration.contract, descriptor.contract());
        }
    }
    registry.validate_integrity().expect("registry integrity");
}

#[test]
fn schema_hash_binds_constraints() {
    let contract = |maximum: f64| {
        CapabilityContract::new(
            "test.range",
            1,
            "Range",
            "Test",
            "test",
            CapabilityAccess::Read,
            ReleasePhase::Stable,
            capsule_schema::object(
                BTreeMap::from([(
                    "value".to_string(),
                    capsule_schema::number(None, Some(0.0), Some(maximum)),
                )]),
                vec!["value".to_string()],
                None,
                false,
            ),
            CapabilitySource::BUILTIN,
            None,
        )
    };
    let original = contract(1.0);
    let changed = contract(2.0);
    assert_ne!(original.schema_hash, changed.schema_hash);
    assert_ne!(original.tool_name(), changed.tool_name());
}

#[test]
fn draft_creation_is_side_effect_free() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let revision = scene.snapshot().revision;
    let snapshot = ai_exposure_snapshot(Some(revision), &["scene.set_transform"]);
    let contract = snapshot
        .contract("scene.set_transform")
        .expect("set_transform contract")
        .clone();
    let input = serde_json::to_vec(&serde_json::json!({
        "entity_id": entity_ref(entity),
        "position": [1, 2, 3],
    }))
    .expect("encode input");
    let store = CapabilityDraftStore::default();
    let now = SwiftDate::now();
    let draft = store
        .create_draft(&contract.tool_name(), &input, &snapshot, revision, now)
        .expect("create draft");

    assert_eq!(scene.snapshot().revision, revision);
    assert_eq!(draft.capability_id, "scene.set_transform");
    let duplicate = store
        .validated_drafts(
            &[draft.id.clone(), draft.id.clone()],
            &snapshot,
            revision,
            now,
        )
        .expect_err("duplicate draft ids");
    assert_eq!(
        duplicate,
        CapabilityDraftError::DuplicateDraftID(draft.id.clone())
    );
    store
        .validated_drafts(
            std::slice::from_ref(&draft.id),
            &snapshot,
            revision + 1,
            now,
        )
        .expect_err("stale scene revision");

    let mut expired_snapshot = snapshot.clone();
    expired_snapshot.created_at = SwiftDate(now.0 - 301.0);
    let stale = store
        .create_draft(
            &contract.tool_name(),
            &input,
            &expired_snapshot,
            revision,
            now,
        )
        .expect_err("expired snapshot");
    assert_eq!(stale, CapabilityDraftError::StaleSnapshot);
}

#[test]
fn optional_schema_decoder_consistency() {
    #[derive(serde::Deserialize)]
    struct OptionalInput {
        required: String,
        optional: Option<String>,
    }

    let schema = capsule_schema::object(
        BTreeMap::from([
            (
                "required".to_string(),
                capsule_schema::string(None, None, None),
            ),
            (
                "optional".to_string(),
                capsule_schema::string(None, None, None),
            ),
        ]),
        vec!["required".to_string()],
        None,
        false,
    );
    let value: Value = serde_json::from_str(r#"{"required":"value","optional":null}"#).unwrap();
    validate_capability_input(&value, &schema).expect("schema accepts null");
    let decoded: OptionalInput = serde_json::from_value(value).expect("decode optional input");
    assert_eq!(decoded.required, "value");
    assert!(decoded.optional.is_none());
}

#[test]
fn forged_tool_name_fails_closed() {
    let snapshot = ai_exposure_snapshot(Some(0), &["scene.set_name"]);
    let input = serde_json::to_vec(&serde_json::json!({
        "entity_id": "scene:1",
        "name": "Forged",
    }))
    .expect("encode input");
    let store = CapabilityDraftStore::default();
    let error = store
        .create_draft(
            "cap_scene_set_name_v1_forged",
            &input,
            &snapshot,
            0,
            SwiftDate::now(),
        )
        .expect_err("forged tool name");
    assert_eq!(
        error,
        CapabilityDraftError::UnknownTool("cap_scene_set_name_v1_forged".to_string())
    );
}

#[test]
fn exposure_session_expansion_preserves_draft_authority() {
    let session_id = new_session_id();
    let sessions = CapabilityExposureSessionStore::new();
    let first = sessions
        .search_with_defaults(&session_id, "rename entity", 9)
        .expect("first search");
    let rename = first
        .contracts
        .iter()
        .find(|contract| contract.id == "scene.set_name")
        .expect("rename contract")
        .clone();
    let draft = sessions
        .create_draft_with_defaults(
            &session_id,
            &rename.tool_name(),
            br#"{"entity_id":"scene:1","name":"Renamed"}"#,
            9,
        )
        .expect("create draft");

    let second = sessions
        .search_with_defaults(&session_id, "transform", 9)
        .expect("second search");
    assert_eq!(second.snapshot_id, first.snapshot_id);
    assert!(second
        .contracts
        .iter()
        .any(|contract| contract.id == "scene.set_transform"));
    let (submitted, snapshot) = sessions
        .validated_drafts_with_defaults(&session_id, std::slice::from_ref(&draft.id), 9)
        .expect("validated drafts");
    assert_eq!(submitted, vec![draft.clone()]);
    assert_eq!(snapshot.id, first.snapshot_id);

    sessions
        .search_with_defaults(&session_id, "rename", 10)
        .expect("revision change");
    let error = sessions
        .validated_drafts_with_defaults(&session_id, std::slice::from_ref(&draft.id), 10)
        .expect_err("stale draft");
    draft_error(error);
}

#[test]
fn exposure_session_bootstrap_is_bounded() {
    let session_id = new_session_id();
    let sessions = CapabilityExposureSessionStore::new();
    let initial = sessions
        .bootstrap_with_defaults(&session_id, 4)
        .expect("bootstrap");
    let initial_ids: BTreeSet<&str> = initial
        .contracts
        .iter()
        .map(|contract| contract.id.as_str())
        .collect();
    assert_eq!(
        initial_ids,
        BTreeSet::from([
            "scene.get_entities",
            "scene.get_selection",
            "scene.find_entities",
        ])
    );
    assert!(initial
        .contracts
        .iter()
        .all(|contract| contract.access == CapabilityAccess::Read));

    let expanded = sessions
        .search_with_defaults(&session_id, "scene", 4)
        .expect("expanded search");
    assert_eq!(expanded.snapshot_id, initial.snapshot_id);
    assert!(
        expanded.active_contracts.len()
            <= CapabilityExposureSessionStore::MAXIMUM_ACTIVE_CAPABILITIES
    );
    assert_eq!(expanded.active_tool_count, expanded.active_contracts.len());
    let active_ids: BTreeSet<&str> = expanded
        .active_contracts
        .iter()
        .map(|contract| contract.id.as_str())
        .collect();
    assert!(initial_ids.is_subset(&active_ids));

    let error = sessions
        .contract_with_defaults(&session_id, "cap_scene_set_name_v1_forged", 4)
        .expect_err("forged tool");
    assert_eq!(
        draft_error(error),
        CapabilityDraftError::UnknownTool("cap_scene_set_name_v1_forged".to_string())
    );
}

#[test]
fn typed_built_in_primitive_is_authoritative() {
    let registry = BuiltInTypedCapabilityCatalog::registry();
    for registration in BuiltInTypedCapabilityCatalog::registrations() {
        let exposed = registry
            .descriptor(&registration.contract.id)
            .expect("registered capability")
            .contract();
        assert_eq!(exposed, registration.contract);
        assert_eq!(exposed.input_schema.additional_properties, Some(false));
    }
    let name_schema = SetNameCapability::contract()
        .input_schema
        .properties
        .get("name")
        .cloned()
        .expect("name property");
    assert_eq!(name_schema.minimum_length, Some(1));
    assert_eq!(name_schema.maximum_length, Some(256));
    let invalid: Value = serde_json::from_str(r#"{"entity_id":"scene:1","name":""}"#).unwrap();
    assert!(
        validate_capability_input(&invalid, &SetNameCapability::contract().input_schema).is_err()
    );

    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let snapshot = ai_exposure_snapshot(Some(scene.snapshot().revision), &["scene.set_name"]);
    let plan = decode_plan(&format!(
        r#"{{"summary":"Rename","steps":[{{"op":"set_name","entity_id":"{}","name":"Typed"}}]}}"#,
        entity_ref(entity)
    ));
    let transaction = build_with_exposure(&plan, &scene, &snapshot);

    assert_eq!(
        transaction.operations,
        vec![
            diffuse_intent::transactions::transaction_ir::TransactionOperation::Scene(
                SceneMutation::SetSceneName {
                    entity_id: entity.raw_value(),
                    value: "Typed".to_string(),
                }
            )
        ]
    );
    assert_eq!(
        transaction
            .capability_invocations
            .first()
            .map(|record| record.schema_hash.clone()),
        Some(SetNameCapability::contract().schema_hash)
    );
}

#[test]
fn typed_scene_utilities_are_authoritative() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let parent = scene.create_entity();
    let entity = scene.create_entity();
    let _ = scene.set_local_transform(translation_transform(Float3::new(1.0, 5.0, 3.0)), entity);
    let _ = scene.set_component(
        RenderMeshComponent::new(0, true, Float3::ONE, None, Vec::new()),
        entity,
    );
    let _ = scene.set_component(
        AudioSource::new("ambience", 0.25, 0.8, true, false, 0.4),
        entity,
    );
    let _ = scene.set_component(
        AnimationPlayer::new(Some("Idle".to_string()), 0.5, true, true, 0.0),
        entity,
    );
    let _ = scene.set_component(
        ScriptComponent::new(vec![ScriptBinding::new(
            ScriptHandle::new(7),
            ScriptBindingID::new(),
            None,
            true,
            r#"{"existing":1}"#,
        )]),
        entity,
    );
    let capabilities = [
        "scene.spawn_entity",
        "scene.snap_to_ground",
        "scene.set_mesh_color",
        "scene.set_mesh_visibility",
        "scene.set_audio_source",
        "scene.set_animation_player",
        "scene.set_script_property",
        "scene.set_script_bindings",
    ];
    let snapshot = ai_exposure_snapshot(Some(scene.snapshot().revision), &capabilities);
    let plan = decode_plan(&format!(
        r#"{{
          "summary":"Typed utilities",
          "steps":[
            {{"op":"spawn_entity","label":"Key Light","spawn_kind":"light","spawn_parent_id":"{}","light_type":"spot","intensity":12,"color":[1,0.5,0.25]}},
            {{"op":"snap_to_ground","entity_id":"{entity}"}},
            {{"op":"set_mesh_color","entity_id":"{entity}","color":[0.2,0.3,0.4]}},
            {{"op":"set_mesh_visibility","entity_id":"{entity}","is_visible":false}},
            {{"op":"set_audio_source","entity_id":"{entity}","audio_pitch":2}},
            {{"op":"set_animation_player","entity_id":"{entity}","animation_is_playing":false}},
            {{"op":"set_script_property","entity_id":"{entity}","script_index":0,"script_property_name":"mode","script_property_value":[1,true,"safe"]}},
            {{"op":"set_script_enabled","entity_id":"{entity}","script_index":0,"is_enabled":false}}
          ]
        }}"#,
        entity_ref(parent),
        entity = entity_ref(entity),
    ));
    let transaction = build_with_exposure(&plan, &scene, &snapshot);

    assert_eq!(transaction.operations.len(), 8);
    let invoked: Vec<&str> = transaction
        .capability_invocations
        .iter()
        .map(|record| record.capability_id.as_str())
        .collect();
    assert_eq!(invoked, capabilities);

    let diffuse_intent::transactions::transaction_ir::TransactionOperation::Scene(
        SceneMutation::SpawnLightEntity {
            label,
            light_type,
            initial_intensity,
            initial_color,
            parent_id,
            ..
        },
    ) = &transaction.operations[0]
    else {
        panic!("expected spawn light operation");
    };
    assert_eq!(label, "Key Light");
    assert_eq!(*light_type, LightType::Spot);
    assert_eq!(*initial_intensity, Some(12.0));
    assert_eq!(*initial_color, Some(Float3::new(1.0, 0.5, 0.25)));
    assert_eq!(*parent_id, Some(parent.raw_value()));

    let diffuse_intent::transactions::transaction_ir::TransactionOperation::Scene(
        SceneMutation::SetLocalTransform { transform, .. },
    ) = &transaction.operations[1]
    else {
        panic!("expected grounded transform");
    };
    assert_eq!(transform.matrix.columns[3].x, 1.0);
    assert_eq!(transform.matrix.columns[3].y, 0.0);
    assert_eq!(transform.matrix.columns[3].z, 3.0);

    let (_, audio) = transaction.operations[4]
        .decoded_component::<AudioSource>("audioSource")
        .expect("audio source component");
    assert_eq!(audio.clip_name, "ambience");
    assert_eq!(audio.volume, 0.25);
    assert_eq!(audio.pitch, 2.0);

    let (_, animation) = transaction.operations[5]
        .decoded_component::<AnimationPlayer>("animationPlayer")
        .expect("animation player component");
    assert_eq!(animation.clip_name.as_deref(), Some("Idle"));
    assert_eq!(animation.speed, 0.5);
    assert!(animation.loop_);
    assert!(!animation.is_playing);

    let (_, scripts) = transaction.operations[7]
        .decoded_component::<ScriptComponent>("script")
        .expect("script component");
    assert_eq!(scripts.bindings.len(), 1);
    assert!(!scripts.bindings[0].is_enabled);
    let parameters: Value =
        serde_json::from_str(&scripts.bindings[0].parameters_json).expect("script parameters");
    assert_eq!(parameters["existing"].as_i64(), Some(1));
    assert_eq!(
        parameters["mode"].as_array().map(|values| values.len()),
        Some(3)
    );

    let script_property_contract =
        BuiltInTypedCapabilityCatalog::registration("scene.set_script_property")
            .expect("script property capability")
            .contract;
    let script_index_schema = script_property_contract
        .input_schema
        .properties
        .get("script_index")
        .cloned()
        .expect("script_index property");
    let integer_schema = script_index_schema
        .one_of
        .iter()
        .find(|schema| schema.r#type == Some(JsonSchemaType::Integer))
        .expect("integer script_index alternative");
    assert_eq!(integer_schema.maximum, Some(255.0));

    let unsafe_value: Value = serde_json::from_str(
        r#"{"entity_id":"scene:1","script_property_name":"unsafe","script_property_value":{"arbitrary":true}}"#,
    )
    .unwrap();
    assert!(
        validate_capability_input(&unsafe_value, &script_property_contract.input_schema).is_err()
    );
}

#[test]
fn typed_transform_uses_value_only_shadow_state() {
    let contract = SetTransformCapability::contract();
    assert_eq!(contract.input_schema.additional_properties, Some(false));
    assert_eq!(
        contract.input_schema.required,
        vec!["entity_id".to_string()]
    );
    let scale_schema = contract
        .input_schema
        .properties
        .get("scale")
        .cloned()
        .expect("scale property");
    let scale_array = scale_schema
        .one_of
        .iter()
        .find(|schema| schema.r#type == Some(JsonSchemaType::Array))
        .expect("scale array alternative");
    let scale_items = scale_array.items.as_deref().expect("scale items");
    assert_eq!(scale_items.minimum, Some(0.001));
    assert_eq!(scale_items.maximum, Some(1000.0));

    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let _ = scene.set_local_transform(translation_transform(Float3::new(1.0, 2.0, 3.0)), entity);
    let snapshot = ai_exposure_snapshot(Some(scene.snapshot().revision), &["scene.set_transform"]);
    let plan = decode_plan(&format!(
        r#"{{"summary":"Transform","steps":[{{"op":"set_transform","entity_id":"{entity}","position":[10,20,30]}},{{"op":"set_transform","entity_id":"{entity}","scale":[2,3,4]}}]}}"#,
        entity = entity_ref(entity),
    ));
    let transaction = build_with_exposure(&plan, &scene, &snapshot);

    assert_eq!(transaction.operations.len(), 2);
    let diffuse_intent::transactions::transaction_ir::TransactionOperation::Scene(
        SceneMutation::SetLocalTransform { transform, .. },
    ) = &transaction.operations[1]
    else {
        panic!("expected set transform operation");
    };
    assert_eq!(transform.matrix.columns[3].x, 10.0);
    assert_eq!(transform.matrix.columns[3].y, 20.0);
    assert_eq!(transform.matrix.columns[3].z, 30.0);
    assert_eq!(
        transform.matrix.columns[0].xyz(),
        Float3::new(2.0, 0.0, 0.0)
    );
    assert_eq!(
        transform.matrix.columns[1].xyz(),
        Float3::new(0.0, 3.0, 0.0)
    );
    assert_eq!(
        transform.matrix.columns[2].xyz(),
        Float3::new(0.0, 0.0, 4.0)
    );
    assert!(transaction
        .capability_invocations
        .iter()
        .all(|record| { record.schema_hash == SetTransformCapability::contract().schema_hash }));

    let zero_scale: Value =
        serde_json::from_str(r#"{"entity_id":"scene:1","scale":[0,1,1]}"#).unwrap();
    assert!(validate_capability_input(&zero_scale, &contract.input_schema).is_err());

    let empty_plan = decode_plan(&format!(
        r#"{{"summary":"No fields","steps":[{{"op":"set_transform","entity_id":"{}"}}]}}"#,
        entity_ref(entity)
    ));
    assert!(SceneEditPlanExecutor::new()
        .build_transaction(
            &empty_plan,
            &scene,
            None,
            TransactionApprovalPolicy::Automatic,
            Some(&snapshot),
            &BuiltInTypedCapabilityCatalog::registry(),
        )
        .is_err());
}

#[test]
fn typed_light_capabilities_prepare_host_operations() {
    let light_type_contract = BuiltInTypedCapabilityCatalog::registration("scene.set_light_type")
        .expect("set light type capability")
        .contract;
    let type_schema = light_type_contract
        .input_schema
        .properties
        .get("light_type")
        .cloned()
        .expect("light_type property");
    assert_eq!(
        type_schema.allowed_values,
        vec![
            JsonSchemaScalar::String("directional".to_string()),
            JsonSchemaScalar::String("point".to_string()),
            JsonSchemaScalar::String("spot".to_string()),
        ]
    );
    let light_color_contract = BuiltInTypedCapabilityCatalog::registration("scene.set_light_color")
        .expect("set light color capability")
        .contract;
    let color_schema = light_color_contract
        .input_schema
        .properties
        .get("color")
        .cloned()
        .expect("color property");
    let color_items = color_schema.items.as_deref().expect("color items");
    assert_eq!(color_items.minimum, Some(0.0));
    assert_eq!(color_items.maximum, Some(1.0));

    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let light = scene.create_entity();
    let _ = scene.set_component(
        LightComponent::new(
            LightType::Point,
            Float3::new(1.0, 1.0, 1.0),
            1.0,
            10.0,
            0.0,
            30.0,
            false,
        ),
        light,
    );
    let capability_ids = [
        "scene.set_light_type",
        "scene.set_light_intensity",
        "scene.set_light_color",
        "scene.set_light_range",
        "scene.set_light_spot_angles",
        "scene.set_light_cast_shadows",
    ];
    let snapshot = ai_exposure_snapshot(Some(scene.snapshot().revision), &capability_ids);
    let reference = entity_ref(light);
    let plan = decode_plan(&format!(
        r#"{{
          "summary":"Configure light",
          "steps":[
            {{"op":"set_light_type","entity_id":"{reference}","light_type":"spot"}},
            {{"op":"set_light_intensity","entity_id":"{reference}","intensity":250}},
            {{"op":"set_light_color","entity_id":"{reference}","color":[0.2,0.4,0.6]}},
            {{"op":"set_light_range","entity_id":"{reference}","range":15}},
            {{"op":"set_light_spot_angles","entity_id":"{reference}","spot_inner_angle":15,"spot_outer_angle":25}},
            {{"op":"set_light_cast_shadows","entity_id":"{reference}","light_cast_shadows":true}}
          ]
        }}"#
    ));
    let transaction = build_with_exposure(&plan, &scene, &snapshot);

    let raw = light.raw_value();
    assert_eq!(
        transaction.operations,
        vec![
            TransactionOperation::Scene(SceneMutation::component_fields(
                raw,
                "light",
                [(
                    "type".to_string(),
                    Some(ComponentValue::String("spot".to_string())),
                )],
            )),
            TransactionOperation::Scene(SceneMutation::component_fields(
                raw,
                "light",
                [("intensity".to_string(), Some(ComponentValue::Number(250.0)),)],
            )),
            TransactionOperation::Scene(SceneMutation::component_fields(
                raw,
                "light",
                [(
                    "color".to_string(),
                    Some(ComponentValue::Array(vec![
                        ComponentValue::Number(f64::from(0.2_f32)),
                        ComponentValue::Number(f64::from(0.4_f32)),
                        ComponentValue::Number(f64::from(0.6_f32)),
                    ])),
                )],
            )),
            TransactionOperation::Scene(SceneMutation::component_fields(
                raw,
                "light",
                [("range".to_string(), Some(ComponentValue::Number(15.0)),)],
            )),
            TransactionOperation::Scene(SceneMutation::component_fields(
                raw,
                "light",
                [(
                    "spotOuterAngleDegrees".to_string(),
                    Some(ComponentValue::Number(25.0)),
                )],
            )),
            TransactionOperation::Scene(SceneMutation::component_fields(
                raw,
                "light",
                [(
                    "spotInnerAngleDegrees".to_string(),
                    Some(ComponentValue::Number(15.0)),
                )],
            )),
            TransactionOperation::Scene(SceneMutation::component_fields(
                raw,
                "light",
                [("castShadows".to_string(), Some(ComponentValue::Bool(true)),)],
            )),
        ]
    );
    let invoked: Vec<&str> = transaction
        .capability_invocations
        .iter()
        .map(|record| record.capability_id.as_str())
        .collect();
    assert_eq!(invoked, capability_ids);
    assert!(transaction.verification_assertions.contains(
        &TransactionVerificationAssertion::ComponentData {
            entity_id: raw,
            type_id: "light".to_string(),
            value: ComponentValue::Object(BTreeMap::from([(
                "spotOuterAngleDegrees".to_string(),
                ComponentValue::Number(25.0),
            )])),
            mode: ComponentWriteMode::Merge,
        }
    ));
    assert!(transaction.verification_assertions.contains(
        &TransactionVerificationAssertion::ComponentData {
            entity_id: raw,
            type_id: "light".to_string(),
            value: ComponentValue::Object(BTreeMap::from([(
                "spotInnerAngleDegrees".to_string(),
                ComponentValue::Number(15.0),
            )])),
            mode: ComponentWriteMode::Merge,
        }
    ));

    let mut context = TransactionExecutionContext {
        scene_runtime: Some(scene.clone()),
        ..Default::default()
    };
    TransactionExecutor::new()
        .apply(&transaction, &mut context)
        .expect("apply light transaction");
    let applied = context
        .scene_runtime
        .as_ref()
        .and_then(|scene| scene.component::<LightComponent>(light));
    assert_eq!(
        applied,
        Some(LightComponent::new(
            LightType::Spot,
            Float3::new(0.2, 0.4, 0.6),
            250.0,
            15.0,
            15.0,
            25.0,
            true,
        ))
    );

    let invalid_angle_plan = decode_plan(&format!(
        r#"{{"summary":"Invalid spot angle","steps":[{{"op":"set_light_spot_angles","entity_id":"{reference}","spot_inner_angle":40}}]}}"#
    ));
    assert!(try_build(&invalid_angle_plan, &scene, &snapshot).is_err());

    let non_light = scene.create_entity();
    let invalid_target_plan = decode_plan(&format!(
        r#"{{"summary":"Invalid target","steps":[{{"op":"set_light_intensity","entity_id":"{}","intensity":1}}]}}"#,
        entity_ref(non_light)
    ));
    assert!(try_build(&invalid_target_plan, &scene, &snapshot).is_err());

    let invalid_angles_plan = decode_plan(&format!(
        r#"{{"summary":"Invalid angles","steps":[{{"op":"set_light_spot_angles","entity_id":"{reference}","spot_inner_angle":60,"spot_outer_angle":30}}]}}"#
    ));
    assert!(try_build(&invalid_angles_plan, &scene, &snapshot).is_err());
}

#[test]
fn typed_camera_capabilities_prepare_host_operations() {
    let fov_contract = BuiltInTypedCapabilityCatalog::registration("scene.set_camera_fov")
        .expect("set camera fov capability")
        .contract;
    let fov_schema = fov_contract
        .input_schema
        .properties
        .get("camera_fov_y")
        .cloned()
        .expect("camera_fov_y property");
    assert_eq!(fov_schema.minimum, Some(1.0));
    assert_eq!(fov_schema.maximum, Some(179.0));

    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let camera = scene.create_entity();
    let _ = scene.set_component(
        CameraComponent::new(
            Float3::ZERO,
            Float3::new(0.0, 1.0, 0.0),
            1.0,
            1.0,
            0.1,
            100.0,
            true,
        ),
        camera,
    );
    let capability_ids = [
        "scene.set_camera_pose",
        "scene.set_camera_fov",
        "scene.set_camera_aspect_ratio",
        "scene.set_camera_active",
    ];
    let snapshot = ai_exposure_snapshot(Some(scene.snapshot().revision), &capability_ids);
    let reference = entity_ref(camera);
    let plan = decode_plan(&format!(
        r#"{{
          "summary":"Configure camera",
          "steps":[
            {{"op":"set_camera_pose","entity_id":"{reference}","position":[4,3,2],"camera_target":[0,0,0],"camera_up":[0,1,0]}},
            {{"op":"set_camera_fov","entity_id":"{reference}","camera_fov_y":70}},
            {{"op":"set_camera_aspect_ratio","entity_id":"{reference}","camera_aspect_ratio":1.777}},
            {{"op":"set_camera_active","entity_id":"{reference}","camera_is_active":false}}
          ]
        }}"#
    ));
    let transaction = build_with_exposure(&plan, &scene, &snapshot);

    assert_eq!(transaction.operations.len(), 5);
    let expected_hashes: Vec<String> = capability_ids
        .iter()
        .map(|id| {
            BuiltInTypedCapabilityCatalog::registration(id)
                .expect("camera capability")
                .contract
                .schema_hash
                .clone()
        })
        .collect();
    let actual_hashes: Vec<String> = transaction
        .capability_invocations
        .iter()
        .map(|record| record.schema_hash.clone())
        .collect();
    assert_eq!(actual_hashes, expected_hashes);

    let TransactionOperation::Scene(SceneMutation::SetLocalTransform { transform, .. }) =
        &transaction.operations[0]
    else {
        panic!("expected typed setCameraPose operation");
    };
    assert_eq!(
        transform.matrix.columns[3].xyz(),
        Float3::new(4.0, 3.0, 2.0)
    );
    let (_, decoded) = transaction.operations[1]
        .decoded_component::<CameraComponent>("camera")
        .expect("camera component");
    assert_eq!(decoded.target, Float3::ZERO);
    assert_eq!(decoded.up, Float3::new(0.0, 1.0, 0.0));

    let coincident = decode_plan(&format!(
        r#"{{"summary":"Invalid camera","steps":[{{"op":"set_camera_pose","entity_id":"{reference}","position":[1,1,1],"camera_target":[1,1,1]}}]}}"#
    ));
    assert!(try_build(&coincident, &scene, &snapshot).is_err());

    let non_camera = scene.create_entity();
    let wrong_target = decode_plan(&format!(
        r#"{{"summary":"Wrong target","steps":[{{"op":"set_camera_fov","entity_id":"{}","camera_fov_y":60}}]}}"#,
        entity_ref(non_camera)
    ));
    assert!(try_build(&wrong_target, &scene, &snapshot).is_err());
}

#[test]
fn typed_material_uses_value_only_shadow_state() {
    let material_contract = BuiltInTypedCapabilityCatalog::registration("scene.set_material")
        .expect("set material capability")
        .contract;
    let base_color_schema = material_contract
        .input_schema
        .properties
        .get("material_base_color")
        .cloned()
        .expect("material_base_color property");
    let base_color_array = base_color_schema
        .one_of
        .iter()
        .find(|schema| schema.r#type == Some(JsonSchemaType::Array))
        .expect("base color array alternative");
    let base_color_items = base_color_array.items.as_deref().expect("base color items");
    assert_eq!(base_color_items.minimum, Some(0.0));
    assert_eq!(base_color_items.maximum, Some(1.0));

    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let _ = scene.set_component(
        RenderMaterialComponent::new(
            Float4::new(0.2, 0.4, 0.6, 1.0),
            None,
            None,
            0.3,
            0.8,
            Float3::new(0.1, 0.2, 0.3),
            None,
            None,
            None,
        ),
        entity,
    );
    let snapshot = ai_exposure_snapshot(Some(scene.snapshot().revision), &["scene.set_material"]);
    let reference = entity_ref(entity);
    let plan = decode_plan(&format!(
        r#"{{"summary":"Update material","steps":[{{"op":"set_material","entity_id":"{reference}","material_roughness":0.2}},{{"op":"set_material","entity_id":"{reference}","material_metallic":0.9}}]}}"#
    ));
    let transaction = build_with_exposure(&plan, &scene, &snapshot);

    assert_eq!(transaction.operations.len(), 2);
    let (_, material) = transaction.operations[1]
        .decoded_component::<RenderMaterialComponent>("renderMaterial")
        .expect("second typed material operation");
    assert_eq!(material.base_color_factor, Float4::new(0.2, 0.4, 0.6, 1.0));
    assert!((material.metallic_factor - 0.9).abs() < 0.001);
    assert!((material.roughness_factor - 0.2).abs() < 0.001);
    assert_eq!(material.emissive_factor, Float3::new(0.1, 0.2, 0.3));

    let empty_plan = decode_plan(&format!(
        r#"{{"summary":"No-op material","steps":[{{"op":"set_material","entity_id":"{reference}"}}]}}"#
    ));
    assert!(try_build(&empty_plan, &scene, &snapshot).is_err());
}

#[test]
fn typed_physics_capabilities_use_sequential_copies() {
    let physics_ids = [
        "scene.set_rigid_body_motion_type",
        "scene.set_rigid_body_mass",
        "scene.set_rigid_body_gravity_scale",
        "scene.set_rigid_body_allow_sleep",
        "scene.set_collider_shape",
        "scene.set_collider_box_extents",
        "scene.set_collider_sphere_radius",
        "scene.set_collider_capsule",
        "scene.set_collider_material",
        "scene.set_collider_trigger",
        "scene.set_collider_layer",
    ];
    let physics: BTreeSet<String> = included_ids(&physics_ids);
    let migrated: BTreeSet<String> = BuiltInTypedCapabilityCatalog::registrations()
        .iter()
        .map(|registration| registration.contract.id.clone())
        .collect();
    assert!(physics.is_subset(&migrated));

    let stable_snapshot = ai_exposure_snapshot(None, &physics_ids);
    assert!(stable_snapshot.contracts.is_empty());

    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let mut policy = CapabilityExposurePolicy::new(ReleasePhase::Beta);
    policy.maximum_capabilities = 32;
    let snapshot = exposure_snapshot(
        &BuiltInTypedCapabilityCatalog::registry(),
        &policy,
        Some(scene.snapshot().revision),
        Some(&physics),
        &no_authorities(),
    );
    let snapshot_ids: BTreeSet<String> = snapshot
        .contracts
        .iter()
        .map(|contract| contract.id.clone())
        .collect();
    assert_eq!(snapshot_ids, physics);

    let reference = entity_ref(entity);
    let plan = decode_plan(&format!(
        r#"{{
          "summary":"Configure physics",
          "steps":[
            {{"op":"set_rigidbody_motion","entity_id":"{reference}","motion_type":"kinematic"}},
            {{"op":"set_rigidbody_mass","entity_id":"{reference}","mass":12}},
            {{"op":"set_collider_trigger","entity_id":"{reference}","is_trigger":true}},
            {{"op":"set_collider_sphere_radius","entity_id":"{reference}","radius":2}}
          ]
        }}"#
    ));
    let transaction = build_with_exposure(&plan, &scene, &snapshot);

    assert_eq!(transaction.operations.len(), 4);
    let (_, body) = transaction.operations[1]
        .decoded_component::<RigidBody>("rigidbody")
        .expect("typed rigid body replacement");
    assert_eq!(body.motion_type, RigidBodyMotionType::Kinematic);
    assert!((body.mass - 12.0).abs() < 0.001);
    let (_, collider) = transaction.operations[3]
        .decoded_component::<Collider>("collider")
        .expect("typed collider replacement");
    assert!(collider.is_trigger);
    match collider.shape() {
        ColliderShape::Sphere { radius, .. } => assert!((radius - 2.0).abs() < 0.001),
        other => panic!("expected the sequential collider state to be a sphere, got {other:?}"),
    }

    let mut context = TransactionExecutionContext {
        scene_runtime: Some(scene.clone()),
        ..Default::default()
    };
    TransactionExecutor::new()
        .apply(&transaction, &mut context)
        .expect("apply physics transaction");
    let applied_scene = context.scene_runtime.as_ref().expect("scene runtime");
    let applied_body = applied_scene
        .component::<RigidBody>(entity)
        .expect("applied rigid body");
    assert_eq!(applied_body.motion_type, RigidBodyMotionType::Kinematic);
    assert_eq!(applied_body.mass, 12.0);
    let applied_collider = applied_scene
        .component::<Collider>(entity)
        .expect("applied collider");
    assert!(applied_collider.is_trigger);
    match applied_collider.shape() {
        ColliderShape::Sphere { radius, .. } => assert_eq!(radius, 2.0),
        other => panic!("expected verified sphere collider state, got {other:?}"),
    }

    let mass_contract = BuiltInTypedCapabilityCatalog::registration("scene.set_rigid_body_mass")
        .expect("set rigid body mass capability")
        .contract;
    let zero_mass: Value = serde_json::from_str(r#"{"entity_id":"scene:1","mass":0}"#).unwrap();
    assert!(validate_capability_input(&zero_mass, &mass_contract.input_schema).is_err());

    let no_fields = decode_plan(&format!(
        r#"{{"summary":"Invalid material","steps":[{{"op":"set_collider_material","entity_id":"{reference}"}}]}}"#
    ));
    assert!(try_build(&no_fields, &scene, &snapshot).is_err());
}

#[test]
fn transaction_carries_explicit_authority() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let snapshot = ai_exposure_snapshot(Some(scene.snapshot().revision), &["scene.set_name"]);
    let plan = decode_plan(&format!(
        r#"{{"summary":"Rename","steps":[{{"op":"set_name","entity_id":"{}","name":"Renamed"}}]}}"#,
        entity_ref(entity)
    ));
    let transaction = SceneEditPlanExecutor::new()
        .build_transaction(
            &plan,
            &scene,
            Some(scene.snapshot().revision),
            TransactionApprovalPolicy::Automatic,
            Some(&snapshot),
            &BuiltInTypedCapabilityCatalog::registry(),
        )
        .expect("build transaction");

    assert_eq!(transaction.capability_invocations.len(), 1);
    assert_eq!(
        transaction.capability_invocations[0].capability_id,
        "scene.set_name"
    );
    assert_eq!(
        transaction.capability_invocations[0].exposure_snapshot_id,
        snapshot.id
    );
    assert!(transaction.verification_assertions.contains(
        &TransactionVerificationAssertion::EntityExists(entity.raw_value())
    ));
}

#[test]
fn parameter_repair_is_bounded() {
    let server = FixtureHttpServer::start_with(|index, body| {
        let value: Value = serde_json::from_slice(body).expect("decode request body");
        let (tool_name, arguments) = if index == 0 {
            (
                CapabilityToolset::SEARCH_TOOL_NAME.to_string(),
                r#"{"query":"rename entity"}"#.to_string(),
            )
        } else {
            let tools = value["tools"].as_array().expect("tools array");
            let tool_name = tools
                .iter()
                .filter_map(|tool| tool["name"].as_str())
                .find(|name| name.contains("scene_set_name"))
                .expect("rename tool registration")
                .to_string();
            (
                tool_name,
                r#"{"entity_id":"forged","name":"Bad"}"#.to_string(),
            )
        };
        FixtureResponse::json(
            serde_json::json!({
                "output": [{
                    "type": "function_call",
                    "call_id": format!("invalid_{index}"),
                    "name": tool_name,
                    "arguments": arguments,
                }],
            })
            .to_string()
            .into_bytes(),
        )
    });
    let session = Session::new(
        None,
        SessionConfig::new_with_defaults(
            "test",
            "fixture",
            server.base_url(),
            SessionApiFormat::OpenAiResponses,
        ),
        None,
        None,
        None,
        None,
        None,
        None,
        None,
    );

    let error = session
        .process_with_defaults(&Signal::NaturalLanguage {
            text: "Rename the entity".to_string(),
            locale: "en".to_string(),
        })
        .expect_err("parameter repair is bounded");
    assert!(matches!(
        error,
        crate::session::session::SessionError::Draft(_)
    ));
    assert_eq!(server.requests().len(), 4);
}

#[test]
fn typed_preparation_uses_sequential_shadow_scene() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let snapshot = ai_exposure_snapshot(
        Some(scene.snapshot().revision),
        &["scene.delete_entity", "scene.set_name"],
    );
    let plan = decode_plan(&format!(
        r#"{{"summary":"Stale preparation","steps":[{{"op":"delete_entity","entity_id":"{}"}},{{"op":"set_name","entity_id":"{}","name":"Gone"}}]}}"#,
        entity_ref(entity),
        entity_ref(entity),
    ));
    assert!(try_build(&plan, &scene, &snapshot).is_err());
}

// MARK: - Plugin helpers

struct PluginSetup {
    binding: PluginExecutionBinding,
    contract: CapabilityContract,
}

fn make_plugin_binding(
    plugin_id: &str,
    capability_name: &str,
    access: CapabilityAccess,
    composable_host_capabilities: &[&str],
    host_generation: u64,
) -> PluginSetup {
    let mut contributes = ContributionDescriptor::default();
    contributes
        .set::<AIToolContributionPoint>(&[AIToolContribution::new(
            capability_name,
            "Test Capability",
            "Test WIT-derived capability",
        )])
        .expect("declare tool contribution");
    let manifest = CovePluginManifest::new(
        plugin_id,
        1,
        "Test plugin",
        "Bounded test plugin",
        access,
        Vec::new(),
        composable_host_capabilities
            .iter()
            .map(|value| (*value).to_string())
            .collect(),
        Vec::new(),
        Default::default(),
        contributes,
    );
    let contract = CapabilityContract::new(
        format!("{plugin_id}.{capability_name}"),
        1,
        "Test Capability",
        "Test WIT-derived capability",
        "plugin",
        access,
        ReleasePhase::Stable,
        capsule_schema::object(
            BTreeMap::from([(
                "entity_id".to_string(),
                capsule_schema::string(None, None, None),
            )]),
            vec!["entity_id".to_string()],
            None,
            false,
        ),
        CapabilitySource::plugin(plugin_id),
        None,
    );
    let inspection = PluginInspection::new(
        manifest,
        Some("component-hash".to_string()),
        Some("wit-hash".to_string()),
        vec![contract.clone()],
    );
    let authorization = PluginAuthorizationRecord::from_inspection(&inspection, SwiftDate(1.0))
        .expect("authorise plugin");
    let binding = PluginExecutionBinding::new(
        format!("tmp/{plugin_id}.coveplugin"),
        inspection,
        authorization,
        host_generation,
    )
    .expect("plugin execution binding");
    PluginSetup { binding, contract }
}

struct StubPluginInvoker {
    generation: std::sync::Mutex<u64>,
    result: PluginPreparedCapabilityResult,
}

impl StubPluginInvoker {
    fn new(generation: u64, result: PluginPreparedCapabilityResult) -> Self {
        StubPluginInvoker {
            generation: std::sync::Mutex::new(generation),
            result,
        }
    }

    fn set_generation(&self, value: u64) {
        *self.generation.lock().expect("invoker generation") = value;
    }
}

impl PluginCapabilityInvoking for StubPluginInvoker {
    fn generation(&self) -> u64 {
        *self.generation.lock().expect("invoker generation")
    }

    fn prepare_capability(
        &self,
        _binding: &PluginExecutionBinding,
        _capability_id: &str,
        _input: &[u8],
        _query_snapshot: Option<&PluginQuerySnapshot>,
    ) -> Result<PluginPreparedCapabilityResult, diffuse_plugin::PluginError> {
        Ok(self.result.clone())
    }
}

fn plugin_executor(
    setup: &PluginSetup,
    invoker: Arc<StubPluginInvoker>,
) -> PluginCapabilityExecutor {
    PluginCapabilityExecutor::new(
        &BuiltInTypedCapabilityCatalog::registry(),
        vec![setup.binding.clone()],
        std::slice::from_ref(&setup.binding.inspection),
        invoker,
    )
    .expect("plugin capability executor")
}

fn plugin_sessions(executor: &PluginCapabilityExecutor) -> CapabilityExposureSessionStore {
    CapabilityExposureSessionStore::with_configuration(
        executor.registry.clone(),
        CapabilityDraftStore::DEFAULT_TTL,
        executor.exposure_policy(),
        executor.plugin_authorities.clone(),
        None,
    )
}

// MARK: - Plugin tests

#[test]
fn plugin_write_uses_unified_draft_and_transaction_pipeline() {
    let setup = make_plugin_binding(
        "safe.layout",
        "rename-selected",
        CapabilityAccess::ReversibleWrite,
        &["scene.set_name"],
        7,
    );
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let revision = scene.snapshot().revision;
    let host_arguments = format!(
        r#"{{"entity_id":"scene:{}","name":"Plugin Rename"}}"#,
        entity.raw_value()
    );
    let invoker = Arc::new(StubPluginInvoker::new(
        7,
        PluginPreparedCapabilityResult::HostCalls(vec![HostCapabilityCall::new(
            "scene.set_name",
            1,
            host_arguments.into_bytes(),
        )]),
    ));
    let executor = plugin_executor(&setup, invoker.clone());
    let sessions = plugin_sessions(&executor);
    let session_id = new_session_id();
    let activation = sessions
        .search(
            &session_id,
            "rename",
            Some("plugin"),
            None,
            revision,
            SwiftDate::now(),
        )
        .expect("plugin search");
    let contract = activation
        .contracts
        .iter()
        .find(|contract| contract.id == setup.contract.id)
        .expect("plugin contract")
        .clone();
    let draft = sessions
        .create_draft_with_defaults(
            &session_id,
            &contract.tool_name(),
            format!(r#"{{"entity_id":"scene:{}"}}"#, entity.raw_value()).as_bytes(),
            revision,
        )
        .expect("plugin draft");
    assert_eq!(draft.plugin_authority, Some(setup.binding.authority()));
    let validated = sessions
        .validated_drafts_with_defaults(&session_id, std::slice::from_ref(&draft.id), revision)
        .expect("validated drafts");

    let transaction = executor
        .build_transaction_with_defaults(
            "Plugin rename",
            &validated.0,
            &validated.1,
            &scene,
            revision,
        )
        .expect("plugin transaction");
    assert_eq!(
        transaction.operations,
        vec![TransactionOperation::Scene(SceneMutation::SetSceneName {
            entity_id: entity.raw_value(),
            value: "Plugin Rename".to_string(),
        })]
    );
    let invoked: Vec<&str> = transaction
        .capability_invocations
        .iter()
        .map(|record| record.capability_id.as_str())
        .collect();
    assert_eq!(invoked, vec![setup.contract.id.as_str(), "scene.set_name"]);
    assert_eq!(
        transaction.capability_invocations[0]
            .source_plugin_id
            .as_deref(),
        Some("safe.layout")
    );
    assert_eq!(
        transaction.capability_invocations[0].plugin_authority,
        Some(setup.binding.authority())
    );
    assert_eq!(transaction.capability_invocations[1].source_plugin_id, None);
    assert!(transaction.verification_assertions.contains(
        &TransactionVerificationAssertion::EntityExists(entity.raw_value())
    ));

    let planner = executor.make_invocation_planner_with_defaults();
    let context = CapabilityInvocationContext::from_scene_runtime(
        &scene,
        None,
        true,
        IntentSource::System,
        1.0,
        Vec::new(),
    );
    let planned = planner
        .plan(&transaction, &context)
        .expect("invocation plan");
    assert_eq!(
        planned.approval_policy,
        TransactionApprovalPolicy::RequiresApproval
    );

    invoker.set_generation(8);
    assert!(planner.plan(&transaction, &context).is_err());
    let error = executor
        .build_transaction_with_defaults("Stale", &validated.0, &validated.1, &scene, revision)
        .expect_err("changed plugin authority");
    assert!(matches!(
        error,
        PluginCapabilityExecutionFailure::Executor(
            PluginCapabilityExecutorError::AuthorityChanged(plugin_id)
        ) if plugin_id == "safe.layout"
    ));

    sessions.replace_plugin_authorities(
        BTreeMap::from([(
            "safe.layout".to_string(),
            PluginCapabilityAuthority::new(
                "safe.layout".to_string(),
                setup.binding.authorization.authority_digest().to_string(),
                8,
            ),
        )]),
        &included_ids(&["safe.layout"]),
    );
    assert!(matches!(
        sessions.validated_drafts_with_defaults(
            &session_id,
            std::slice::from_ref(&draft.id),
            revision
        ),
        Err(CapabilityExposureSessionStoreError::Session(
            CapabilityExposureSessionError::SessionNotFound
        ))
    ));
}

#[test]
fn plugin_read_is_immediate_bounded_context() {
    let setup = make_plugin_binding("safe.reader", "inspect", CapabilityAccess::Read, &[], 3);
    let invoker = Arc::new(StubPluginInvoker::new(
        3,
        PluginPreparedCapabilityResult::Read(br#"{"finding":"ok"}"#.to_vec()),
    ));
    let executor = plugin_executor(&setup, invoker);
    let revision = 41;
    let snapshot = exposure_snapshot(
        &executor.registry,
        &executor.exposure_policy(),
        Some(revision),
        Some(&included_ids(&[&setup.contract.id])),
        &executor.plugin_authorities,
    );
    let output = executor
        .execute_read_with_defaults(
            &setup.contract.tool_name(),
            br#"{"entity_id":"scene:1"}"#,
            &snapshot,
            revision,
        )
        .expect("plugin read");
    assert_eq!(output, Data::from_bytes(br#"{"finding":"ok"}"#.to_vec()));

    let invalid_invoker = Arc::new(StubPluginInvoker::new(
        3,
        PluginPreparedCapabilityResult::Read(b"not-json".to_vec()),
    ));
    let invalid_executor = plugin_executor(&setup, invalid_invoker);
    let error = invalid_executor
        .execute_read_with_defaults(
            &setup.contract.tool_name(),
            br#"{"entity_id":"scene:1"}"#,
            &snapshot,
            revision,
        )
        .expect_err("invalid read result");
    assert!(matches!(
        error,
        PluginCapabilityExecutionFailure::Executor(
            PluginCapabilityExecutorError::InvalidReadResult(capability_id)
        ) if capability_id == setup.contract.id
    ));
}

#[test]
fn dynamic_registry_replacement_scopes_invalidation() {
    let mut plugin_policy = CapabilityExposurePolicy::new(ReleasePhase::Stable);
    plugin_policy.allowed_domains = Some(included_ids(&["scene", "plugin"]));
    plugin_policy.enabled_plugin_ids = included_ids(&["safe.dynamic"]);
    let sessions = CapabilityExposureSessionStore::with_configuration(
        BuiltInTypedCapabilityCatalog::registry(),
        CapabilityDraftStore::DEFAULT_TTL,
        plugin_policy.clone(),
        no_authorities(),
        None,
    );
    let session_id = new_session_id();
    let activation = sessions
        .search_with_defaults(&session_id, "rename", 12)
        .expect("initial search");
    let rename = activation
        .contracts
        .iter()
        .find(|contract| contract.id == "scene.set_name")
        .expect("rename contract")
        .clone();
    let old_draft = sessions
        .create_draft_with_defaults(
            &session_id,
            &rename.tool_name(),
            br#"{"entity_id":"scene:1","name":"Old"}"#,
            12,
        )
        .expect("old draft");

    let setup = make_plugin_binding(
        "safe.dynamic",
        "arrange",
        CapabilityAccess::ReversibleWrite,
        &["scene.set_name"],
        4,
    );
    let invoker = Arc::new(StubPluginInvoker::new(
        4,
        PluginPreparedCapabilityResult::HostCalls(vec![HostCapabilityCall::new(
            "scene.set_name",
            1,
            br#"{"entity_id":"scene:1","name":"New"}"#.to_vec(),
        )]),
    ));
    let executor = plugin_executor(&setup, invoker);
    sessions.replace_registry(
        executor.registry.clone(),
        plugin_policy.clone(),
        executor.plugin_authorities.clone(),
    );

    let survivors = sessions
        .validated_drafts_with_defaults(&session_id, std::slice::from_ref(&old_draft.id), 12)
        .expect("built-in draft survives");
    assert_eq!(survivors.0, vec![old_draft.clone()]);
    let plugin_activation = sessions
        .search(
            &session_id,
            "arrange",
            Some("plugin"),
            None,
            12,
            SwiftDate::now(),
        )
        .expect("plugin search");
    assert_eq!(
        plugin_activation
            .contracts
            .iter()
            .map(|contract| contract.id.clone())
            .collect::<Vec<String>>(),
        vec![setup.contract.id.clone()]
    );
    let plugin_draft = sessions
        .create_draft_with_defaults(
            &session_id,
            &setup.contract.tool_name(),
            br#"{"entity_id":"scene:1"}"#,
            12,
        )
        .expect("plugin draft");
    let combined = sessions
        .validated_drafts_with_defaults(
            &session_id,
            &[old_draft.id.clone(), plugin_draft.id.clone()],
            12,
        )
        .expect("combined drafts");
    assert_eq!(combined.0, vec![old_draft.clone(), plugin_draft.clone()]);
    let snapshot = sessions
        .snapshot_with_defaults(&session_id, 12)
        .expect("session snapshot");
    assert_eq!(
        snapshot.authority("safe.dynamic"),
        Some(&setup.binding.authority())
    );

    sessions.replace_plugin_authorities(
        BTreeMap::from([(
            setup.binding.plugin_id().to_string(),
            setup.binding.authority(),
        )]),
        &included_ids(&[setup.binding.plugin_id()]),
    );
    sessions
        .snapshot_with_defaults(&session_id, 12)
        .expect("identical authority keeps session");

    let built_in_only_session_id = new_session_id();
    sessions
        .bootstrap_with_defaults(&built_in_only_session_id, 12)
        .expect("built-in bootstrap");

    let mut revoked = plugin_policy;
    revoked.enabled_plugin_ids = BTreeSet::new();
    sessions.replace_registry(
        BuiltInTypedCapabilityCatalog::registry(),
        revoked,
        no_authorities(),
    );
    assert!(matches!(
        sessions.snapshot_with_defaults(&session_id, 12),
        Err(CapabilityExposureSessionStoreError::Session(
            CapabilityExposureSessionError::SessionNotFound
        ))
    ));
    sessions
        .snapshot_with_defaults(&built_in_only_session_id, 12)
        .expect("built-in session survives");
}

#[test]
fn changed_built_in_contract_invalidates_session() {
    let sessions = CapabilityExposureSessionStore::new();
    let session_id = new_session_id();
    sessions
        .bootstrap_with_defaults(&session_id, 1)
        .expect("bootstrap");
    let mut policy = CapabilityExposurePolicy::new(ReleasePhase::Stable);
    policy.allowed_domains = Some(included_ids(&["scene"]));
    sessions.replace_registry(
        CapabilityRegistry::new(Vec::new()),
        policy,
        no_authorities(),
    );
    assert!(matches!(
        sessions.snapshot_with_defaults(&session_id, 1),
        Err(CapabilityExposureSessionStoreError::Session(
            CapabilityExposureSessionError::SessionNotFound
        ))
    ));
}

#[test]
fn session_returns_plugin_draft_proposal() {
    let setup = make_plugin_binding(
        "safe.session",
        "arrange",
        CapabilityAccess::ReversibleWrite,
        &["scene.set_name"],
        5,
    );
    let invoker = Arc::new(StubPluginInvoker::new(
        5,
        PluginPreparedCapabilityResult::HostCalls(vec![HostCapabilityCall::new(
            "scene.set_name",
            1,
            br#"{"entity_id":"scene:1","name":"Arranged"}"#.to_vec(),
        )]),
    ));
    let executor = plugin_executor(&setup, invoker);
    let plugin_tool_name = setup.contract.tool_name();
    let server = FixtureHttpServer::start_with(move |index, body| {
        let value: Value = serde_json::from_slice(body).expect("decode request body");
        let call = match index {
            0 => serde_json::json!({
                "type": "function_call",
                "call_id": "plugin_search",
                "name": CapabilityToolset::SEARCH_TOOL_NAME,
                "arguments": r#"{"query":"arrange","domain":"plugin"}"#,
            }),
            1 => {
                let tools = value["tools"].as_array().expect("tools array");
                assert!(tools
                    .iter()
                    .any(|tool| tool["name"] == plugin_tool_name.as_str()));
                serde_json::json!({
                    "type": "function_call",
                    "call_id": "plugin_draft",
                    "name": plugin_tool_name,
                    "arguments": r#"{"entity_id":"scene:1"}"#,
                })
            }
            _ => {
                let inputs = value["input"].as_array().expect("input array");
                let draft_id = inputs
                    .iter()
                    .rev()
                    .filter(|item| item["type"] == "function_call_output")
                    .filter_map(|item| item["output"].as_str())
                    .filter_map(|output| serde_json::from_str::<Value>(output).ok())
                    .find_map(|object| object["draft_id"].as_str().map(str::to_string))
                    .expect("plugin draft id");
                serde_json::json!({
                    "type": "function_call",
                    "call_id": "plugin_submit",
                    "name": CapabilityToolset::SUBMIT_TOOL_NAME,
                    "arguments": serde_json::json!({
                        "summary": "Arrange selection",
                        "draft_ids": [draft_id],
                    })
                    .to_string(),
                })
            }
        };
        FixtureResponse::json(
            serde_json::json!({ "output": [call] })
                .to_string()
                .into_bytes(),
        )
    });
    let session = Session::new(
        None,
        SessionConfig::new_with_defaults(
            "test",
            "fixture",
            server.base_url(),
            SessionApiFormat::OpenAiResponses,
        ),
        None,
        None,
        None,
        None,
        Some(executor),
        None,
        None,
    );

    let proposal = session
        .process_with_defaults(&Signal::NaturalLanguage {
            text: "Arrange with the plugin".to_string(),
            locale: "en".to_string(),
        })
        .expect("proposal");
    assert_eq!(proposal.plan.summary, "Arrange selection");
    assert!(proposal.plan.steps.is_empty());
    assert_eq!(proposal.capability_drafts.len(), 1);
    assert_eq!(
        proposal.capability_drafts[0].capability_id,
        setup.contract.id
    );
    assert_eq!(
        proposal.capability_drafts[0].plugin_authority,
        Some(setup.binding.authority())
    );
    assert_eq!(
        proposal
            .capability_exposure_snapshot
            .as_ref()
            .and_then(|snapshot| snapshot.authority("safe.session")),
        Some(&setup.binding.authority())
    );
    assert_eq!(server.request_path(2), "/v1/responses");
    assert_eq!(server.requests().len(), 3);
}

#[derive(Clone, Debug, PartialEq)]
struct DescriptionFlag {
    enabled: bool,
}

impl RuntimeComponent for DescriptionFlag {}

fn encode_description_flag(
    world: &RuntimeWorld,
    entity: EntityID,
    _context: &mut ComponentEncodeContext,
) -> Option<ComponentValue> {
    world.component::<DescriptionFlag>(entity).map(|flag| {
        ComponentValue::Object(BTreeMap::from([(
            "enabled".to_string(),
            ComponentValue::Bool(flag.enabled),
        )]))
    })
}

fn decode_description_flag(
    value: &ComponentValue,
    entity: EntityID,
    _context: &mut ComponentDecodeContext,
    world: &mut RuntimeWorld,
) {
    let ComponentValue::Object(fields) = value else {
        return;
    };
    let Some(ComponentValue::Bool(enabled)) = fields.get("enabled") else {
        return;
    };
    let _ = world.set_component(DescriptionFlag { enabled: *enabled }, entity);
}

#[test]
fn component_descriptions_read() {
    let mut registry = ComponentRegistry::built_in();
    registry.register(ComponentSchema::for_component::<DescriptionFlag>(
        "test.described",
        "Described flag",
        ComponentCategory::Gameplay,
        encode_description_flag,
        decode_description_flag,
        |entity, world| {
            let _ = world.set_component(DescriptionFlag { enabled: true }, entity);
        },
    ));
    let scene = SceneRuntime::new(registry.clone());
    let described_registry = registry;
    let describe_contract = BuiltInTypedCapabilityCatalog::registry()
        .descriptor("scene.describe_components")
        .expect("describe contract")
        .contract()
        .clone();
    assert_eq!(describe_contract.access, CapabilityAccess::Read);
    let describe_tool_name = describe_contract.tool_name();

    let server = FixtureHttpServer::start_with(move |index, body| {
        let value: Value = serde_json::from_slice(body).expect("decode request body");
        let call = match index {
            0 => serde_json::json!({
                "type": "function_call",
                "call_id": "describe_search",
                "name": CapabilityToolset::SEARCH_TOOL_NAME,
                "arguments": r#"{"query":"describe components","domain":"scene","access":"read"}"#,
            }),
            1 => {
                let tools = value["tools"].as_array().expect("tools array");
                assert!(tools
                    .iter()
                    .any(|tool| tool["name"] == describe_tool_name.as_str()));
                serde_json::json!({
                    "type": "function_call",
                    "call_id": "describe_read",
                    "name": describe_tool_name,
                    "arguments": r#"{"type_id":"test.described"}"#,
                })
            }
            _ => {
                let inputs = value["input"].as_array().expect("input array");
                let output = inputs
                    .iter()
                    .rev()
                    .find(|item| item["type"] == "function_call_output")
                    .and_then(|item| item["output"].as_str())
                    .expect("component description output");
                let descriptions: Vec<ComponentDescription> =
                    serde_json::from_str(output).expect("decode component descriptions");
                assert_eq!(descriptions.len(), 1);
                assert_eq!(descriptions[0].type_id, "test.described");
                assert_eq!(
                    descriptions[0].defaults,
                    Some(ComponentValue::Object(BTreeMap::from([(
                        "enabled".to_string(),
                        ComponentValue::Bool(true),
                    )])))
                );
                assert_eq!(
                    descriptions[0].fields.first().map(|field| field.kind),
                    Some(ComponentFieldKind::Boolean)
                );
                serde_json::json!({
                    "type": "function_call",
                    "call_id": "describe_submit",
                    "name": CapabilityToolset::SUBMIT_TOOL_NAME,
                    "arguments": r#"{"summary":"Read component descriptions","draft_ids":[]}"#,
                })
            }
        };
        FixtureResponse::json(
            serde_json::json!({ "output": [call] })
                .to_string()
                .into_bytes(),
        )
    });
    let session = Session::new(
        None,
        SessionConfig::new_with_defaults(
            "test",
            "fixture",
            server.base_url(),
            SessionApiFormat::OpenAiResponses,
        ),
        None,
        None,
        None,
        None,
        None,
        None,
        None,
    );
    session.set_component_description_provider(Some(Arc::new(move |type_id| {
        SceneRuntime::new(described_registry.clone()).component_descriptions(type_id)
    })));

    let proposal = session
        .process_with_defaults(&Signal::NaturalLanguage {
            text: "Describe the component fields".to_string(),
            locale: "en".to_string(),
        })
        .expect("proposal");
    assert!(proposal.capability_drafts.is_empty());
    assert!(proposal.plan.steps.is_empty());
    assert_eq!(server.requests().len(), 3);
    assert!(scene.entities().is_empty());
}
