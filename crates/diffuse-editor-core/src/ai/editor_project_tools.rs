//! `Editor/Sources/EditorCore/AI/EditorProjectTools.swift`.
//!
//! Ports the two top-level types (`EditorProjectToolError`,
//! `ProjectCompileReport`) and the `extension EditorApplication` project-tool
//! executor/dispatcher (`makeProjectToolExecutor` / `executeProjectTool` and its
//! `get_project_info`, `get_scripting_api`, `get_runtime_state`, `list_scripts`,
//! `read_script`, `write_script`, `compile_scripts`, `save_scene`,
//! `export_project`, `set_playback_state`, `get_console_messages` arms).
//!
//! Diagnostic tools are wired separately through the UI diagnostics session.

use std::collections::BTreeMap;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::{Arc, Mutex, mpsc};

use cove_agent::JsonSchemaValidator;
use cove_system::paths::PathIdentity;
use serde_json::{Map, Value};
use unicode_segmentation::UnicodeSegmentation;

use diffuse_ai::tools::project_toolset::ProjectToolset;
use diffuse_ai::tools::tool_policy::{ToolCall, ToolCallOrigin};
use diffuse_capability::release::sha256::CapabilityDigest;
use diffuse_plugin::base64_data::Data;
use diffuse_script::interop::script_debug_state::ScriptDebugState;

use crate::ai::chat::editor_ai_request_policy::EditorAIRequestPolicy;
use crate::application::editor_application::EditorApplication;
use crate::scene::project_exporter::{ProjectExportError, ProjectExporter, is_executable_file};
use crate::scripting::dynamic::dynamic_script_manager::{
    CompilationStatus, DynamicScriptManagerError, ScriptFile,
};
use crate::scripting::dynamic::project_compiled_scripts::ProjectScriptBuildConfiguration;
use crate::state::editor_reducer::EditorAction;
use crate::state::editor_state::{EditorConsoleSeverity, PlaybackState};
use crate::state::workspace::content::EditorContent;

/// `public struct EditorProjectToolError: Error, LocalizedError, Sendable`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EditorProjectToolError {
    pub message: String,
}

impl EditorProjectToolError {
    pub fn new(message: impl Into<String>) -> Self {
        EditorProjectToolError {
            message: message.into(),
        }
    }

    /// Swift's `LocalizedError.errorDescription` (`public var errorDescription:
    /// String? { message }`).
    pub fn error_description(&self) -> &str {
        &self.message
    }
}

impl std::fmt::Display for EditorProjectToolError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for EditorProjectToolError {}

impl From<DynamicScriptManagerError> for EditorProjectToolError {
    fn from(error: DynamicScriptManagerError) -> Self {
        EditorProjectToolError::new(error.to_string())
    }
}

impl From<ProjectExportError> for EditorProjectToolError {
    fn from(error: ProjectExportError) -> Self {
        EditorProjectToolError::new(error.to_string())
    }
}

/// `private final class ProjectCompileReport: @unchecked Sendable`.
///
/// Swift's `NSLock` + `[[String: Any]]` become `Arc<Mutex<Vec<Value>>>` so the
/// report can be shared by the compilation callbacks (§5.5). Each result entry
/// is built from a `BTreeMap`, and the top-level object too, so the
/// `.sortedKeys` JSON output is byte-stable (§5.2 / §5.4).
#[derive(Clone, Default)]
pub struct ProjectCompileReport {
    results: Arc<Mutex<Vec<Value>>>,
}

impl ProjectCompileReport {
    pub fn new() -> Self {
        ProjectCompileReport {
            results: Arc::new(Mutex::new(Vec::new())),
        }
    }

