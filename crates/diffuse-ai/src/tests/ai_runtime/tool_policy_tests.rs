//! Ported from `Engine/Tests/AIRuntimeTests/ToolPolicyTests.swift`.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;

use diffuse_capability::capability_contract::{CapabilityExposurePolicy, ReleasePhase};
use diffuse_capability::contracts::exports::SessionApiFormat;
use diffuse_intent::BuiltInTypedCapabilityCatalog;
use diffuse_plugin::base64_data::Data;

use crate::planning::capability_draft_pipeline::CapabilityDraftStore;
use crate::session::session::Session;
use crate::session::session_config::SessionConfig;
use crate::session::signal::Signal;
use crate::tests::ai_runtime::fixture_http::FixtureHttpServer;
use crate::tools::capability_exposure_session_store::{
    CapabilityExposureSessionStore, CapabilityExposureSessionStoreError,
};
use crate::tools::capability_toolset::CapabilityToolset;
use crate::tools::tool_policy::{
    ToolCall, ToolCallOrigin, ToolPolicy, ToolPolicyDecision, ToolPolicyDenial,
    ToolPolicyDenialCode, ToolPolicyError,
};

fn responses_call(id: &str, name: &str, arguments: &str) -> Vec<u8> {
    serde_json::json!({
        "output": [{
            "type": "function_call",
            "call_id": id,
            "name": name,
            "arguments": arguments,
        }],
    })
    .to_string()
    .into_bytes()
}

fn responses_session(base_url: &str, policy: ToolPolicy) -> Session {
    Session::new(
        None,
        SessionConfig::new_with_defaults(
            "test",
            "fixture",
            base_url,
            SessionApiFormat::OpenAiResponses,
        ),
        None,
        None,
        None,
        None,
        None,
        None,
        Some(policy),
    )
}

fn store_with_policy(policy: ToolPolicy) -> CapabilityExposureSessionStore {
    let mut exposure = CapabilityExposurePolicy::new(ReleasePhase::Stable);
    exposure.allowed_domains = Some(BTreeSet::from(["scene".to_string()]));
    CapabilityExposureSessionStore::with_configuration(
        BuiltInTypedCapabilityCatalog::registry(),
        CapabilityDraftStore::DEFAULT_TTL,
        exposure,
        BTreeMap::new(),
        Some(policy),
    )
}

