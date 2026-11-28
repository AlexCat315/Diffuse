//! `Editor/Sources/EditorCore/Application/Bridge/MCPIntegration.swift`.

use std::collections::BTreeSet;
use std::io;
use std::rc::Rc;
use std::sync::{Arc, mpsc};
use std::time::Duration;

use cove_agent::transport::AgentLocalServer;
use diffuse_ai::planning::capability_draft_pipeline::SceneCapabilityDraftLowering;
use diffuse_ai::planning::scene_edit_plan_executor::SceneEditPlanExecutor;
use diffuse_ai::semantic::scene_semantic_encoder::SceneSemanticEncoder;
use diffuse_ai::semantic::scene_semantic_snapshot::SceneSemanticSnapshot;
use diffuse_ai::tools::capability_exposure_session_store::{
    CapabilityExposureSessionError, CapabilitySearchActivation,
};
use diffuse_ai::tools::tool_policy::{ToolCall, ToolCallOrigin};
use diffuse_capability::capability_contract::{
    CapabilityAccess, CapabilityContract, CapabilityExposurePolicy,
};
use diffuse_capability::capsule_schema::validate_capability_input;
use diffuse_capability::drafts::capability_draft_limits::CapabilityDraftLimits;
use diffuse_capability::support::swift_date::SwiftDate;
use diffuse_intent::BuiltInTypedCapabilityCatalog;
use diffuse_intent::pipeline::commit_pipeline::CommitEntry;
use diffuse_intent::planning::intent_ir::IntentSource;
use diffuse_intent::transactions::transaction_ir::TransactionApprovalPolicy;
use diffuse_plugin::Uuid;
use diffuse_plugin::base64_data::Data;
use serde_json::{Map, Value, json};

use crate::ai::chat::editor_agent_task_service::EditorAgentTaskTarget;
use crate::application::editor_application::EditorApplication;
use crate::application::plugins::editor_plugin_capability_error::EditorPluginCapabilityError;

const DEFAULT_PORT: u16 = 9898;
const MAX_QUEUED_REQUESTS: usize = 32;
const REQUESTS_PER_TICK: usize = 8;
const DISPATCH_TIMEOUT: Duration = Duration::from_secs(5);

type Params = Map<String, Value>;
type CommandResult = Result<Value, Box<dyn std::error::Error + Send + Sync>>;

struct Request {
    command: Vec<u8>,
    accepted: mpsc::SyncSender<()>,
    response: mpsc::Sender<Vec<u8>>,
}

pub(crate) struct EditorMcpBridge {
    // Drop the mailbox before stopping the listener, releasing queued clients.
    requests: mpsc::Receiver<Request>,
    server: AgentLocalServer,
}

impl EditorMcpBridge {
    fn start(port: u16) -> io::Result<Self> {
        let (sender, requests) = mpsc::sync_channel(MAX_QUEUED_REQUESTS);
        let server = AgentLocalServer::new(
            port,
            Arc::new(move |command| {
                let (accepted, admission) = mpsc::sync_channel(0);
                let (response, reply) = mpsc::channel();
                let request = Request {
                    command: command.to_vec(),
                    accepted,
                    response,
                };
                let result = match sender.try_send(request) {
                    Ok(()) => {
                        cove_runtime::scene::wake_scene_thread();
                        match admission.recv_timeout(DISPATCH_TIMEOUT) {
                            Ok(()) => reply
                                .recv()
                                .unwrap_or_else(|_| error_bytes("editor unavailable")),
                            Err(mpsc::RecvTimeoutError::Timeout) => {
                                error_bytes("editor request timed out")
                            }
                            Err(mpsc::RecvTimeoutError::Disconnected) => {
                                error_bytes("editor unavailable")
                            }
                        }
                    }
                    Err(mpsc::TrySendError::Full(_)) => error_bytes("editor busy"),
                    Err(mpsc::TrySendError::Disconnected(_)) => error_bytes("editor unavailable"),
                };
                Some(result)
            }),
        );
        server.start()?;
        Ok(Self { requests, server })
    }
}