    pub fn append(&self, file: &ScriptFile, status: CompilationStatus) {
        let (succeeded, message) = match &status {
            CompilationStatus::Succeeded => (true, "compiled and loaded".to_string()),
            CompilationStatus::Failed { message } | CompilationStatus::Blocked { message } => {
                (false, message.clone())
            }
            CompilationStatus::Cancelled => (false, "cancelled".to_string()),
            CompilationStatus::Idle | CompilationStatus::Compiling => {
                (false, "not compiled".to_string())
            }
        };
        let diagnostics = grapheme_suffix(&message, 16_384);
        let filename = file
            .url
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_default();
        let mut entry = BTreeMap::new();
        entry.insert("filename".to_string(), Value::String(filename));
        entry.insert(
            "identifier".to_string(),
            Value::String(file.identifier.clone()),
        );
        entry.insert("ok".to_string(), Value::Bool(succeeded));
        entry.insert("diagnostics".to_string(), Value::String(diagnostics));
        self.results
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .push(Value::Object(entry.into_iter().collect()));
    }

    /// `func data() throws -> Data` (`JSONSerialization` with `[.sortedKeys]`).
    pub fn data(&self) -> Result<Vec<u8>, serde_json::Error> {
        let results = self
            .results
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        let ok = results
            .iter()
            .all(|entry| entry.get("ok").and_then(Value::as_bool) == Some(true));
        let mut report = BTreeMap::new();
        report.insert("ok".to_string(), Value::Bool(ok));
        report.insert(
            "scripts".to_string(),
            Value::Array(results.iter().cloned().collect()),
        );
        serde_json::to_vec(&report)
    }
}

/// `String(message.suffix(16_384))`: Swift `Character`s are grapheme clusters,
/// so §5.2 requires `unicode-segmentation`, not byte slicing.
fn grapheme_suffix(text: &str, limit: usize) -> String {
    let graphemes: Vec<&str> = text.graphemes(true).collect();
    let start = graphemes.len().saturating_sub(limit);
    graphemes[start..].concat()
}

// ---------------------------------------------------------------------------
// `extension EditorApplication` — the project-tool executor and dispatcher (the
// `makeProjectToolExecutor` / `executeProjectTool` family from
// `Editor/Sources/EditorCore/AI/EditorProjectTools.swift`).
// ---------------------------------------------------------------------------

impl EditorApplication {
    /// `makeProjectToolExecutor()` — a closure that routes an agent-session tool
    /// call into `execute_project_tool` with the `.agentSession` origin.
    pub fn make_project_tool_executor(
        self: &Rc<Self>,
    ) -> impl Fn(String, Vec<u8>) -> Result<Vec<u8>, EditorProjectToolError> + use<> {
        let app = Rc::downgrade(self);
        move |name, input| {
            app.upgrade()
                .ok_or_else(|| EditorProjectToolError::new("Editor is unavailable."))?
                .execute_project_tool(&name, &input, ToolCallOrigin::AgentSession)
        }
    }