#[test]
fn policy_semantics() {
    let call = ToolCall::new(
        "write_file",
        Data::from_bytes(br#"{"path":"a"}"#.to_vec()),
        ToolCallOrigin::Mcp,
    );
    assert_eq!(ToolPolicy::default().evaluate(call.clone()).unwrap(), call);

    let rewritten = ToolPolicy::new(vec![Arc::new(
        |request: ToolCall| -> Result<ToolPolicyDecision, ToolPolicyError> {
            Ok(ToolPolicyDecision::Allow(ToolCall::new(
                request.name,
                Data::from_bytes(br#"{"path":"b"}"#.to_vec()),
                request.origin,
            )))
        },
    )])
    .evaluate(call.clone())
    .unwrap();
    assert_eq!(
        rewritten.arguments,
        Data::from_bytes(br#"{"path":"b"}"#.to_vec())
    );

    // The first denial short-circuits: if the third handler ran, evaluate would
    // return normally and the expectation below would fail.
    let denial = ToolPolicyDenial::new(
        ToolPolicyDenialCode::UntrustedProject,
        "project is untrusted",
    );
    let denying = ToolPolicy::new(vec![
        Arc::new(
            |request: ToolCall| -> Result<ToolPolicyDecision, ToolPolicyError> {
                Ok(ToolPolicyDecision::Allow(request))
            },
        ),
        {
            let denial = denial.clone();
            Arc::new(
                move |_: ToolCall| -> Result<ToolPolicyDecision, ToolPolicyError> {
                    Ok(ToolPolicyDecision::Deny(denial.clone()))
                },
            )
        },
        Arc::new(
            |request: ToolCall| -> Result<ToolPolicyDecision, ToolPolicyError> {
                Ok(ToolPolicyDecision::Allow(request))
            },
        ),
    ]);
    assert_eq!(
        denying.evaluate(call.clone()),
        Err(ToolPolicyError::Denied(denial))
    );

    // Handler errors propagate unchanged. Swift threw a custom `TestError`;
    // Rust handlers can only fail with a `ToolPolicyError`, so the port uses
    // the closest observable equivalent.
    let failing = ToolPolicy::new(vec![Arc::new(
        |_: ToolCall| -> Result<ToolPolicyDecision, ToolPolicyError> {
            Err(ToolPolicyError::InvalidRewrite)
        },
    )]);
    assert_eq!(failing.evaluate(call), Err(ToolPolicyError::InvalidRewrite));
}

#[test]
fn session_denial_is_an_observation() {
    for tool_name in [
        CapabilityToolset::SEARCH_TOOL_NAME,
        "execute_edit_plan",
        "find_entities",
    ] {
        let server = FixtureHttpServer::start(move |index, _| {
            if index == 0 {
                responses_call("search_1", tool_name, r#"{"query":"rename"}"#)
            } else {
                responses_call(
                    "final_1",
                    "execute_edit_plan",
                    r#"{"summary":"No changes","steps":[]}"#,
                )
            }
        });
        let denial = ToolPolicyDenial::new(ToolPolicyDenialCode::Mode, "blocked by test policy");
        let policy = ToolPolicy::new(vec![{
            let denial = denial.clone();
            Arc::new(
                move |call: ToolCall| -> Result<ToolPolicyDecision, ToolPolicyError> {
                    if String::from_utf8_lossy(call.arguments.as_slice()).contains("query") {
                        Ok(ToolPolicyDecision::Deny(denial.clone()))
                    } else {
                        Ok(ToolPolicyDecision::Allow(call))
                    }
                },
            )
        }]);
        let session = responses_session(server.base_url(), policy);
        let proposal = session
            .process_with_defaults(&Signal::NaturalLanguage {
                text: "Rename an entity".to_string(),
                locale: "en".to_string(),
            })
            .unwrap();
        assert_eq!(proposal.plan.summary, "No changes", "{tool_name}");
        let requests = server.requests();
        assert_eq!(requests.len(), 2, "{tool_name}");
        assert!(
            String::from_utf8_lossy(&requests[1]).contains("Tool call denied"),
            "{tool_name} denial is missing from the second request"
        );
    }
}

#[test]
fn invalid_rewrites_fail_closed() {
    let call = ToolCall::new(
        "read",
        Data::from_bytes(b"{}".to_vec()),
        ToolCallOrigin::Mcp,
    );
    assert_eq!(
        ToolPolicy::new(vec![{
            let arguments = call.arguments.clone();
            let origin = call.origin;
            Arc::new(
                move |_: ToolCall| -> Result<ToolPolicyDecision, ToolPolicyError> {
                    Ok(ToolPolicyDecision::Allow(ToolCall::new(
                        "write",
                        arguments.clone(),
                        origin,
                    )))
                },
            )
        }])
        .evaluate(call.clone()),
        Err(ToolPolicyError::InvalidRewrite)
    );

    let server = FixtureHttpServer::start(|index, _| {
        if index == 0 {
            responses_call(
                "search_1",
                CapabilityToolset::SEARCH_TOOL_NAME,
                r#"{"query":"inspect"}"#,
            )
        } else {
            responses_call(
                "final_1",
                "execute_edit_plan",
                r#"{"summary":"No changes","steps":[]}"#,
            )
        }
    });
    let policy = ToolPolicy::new(vec![Arc::new(
        |call: ToolCall| -> Result<ToolPolicyDecision, ToolPolicyError> {
            if call.name != CapabilityToolset::SEARCH_TOOL_NAME {
                return Ok(ToolPolicyDecision::Allow(call));
            }
            Ok(ToolPolicyDecision::Allow(ToolCall::new(
                call.name,
                Data::from_bytes(b"invalid JSON".to_vec()),
                call.origin,
            )))
        },
    )]);
    let session = responses_session(server.base_url(), policy);
    session
        .process_with_defaults(&Signal::NaturalLanguage {
            text: "Inspect".to_string(),
            locale: "en".to_string(),
        })
        .unwrap();
    let requests = server.requests();
    assert_eq!(requests.len(), 2);
    assert!(
        String::from_utf8_lossy(&requests[1]).contains("Tool call denied"),
        "a malformed policy rewrite must become a denial observation"
    );
}

#[test]
fn store_policy_denies_and_rewrites() {
    let session_id = diffuse_kernel::codable::new_uuid();
    let denial = ToolPolicyDenial::new(ToolPolicyDenialCode::Policy, "blocked by test policy");
    let denied = store_with_policy(ToolPolicy::new(vec![{
        let denial = denial.clone();
        Arc::new(
            move |_: ToolCall| -> Result<ToolPolicyDecision, ToolPolicyError> {
                Ok(ToolPolicyDecision::Deny(denial.clone()))
            },
        )
    }]));
    let activation = denied
        .search_with_defaults(&session_id, "rename", 5)
        .unwrap();
    let rename = activation
        .contracts
        .iter()
        .find(|contract| contract.id == "scene.set_name")
        .expect("scene.set_name contract");
    let error = denied
        .create_draft_with_defaults(
            &session_id,
            &rename.tool_name(),
            br#"{"entity_id":"scene:1","name":"Blocked"}"#,
            5,
        )
        .unwrap_err();
    assert_eq!(
        error,
        CapabilityExposureSessionStoreError::ToolPolicy(ToolPolicyError::Denied(denial))
    );

    let rewritten_session_id = diffuse_kernel::codable::new_uuid();
    let rewritten = store_with_policy(ToolPolicy::new(vec![Arc::new(
        |call: ToolCall| -> Result<ToolPolicyDecision, ToolPolicyError> {
            if call.origin != ToolCallOrigin::Mcp {
                return Ok(ToolPolicyDecision::Allow(call));
            }
            Ok(ToolPolicyDecision::Allow(ToolCall::new(
                call.name,
                Data::from_bytes(br#"{"entity_id":"scene:1","name":"Rewritten"}"#.to_vec()),
                call.origin,
            )))
        },
    )]));
    let rewrite_activation = rewritten
        .search_with_defaults(&rewritten_session_id, "rename", 5)
        .unwrap();
    let rewrite_contract = rewrite_activation
        .contracts
        .iter()
        .find(|contract| contract.id == "scene.set_name")
        .expect("scene.set_name contract");
    let draft = rewritten
        .create_draft_with_defaults(
            &rewritten_session_id,
            &rewrite_contract.tool_name(),
            br#"{"entity_id":"scene:1","name":"Original"}"#,
            5,
        )
        .unwrap();
    let decoded: serde_json::Value =
        serde_json::from_slice(draft.validated_input.as_slice()).unwrap();
    assert_eq!(decoded["name"], "Rewritten");
}
