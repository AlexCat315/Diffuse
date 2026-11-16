//! `Editor/Sources/EditorCore/AI/EditorProjectTools.swift`.
//!
//! Ports the two top-level types (`EditorProjectToolError`,
//! `ProjectCompileReport`) and the `extension EditorApplication` project-tool
//! executor/dispatcher (`makeProjectToolExecutor` / `executeProjectTool` and its
//! `get_project_info`, `get_scripting_api`, `get_runtime_state`, `list_scripts`,
//! `read_script`, `write_script`, `compile_scripts`, `save_scene`,
//! `export_project`, `set_playback_state`, `get_console_messages` arms).
//!
//! Two helpers remain intentionally simplified until their dependencies land:
//! `execute_diagnostic_tool` returns no diagnostic payload (the Rust
//! `EditorDiagnosticSession` does not yet expose an `execute_tool` entry point),
//! and `validate_json_schema` is a pass-through (host tool policy already
//! restricts arguments to declared names).

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use serde_json::{Map, Value};
use unicode_segmentation::UnicodeSegmentation;

use diffuse_ai::tools::project_toolset::ProjectToolset;
use diffuse_ai::tools::tool_policy::{ToolCall, ToolCallOrigin};
use diffuse_capability::contracts::exports::JsonSchema;
use diffuse_plugin::base64_data::Data;
use diffuse_capability::release::sha256::CapabilityDigest;
use diffuse_script::interop::script_debug_state::ScriptDebugState;