    /// `executeProjectTool(name:input:origin:)` — shared implementation for the
    /// built-in assistant and the stdio MCP server. Exposes no shell, credentials,
    /// project trust override or arbitrary path.
    pub fn execute_project_tool(
        &self,
        name: &str,
        input: &[u8],
        origin: ToolCallOrigin,
    ) -> Result<Vec<u8>, EditorProjectToolError> {
        // Host tool policy runs before any workspace effect.
        let evaluated_call = self
            .tool_access
            .policy
            .evaluate(ToolCall {
                name: name.to_string(),
                arguments: Data::from(input.to_vec()),
                origin,
            })
            .map_err(|error| EditorProjectToolError::new(error.to_string()))?;
        let evaluated_input = evaluated_call.arguments.0;
        let definition = ProjectToolset::definition(name)
            .ok_or_else(|| EditorProjectToolError::new(format!("Unknown project tool: {name}")))?;
        let task = self.agent_task_service.borrow().active_task().cloned();
        let profile = (task
            .as_ref()
            .map(|task| task.target.content)
            .unwrap_or_else(|| self.store.content()))
        .profile();
        if !profile.project_tool_names().contains(name) {
            return Err(EditorProjectToolError::new(
                "This tool is unavailable in the active authoring workflow.".to_string(),
            ));
        }
        if !definition.read_only
            && let Some(target) = task.as_ref().map(|task| &task.target)
        {
            self.validate_agent_task_target(target)?;
        }
        if origin != ToolCallOrigin::Mcp
            && let Some(content) = EditorContent::touched_by_tool(name)
            && self.store.agent_canvas() != Some(content)
        {
            self.store
                .dispatch(EditorAction::SetAgentCanvas(Some(content)));
        }
        let input: Value = serde_json::from_slice(&evaluated_input)
            .map_err(|error| EditorProjectToolError::new(error.to_string()))?;
        JsonSchemaValidator::validate(&input, &definition.schema)
            .map_err(|error| EditorProjectToolError::new(error.to_string()))?;
        let args: Map<String, Value> = input
            .as_object()
            .ok_or_else(|| EditorProjectToolError::new("Expected tool arguments as an object."))?
            .iter()
            .filter(|(_, value)| !value.is_null())
            .map(|(key, value)| (key.clone(), value.clone()))
            .collect();
        if !definition.read_only {
            if self.store.pending_confirmation_request().is_some() {
                return Err(EditorProjectToolError::new(
                    EditorAIRequestPolicy::PENDING_CONFIRMATION_MESSAGE.to_string(),
                ));
            }
            if name != "set_playback_state" && self.store.playback_state() != PlaybackState::Stopped
            {
                return Err(EditorProjectToolError::new(
                    "Stop simulation before changing project files or outputs.".to_string(),
                ));
            }
            if *self.project_tool_build_in_progress.borrow() {
                return Err(EditorProjectToolError::new(
                    "Wait for the current script compilation to finish.".to_string(),
                ));
            }
        }

        if let Some(result) = self.execute_workstation_tool(name, &args)? {
            return serde_json::to_vec(&result)
                .map_err(|error| EditorProjectToolError::new(error.to_string()));
        }
        if let Some(result) = self.execute_version_control_tool(name, &args)? {
            return serde_json::to_vec(&result)
                .map_err(|error| EditorProjectToolError::new(error.to_string()));
        }
        if let Some(result) = self.execute_diagnostic_tool(name, &evaluated_input)? {
            return Ok(result);
        }
        let mut result: Map<String, Value> = Map::new();
        result.insert("ok".into(), Value::Bool(true));
        match name {
            "get_project_info" => {
                result.insert(
                    "project_directory".into(),
                    Value::String(self.project_directory.clone()),
                );
                result.insert("scene_revision".into(), Value::from(self.scene.revision()));
                result.insert(
                    "entity_count".into(),
                    Value::from(self.scene.manifest().entity_count),
                );
                result.insert(
                    "playback_state".into(),
                    Value::String(playback_state_name(self.store.playback_state())),
                );
                result.insert(
                    "pending_confirmation".into(),
                    Value::Bool(self.store.pending_confirmation_request().is_some()),
                );
                result.insert(
                    "script_build_in_progress".into(),
                    Value::Bool(*self.project_tool_build_in_progress.borrow()),
                );
                result.insert(
                    "script_execution_trusted".into(),
                    Value::Bool(
                        self.workstation
                            .scripts
                            .manager()
                            .project_trust_state()
                            .allows_execution(),
                    ),
                );
                result.insert(
                    "ai_provider".into(),
                    Value::String(self.store.ai_settings().provider_id.clone()),
                );
                result.insert(
                    "ai_credential_available".into(),
                    Value::Bool(self.has_stored_ai_key(None)),
                );
                result.insert(
                    "script_sdk_available".into(),
                    Value::Bool(self.script_sdk_available()),
                );
            }
            "get_scripting_api" => {
                result.insert(
                    "documentation".into(),
                    Value::String(Self::gameplay_scripting_api()),
                );
            }
            "get_runtime_state" => {
                let debug = self
                    .scene
                    .scene()
                    .resource::<ScriptDebugState>()
                    .unwrap_or_default();
                result.insert(
                    "entity_count".into(),
                    Value::from(self.scene.scene().snapshot().entity_count),
                );
                let rendered = self.last_render_frame_stats.borrow();
                let mut render = Map::new();
                render.insert("frame_index".into(), Value::from(rendered.frame_index));
                render.insert(
                    "visible_mesh_instances".into(),
                    Value::from(rendered.visible_mesh_instance_count),
                );
                render.insert(
                    "draw_call_count".into(),
                    Value::from(rendered.draw_call_count),
                );
                render.insert(
                    "viewport_valid".into(),
                    Value::Bool(self.last_viewport_surface_state.borrow().is_valid()),
                );
                result.insert("render".into(), Value::Object(render));
                result.insert(
                    "unresolved_bindings".into(),
                    Value::from(self.scene.unresolved_script_binding_descriptions(true)),
                );
                let mut scripts = Vec::new();
                let scene = self.scene.scene();
                for (entity, values) in debug
                    .entities
                    .iter()
                    .filter(|(entity, _)| scene.contains(**entity))
                    .take(100)
                {
                    scripts.push(serde_json::json!({
                        "entity_id": format!("scene:{}", entity.raw_value()),
                        "values": values,
                    }));
                }
                result.insert("scripts".into(), Value::Array(scripts));
            }
            "list_scripts" => {
                self.validate_project_scripts_directory()?;
                let files = self.workstation.scripts.manager().scan_script_files()?;
                let snapshot = self.workstation.scripts.snapshot();
                let scripts = files
                    .into_iter()
                    .map(|file| {
                        let filename = file.url.file_name().and_then(|name| name.to_str()).unwrap_or("");
                        let url = self.project_script_url(filename)?;
                        let document = snapshot
                            .documents
                            .iter()
                            .find(|document| document.file.identifier == file.identifier);
                        let sha = CapabilityDigest::sha256(&self.bounded_script_data(&url)?);
                        Ok(serde_json::json!({
                            "filename": url.file_name().unwrap_or_default().to_string_lossy(),
                            "identifier": file.identifier,
                            "sha256": sha,
                            "unsaved_changes": document.map(|d| d.is_dirty).unwrap_or(false),
                            "diagnostics": document.map(|d| grapheme_suffix(&d.output, 8192)).unwrap_or_default(),
                        }))
                    })
                    .collect::<Result<Vec<_>, EditorProjectToolError>>()?;
                result.insert("scripts".into(), Value::Array(scripts));
            }
            "read_script" => {
                let url = self.project_script_url(
                    args.get("filename").and_then(Value::as_str).unwrap_or(""),
                )?;
                let data = self.bounded_script_data(&url)?;
                let source = String::from_utf8(data.clone()).map_err(|_| {
                    EditorProjectToolError::new("Script must contain UTF-8 source.".to_string())
                })?;
                result.insert(
                    "filename".into(),
                    Value::String(
                        url.file_name()
                            .unwrap_or_default()
                            .to_string_lossy()
                            .into_owned(),
                    ),
                );
                result.insert("source".into(), Value::String(source));
                result.insert(
                    "sha256".into(),
                    Value::String(CapabilityDigest::sha256(&data)),
                );
            }
            "write_script" => {
                let url = self.project_script_url(
                    args.get("filename").and_then(Value::as_str).unwrap_or(""),
                )?;
                let source = args
                    .get("source")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string();
                if source.len() > 262_144 {
                    return Err(EditorProjectToolError::new(
                        "Source exceeds 256 KiB.".to_string(),
                    ));
                }
                if url.exists() {
                    let has_dirty =
                        self.workstation
                            .scripts
                            .snapshot()
                            .documents
                            .iter()
                            .any(|document| {
                                document.is_dirty
                                    && PathIdentity::same_location(&document.file.url, &url)
                            });
                    if has_dirty {
                        return Err(EditorProjectToolError::new(format!(
                            "The editor has unsaved changes for {}. Save or resolve them first.",
                            url.file_name().unwrap_or_default().to_string_lossy()
                        )));
                    }
                    let current = CapabilityDigest::sha256(&self.bounded_script_data(&url)?);
                    if args.get("expected_sha256").and_then(Value::as_str) != Some(&current) {
                        return Err(EditorProjectToolError::new(
                            "Source changed or expected_sha256 is missing. Read the script again before replacing it.".to_string(),
                        ));
                    }
                    self.workstation
                        .scripts
                        .manager()
                        .write_source(&source, &url)?;
                    self.workstation.scripts.refresh_from_disk();
                } else {
                    if args.get("expected_sha256").is_some() {
                        return Err(EditorProjectToolError::new(
                            "The expected source no longer exists.".to_string(),
                        ));
                    }
                    let name = url.file_stem().and_then(|n| n.to_str()).unwrap_or_default();
                    if !self.workstation.scripts.create_script(name, &source) {
                        return Err(EditorProjectToolError::new(
                            "Could not create script. Check editor diagnostics.".to_string(),
                        ));
                    }
                }
                let file = self.workstation.scripts.manager().script_file_at(&url)?;
                if let Some(ref file) = file {
                    self.scene.register_dynamic_script_option(
                        &file.identifier,
                        &file.display_name,
                        &file.legacy_identifiers,
                    );
                    result.insert("identifier".into(), Value::String(file.identifier.clone()));
                }
                result.insert(
                    "filename".into(),
                    Value::String(
                        url.file_name()
                            .unwrap_or_default()
                            .to_string_lossy()
                            .into_owned(),
                    ),
                );
                result.insert(
                    "sha256".into(),
                    Value::String(CapabilityDigest::sha256(source.as_bytes())),
                );
                result.insert("executed".into(), Value::Bool(false));
                self.store.dispatch(EditorAction::ForceUIRefresh);
            }
            "compile_scripts" => {
                self.validate_project_scripts_directory()?;
                if !self
                    .workstation
                    .scripts
                    .manager()
                    .project_trust_state()
                    .allows_execution()
                {
                    return Err(EditorProjectToolError::new(
                        "Execution is blocked until this project is trusted.".to_string(),
                    ));
                }
                if self
                    .workstation
                    .scripts
                    .snapshot()
                    .documents
                    .iter()
                    .any(|document| document.is_dirty)
                {
                    return Err(EditorProjectToolError::new(
                        "Save unsaved script documents before compiling project files.".to_string(),
                    ));
                }
                *self.project_tool_build_in_progress.borrow_mut() = true;
                self.workstation.scripts.mark_all_builds_started();
                let report = self.compile_project_tool_scripts();
                *self.project_tool_build_in_progress.borrow_mut() = false;
                self.store.dispatch(EditorAction::ForceUIRefresh);
                return report;
            }
            "save_scene" => {
                let url = self
                    .save_scene_manifest()
                    .ok_or_else(|| self.project_output_error("Scene save failed."))?;
                result.insert(
                    "path".into(),
                    Value::String(url.to_string_lossy().into_owned()),
                );
            }
            "export_project" => {
                let url = self
                    .export_project()
                    .ok_or_else(|| self.project_output_error("Project export failed."))?;
                let descriptor = ProjectExporter::read_descriptor(&url)?;
                let executable =
                    ProjectExporter::runnable_executable_url(&descriptor.app_name, &url);
                result.insert(
                    "path".into(),
                    Value::String(url.to_string_lossy().into_owned()),
                );
                let runnable = is_executable_file(&executable);
                result.insert("runnable".into(), Value::Bool(runnable));
                if runnable {
                    result.insert(
                        "executable".into(),
                        Value::String(executable.to_string_lossy().into_owned()),
                    );
                }
            }
            "set_playback_state" => {
                let state = args
                    .get("state")
                    .and_then(Value::as_str)
                    .and_then(playback_state_from_name)
                    .ok_or_else(|| {
                        EditorProjectToolError::new("Invalid playback state.".to_string())
                    })?;
                self.apply_playback_state(state);
                result.insert(
                    "state".into(),
                    Value::String(playback_state_name(self.store.playback_state())),
                );
            }
            "get_console_messages" => {
                let limit = args.get("limit").and_then(Value::as_u64).unwrap_or(20) as usize;
                let state = self.store.state();
                let entries = &state.output.console_entries;
                let messages: Vec<Value> = entries[entries.len().saturating_sub(limit)..]
                    .iter()
                    .map(|entry| {
                        serde_json::json!({
                            "severity": entry.severity,
                            "message": entry.message,
                            "detail": grapheme_suffix(entry.detail.as_deref().unwrap_or_default(), 8192),
                        })
                    })
                    .collect();
                result.insert("messages".into(), Value::Array(messages));
            }
            _ => {
                return Err(EditorProjectToolError::new(format!(
                    "Unknown project tool: {name}"
                )));
            }
        }
        serde_json::to_vec(&Value::Object(result))
            .map_err(|error| EditorProjectToolError::new(error.to_string()))
    }

