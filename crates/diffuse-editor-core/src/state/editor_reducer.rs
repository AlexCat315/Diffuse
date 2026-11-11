//! `Editor/Sources/EditorCore/State/EditorReducer.swift`.
//!
//! Every mutation of the editor state arrives as one [`EditorAction`]; the
//! reducer is pure, so the store can diff the state before and after.

use std::collections::BTreeSet;

use cove_logging::{Level, LogRecord, LogValue};
use cove_ui_compose::primitives::text::TextBuffer;

use diffuse_intent::invocation::capability_invocation::ConfirmationRequestBatch;
use diffuse_plugin::Uuid;

use crate::ai::chat::ai_chat_message::{AIChatAssistantState, AIChatMessage};
use crate::ai::chat::editor_agent_task_service::EditorAgentTask;
use crate::ai::chat::editor_ai_settings::{EditorAISettings, EditorCapabilitySettings};
use crate::ai::plugins::editor_plugin_management_state::EditorPluginManagementState;
use crate::state::editor_state::{
    EditorAssetDragPayload, EditorConsoleEntry, EditorConsoleSeverity, EditorFrameStats,
    EditorGizmoMode, EditorGizmoSpace, EditorLanguage, EditorParticleDiagnosticsSample,
    EditorPendingCloseRequest, EditorPhysicsDebugOverlayOptions, EditorPhysicsDebugOverlayScope,
    EditorState, EditorThemeMode, EditorVSyncMode, EditorViewportShadingMode, PlaybackState,
    SelectionPrimaryModifierBehavior,
};
use crate::state::workspace::content::EditorContent;
use crate::state::workspace::editor_workbench_state::{
    EditorGamePreviewResolution, EditorIssueTarget, EditorOperation, EditorOperationStatus,
    EditorOutputTab, EditorScriptNavigationRequest, EditorViewportMode,
};

#[derive(Clone)]
pub enum EditorAction {
    /// Dispatched every engine frame.
    TickFrame(u64),
    SetConnected(bool),
    SetSelectedEntity(Option<u64>),
    SetPrimarySelectedEntity(Option<u64>),
    SetSelectedEntities(BTreeSet<u64>),
    SetPlaybackState(PlaybackState),
    SetAgentTasks(Vec<EditorAgentTask>),
    BeginSceneDocument,
    SetContent(EditorContent),
    SetSceneRevision(u64),
    MarkSceneSaved(u64),
    MarkSceneUnsaved,
    SetSceneRecoveryPending(bool),
    RequestClose(EditorPendingCloseRequest),
    DismissCloseRequest,
    SetWindowFocused(bool),
    SetWindowMinimized(bool),
    SetWindowOccluded(bool),
    SetGizmoMode(EditorGizmoMode),
    SetGizmoSpace(EditorGizmoSpace),
    SetViewportShadingMode(EditorViewportShadingMode),
    SetViewportShadowsEnabled(bool),
    SetViewportGridEnabled(bool),
    ViewportCameraChanged,
    SetViewportRenderScalePercent(i64),
    SetViewportInteractionDownscale(bool),
    SetViewportRealtime(bool),
    SetPhysicsDebugOverlayOptions(EditorPhysicsDebugOverlayOptions),
    SetPhysicsDebugOverlayScope(EditorPhysicsDebugOverlayScope),
    SetTranslateSnapEnabled(bool),
    SetRotateSnapEnabled(bool),
    SetScaleSnapEnabled(bool),
    SetTranslateSnapStep(f32),
    SetRotateSnapStepDegrees(f32),
    SetScaleSnapStep(f32),
    SetPrimarySelectBehavior(SelectionPrimaryModifierBehavior),
    SetThemeMode(EditorThemeMode),
    SetThemeID(String),
    ThemeCatalogChanged,
    SetLanguage(EditorLanguage),
    ForceUIRefresh,
    SetVSyncMode(EditorVSyncMode),
    BeginAssetDrag(EditorAssetDragPayload),
    UpdateAssetDragCursor {
        x: f32,
        y: f32,
    },
    EndAssetDrag,
    SetInspectorSectionCollapsed {
        id: String,
        is_collapsed: bool,
    },
    SetInspectorSectionsCollapsed {
        ids: BTreeSet<String>,
        is_collapsed: bool,
    },
    SetPendingConfirmationRequest(Option<ConfirmationRequestBatch>),
    SetAISettings(EditorAISettings),
    SetCapabilitySettings(EditorCapabilitySettings),
    SetPluginManagementState(EditorPluginManagementState),
    SetAIStatusMessage(Option<String>),
    SetAIWarnings(Vec<String>),
    AppendChatMessage(AIChatMessage),
    UpdateChatMessage {
        id: String,
        assistant_state: AIChatAssistantState,
    },
    ClearChatHistory,
    SetAgentCanvas(Option<EditorContent>),
    /// Swift spelled the five payload fields with `severity` defaulting to
    /// `.info` and the rest to `nil`; Rust enums cannot carry defaults, so
    /// [`EditorAction::console_message`] supplies them.
    AppendConsoleMessage {
        message: String,
        severity: EditorConsoleSeverity,
        detail: Option<String>,
        target: Option<EditorIssueTarget>,
        next_step: Option<String>,
    },
    SetOperation(EditorOperation),
    NavigateToScript(EditorScriptNavigationRequest),
    NavigateToAsset(Option<String>),
    SetInspectorSceneSettingsVisible(bool),
    SetCommandPaletteQuery(TextBuffer),
    SetOutputTab(EditorOutputTab),
    SetViewportMode(EditorViewportMode),
    SetGamePreviewResolution(EditorGamePreviewResolution),
    SetGamePreviewHUDEnabled(bool),
    SetGamePreviewFocused(bool),
    AppendLogRecord(LogRecord),
    ClearConsole,
    SetCommandPaletteVisible(bool),
    FrameTimingUpdated,
    /// Bump the viewport surface revision so only viewport subscribers pull
    /// the newest `current_viewport_surface_state()`.
    ViewportSurfaceUpdated,
    UpdateFrameStats(EditorFrameStats),
    UpdateParticleDiagnostics(EditorParticleDiagnosticsSample),
}

