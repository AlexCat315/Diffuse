//! Ported from `Engine/Tests/AIRuntimeTests/ProjectToolSessionTests.swift`.
//! `HarnessSessionTests` lives in the same Swift file and is ported here.

use std::collections::BTreeSet;
use std::error::Error;
use std::sync::{Arc, Mutex};

use diffuse_capability::contracts::exports::SessionApiFormat;
use diffuse_plugin::contract::plugin_json::PluginJSON;
use serde_json::{Value, json};

use crate::context::asset_workflow_context::AssetWorkflowContext;
use crate::context::workflow_context::WorkflowContext;
use crate::session::harness::{
    SessionHarness, SessionHarnessStep, SessionHarnessStepAction, SessionHarnessTurn,
    SessionHarnessTurnCall, SessionHarnessTurnObservation, SessionHarnessTurnRequest,
};
use crate::session::session::{Session, SessionError};
use crate::session::session_config::SessionConfig;
use crate::session::session_workflow_scope::{
    SessionAgentContext, SessionContextSection, SessionContextSource, SessionWorkflowScope,
};
use crate::session::signal::Signal;
use crate::tests::ai_runtime::fixture_http::FixtureHttpServer;

fn provider_tool_response(
    format: SessionApiFormat,
    call_id: &str,
    name: &str,
    input: &Value,
) -> Vec<u8> {
    let arguments = input.to_string();
    let response = match format {
        SessionApiFormat::Anthropic => json!({
            "content": [{"type": "tool_use", "id": call_id, "name": name, "input": input}],
            "stop_reason": "tool_use",
        }),
        SessionApiFormat::OpenAiCompatible => json!({
            "choices": [{
                "message": {
                    "role": "assistant",
                    "tool_calls": [{
                        "id": call_id,
                        "type": "function",
                        "function": {"name": name, "arguments": arguments},
                    }],
                },
                "finish_reason": "tool_calls",
            }],
        }),
        SessionApiFormat::OpenAiResponses => json!({
            "output": [{
                "type": "function_call",
                "call_id": call_id,
                "name": name,
                "arguments": arguments,
            }],
        }),
    };
    response.to_string().into_bytes()
}

fn session_for(format: SessionApiFormat, base_url: &str) -> Session {
    Session::with_defaults(SessionConfig::new_with_defaults(
        "fixture", "fixture", base_url, format,
    ))
}

fn natural_language(text: &str) -> Signal {
    Signal::NaturalLanguage {
        text: text.to_string(),
        locale: "en".to_string(),
    }
}

fn tool_names(tools: &[Value]) -> Vec<&str> {
    tools
        .iter()
        .filter_map(|tool| {
            tool.get("name")
                .and_then(Value::as_str)
                .or_else(|| tool.get("function")?.get("name")?.as_str())
        })
        .collect()
}

fn plugin_json(value: Value) -> PluginJSON {
    PluginJSON::from_foundation_value(&value)
}

type RecordedCalls = Arc<Mutex<Vec<(String, Vec<u8>)>>>;

fn harness_step(action: SessionHarnessStepAction) -> SessionHarnessStep {
    SessionHarnessStep::new(action)
}