impl EditorApplication {
    /// Starts the editor's private loopback bridge. The owner must drive
    /// `tick` or `poll_mcp_bridge` while the listener is active.
    pub fn start_mcp_bridge(&self) -> io::Result<u16> {
        let port = std::env::var("DIFFUSE_MCP_PORT")
            .ok()
            .and_then(|port| port.parse().ok())
            .unwrap_or(DEFAULT_PORT);
        self.start_mcp_bridge_on(port)
    }

    pub fn start_mcp_bridge_on(&self, port: u16) -> io::Result<u16> {
        if !self.is_active() {
            return Err(io::Error::new(
                io::ErrorKind::NotConnected,
                "editor unavailable",
            ));
        }
        let mut bridge = self.mcp_bridge.borrow_mut();
        if let Some(port) = bridge
            .as_ref()
            .and_then(|bridge| bridge.server.bound_port())
        {
            return Ok(port);
        }
        let started = EditorMcpBridge::start(port)?;
        let bound = started.server.bound_port().ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::AddrNotAvailable,
                "editor MCP port unavailable",
            )
        })?;
        *bridge = Some(started);
        Ok(bound)
    }

    pub fn poll_mcp_bridge(self: &Rc<Self>) {
        for _ in 0..REQUESTS_PER_TICK {
            let request = self
                .mcp_bridge
                .borrow()
                .as_ref()
                .and_then(|bridge| bridge.requests.try_recv().ok());
            let Some(request) = request else { return };
            // The admission handshake prevents an expired command from
            // executing after the connection has received a timeout.
            if request.accepted.send(()).is_ok() {
                let _ = request
                    .response
                    .send(self.handle_mcp_message(&request.command));
            }
        }
        cove_runtime::scene::wake_scene_thread();
    }

    pub(crate) fn handle_mcp_message(self: &Rc<Self>, data: &[u8]) -> Vec<u8> {
        let Ok(mut params) = serde_json::from_slice::<Params>(data) else {
            return error_bytes("invalid JSON command");
        };
        let Some(Value::String(action)) = params.remove("action") else {
            return error_bytes("invalid JSON command");
        };
        if action == "project_tool" {
            let Some((name, arguments)) = params
                .get("tool_name")
                .and_then(Value::as_str)
                .zip(params.get("arguments").and_then(Value::as_object))
            else {
                return error_bytes("Missing project tool name or arguments.");
            };
            return serde_json::to_vec(arguments)
                .map_err(|error| error.to_string())
                .and_then(|input| {
                    self.execute_project_tool(name, &input, ToolCallOrigin::Mcp)
                        .map_err(|error| error.to_string())
                })
                .unwrap_or_else(|error| error_bytes(&error));
        }
        let response = self
            .handle_mcp_action(&action, params)
            .unwrap_or_else(|error| json!({"ok": false, "error": error.to_string()}));
        encode_response(&response)
    }

    fn handle_mcp_action(self: &Rc<Self>, action: &str, mut params: Params) -> CommandResult {
        let session_id = params.remove("session_id");
        if matches!(action, "open_capability_session" | "search_capabilities")
            && session_id
                .as_ref()
                .and_then(Value::as_str)
                .and_then(Uuid::parse)
                .is_some()
        {
            self.activate_plugins("onAIChat")?;
        }
        let mut policy = self
            .plugin_capability_executor
            .borrow()
            .as_ref()
            .map(|executor| executor.exposure_policy())
            .unwrap_or_else(|| CapabilityExposurePolicy {
                allowed_domains: Some(BTreeSet::from(["scene".to_string()])),
                ..CapabilityExposurePolicy::default()
            });
        let document_id = self.store.state().document.identity;
        let target = EditorAgentTaskTarget::new(
            document_id.clone(),
            self.store.scene_revision(),
            self.store.content(),
            self.store.selected_entity_ids(),
            self.store.selected_entity_id(),
        );
        policy.allowed_capability_ids = self
            .make_agent_workflow_scope(&target)
            .allowed_capability_ids;
        let sessions = &self.tool_access.capability_sessions;
        sessions.set_workflow_scope(&policy, &document_id);
        let session_id = || {
            session_id
                .as_ref()
                .and_then(Value::as_str)
                .ok_or("missing session_id")
        };
        match action {
            "get_scene" => self.mcp_get_scene(),
            "get_context_memory" => self.mcp_get_context_memory(&params),
            "get_ai_entity" => self.mcp_get_ai_entity(&params),
            "get_selection" => Ok(json!({"ok": true, "selectedRef": self.mcp_selected_ref()})),
            "find_entities" => Ok(self.mcp_find_entities(&params)),
            "open_capability_session" => Ok(activation_response(
                sessions.bootstrap_with_defaults(session_id()?, self.scene.revision())?,
            )),
            "search_capabilities" => {
                let session_id = session_id()?;
                let input = validated_framework_input(params, "system.search_capabilities")?;
                let query = string(&input, "query").unwrap_or_default();
                let domain = string(&input, "domain");
                let access = string(&input, "access").and_then(|value| {
                    CapabilityAccess::ALL
                        .into_iter()
                        .find(|access| access.raw_value() == value)
                });
                Ok(activation_response(sessions.search(
                    session_id,
                    query,
                    domain,
                    access,
                    self.scene.revision(),
                    SwiftDate::now(),
                )?))
            }
            "invoke_capability" => self.mcp_invoke_capability(session_id()?, &params),
            "submit_capability_plan" => self.mcp_submit_capability_plan(session_id()?, params),
            "close_capability_session" => {
                sessions.remove_session(session_id()?)?;
                Ok(json!({"ok": true}))
            }
            "reload_plugin" => {
                let id = string(&params, "plugin_id")
                    .filter(|id| !id.trim().is_empty())
                    .ok_or("missing plugin_id")?;
                Ok(match self.reload_plugin(id) {
                    Ok(()) => json!({"ok": true, "plugin_id": id, "reloaded": true}),
                    Err(error) => json!({"ok": false, "plugin_id": id, "error": error.to_string()}),
                })
            }
            _ => Err(format!("unknown action '{action}'").into()),
        }
    }

    fn mcp_invoke_capability(&self, session_id: &str, params: &Params) -> CommandResult {
        let tool_name = string(params, "tool_name").ok_or("missing tool_name")?;
        let arguments = params
            .get("arguments")
            .and_then(Value::as_object)
            .cloned()
            .unwrap_or_default();
        let raw_input = serde_json::to_vec(&arguments)?;
        let revision = self.scene.revision();
        let sessions = &self.tool_access.capability_sessions;
        let contract = sessions.contract_with_defaults(session_id, tool_name, revision)?;
        if contract.access.is_write() {
            let draft =
                sessions.create_draft_with_defaults(session_id, tool_name, &raw_input, revision)?;
            return Ok(json!({
                "ok": true, "status": "draft_created", "draft_id": draft.id,
                "capability_id": draft.capability_id, "capability_version": draft.capability_version,
                "schema_hash": draft.schema_hash, "scene_revision": draft.scene_revision,
            }));
        }

        let input = self
            .tool_access
            .policy
            .evaluate(ToolCall::new(
                tool_name,
                Data::from(raw_input),
                ToolCallOrigin::Mcp,
            ))?
            .arguments
            .0;
        let arguments: Value = serde_json::from_slice(&input)?;
        validate_capability_input(&arguments, &contract.input_schema)?;
        if let Some(plugin_id) = &contract.source.plugin_id {
            let executor = self
                .plugin_capability_executor
                .borrow()
                .clone()
                .ok_or_else(|| EditorPluginCapabilityError::PluginNotEnabled(plugin_id.clone()))?;
            let query = self.make_plugin_query_snapshot(plugin_id, revision)?;
            let snapshot = sessions.snapshot_with_defaults(session_id, revision)?;
            let payload =
                executor.execute_read(tool_name, &input, &snapshot, revision, query.as_ref())?;
            return Ok(json!({"ok": true, "result": serde_json::from_slice::<Value>(&payload.0)?}));
        }
        match contract.id.as_str() {
            "scene.describe_components" => {
                let descriptions = self
                    .scene
                    .scene()
                    .component_descriptions(arguments.get("type_id").and_then(Value::as_str));
                Ok(json!({"ok": true, "components": descriptions}))
            }
            "scene.get_entities" => self.mcp_get_scene(),
            "scene.get_selection" => {
                Ok(json!({"ok": true, "selectedRef": self.mcp_selected_ref()}))
            }
            "scene.find_entities" => {
                Ok(self.mcp_find_entities(&arguments.as_object().cloned().unwrap_or_default()))
            }
            _ => Err(
                CapabilityExposureSessionError::ReadCapabilityRequiresHostAdapter(contract.id)
                    .into(),
            ),
        }
    }

    fn mcp_submit_capability_plan(&self, session_id: &str, params: Params) -> CommandResult {
        let input = validated_framework_input(params, "system.submit_plan")?;
        let summary = string(&input, "summary").unwrap_or("AI capability plan");
        let reasoning = string(&input, "reasoning");
        let limit = CapabilityDraftLimits::MAXIMUM_DRAFTS_PER_PLAN;
        let ids = input
            .get("draft_ids")
            .and_then(Value::as_array)
            .filter(|ids| ids.len() <= limit)
            .ok_or_else(|| format!("draft_ids may contain at most {limit} ids"))?;
        let mut unique = BTreeSet::new();
        let mut draft_ids = Vec::with_capacity(ids.len());
        for id in ids {
            let id = id
                .as_str()
                .and_then(Uuid::parse)
                .filter(|id| unique.insert(id.clone()))
                .ok_or("draft_ids contains an invalid or duplicate id")?;
            draft_ids.push(id.as_str().to_owned());
        }
        let revision = self.scene.revision();
        let sessions = &self.tool_access.capability_sessions;
        let (drafts, snapshot) =
            sessions.validated_drafts_with_defaults(session_id, &draft_ids, revision)?;
        let built_in_drafts = drafts
            .iter()
            .filter(|draft| draft.source_plugin_id.is_none())
            .cloned()
            .collect::<Vec<_>>();
        let plan = SceneCapabilityDraftLowering::plan(summary, reasoning, &built_in_drafts)?;
        if drafts.is_empty() {
            return Ok(
                json!({"ok": true, "status": "no_changes", "summary": plan.summary, "snapshot_id": snapshot.id}),
            );
        }
        let approval_policy = TransactionApprovalPolicy::RequiresApproval;
        let transaction = if let Some(plugin_id) = drafts
            .iter()
            .find_map(|draft| draft.source_plugin_id.as_ref())
        {
            let executor = self
                .plugin_capability_executor
                .borrow()
                .clone()
                .ok_or_else(|| EditorPluginCapabilityError::PluginNotEnabled(plugin_id.clone()))?;
            let queries = self.make_plugin_query_snapshots(&drafts, revision)?;
            executor.build_transaction(
                summary,
                reasoning,
                &drafts,
                &snapshot,
                &self.scene.scene(),
                revision,
                &queries,
                approval_policy,
            )?
        } else {
            SceneEditPlanExecutor::new().build_transaction(
                &plan,
                &self.scene.scene(),
                Some(revision),
                approval_policy,
                Some(&snapshot),
                &BuiltInTypedCapabilityCatalog::registry(),
            )?
        };
        let context =
            self.make_capability_invocation_context(IntentSource::System, 1.0, Vec::new());
        let result = self.run_plan_transaction(
            &transaction,
            Some(context),
            CommitEntry::Mcp {
                session_id: session_id.to_owned(),
            },
        )?;
        sessions.consume(session_id, &draft_ids)?;
        Ok(json!({
            "ok": true, "summary": plan.summary, "transaction_id": result.transaction_id,
            "disposition": result.disposition.raw_value(), "snapshot_id": snapshot.id,
        }))
    }

    fn mcp_scene_snapshot(&self) -> SceneSemanticSnapshot {
        SceneSemanticEncoder::new().encode(
            &self.scene.scene(),
            self.store.selected_entity_id(),
            Some(self.store.content().raw_value().to_owned()),
            None,
        )
    }

    fn mcp_selected_ref(&self) -> Option<String> {
        self.store
            .selected_entity_id()
            .map(|id| format!("scene:{id}"))
    }

    fn mcp_get_scene(&self) -> CommandResult {
        let scene =
            serde_json::to_value(self.mcp_scene_snapshot()).map_err(|_| "scene encoding failed")?;
        Ok(json!({"ok": true, "scene": scene}))
    }

    fn mcp_find_entities(&self, params: &Params) -> Value {
        let name = string(params, "name").map(str::to_lowercase);
        let kind = string(params, "kind");
        let component = string(params, "component").map(str::to_lowercase);
        let limit = params
            .get("limit")
            .and_then(Value::as_i64)
            .unwrap_or(20)
            .clamp(1, 200) as usize;
        let near = params
            .get("near_position")
            .and_then(Value::as_array)
            .and_then(|values| {
                let values = values.iter().filter_map(Value::as_f64).collect::<Vec<_>>();
                <[f64; 3]>::try_from(values).ok()
            });
        let radius = params.get("near_radius").and_then(Value::as_f64);
        let mut matches = Vec::new();
        for entity in self.mcp_scene_snapshot().entities {
            if name
                .as_ref()
                .is_some_and(|name| !entity.name.to_lowercase().contains(name))
                || kind.is_some_and(|kind| entity.kind != kind)
                || component.as_ref().is_some_and(|component| {
                    !entity
                        .components
                        .iter()
                        .any(|item| item.to_lowercase() == *component)
                })
            {
                continue;
            }
            let position = entity.world_position.or(entity.position);
            let distance = if let Some((center, radius)) = near.zip(radius) {
                let Some([x, y, z]) = position.as_deref() else {
                    continue;
                };
                let dx = f64::from(*x) - center[0];
                let dy = f64::from(*y) - center[1];
                let dz = f64::from(*z) - center[2];
                let distance = (dx * dx + dy * dy + dz * dz).sqrt();
                if distance > radius {
                    continue;
                }
                Some(distance)
            } else {
                None
            };
            let mut result = json!({
                "id": entity.id, "name": entity.name, "kind": entity.kind, "components": entity.components,
            });
            if let Some(position) = position {
                result["position"] = json!(position);
            }
            if let Some(distance) = distance {
                result["distance"] = json!(distance);
            }
            matches.push((distance, result));
        }
        if near.is_some() {
            matches.sort_by(|left, right| {
                left.0
                    .unwrap_or(f64::INFINITY)
                    .total_cmp(&right.0.unwrap_or(f64::INFINITY))
            });
        }
        let entities = matches
            .into_iter()
            .take(limit)
            .map(|(_, entity)| entity)
            .collect::<Vec<_>>();
        json!({"ok": true, "count": entities.len(), "entities": entities})
    }

    fn mcp_get_context_memory(&self, params: &Params) -> CommandResult {
        let memory = self
            .context_memory_store
            .as_ref()
            .ok_or("context memory is not configured for this project")?;
        let budget = params
            .get("budget")
            .and_then(Value::as_i64)
            .unwrap_or(20)
            .max(0) as usize;
        let entries = memory.symbolic_view(budget);
        Ok(json!({"ok": true, "count": entries.len(), "entries": entries}))
    }

    fn mcp_get_ai_entity(&self, params: &Params) -> CommandResult {
        let target = string(params, "entity_id")
            .map(str::to_owned)
            .or_else(|| self.mcp_selected_ref())
            .filter(|target| !target.is_empty())
            .ok_or("missing target entity; pass entity_id or select an entity")?;
        let record = self
            .read_ai_world_entity_record(&target)
            .ok_or_else(|| format!("no AI world record for '{target}'"))?;
        let entity = serde_json::to_value(record).unwrap_or_else(|_| json!({}));
        Ok(json!({"ok": true, "targetRef": target, "entity": entity}))
    }
}