    fn compile_project_tool_scripts(&self) -> Result<Vec<u8>, EditorProjectToolError> {
        let (results, receive_results) = mpsc::channel();
        let (finished, receive_finished) = mpsc::channel();
        self.workstation.scripts.manager().compile_all_scripts(
            Arc::new(move |file, status| {
                let _ = results.send((file.clone(), status));
            }),
            Arc::new(move || {
                let _ = finished.send(());
            }),
        )?;
        receive_finished
            .recv()
            .map_err(|error| EditorProjectToolError::new(error.to_string()))?;

        let report = ProjectCompileReport::new();
        for (file, status) in receive_results.try_iter() {
            self.workstation
                .scripts
                .record_build_result(&file.identifier, status.clone());
            if matches!(status, CompilationStatus::Succeeded) {
                self.scene.register_dynamic_script_option(
                    &file.identifier,
                    &file.display_name,
                    &file.legacy_identifiers,
                );
            }
            report.append(&file, status);
        }
        report
            .data()
            .map_err(|error| EditorProjectToolError::new(error.to_string()))
    }

    /// `executeDiagnosticTool(name:input:)` — routes a UI diagnostic tool call:
    /// inactive or unknown tools return `None`, the editor-owned tools answer
    /// directly, and everything else runs against the attached UI session.
    pub(crate) fn execute_diagnostic_tool(
        &self,
        name: &str,
        input: &[u8],
    ) -> Result<Option<Vec<u8>>, EditorProjectToolError> {
        use cove_agent::ui_tools::Tools as UITools;

        let Some(tool) = UITools::tool(name) else {
            return Ok(None);
        };
        if name == "get_diagnostics" {
            let arguments: Value = serde_json::from_slice(input).unwrap_or_default();
            let limit = arguments
                .get("limit")
                .and_then(Value::as_i64)
                .unwrap_or(50);
            return self
                .diagnostic_report(limit)
                .map(|report| Some(report.to_string().into_bytes()));
        }
        // Task guides stay available in headless sessions.
        if name == "list_skills" {
            let skills = UITools::skills();
            let metadata: Vec<Value> = skills
                .skills
                .iter()
                .map(|skill| {
                    serde_json::json!({"name": skill.name, "description": skill.description})
                })
                .collect();
            let payload = serde_json::json!({"ok": true, "data": metadata});
            return Ok(Some(payload.to_string().into_bytes()));
        }
        if name == "read_skill" {
            let arguments: Value = serde_json::from_slice(input).unwrap_or_default();
            let skill_name = arguments
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or_default();
            let library = UITools::skills();
            let skill = library
                .read(skill_name)
                .map_err(|error| EditorProjectToolError::new(error.to_string()))?
                .clone();
            let payload = serde_json::json!({
                "ok": true,
                "data": {
                    "name": skill.name,
                    "description": skill.description,
                    "instructions": skill.instructions,
                },
            });
            return Ok(Some(payload.to_string().into_bytes()));
        }
        let Some(diagnostics) = self.diagnostic_session.ui() else {
            return Err(EditorProjectToolError::new(
                "UI diagnostics are unavailable: this editor has no attached graphical UI session.",
            ));
        };
        let arguments: Value = serde_json::from_slice(input).unwrap_or_default();
        let result = diagnostics
            .execute_read_json(tool, &arguments)
            .map_err(|error| EditorProjectToolError::new(error.to_string()))?;
        if !self.is_active() {
            return Err(EditorProjectToolError::new("Request cancelled."));
        }
        Ok(Some(result.to_string().into_bytes()))
    }