impl EditorAction {
    /// Swift's `appendConsoleMessage(_:severity:detail:target:nextStep:)` with
    /// the `severity: .info` and `nil` defaults.
    pub fn console_message(message: impl Into<String>) -> EditorAction {
        EditorAction::AppendConsoleMessage {
            message: message.into(),
            severity: EditorConsoleSeverity::Info,
            detail: None,
            target: None,
            next_step: None,
        }
    }

    pub fn notifies_subscribers(&self) -> bool {
        !matches!(
            self,
            EditorAction::TickFrame(_) | EditorAction::UpdateAssetDragCursor { .. }
        )
    }

    pub fn invalidates_whole_state_observation(&self) -> bool {
        !matches!(
            self,
            EditorAction::FrameTimingUpdated
                | EditorAction::ViewportSurfaceUpdated
                | EditorAction::UpdateFrameStats(_)
                | EditorAction::UpdateParticleDiagnostics(_)
        )
    }
}

pub struct EditorReducer;

impl EditorReducer {
    pub fn reduce(state: &mut EditorState, action: EditorAction) {
        match action {
            EditorAction::SetConnected(value) => state.timing.connected = value,
            EditorAction::SetSelectedEntity(value) => {
                state.selection.selected_entity_id = value;
                match value {
                    Some(entity_id) => {
                        state.selection.selected_entity_ids = BTreeSet::from([entity_id])
                    }
                    None => state.selection.selected_entity_ids.clear(),
                }
            }
            EditorAction::SetPrimarySelectedEntity(value) => {
                state.selection.selected_entity_id = value;
                match value {
                    Some(entity_id) => {
                        if !state.selection.selected_entity_ids.contains(&entity_id) {
                            state.selection.selected_entity_ids = BTreeSet::from([entity_id]);
                        }
                    }
                    None => state.selection.selected_entity_ids.clear(),
                }
            }
            EditorAction::SetSelectedEntities(entity_ids) => {
                let current = state.selection.selected_entity_id;
                state.selection.selected_entity_ids = entity_ids;
                state.selection.selected_entity_id = match current {
                    Some(current) if state.selection.selected_entity_ids.contains(&current) => {
                        Some(current)
                    }
                    _ => state.selection.selected_entity_ids.iter().next().copied(),
                };
            }
            EditorAction::SetPlaybackState(value) => state.timing.playback_state = value,
            EditorAction::SetAgentTasks(tasks) => state.assistant.agent_tasks = tasks,
            EditorAction::BeginSceneDocument => state.document.identity = Uuid::new(),
            EditorAction::SetContent(content) => state.content = content,
            EditorAction::SetSceneRevision(value) => state.document.scene_revision = value,
            EditorAction::MarkSceneSaved(revision) => {
                state.document.last_saved_scene_revision = revision;
                state.document.scene_recovery_pending = false;
            }
            EditorAction::MarkSceneUnsaved => {
                // A new empty document can have the same revision as the previous saved document.
                state.document.last_saved_scene_revision =
                    state.document.scene_revision.wrapping_sub(1);
            }
            EditorAction::SetSceneRecoveryPending(pending) => {
                state.document.scene_recovery_pending = pending
            }
            EditorAction::RequestClose(request) => {
                state.document.pending_close_request = Some(request)
            }
            EditorAction::DismissCloseRequest => state.document.pending_close_request = None,
            EditorAction::TickFrame(n) => state.timing.frame_index = n,
            EditorAction::SetWindowFocused(value) => state.window.focused = value,
            EditorAction::SetWindowMinimized(value) => state.window.minimized = value,
            EditorAction::SetWindowOccluded(value) => state.window.occluded = value,
            EditorAction::SetGizmoMode(value) => state.viewport.gizmo_mode = value,
            EditorAction::SetGizmoSpace(space) => state.viewport.gizmo_space = space,
            EditorAction::SetViewportShadingMode(mode) => state.viewport.shading_mode = mode,
            EditorAction::SetViewportShadowsEnabled(enabled) => state.shadows.enabled = enabled,
            EditorAction::SetViewportGridEnabled(enabled) => state.viewport.grid_enabled = enabled,
            EditorAction::SetViewportRenderScalePercent(percent) => {
                state.viewport.render_scale_percent =
                    EditorState::sanitized_render_scale_percent(percent)
            }
            EditorAction::SetViewportInteractionDownscale(enabled) => {
                state.viewport.interaction_downscale_enabled = enabled
            }
            EditorAction::SetViewportRealtime(enabled) => state.viewport.realtime_enabled = enabled,
            EditorAction::SetPhysicsDebugOverlayOptions(options) => {
                state.viewport.physics_debug_overlay_options =
                    options.intersection(EditorPhysicsDebugOverlayOptions::all())
            }
            EditorAction::SetPhysicsDebugOverlayScope(scope) => {
                state.viewport.physics_debug_overlay_scope = scope
            }
            EditorAction::SetTranslateSnapEnabled(enabled) => {
                state.snapping.translate_snap_enabled = enabled
            }
            EditorAction::SetRotateSnapEnabled(enabled) => {
                state.snapping.rotate_snap_enabled = enabled
            }
            EditorAction::SetScaleSnapEnabled(enabled) => {
                state.snapping.scale_snap_enabled = enabled
            }
            EditorAction::ViewportCameraChanged => {
                state.viewport.camera_revision = state.viewport.camera_revision.wrapping_add(1)
            }
            EditorAction::SetTranslateSnapStep(step) => {
                state.snapping.translate_snap_step =
                    EditorState::sanitized_translate_snap_step(step)
            }
            EditorAction::SetRotateSnapStepDegrees(step) => {
                state.snapping.rotate_snap_step_degrees =
                    EditorState::sanitized_rotate_snap_step(step)
            }
            EditorAction::SetScaleSnapStep(step) => {
                state.snapping.scale_snap_step = EditorState::sanitized_scale_snap_step(step)
            }
            EditorAction::SetPrimarySelectBehavior(behavior) => {
                state.selection.primary_select_behavior = behavior
            }
            EditorAction::SetThemeID(id) => state.presentation.set_theme_id(id),
            EditorAction::ThemeCatalogChanged => state.presentation.refresh_theme_catalog(),
            EditorAction::SetThemeMode(mode) => {
                state.presentation.set_theme_mode(mode);
            }
            EditorAction::SetLanguage(language) => {
                state.presentation.set_language(language);
            }
            EditorAction::ForceUIRefresh => state.presentation.force_refresh(),
            EditorAction::SetVSyncMode(mode) => state.vsync_mode = mode,
            EditorAction::BeginAssetDrag(payload) => {
                state.navigation.active_asset_drag = Some(payload)
            }
            EditorAction::UpdateAssetDragCursor { x, y } => {
                if let Some(payload) = state.navigation.active_asset_drag.as_mut() {
                    payload.cursor_x = x;
                    payload.cursor_y = y;
                }
            }
            EditorAction::EndAssetDrag => state.navigation.active_asset_drag = None,
            EditorAction::SetInspectorSectionCollapsed { id, is_collapsed } => {
                if is_collapsed {
                    state.selection.inspector_collapsed_section_ids.insert(id);
                } else {
                    state.selection.inspector_collapsed_section_ids.remove(&id);
                }
            }
            EditorAction::SetInspectorSectionsCollapsed { ids, is_collapsed } => {
                if is_collapsed {
                    state.selection.inspector_collapsed_section_ids.extend(ids);
                } else {
                    for id in &ids {
                        state.selection.inspector_collapsed_section_ids.remove(id);
                    }
                }
            }
            EditorAction::SetPendingConfirmationRequest(request) => {
                // Reviews come from scene edit plans.
                if request.is_some() {
                    state.assistant.agent_canvas = Some(EditorContent::Scene);
                }
                state.assistant.pending_confirmation_request = request;
            }
            EditorAction::SetAISettings(settings) => state.assistant.ai_settings = settings,
            EditorAction::SetCapabilitySettings(settings) => {
                state.assistant.capability_settings = settings
            }
            EditorAction::SetPluginManagementState(plugin_management) => {
                state.assistant.plugin_management = plugin_management
            }
            EditorAction::SetAIStatusMessage(message) => {
                state.assistant.ai_status_message = message
            }
            EditorAction::SetAIWarnings(warnings) => state.assistant.ai_warnings = warnings,
            EditorAction::AppendChatMessage(message) => state.assistant.chat_messages.push(message),
            EditorAction::UpdateChatMessage {
                id,
                assistant_state,
            } => {
                if let Some(message) = state
                    .assistant
                    .chat_messages
                    .iter_mut()
                    .find(|message| message.id == id)
                {
                    message.assistant_state = Some(assistant_state);
                }
            }
            EditorAction::ClearChatHistory => {
                // Everything the conversation produced goes with it. A pending
                // review is an assistant-authored plan, not project content, and it
                // is persisted: leaving it behind would restore a review for a
                // conversation — and possibly a plugin — that no longer exists.
                state.assistant.chat_messages.clear();
                state.assistant.agent_canvas = None;
                state.assistant.pending_confirmation_request = None;
                state.assistant.ai_status_message = None;
                state.assistant.ai_warnings.clear();
            }
            EditorAction::SetAgentCanvas(content) => state.assistant.agent_canvas = content,
            EditorAction::SetOperation(operation) => {
                let operations = &mut state.navigation.operations;
                operations.retain(|existing| existing.id != operation.id);
                operations.push(operation);
                if operations.len() > 30
                    && let Some(oldest) = operations
                        .iter()
                        .position(|operation| operation.status != EditorOperationStatus::Running)
                {
                    operations.remove(oldest);
                }
            }
            EditorAction::NavigateToScript(request) => {
                state.navigation.script_navigation = Some(request)
            }
            EditorAction::NavigateToAsset(id) => {
                state.navigation.asset_navigation_id = id;
                state.navigation.asset_navigation_revision =
                    state.navigation.asset_navigation_revision.wrapping_add(1);
            }
            EditorAction::SetInspectorSceneSettingsVisible(visible) => {
                state.selection.inspector_scene_settings_visible = visible
            }
            EditorAction::SetCommandPaletteQuery(query) => {
                state.navigation.command_palette_query = query
            }
            EditorAction::SetOutputTab(tab) => state.output.output_tab = tab,
            EditorAction::SetViewportMode(mode) => {
                if state.viewport.mode != mode {
                    state.viewport.mode = mode;
                    state.viewport.game_preview_focused = false;
                }
            }
            EditorAction::SetGamePreviewResolution(resolution) => {
                state.viewport.game_preview_resolution = resolution
            }
            EditorAction::SetGamePreviewHUDEnabled(enabled) => {
                state.viewport.game_preview_hud_enabled = enabled
            }
            EditorAction::SetGamePreviewFocused(focused) => {
                state.viewport.game_preview_focused = focused
            }
            EditorAction::AppendConsoleMessage {
                message,
                severity,
                detail,
                target,
                next_step,
            } => {
                let trimmed = message.trim().to_string();
                if trimmed.is_empty() {
                    return;
                }
                state.output.console_entries.push(EditorConsoleEntry {
                    id: state.output.next_console_entry_id,
                    severity,
                    message: trimmed,
                    detail,
                    target,
                    next_step,
                    record: None,
                });
                state.output.next_console_entry_id =
                    state.output.next_console_entry_id.wrapping_add(1);
                let entries = &mut state.output.console_entries;
                if entries.len() > 200 {
                    let excess = entries.len() - 200;
                    entries.drain(..excess);
                }
            }
            EditorAction::AppendLogRecord(record) => {
                let severity = if record.level >= Level::Error {
                    EditorConsoleSeverity::Error
                } else if record.level >= Level::Warning {
                    EditorConsoleSeverity::Warning
                } else {
                    EditorConsoleSeverity::Info
                };
                let detail = format!(
                    "[{}] {}:{}\n{}",
                    record.label,
                    record.location.file,
                    record.location.line,
                    format_log_metadata(&record.metadata)
                );
                let message = record.message.clone();
                state.output.console_entries.push(EditorConsoleEntry {
                    id: state.output.next_console_entry_id,
                    severity,
                    message,
                    detail: Some(detail),
                    target: None,
                    next_step: None,
                    record: Some(record),
                });
                state.output.next_console_entry_id =
                    state.output.next_console_entry_id.wrapping_add(1);
                let entries = &mut state.output.console_entries;
                if entries.len() > 200 {
                    let excess = entries.len() - 200;
                    entries.drain(..excess);
                }
            }
            EditorAction::ClearConsole => state.output.console_entries.clear(),
            EditorAction::SetCommandPaletteVisible(visible) => {
                state.navigation.command_palette_visible = visible
            }
            EditorAction::FrameTimingUpdated => {
                state.timing.frame_timing_revision =
                    state.timing.frame_timing_revision.wrapping_add(1)
            }
            EditorAction::ViewportSurfaceUpdated => {
                state.viewport.surface_revision = state.viewport.surface_revision.wrapping_add(1)
            }
            EditorAction::UpdateFrameStats(stats) => {
                state.timing.frame_stats = stats.clone();
                state.append_frame_stats_history(stats);
            }
            EditorAction::UpdateParticleDiagnostics(sample) => {
                state.append_particle_diagnostics_history(sample)
            }
        }
    }
}

/// Swift interpolated the metadata dictionary; the Rust record stores typed
/// values, so the text spells them without the enum wrapper and in sorted key
/// order (Swift left the order unspecified).
fn format_log_metadata(metadata: &std::collections::BTreeMap<String, LogValue>) -> String {
    let entries: Vec<String> = metadata
        .iter()
        .map(|(key, value)| format!("{key}: {}", format_log_value(value)))
        .collect();
    format!("[{}]", entries.join(", "))
}

fn format_log_value(value: &LogValue) -> String {
    match value {
        LogValue::String(text) => text.clone(),
        LogValue::Array(values) => {
            let entries: Vec<String> = values.iter().map(format_log_value).collect();
            format!("[{}]", entries.join(", "))
        }
        LogValue::Object(values) => format_log_metadata(values),
    }
}