fn string<'a>(params: &'a Params, key: &str) -> Option<&'a str> {
    params.get(key).and_then(Value::as_str)
}

fn validated_framework_input(
    params: Params,
    id: &str,
) -> Result<Params, Box<dyn std::error::Error + Send + Sync>> {
    let registry = BuiltInTypedCapabilityCatalog::registry();
    let contract = registry
        .descriptor(id)
        .ok_or_else(|| format!("unknown tool '{id}'"))?;
    let mut input = Value::Object(params);
    validate_capability_input(&input, &contract.contract().input_schema)?;
    Ok(std::mem::take(
        input.as_object_mut().expect("framework input object"),
    ))
}

fn activation_response(activation: CapabilitySearchActivation) -> Value {
    fn encode(contracts: &[CapabilityContract]) -> Vec<Value> {
        contracts.iter().map(|contract| json!({
            "id": contract.id, "version": contract.version, "tool_name": contract.tool_name(),
            "title": contract.title, "description": contract.description, "domain": contract.domain,
            "access": contract.access.raw_value(), "schema_hash": contract.schema_hash,
            "input_schema": contract.input_schema,
        })).collect()
    }
    json!({
        "ok": true, "snapshot_id": activation.snapshot_id, "active_tool_count": activation.active_tool_count,
        "capabilities": encode(&activation.contracts), "active_capabilities": encode(&activation.active_contracts),
    })
}