    /// `diagnosticReport(limit:)` — the editor's own diagnostics payload for the
    /// UI tool: scene revision, pacing/issues, frame trend and render passes.
    fn diagnostic_report(&self, limit: i64) -> Result<Value, EditorProjectToolError> {
        use crate::diagnostics::frame::trend::make_developer_frame_trend_summary;
        use crate::diagnostics::issues::assessment::make_developer_workbench_issues;
        use crate::diagnostics::particles::authoring::make_developer_particle_authoring_diagnostic_summary;
        use crate::diagnostics::particles::runtime::{
            make_developer_particle_diagnostic_summary, make_developer_particle_emitter_hotspots,
        };
        use crate::diagnostics::rendering::passes::make_developer_render_pass_breakdown;

        let state = self.store.state();
        let selected = self.store.selected_entity_id();
        let frame_stats = self.store.frame_stats();
        let render_stats = self.last_render_frame_stats.borrow().clone();
        let particle = self.scene.current_particle_frame_stats();
        let events = self.scene.current_particle_simulation_event_apply_report();
        let scalability = self.scene.current_particle_scalability_state();
        let render_scene = self.scene.current_render_scene();
        let particle_summary = make_developer_particle_diagnostic_summary(
            &particle,
            &events,
            &scalability,
            &render_scene.particle_summary,
            &render_stats,
        );
        let gpu_plan = self
            .scene
            .current_particle_gpu_simulation_plan(selected);
        let module_issues = self
            .scene
            .current_particle_module_validation_issues(selected);
        let authoring_summary = selected.map(|_| {
            make_developer_particle_authoring_diagnostic_summary(
                gpu_plan.as_ref(),
                &module_issues,
            )
        });
        let hotspots = make_developer_particle_emitter_hotspots(&particle, &events, 16);
        let issues = make_developer_workbench_issues(
            &frame_stats,
            &state.timing.frame_stats_history,
            &render_stats,
            Some(&particle_summary),
            authoring_summary.as_ref(),
            &hotspots,
            selected,
            &state.output.console_entries,
        );
        let bounded_limit = limit.max(1).min(100) as usize;
        let total = issues.len();
        let issues_payload: Vec<Value> = issues
            .into_iter()
            .take(bounded_limit)
            .map(|issue| serde_json::to_value(issue).unwrap_or(Value::Null))
            .collect();
        let trend = make_developer_frame_trend_summary(&state.timing.frame_stats_history);
        let passes: Vec<Value> = make_developer_render_pass_breakdown(&render_stats)
            .into_iter()
            .take(100)
            .map(|pass| serde_json::to_value(pass).unwrap_or(Value::Null))
            .collect();
        Ok(serde_json::json!({
            "ok": true,
            "sceneRevision": self.scene.revision(),
            "uiAvailable": self.diagnostic_session.ui().is_some(),
            "frameSampleCount": state.timing.frame_stats_history.len(),
            "renderFrameIndex": render_stats.frame_index,
            "issues": issues_payload,
            "totalIssueCount": total,
            "frameTrend": trend.map(|trend| serde_json::to_value(trend).unwrap_or(Value::Null)),
            "renderPasses": passes,
        }))
    }