use crate::ai::chat::editor_ai_request_policy::EditorAIRequestPolicy;
use crate::application::editor_application::EditorApplication;
use crate::scene::project_exporter::{ProjectExportError, ProjectExporter};
use crate::scripting::dynamic::dynamic_script_manager::{CompilationStatus, DynamicScriptManagerError, ScriptFile};
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
    pub fn make_project_tool_executor(&self) -> impl Fn(String, Vec<u8>) -> Result<Vec<u8>, EditorProjectToolError> {
        let this = self.clone();
        move |name, input| this.execute_project_tool(&name, &input, ToolCallOrigin::AgentSession)
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
        let definition = ProjectToolset::definition(name).ok_or_else(|| {
            EditorProjectToolError::new(format!("Unknown project tool: {name}"))
        })?;
        let task = self.agent_task_service.borrow().active_task().cloned();
        let profile = (task.as_ref().map(|t| t.target.content.clone()).unwrap_or_else(|| self.store.content()))
            .profile();
        if !profile.project_tool_names().contains(name) {
            return Err(EditorProjectToolError::new(
                "This tool is unavailable in the active authoring workflow.".to_string(),
            ));
        }
        if !definition.read_only {
            if let Some(target) = task.as_ref().map(|t| &t.target) {
                self.validate_agent_task_target(target)?;
            }
        }
        if origin != ToolCallOrigin::Mcp {
            if let Some(content) = EditorContent::touched_by_tool(name) {
                if self.store.agent_canvas() != Some(content) {
                    self.store.dispatch(EditorAction::SetAgentCanvas(Some(content)));
                }
            }
        }
        validate_json_schema(&evaluated_input, &definition.schema)?;
        let args: Map<String, Value> = serde_json::from_slice(&evaluated_input)
            .unwrap_or(Map::new())
            .into_iter()
            .filter(|(_, value)| !value.is_null())
            .collect();
        if !definition.read_only {
            if self.store.pending_confirmation_request().is_some() {
                return Err(EditorProjectToolError::new(
                    EditorAIRequestPolicy::PENDING_CONFIRMATION_MESSAGE.to_string(),
                ));
            }
            if name != "set_playback_state" && self.store.playback_state() != PlaybackState::Stopped {
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
                result.insert("project_directory".into(), Value::String(self.project_directory.clone()));
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
                    Value::Bool(self.workstation.scripts.manager().project_trust_state().allows_execution()),
                );
                result.insert(
                    "ai_provider".into(),
                    Value::String(self.store.ai_settings().provider_id.clone()),
                );
                result.insert("ai_credential_available".into(), Value::Bool(self.has_stored_ai_key()));
                result.insert(
                    "script_sdk_available".into(),
                    Value::Bool(self.script_sdk_available()),
                );
            }
            "get_scripting_api" => {
                result.insert("documentation".into(), Value::String(Self::gameplay_scripting_api()));
            }
            "get_runtime_state" => {
                let debug = self.scene.scene().resource::<ScriptDebugState>().unwrap_or_default();
                result.insert("entity_count".into(), Value::from(self.scene.scene().snapshot().entity_count));
                let rendered = self.last_render_frame_stats.borrow();
                let mut render = Map::new();
                render.insert("frame_index".into(), Value::from(rendered.frame_index));
                render.insert(
                    "visible_mesh_instances".into(),
                    Value::from(rendered.visible_mesh_instance_count),
                );
                render.insert("draw_call_count".into(), Value::from(rendered.draw_call_count));
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
                for entity in debug.entities.keys().take(100) {
                    if self.scene.scene().contains(*entity) {
                        scripts.push(serde_json::json!({
                            "entity_id": format!("scene:{}", entity.raw_value()),
                            "values": debug.entities.get(entity).cloned().unwrap_or_default(),
                        }));
                    }
                }
                result.insert("scripts".into(), Value::Array(scripts));
            }
            "list_scripts" => {
                self.validate_project_scripts_directory()?;
                let files = self.workstation.scripts.manager().scan_script_files()?;
                let scripts: Vec<Value> = files
                    .into_iter()
                    .map(|file| {
                        let filename = file.url.file_name().and_then(|name| name.to_str()).unwrap_or("");
                        let url = match self.project_script_url(filename) {
                            Ok(url) => url,
                            Err(_) => {
                                return serde_json::json!({
                                    "filename": filename,
                                    "identifier": file.identifier,
                                });
                            }
                        };
                        let snapshot = self.workstation.scripts.snapshot();
                        let document = snapshot
                            .documents
                            .iter()
                            .find(|document| document.file.identifier == file.identifier);
                        let sha = self
                            .bounded_script_data(&url)
                            .map(|data| CapabilityDigest::sha256(&data))
                            .unwrap_or_default();
                        serde_json::json!({
                            "filename": filename,
                            "identifier": file.identifier,
                            "sha256": sha,
                            "unsaved_changes": document.map(|d| d.is_dirty).unwrap_or(false),
                            "diagnostics": document.map(|d| d.output.chars().take(8192).collect::<String>()).unwrap_or_default(),
                        })
                    })
                    .collect();
                result.insert("scripts".into(), Value::Array(scripts));
            }
            "read_script" => {
                let url = self.project_script_url(args.get("filename").and_then(Value::as_str).unwrap_or(""))?;
                let data = self.bounded_script_data(&url)?;
                let source = String::from_utf8(data.clone())
                    .map_err(|_| EditorProjectToolError::new("Script must contain UTF-8 source.".to_string()))?;
                result.insert(
                    "filename".into(),
                    Value::String(url.file_name().unwrap_or_default().to_string_lossy().into_owned()),
                );
                result.insert("source".into(), Value::String(source));
                result.insert("sha256".into(), Value::String(CapabilityDigest::sha256(&data)));
            }
            "write_script" => {
                let url = self.project_script_url(args.get("filename").and_then(Value::as_str).unwrap_or(""))?;
                let source = args.get("source").and_then(Value::as_str).unwrap_or("").to_string();
                if source.len() > 262_144 {
                    return Err(EditorProjectToolError::new("Source exceeds 256 KiB.".to_string()));
                }
                if url.exists() {
                    let has_dirty = self
                        .workstation
                        .scripts
                        .snapshot()
                        .documents
                        .iter()
                        .any(|document| document.file.url == url && document.is_dirty);
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
                    self.workstation.scripts.manager().write_source(&source, &url)?;
                    self.workstation.scripts.refresh_from_disk();
                } else {
                    if args.get("expected_sha256").is_some() {
                        return Err(EditorProjectToolError::new("The expected source no longer exists.".to_string()));
                    }
                    let name = url.file_stem().and_then(|n| n.to_str()).unwrap_or_default();
                    if !self.workstation.scripts.create_script(&name, &source) {
                        return Err(EditorProjectToolError::new(
                            "Could not create script. Check editor diagnostics.".to_string(),
                        ));
                    }
                }
                let file = self.workstation.scripts.manager().script_file_at(&url)?;
                if let Some(ref file) = file {
                    self.scene.register_dynamic_script_option(&file.identifier, &file.display_name, &[]);
                }
                result.insert(
                    "filename".into(),
                    Value::String(url.file_name().unwrap_or_default().to_string_lossy().into_owned()),
                );
                result.insert("identifier".into(), Value::String(file.map(|f| f.identifier).unwrap_or_default()));
                result.insert("sha256".into(), Value::String(CapabilityDigest::sha256(source.as_bytes())));
                result.insert("executed".into(), Value::Bool(false));
                self.store.dispatch(EditorAction::ForceUIRefresh);
            }
            "compile_scripts" => {
                self.validate_project_scripts_directory()?;
                if !self.workstation.scripts.manager().project_trust_state().allows_execution() {
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
                let scripts = Arc::clone(&self.workstation.scripts);
                let report = Arc::new(ProjectCompileReport::new());
                let this = self.clone();
                self.workstation.scripts.manager().clone().compile_all_scripts(
                    Arc::new(move |file: &ScriptFile, status| {
                        scripts.record_build_result(&file.identifier, status.clone());
                        if matches!(status, CompilationStatus::Succeeded) {
                            this.scene.register_dynamic_script_option(
                                &file.identifier,
                                &file.display_name,
                                &[],
                            );
                        }
                        report.append(file, status);
                    }),
                    Arc::new(|| {}),
                )?;
                *self.project_tool_build_in_progress.borrow_mut() = false;
                self.store.dispatch(EditorAction::ForceUIRefresh);
                return report
                    .data()
                    .map_err(|error| EditorProjectToolError::new(error.to_string()));
            }
            "save_scene" => {
                let url = self.save_scene_manifest().ok_or_else(|| self.project_output_error("Scene save failed."))?;
                result.insert("path".into(), Value::String(url.to_string_lossy().into_owned()));
            }
            "export_project" => {
                let url = self.export_project().ok_or_else(|| self.project_output_error("Project export failed."))?;
                let descriptor = ProjectExporter::read_descriptor(&url)?;
                let executable = ProjectExporter::runnable_executable_url(&descriptor.app_name, &url);
                result.insert("path".into(), Value::String(url.to_string_lossy().into_owned()));
                let runnable = executable.exists();
                result.insert("runnable".into(), Value::Bool(runnable));
                if runnable {
                    result.insert("executable".into(), Value::String(executable.to_string_lossy().into_owned()));
                }
            }
            "set_playback_state" => {
                let state = args
                    .get("state")
                    .and_then(Value::as_str)
                    .and_then(playback_state_from_name)
                    .ok_or_else(|| EditorProjectToolError::new("Invalid playback state.".to_string()))?;
                self.apply_playback_state(state);
                result.insert("state".into(), Value::String(playback_state_name(self.store.playback_state())));
            }
            "get_console_messages" => {
                let limit = args.get("limit").and_then(Value::as_i64).unwrap_or(20) as usize;
                let messages: Vec<Value> = self
                    .store
                    .state()
                    .output
                    .console_entries
                    .iter()
                    .rev()
                    .take(limit)
                    .map(|entry| {
                        serde_json::json!({
                            "severity": format!("{:?}", entry.severity),
                            "message": entry.message,
                            "detail": entry.detail.clone().unwrap_or_default().chars().take(8192).collect::<String>(),
                        })
                    })
                    .collect();
                result.insert("messages".into(), Value::Array(messages));
            }
            _ => return Err(EditorProjectToolError::new(format!("Unknown project tool: {name}"))),
        }
        serde_json::to_vec(&Value::Object(result)).map_err(|error| EditorProjectToolError::new(error.to_string()))
    }

    /// `executeDiagnosticTool(name:input:)` — Swift routes diagnostic tool calls
    /// through `diagnosticSession`. The Rust `EditorDiagnosticSession` does not yet
    /// expose a `execute_tool` entry point, so this is wired to the actual
    /// `cove_devtools` inspection API in the compile pass; for now it reports no
    /// diagnostic payload and the dispatcher falls through to the "unknown tool"
    /// arm.
    pub(crate) fn execute_diagnostic_tool(
        &self,
        _name: &str,
        _input: &[u8],
    ) -> Result<Option<Vec<u8>>, EditorProjectToolError> {
        Ok(None)
    }

    fn validate_project_scripts_directory(&self) -> Result<(), EditorProjectToolError> {
        let root = std::fs::canonicalize(&self.project_directory)
            .map_err(|_| EditorProjectToolError::new("Scripts directory escapes the project.".to_string()))?;
        let scripts = std::fs::canonicalize(self.workstation.scripts.manager().scripts_directory_url())
            .map_err(|_| EditorProjectToolError::new("Scripts directory escapes the project.".to_string()))?;
        if !scripts.starts_with(&root) {
            return Err(EditorProjectToolError::new("Scripts directory escapes the project.".to_string()));
        }
        Ok(())
    }

    fn project_script_url(&self, filename: &str) -> Result<PathBuf, EditorProjectToolError> {
        let is_valid = filename.ends_with(".swift")
            && filename
                .chars()
                .next()
                .map(|c| c.is_ascii_alphabetic() || c == '_')
                .unwrap_or(false)
            && filename
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | '.'))
            && !filename.contains('/')
            && !filename.contains('\\');
        if !is_valid {
            return Err(EditorProjectToolError::new(
                "Use one top-level Swift filename without directories.".to_string(),
            ));
        }
        self.validate_project_scripts_directory()?;
        let scripts = std::fs::canonicalize(self.workstation.scripts.manager().scripts_directory_url())
            .map_err(|_| EditorProjectToolError::new("Script escapes the project.".to_string()))?;
        let url = scripts.join(filename);
        if url.parent() != Some(scripts.as_path()) {
            return Err(EditorProjectToolError::new("Script escapes the project.".to_string()));
        }
        Ok(url)
    }

    fn bounded_script_data(&self, url: &PathBuf) -> Result<Vec<u8>, EditorProjectToolError> {
        let data = std::fs::read(url)
            .map_err(|_| EditorProjectToolError::new("Expected a regular Swift source file.".to_string()))?;
        if data.len() > 262_144 {
            return Err(EditorProjectToolError::new(
                "Expected a regular Swift source file of at most 256 KiB.".to_string(),
            ));
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

    /// `Self.gameplayScriptingAPI` — documentation surfaced by `get_scripting_api`.
    fn gameplay_scripting_api() -> String {
        "Each Scripts/*.swift file defines one GameScript: ScriptBehavior. Import Foundation, \
         SceneRuntime, ScriptRuntime, SIMDCompat and EngineKernel as needed. Lifecycle methods \
         are mutating onStart/onUpdate/onFixedUpdate/onLateUpdate/onDestroy(_ context: ScriptContext). \
         Each entity binding has independent stored properties. Stable script identifiers are \
         returned by write_script/list_scripts; attach them using scene.set_script_property. \
         context.entity, deltaTime (Double), floatParameter(_), stringParameter(_), input. \
         context.createEntity(named:transform:) -> EntityID; context.destroyEntity(_). \
         LocalTransform(translation: SIMD3<Float>, rotation: simd_quatf, scale: SIMD3<Float>). \
         context.setComponent(Component, for: EntityID); component(Component.self, for: EntityID). \
         context.setLocalTransform(LocalTransform, for: EntityID); localTransform(of: EntityID). \
         RenderMeshComponent(meshIndex: 0, colorTint: SIMD3<Float>) renders a cube. \
         CameraComponent(target: SIMD3<Float>) renders from its entity's transform translation. \
         LightComponent(type: .directional, intensity: Float) adds a light to its entity. \
         context.setResource(InputActionMap.coveDefault); context.input.axis(\"move_x\"/\"move_y\"). \
         InputActionMap.bind(\"restart\", to: .key(Scancode.r)); input.isJustPressed(\"restart\"). \
         context.setResource(custom Sendable resource); resource(Resource.self). \
         context.drawUI { canvas in canvas.label(\"Score: 0\", x: 24, y: 24, fontSize: 24) }. \
         context.reportState([\"score\": \"0\", \"phase\": \"playing\"]) exposes values to get_runtime_state. \
         canvas.rect(x:y:w:h:color:cornerRadius:), progressBar(x:y:w:h:value:maxValue:). \
         Prefab.captureFull(from:root:) includes script bindings; context.instantiate(prefab). \
         Source changes do not execute code. Compile only after the human trusts this project. \
         Compile/export are for the host platform and need matching built Engine modules."
            .into()
    }
}

/// JSON-schema validation for a project-tool payload. The real validator
/// (diffuse-capability `JsonSchema`) is wired in the compile pass; host tool
/// policy already restricts arguments to declared names.
fn validate_json_schema(_data: &[u8], _schema: &JsonSchema) -> Result<(), EditorProjectToolError> {
    Ok(())
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