fn encode_response(response: &Value) -> Vec<u8> {
    serde_json::to_vec(response)
        .unwrap_or_else(|_| br#"{"ok":false,"error":"invalid host response"}"#.to_vec())
}

fn error_bytes(error: &str) -> Vec<u8> {
    encode_response(&json!({"ok": false, "error": error}))
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::io::{BufRead, BufReader, Write};
    use std::net::TcpStream;
    use std::time::Instant;

    use super::*;
    use crate::application::editor_application::EditorApplicationOptions;

    fn with_editor(test: impl FnOnce(&Rc<EditorApplication>)) {
        let path = std::env::temp_dir().join(Uuid::new().as_str());
        fs::create_dir_all(&path).expect("fixture project");
        let app = EditorApplication::with_options(
            path.to_string_lossy().into_owned(),
            EditorApplicationOptions {
                seed_preview_scene: true,
                ..EditorApplicationOptions::default()
            },
        )
        .expect("launch editor");
        test(&app);
        app.shutdown();
        fs::remove_dir_all(path).expect("remove fixture");
    }

    fn call(app: &Rc<EditorApplication>, request: Value) -> Value {
        let response = app.handle_mcp_message(&encode_response(&request));
        serde_json::from_slice(&response).expect("JSON response")
    }

    #[test]
    fn loopback_dispatches_on_the_editor_owner_and_stops_on_shutdown() {
        with_editor(|app| {
            let port = app.start_mcp_bridge_on(0).expect("listen on free port");
            let (done, received) = mpsc::channel();
            let worker = std::thread::spawn(move || {
                let stream = TcpStream::connect(("127.0.0.1", port)).expect("connect");
                stream
                    .set_read_timeout(Some(Duration::from_secs(2)))
                    .expect("timeout");
                let mut client = BufReader::new(stream);
                for request in [b"{\n".as_slice(), b"{\"action\":\"get_scene\"}\n"] {
                    client.get_mut().write_all(request).expect("write request");
                    let mut line = String::new();
                    client.read_line(&mut line).expect("read response");
                    done.send(serde_json::from_str::<Value>(&line).expect("wire JSON"))
                        .expect("send response");
                }
            });
            let deadline = Instant::now() + Duration::from_secs(3);
            let mut responses = Vec::new();
            while responses.len() < 2 && Instant::now() < deadline {
                app.poll_mcp_bridge();
                if let Ok(response) = received.recv_timeout(Duration::from_millis(5)) {
                    responses.push(response);
                }
            }
            worker.join().expect("transport completed");
            assert_eq!(
                responses[0],
                json!({"ok": false, "error": "invalid JSON command"})
            );
            assert_eq!(responses[1]["ok"], true);
            assert!(
                !responses[1]["scene"]["entities"]
                    .as_array()
                    .unwrap()
                    .is_empty()
            );
            app.shutdown();
            assert!(TcpStream::connect(("127.0.0.1", port)).is_err());
        });
    }

    #[test]
    fn writes_require_a_live_session_and_stage_until_local_confirmation() {
        with_editor(|app| {
            let session = Uuid::new();
            let entity = app.scene.default_selection_id().expect("selected entity");
            let find = call(app, json!({"action": "find_entities", "limit": 1}));
            assert_eq!(find["count"], 1);

            let opened = call(
                app,
                json!({
                    "action": "open_capability_session", "session_id": session.as_str(),
                }),
            );
            assert_eq!(opened["ok"], true, "{opened}");
            let wanted = BuiltInTypedCapabilityCatalog::registry()
                .descriptor("scene.set_name")
                .expect("scene name contract")
                .contract();
            let request = json!({
                "action": "invoke_capability", "session_id": session.as_str(),
                "tool_name": wanted.tool_name(),
                "arguments": {"entity_id": format!("scene:{entity}"), "name": "Renamed through MCP"},
            });
            let unavailable = call(app, request.clone());
            assert_eq!(unavailable["ok"], false, "{unavailable}");

            let search = call(
                app,
                json!({
                    "action": "search_capabilities", "session_id": session.as_str(),
                    "query": "scene.set_name", "access": "reversible_write",
                }),
            );
            assert_eq!(search["ok"], true, "{search}");
            assert!(
                search["active_capabilities"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .any(|capability| capability["id"] == wanted.id),
                "{search}"
            );

            let draft = call(app, request);
            assert_eq!(draft["status"], "draft_created", "{draft}");
            let draft_id = draft["draft_id"].as_str().expect("wire draft id");
            assert!(Uuid::parse(draft_id).is_some());
            let submit = json!({
                "action": "submit_capability_plan", "session_id": session.as_str(),
                "summary": "Rename test entity", "draft_ids": [draft_id],
            });
            let submitted = call(app, submit.clone());
            assert_eq!(
                submitted["disposition"], "confirmation_requested",
                "{submitted}"
            );
            assert_ne!(
                app.scene.entity_summary(Some(entity)).unwrap().name,
                "Renamed through MCP"
            );
            assert_eq!(call(app, submit)["ok"], false, "draft already consumed");
            app.accept_pending_confirmation();
            assert_eq!(
                app.scene.entity_summary(Some(entity)).unwrap().name,
                "Renamed through MCP"
            );
            assert_eq!(
                call(
                    app,
                    json!({
                        "action": "close_capability_session", "session_id": session.as_str(),
                    })
                ),
                json!({"ok": true})
            );
        });
    }
}