    fn validate_project_scripts_directory(&self) -> Result<(), EditorProjectToolError> {
        let root = Path::new(&self.project_directory);
        let scripts = self.workstation.scripts.manager().scripts_directory_url();
        if !PathIdentity::contains(&scripts, root, false) {
            return Err(EditorProjectToolError::new(
                "Scripts directory escapes the project.",
            ));
        }
        Ok(())
    }

    fn project_script_url(&self, filename: &str) -> Result<PathBuf, EditorProjectToolError> {
        let is_valid = filename.strip_suffix(".rs").is_some_and(|stem| {
            let mut chars = stem.chars();
            chars
                .next()
                .is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
                && chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-'))
        });
        if !is_valid {
            return Err(EditorProjectToolError::new(
                "Use one top-level Rust filename without directories.",
            ));
        }
        self.validate_project_scripts_directory()?;
        let scripts = PathIdentity::canonical_url(
            &self.workstation.scripts.manager().scripts_directory_url(),
        );
        let url = PathIdentity::canonical_url(&scripts.join(filename));
        if !url
            .parent()
            .is_some_and(|parent| PathIdentity::same_location(parent, &scripts))
        {
            return Err(EditorProjectToolError::new("Script escapes the project."));
        }
        Ok(url)
    }

    fn bounded_script_data(&self, url: &Path) -> Result<Vec<u8>, EditorProjectToolError> {
        const MAX_BYTES: usize = 262_144;
        let expected_source = || {
            EditorProjectToolError::new("Expected a regular Rust source file of at most 256 KiB.")
        };
        let metadata = url.metadata().map_err(|_| expected_source())?;
        if !metadata.is_file() || metadata.len() > MAX_BYTES as u64 {
            return Err(expected_source());
        }
        let mut data = Vec::new();
        std::fs::File::open(url)
            .and_then(|file| file.take(MAX_BYTES as u64 + 1).read_to_end(&mut data))
            .map_err(|error| EditorProjectToolError::new(error.to_string()))?;
        if data.len() > MAX_BYTES {
            return Err(expected_source());
        }
        Ok(data)
    }