#[test]
fn creation_scope_filters_provider_tools_and_binds_selection_in_every_provider() {
    for format in [
        SessionApiFormat::Anthropic,
        SessionApiFormat::OpenAiCompatible,
        SessionApiFormat::OpenAiResponses,
    ] {
        let server = FixtureHttpServer::start(move |_, _| {
            provider_tool_response(
                format,
                "scope",
                "respond",
                &json!({"message": "Asset reviewed"}),
            )
        });
        let session = session_for(format, server.base_url());
        session.set_project_tool_executor(Some(Arc::new(
            |_: String, _: Vec<u8>| -> Result<Vec<u8>, Box<dyn Error + Send + Sync>> {
                Ok(b"{}".to_vec())
            },
        )));
        session
            .set_workflow_scope(SessionWorkflowScope::with_configure(|scope| {
                scope.context = Some(WorkflowContext::Asset(AssetWorkflowContext::default()));
                scope.allowed_project_tool_names = Some(BTreeSet::from([
                    "respond".to_string(),
                    "save_scene".to_string(),
                ]));
                scope.selected_entity_refs = Some(vec!["scene:42".to_string()]);
            }))
            .unwrap();
        session.observe_selection_changed(&["scene:99".to_string()]);
        let proposal = session
            .process_with_defaults(&natural_language("Review material"))
            .unwrap();
        assert_eq!(proposal.plan.summary, "Asset reviewed");

        let body = server.request_json(0);
        let tools = body["tools"].as_array().expect("tools array");
        let names = tool_names(tools);
        assert!(names.contains(&"respond"), "{format:?}: {names:?}");
        assert!(names.contains(&"save_scene"), "{format:?}: {names:?}");
        assert!(!names.contains(&"write_script"), "{format:?}: {names:?}");
        assert!(
            !names.contains(&"set_playback_state"),
            "{format:?}: {names:?}"
        );
        assert!(!names.contains(&"export_project"), "{format:?}: {names:?}");
        let prompt = body["system"]
            .as_str()
            .or_else(|| body["instructions"].as_str())
            .or_else(|| body["messages"][0]["content"].as_str())
            .expect("prompt");
        assert!(prompt.contains("3D asset creation"), "{format:?}: {prompt}");
        assert!(prompt.contains("scene:42"), "{format:?}: {prompt}");
        assert!(
            !prompt.contains("Currently selected: scene:99"),
            "{format:?}: {prompt}"
        );
    }
}

#[test]
fn agent_context_adds_instructions_and_sections_and_drops_unlisted_sources() {
    let server = FixtureHttpServer::start(|_, _| {
        provider_tool_response(
            SessionApiFormat::Anthropic,
            "agent",
            "respond",
            &json!({"message": "Done"}),
        )
    });
    let session = session_for(SessionApiFormat::Anthropic, server.base_url());
    session.set_project_tool_executor(Some(Arc::new(
        |_: String, _: Vec<u8>| -> Result<Vec<u8>, Box<dyn Error + Send + Sync>> {
            Ok(b"{}".to_vec())
        },
    )));
    session
        .set_workflow_scope(SessionWorkflowScope::with_configure(|scope| {
            scope.allowed_project_tool_names = Some(BTreeSet::from(["respond".to_string()]));
            scope.selected_entity_refs = Some(vec!["scene:42".to_string()]);
            scope.agent = SessionAgentContext::new(
                Some("Keep plans short.".to_string()),
                Some(BTreeSet::from([SessionContextSource::Selection])),
                vec![SessionContextSection::new(
                    "Working Tree",
                    "2 files changed",
                )],
            );
        }))
        .unwrap();
    let proposal = session
        .process_with_defaults(&natural_language("Summarize"))
        .unwrap();
    assert_eq!(proposal.plan.summary, "Done");

    let body = server.request_json(0);
    let prompt = body["system"].as_str().expect("system prompt");
    assert!(prompt.contains("Agent instructions (within the rules below):\nKeep plans short."));
    assert!(prompt.contains("Working Tree:\n2 files changed"));
    assert!(prompt.contains("Currently selected: scene:42"));
    assert!(!prompt.contains("Scene entities (JSON)"));
    assert!(prompt.contains("Rules:"));
}