    /// `script_sdk_available` — Swift probed `ProjectScriptBuildConfiguration`'s
    /// `engineModulePaths`; D1 probes the cargo toolchain that builds gameplay
    /// scripts via `has_toolchain()`.
    fn script_sdk_available(&self) -> bool {
        let executable = std::env::current_exe().unwrap_or_default();
        ProjectScriptBuildConfiguration::discover_default(&executable).has_toolchain()
    }

    fn project_output_error(&self, fallback: &str) -> EditorProjectToolError {
        let detail = self
            .store
            .state()
            .output
            .console_entries
            .iter()
            .rev()
            .find(|entry| matches!(entry.severity, EditorConsoleSeverity::Error))
            .and_then(|entry| entry.detail.clone())
            .unwrap_or_else(|| fallback.to_string());
        EditorProjectToolError::new(detail)
    }

    fn gameplay_scripting_api() -> String {
        r#"Top-level Scripts/*.rs files use diffuse_script_api. Implement ScriptBehavior on a Default + Send type and register it with diffuse_scripts!(GameScript).
    Lifecycle methods take &mut self and &ScriptContext: on_start, on_pre_physics, on_update and on_destroy. Script state belongs to each binding.
    Use the stable script identifier from write_script or list_scripts when attaching a script.
    Read context.entity(), context.delta_time(), input_axis("move_x"), input_axis("move_y") and input_just_pressed("restart").
    Use float_parameter, double_parameter, string_parameter, vector3_parameter and entity_parameter for authored parameters.
    Create an entity with context.create_entity(Some("Name"), Transform3::IDENTITY). Use destroy_entity and set_parent to change the hierarchy.
    Transform3::new takes translation, quaternion rotation and scale arrays. Read local_transform or world_transform and update with set_local_transform or set_local_transform_for.
    Components use component_json and set_component_json with the component name and the scene registry's JSON payload. RenderMesh, Camera and Light are built-in components.
    Use resource_json and set_resource_json for resources. Use instantiate with the serialized prefab, optional parent and optional transform.
    Use draw_label, draw_rect and draw_progress_bar for the HUD. Pass a JSON object with string values to report_state to expose gameplay state through get_runtime_state.
    Source edits do not execute code. Compilation requires project trust and uses the host Rust toolchain."#
            .into()
    }
}

fn playback_state_name(state: PlaybackState) -> String {
    match state {
        PlaybackState::Stopped => "stopped",
        PlaybackState::Playing => "playing",
        PlaybackState::Paused => "paused",
    }
    .to_string()
}

fn playback_state_from_name(name: &str) -> Option<PlaybackState> {
    match name {
        "stopped" => Some(PlaybackState::Stopped),
        "playing" => Some(PlaybackState::Playing),
        "paused" => Some(PlaybackState::Paused),
        _ => None,
    }
}