#[test]
fn project_tool_failures_return_to_model_and_finish_as_answer_in_every_provider() {
    for format in [
        SessionApiFormat::Anthropic,
        SessionApiFormat::OpenAiCompatible,
        SessionApiFormat::OpenAiResponses,
    ] {
        let server = FixtureHttpServer::start(move |index, _| {
            if index == 0 {
                provider_tool_response(format, "call_1", "compile_scripts", &json!({}))
            } else {
                provider_tool_response(
                    format,
                    "call_2",
                    "respond",
                    &json!({"message": "Script trust is required before compilation."}),
                )
            }
        });
        let session = session_for(format, server.base_url());
        let calls: RecordedCalls = Arc::new(Mutex::new(Vec::new()));
        let recorded = Arc::clone(&calls);
        session.set_project_tool_executor(Some(Arc::new(
            move |name: String, input: Vec<u8>| -> Result<Vec<u8>, Box<dyn Error + Send + Sync>> {
                match recorded.lock() {
                    Ok(mut calls) => calls.push((name, input)),
                    Err(poisoned) => poisoned.into_inner().push((name, input)),
                }
                Err(Box::new(std::io::Error::other(
                    "Project scripts are not trusted",
                )))
            },
        )));
        let proposal = session
            .process_with_defaults(&natural_language("Compile my project"))
            .unwrap();
        assert_eq!(
            proposal.plan.summary,
            "Script trust is required before compilation."
        );
        assert!(proposal.plan.steps.is_empty());
        let calls = calls.lock().unwrap();
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0].0, "compile_scripts");
        assert_eq!(calls[0].1, b"{}");

        let requests = server.requests();
        assert_eq!(requests.len(), 2, "{format:?}");
        assert!(
            String::from_utf8_lossy(&requests[1]).contains("Project scripts are not trusted"),
            "{format:?}"
        );
        let body: Value = serde_json::from_slice(&requests[0]).unwrap();
        let tools = body["tools"].as_array().expect("tools array");
        let names = tool_names(tools);
        assert!(names.contains(&"write_script"), "{format:?}: {names:?}");
        assert!(names.contains(&"respond"), "{format:?}: {names:?}");
        if format == SessionApiFormat::OpenAiResponses {
            let write = tools
                .iter()
                .find(|tool| tool["name"].as_str() == Some("write_script"))
                .expect("write_script definition");
            assert_eq!(write["strict"], false);
            let required = write["parameters"]["required"]
                .as_array()
                .expect("required array");
            assert!(
                !required
                    .iter()
                    .any(|name| name.as_str() == Some("expected_sha256"))
            );
        }
    }
}

struct Recorder {
    turns: Mutex<Vec<SessionHarnessTurn>>,
    bodies: Mutex<Vec<Value>>,
}

impl Recorder {
    fn new() -> Self {
        Self {
            turns: Mutex::new(Vec::new()),
            bodies: Mutex::new(Vec::new()),
        }
    }

    fn record_turn(&self, turn: SessionHarnessTurn) {
        match self.turns.lock() {
            Ok(mut turns) => turns.push(turn),
            Err(poisoned) => poisoned.into_inner().push(turn),
        }
    }

    fn record_body(&self, body: Value) {
        match self.bodies.lock() {
            Ok(mut bodies) => bodies.push(body),
            Err(poisoned) => poisoned.into_inner().push(body),
        }
    }

    fn turns(&self) -> Vec<SessionHarnessTurn> {
        match self.turns.lock() {
            Ok(turns) => turns.clone(),
            Err(poisoned) => poisoned.into_inner().clone(),
        }
    }

    fn bodies(&self) -> Vec<Value> {
        match self.bodies.lock() {
            Ok(bodies) => bodies.clone(),
            Err(poisoned) => poisoned.into_inner().clone(),
        }
    }
}

fn recording_server(recorder: Arc<Recorder>) -> FixtureHttpServer {
    FixtureHttpServer::start(move |index, body| {
        recorder.record_body(serde_json::from_slice(body).unwrap_or(Value::Null));
        if index == 0 {
            provider_tool_response(
                SessionApiFormat::Anthropic,
                "toolu_1",
                "export_project",
                &json!({}),
            )
        } else {
            provider_tool_response(
                SessionApiFormat::Anthropic,
                "toolu_2",
                "respond",
                &json!({"message": "Done"}),
            )
        }
    })
}

#[test]
fn harness_decides_each_step_while_the_session_calls_the_model_and_runs_tools() {
    let recorder = Arc::new(Recorder::new());
    let server = recording_server(Arc::clone(&recorder));
    let session = session_for(SessionApiFormat::Anthropic, server.base_url());
    session.set_project_tool_executor(Some(Arc::new(
        |_: String, _: Vec<u8>| -> Result<Vec<u8>, Box<dyn Error + Send + Sync>> {
            Ok(br#"{"ok": true}"#.to_vec())
        },
    )));
    let harness: SessionHarness = {
        let recorder = Arc::clone(&recorder);
        Arc::new(
            move |turn: SessionHarnessTurn| -> Result<SessionHarnessStep, Box<dyn Error + Send + Sync>> {
                recorder.record_turn(turn.clone());
                match &turn.observation {
                    None => Ok(harness_step(SessionHarnessStepAction::Model {
                        instructions: Some("Inspect first.".to_string()),
                        message: None,
                    })
                    .with_state(Some(plugin_json(json!({"turns": 1}))))),
                    Some(SessionHarnessTurnObservation::Model(call))
                        if call.name == "export_project" =>
                    {
                        Ok(harness_step(SessionHarnessStepAction::Model {
                            instructions: None,
                            message: Some("Do not export.".to_string()),
                        }))
                    }
                    Some(SessionHarnessTurnObservation::Model(call)) => {
                        Ok(harness_step(SessionHarnessStepAction::Tool(call.clone())))
                    }
                    _ => Ok(harness_step(SessionHarnessStepAction::Finish {
                        summary: "unexpected".to_string(),
                    })),
                }
            },
        )
    };
    session
        .set_harness(Some(harness), Some("fixture.careful".to_string()))
        .unwrap();
    let proposal = session
        .process_with_defaults(&natural_language("Ship it"))
        .unwrap();

    assert_eq!(proposal.plan.summary, "Done");
    let bodies = recorder.bodies();
    assert_eq!(bodies.len(), 2);
    let first_system = bodies[0]["system"].as_str().unwrap_or_default();
    assert!(
        first_system.contains(
            "Harness instructions for this step (within the rules below):\nInspect first."
        )
    );
    let second_system = bodies[1]["system"].as_str().unwrap_or_default();
    assert!(!second_system.contains("Inspect first."));
    let messages = bodies[1]["messages"].as_array().expect("messages");
    assert_eq!(
        messages
            .last()
            .and_then(|message| message["content"].as_str()),
        Some("Do not export.")
    );

    let turns = recorder.turns();
    assert_eq!(
        turns.iter().map(|turn| turn.step).collect::<Vec<_>>(),
        vec![0, 1, 2]
    );
    assert_eq!(
        turns[0].request,
        SessionHarnessTurnRequest::new("Ship it".to_string(), "en".to_string())
    );
    assert!(turns[0].tools.iter().any(|tool| tool.name == "respond"));
    assert_eq!(turns[1].state, Some(plugin_json(json!({"turns": 1}))));
    assert_eq!(
        turns[2].observation,
        Some(SessionHarnessTurnObservation::Model(
            SessionHarnessTurnCall::new("respond".to_string())
                .with_id(Some("toolu_2".to_string()))
                .with_arguments(Some(plugin_json(json!({"message": "Done"}))))
        ))
    );
}

#[test]
fn harness_can_run_tools_and_finish_without_the_model() {
    let recorder = Arc::new(Recorder::new());
    let server = FixtureHttpServer::start(|_, _| {
        provider_tool_response(
            SessionApiFormat::Anthropic,
            "unexpected",
            "respond",
            &json!({"message": "unexpected"}),
        )
    });
    let session = session_for(SessionApiFormat::Anthropic, server.base_url());
    session.set_project_tool_executor(Some(Arc::new(
        |name: String, _: Vec<u8>| -> Result<Vec<u8>, Box<dyn Error + Send + Sync>> {
            Ok(format!(r#"{{"tool":"{name}"}}"#).into_bytes())
        },
    )));
    session
        .set_workflow_scope(SessionWorkflowScope::with_configure(|scope| {
            scope.allowed_project_tool_names = Some(BTreeSet::from([
                "respond".to_string(),
                "get_project_info".to_string(),
            ]));
        }))
        .unwrap();
    let harness: SessionHarness = {
        let recorder = Arc::clone(&recorder);
        Arc::new(
            move |turn: SessionHarnessTurn| -> Result<SessionHarnessStep, Box<dyn Error + Send + Sync>> {
                recorder.record_turn(turn.clone());
                match &turn.observation {
                    None => Ok(harness_step(SessionHarnessStepAction::Tool(
                        SessionHarnessTurnCall::new("get_project_info".to_string()),
                    ))),
                    Some(SessionHarnessTurnObservation::Tool(_, result)) => {
                        Ok(harness_step(SessionHarnessStepAction::Finish {
                            summary: format!(
                                "Read {}",
                                serde_json::to_string(result).unwrap_or_default()
                            ),
                        }))
                    }
                    _ => Ok(harness_step(SessionHarnessStepAction::Finish {
                        summary: "unexpected".to_string(),
                    })),
                }
            },
        )
    };
    session
        .set_harness(Some(harness), Some("fixture.direct".to_string()))
        .unwrap();
    let proposal = session
        .process_with_defaults(&natural_language("Describe"))
        .unwrap();
    assert!(server.requests().is_empty());
    assert!(proposal.plan.summary.contains("get_project_info"));
    assert!(proposal.plan.steps.is_empty());
}

#[test]
fn denied_tools_come_back_as_failures_and_the_step_budget_ends_a_runaway_harness() {
    let recorder = Arc::new(Recorder::new());
    let server = FixtureHttpServer::start(|_, _| {
        provider_tool_response(
            SessionApiFormat::Anthropic,
            "unexpected",
            "respond",
            &json!({"message": "unexpected"}),
        )
    });
    let session = session_for(SessionApiFormat::Anthropic, server.base_url());
    session.set_project_tool_executor(Some(Arc::new(
        |_: String, _: Vec<u8>| -> Result<Vec<u8>, Box<dyn Error + Send + Sync>> {
            Ok(b"{}".to_vec())
        },
    )));
    session
        .set_workflow_scope(SessionWorkflowScope::with_configure(|scope| {
            scope.allowed_project_tool_names = Some(BTreeSet::from(["respond".to_string()]));
        }))
        .unwrap();
    let harness: SessionHarness = {
        let recorder = Arc::clone(&recorder);
        Arc::new(
            move |turn: SessionHarnessTurn| -> Result<SessionHarnessStep, Box<dyn Error + Send + Sync>> {
                recorder.record_turn(turn.clone());
                Ok(harness_step(SessionHarnessStepAction::Tool(
                    SessionHarnessTurnCall::new("write_file".to_string())
                        .with_arguments(Some(plugin_json(json!({"path": "x"})))),
                )))
            },
        )
    };
    session
        .set_harness(Some(harness), Some("fixture.runaway".to_string()))
        .unwrap();
    let result = session.process_with_defaults(&natural_language("Loop"));
    assert!(matches!(result, Err(SessionError::NoPlanInResponse)));

    let turns = recorder.turns();
    assert_eq!(turns.len(), SessionHarnessStep::MAXIMUM_STEPS);
    assert!(
        matches!(
            turns[1].observation,
            Some(SessionHarnessTurnObservation::Failure(_))
        ),
        "the denied tool is not reported"
    );
}

#[test]
fn harness_state_lasts_across_turns_until_the_harness_changes() {
    let recorder = Arc::new(Recorder::new());
    let harness: SessionHarness = {
        let recorder = Arc::clone(&recorder);
        Arc::new(
            move |turn: SessionHarnessTurn| -> Result<SessionHarnessStep, Box<dyn Error + Send + Sync>> {
                recorder.record_turn(turn.clone());
                let count = match &turn.state {
                    Some(PluginJSON::Object(object)) => match object.get("count") {
                        Some(PluginJSON::Number(number)) => number.as_i64().unwrap_or(0),
                        _ => 0,
                    },
                    _ => 0,
                };
                Ok(harness_step(SessionHarnessStepAction::Finish {
                    summary: count.to_string(),
                })
                .with_state(Some(plugin_json(json!({"count": count + 1})))))
            },
        )
    };
    let server = FixtureHttpServer::start(|_, _| {
        provider_tool_response(
            SessionApiFormat::Anthropic,
            "unexpected",
            "respond",
            &json!({"message": "unexpected"}),
        )
    });
    let session = session_for(SessionApiFormat::Anthropic, server.base_url());
    session
        .set_harness(
            Some(Arc::clone(&harness)),
            Some("fixture.counter".to_string()),
        )
        .unwrap();
    let first = session
        .process_with_defaults(&natural_language("One"))
        .unwrap();
    session
        .set_harness(
            Some(Arc::clone(&harness)),
            Some("fixture.counter".to_string()),
        )
        .unwrap();
    let second = session
        .process_with_defaults(&natural_language("Two"))
        .unwrap();
    session
        .set_harness(Some(harness), Some("fixture.other".to_string()))
        .unwrap();
    let third = session
        .process_with_defaults(&natural_language("Three"))
        .unwrap();
    assert_eq!(
        [first, second, third]
            .iter()
            .map(|proposal| proposal.plan.summary.as_str())
            .collect::<Vec<_>>(),
        vec!["0", "1", "0"]
    );
}

#[test]
fn steps_decode_from_the_plugin_wire_format() {
    fn step(json_text: &str) -> Result<SessionHarnessStep, serde_json::Error> {
        serde_json::from_str::<SessionHarnessStep>(json_text)
    }

    assert_eq!(
        step(r#"{"step":"model","instructions":"Plan","state":{"a":1}}"#).unwrap(),
        harness_step(SessionHarnessStepAction::Model {
            instructions: Some("Plan".to_string()),
            message: None,
        })
        .with_state(Some(plugin_json(json!({"a": 1}))))
    );
    assert_eq!(
        step(r#"{"step":"tool","call":{"id":"toolu_1","name":"respond","arguments":{"message":"Hi"}}}"#)
            .unwrap(),
        harness_step(SessionHarnessStepAction::Tool(
            SessionHarnessTurnCall::new("respond".to_string())
                .with_id(Some("toolu_1".to_string()))
                .with_arguments(Some(plugin_json(json!({"message": "Hi"}))))
        ))
    );
    assert_eq!(
        step(r#"{"step":"finish","summary":"Done"}"#).unwrap(),
        harness_step(SessionHarnessStepAction::Finish {
            summary: "Done".to_string(),
        })
    );
    assert!(step(r#"{"step":"shell","command":"rm"}"#).is_err());

    let turn = SessionHarnessTurn::new(
        1,
        None,
        SessionHarnessTurnRequest::new("Hi".to_string(), "en".to_string()),
        Vec::new(),
        Some(SessionHarnessTurnObservation::Tool(
            SessionHarnessTurnCall::new("get_project_info".to_string()),
            plugin_json(json!({"ok": true})),
        )),
    );
    let object = serde_json::to_value(&turn).unwrap();
    let observation = object["observation"].as_object().expect("observation");
    assert_eq!(observation["type"], "tool");
    assert_eq!(observation["result"]["ok"], true);
}
