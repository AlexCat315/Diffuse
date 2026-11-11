//! `Editor/Sources/EditorCore/State/EditorStore.swift`.
//!
//! The observable container around [`EditorState`] and [`EditorReducer`]:
//! callers mutate only through [`EditorStore::dispatch`] and observe through
//! [`EditorStore::subscribe`], while `version` bumps once per notification.
//!
//! Swift marked the class `@unchecked Sendable` to cross nonisolated closures;
//! Rust's equivalent main-thread container is `Rc`/`RefCell` (MIGRATION.md
//! §5.5), so the store is deliberately neither `Send` nor `Sync`.

use std::cell::{Cell, RefCell};
use std::collections::{BTreeMap, BTreeSet};
use std::rc::Rc;

use cove_logging::{Level, LogEvent, LogSystem, LogValue};
use cove_ui_compose::primitives::text::TextBuffer;
use cove_ui_compose::scene_core::scene::{
    ObservableObject, ObservableStateRegistrar, StateAccessKey,
};

use diffuse_intent::invocation::capability_invocation::ConfirmationRequestBatch;

use crate::ai::chat::ai_chat_message::AIChatMessage;
use crate::ai::chat::editor_agent_task_service::EditorAgentTask;
use crate::ai::chat::editor_ai_settings::{EditorAISettings, EditorCapabilitySettings};
use crate::ai::plugins::editor_plugin_management_state::EditorPluginManagementState;
use crate::state::editor_presentation_state::EditorPresentationState;
use crate::state::editor_reducer::{EditorAction, EditorReducer};
use crate::state::editor_state::{
    EditorAssetDragPayload, EditorConsoleEntry, EditorConsoleSeverity, EditorFrameStats,
    EditorFrameStatsHistorySample, EditorGizmoMode, EditorGizmoSpace, EditorLanguage,
    EditorParticleDiagnosticsSample, EditorPendingCloseRequest, EditorPhysicsDebugOverlayOptions,
    EditorPhysicsDebugOverlayScope, EditorState, EditorThemeMode, EditorVSyncMode,
    EditorViewportShadingMode, PlaybackState, SelectionPrimaryModifierBehavior,
};
use crate::state::workspace::content::EditorContent;
use crate::state::workspace::editor_workbench_state::{
    EditorGamePreviewResolution, EditorOperation, EditorOutputTab, EditorScriptNavigationRequest,
    EditorViewportMode,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
enum ObservationKey {
    State,
    Connected,
    SelectedEntityID,
    SelectedEntityIDs,
    PlaybackState,
    AgentTasks,
    Content,
    SceneRevision,
    LastSavedSceneRevision,
    SceneRecoveryPending,
    PendingCloseRequest,
    FrameIndex,
    FrameTimingRevision,
    FrameStats,
    FrameStatsHistory,
    ParticleDiagnosticsHistory,
    ViewportSurfaceRevision,
    ViewportCameraRevision,
    WindowFocused,
    WindowMinimized,
    WindowOccluded,
    ShouldRender,
    GizmoMode,
    GizmoSpace,
    ViewportShadingMode,
    ViewportShadowsEnabled,
    ViewportGridEnabled,
    ViewportRenderScalePercent,
    ViewportInteractionDownscaleEnabled,
    ViewportRealtimeEnabled,
    PhysicsDebugOverlayOptions,
    PhysicsDebugOverlayScope,
    TranslateSnapEnabled,
    RotateSnapEnabled,
    ScaleSnapEnabled,
    TranslateSnapStep,
    RotateSnapStepDegrees,
    ScaleSnapStep,
    PrimarySelectBehavior,
    Presentation,
    ThemeMode,
    Language,
    UIRefreshRevision,
    GeometryRevision,
    VSyncMode,
    ActiveAssetDrag,
    InspectorCollapsedSectionIDs,
    PendingConfirmationRequest,
    AISettings,
    CapabilitySettings,
    PluginManagement,
    AIStatusMessage,
    AIWarnings,
    ChatMessages,
    AgentCanvas,
    ConsoleEntries,
    CommandPaletteVisible,
    ScriptCaretLabel,
    Workbench,
}

/// A store subscriber; Swift's `(EditorStore) -> Void`.
pub type StoreSubscriber = Rc<dyn Fn(&EditorStore)>;
/// An `ObservableObject` observer; Swift's `() -> Void`.
pub type StoreObserver = Rc<dyn Fn()>;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct SubscriptionToken {
    raw: u64,
}

pub struct EditorStore {
    script_caret_labels: RefCell<BTreeMap<String, String>>,
    geometry_revision_value: Cell<u64>,
    storage: RefCell<EditorState>,
    registrar: ObservableStateRegistrar,
    version: Cell<u64>,
    subscribers: RefCell<BTreeMap<SubscriptionToken, StoreSubscriber>>,
    observers: RefCell<BTreeMap<u64, StoreObserver>>,
    next_subscriber_id: Cell<u64>,
    next_observer_id: Cell<u64>,
}

impl EditorStore {
    /// Invalidate authored geometry and transient component selection without
    /// changing the presentation identity or discarding focus/pointer capture.
    pub fn geometry_changed(&self) {
        self.geometry_revision_value
            .set(self.geometry_revision_value.get().wrapping_add(1));
        self.invalidate(&BTreeSet::from([ObservationKey::GeometryRevision]));
    }

    pub fn script_caret_label(&self, document_id: &str) -> String {
        let fallback = self
            .script_caret_labels
            .borrow()
            .get(document_id)
            .cloned()
            .unwrap_or_else(|| "Ln 1, Col 1".to_string());
        self.read(ObservationKey::ScriptCaretLabel, fallback)
    }

    pub fn set_script_caret_label(&self, label: impl Into<String>, document_id: &str) {
        let label = label.into();
        {
            let mut labels = self.script_caret_labels.borrow_mut();
            if labels.get(document_id) == Some(&label) {
                return;
            }
            labels.insert(document_id.to_string(), label);
        }
        self.invalidate(&BTreeSet::from([ObservationKey::ScriptCaretLabel]));
    }

    pub fn state(&self) -> EditorState {
        let value = self.storage.borrow().clone();
        self.read(ObservationKey::State, value)
    }

    pub fn version(&self) -> u64 {
        self.version.get()
    }

    /// Swift's `init(state: EditorState = EditorState())`.
    pub fn new() -> Self {
        Self::with_state(EditorState::new())
    }

    pub fn with_state(state: EditorState) -> Self {
        EditorStore {
            script_caret_labels: RefCell::new(BTreeMap::new()),
            geometry_revision_value: Cell::new(0),
            storage: RefCell::new(state),
            registrar: ObservableStateRegistrar::new(),
            version: Cell::new(0),
            subscribers: RefCell::new(BTreeMap::new()),
            observers: RefCell::new(BTreeMap::new()),
            next_subscriber_id: Cell::new(0),
            next_observer_id: Cell::new(0),
        }
    }

    pub fn dispatch(&self, action: EditorAction) {
        if let EditorAction::AppendConsoleMessage {
            message,
            severity,
            detail,
            target,
            next_step,
        } = &action
        {
            let mut metadata: BTreeMap<String, LogValue> = BTreeMap::new();
            metadata.insert("editor_console".to_string(), LogValue::from("direct"));
            if let Some(detail) = detail {
                metadata.insert("detail".to_string(), LogValue::from(detail.clone()));
            }
            if let Some(target) = target {
                metadata.insert("target".to_string(), LogValue::from(format!("{target:?}")));
            }
            if let Some(next_step) = next_step {
                metadata.insert("next_step".to_string(), LogValue::from(next_step.clone()));
            }
            let level = match severity {
                EditorConsoleSeverity::Error => Level::Error,
                EditorConsoleSeverity::Warning => Level::Warning,
                EditorConsoleSeverity::Info => Level::Info,
            };
            LogSystem::logger("com.cove.editor")
                .log(&LogEvent::new(level, message.clone()).with_metadata(metadata));
        }

        let notifies_subscribers = action.notifies_subscribers();
        let previous = self.storage.borrow().clone();
        EditorReducer::reduce(&mut self.storage.borrow_mut(), action.clone());
        if !notifies_subscribers {
            return;
        }
        let keys = {
            let current = self.storage.borrow();
            self.observation_keys(&action, &previous, &current)
        };
        if keys.is_empty() {
            return;
        }
        self.version.set(self.version.get().wrapping_add(1));
        self.invalidate(&keys);
        let handlers: Vec<StoreSubscriber> = self.subscribers.borrow().values().cloned().collect();
        for handler in handlers {
            handler(self);
        }
    }

    pub fn subscribe(&self, handler: StoreSubscriber) -> SubscriptionToken {
        let next = self.next_subscriber_id.get().wrapping_add(1);
        self.next_subscriber_id.set(next);
        let token = SubscriptionToken { raw: next };
        self.subscribers.borrow_mut().insert(token, handler);
        token
    }

    pub fn unsubscribe(&self, token: SubscriptionToken) {
        self.subscribers.borrow_mut().remove(&token);
    }

    fn read<Value>(&self, key: ObservationKey, value: Value) -> Value {
        self.registrar.access(StateAccessKey::new(key));
        value
    }

    fn invalidate(&self, keys: &BTreeSet<ObservationKey>) {
        for key in keys {
            self.registrar.invalidate(&StateAccessKey::new(*key));
        }
    }

    /// The observation keys Swift computed per action, compared against the
    /// state before and after the reduction.
    fn observation_keys(
        &self,
        action: &EditorAction,
        old: &EditorState,
        new: &EditorState,
    ) -> BTreeSet<ObservationKey> {
        fn mark<T: PartialEq>(
            keys: &mut BTreeSet<ObservationKey>,
            key: ObservationKey,
            old_value: &T,
            new_value: &T,
        ) {
            if old_value != new_value {
                keys.insert(key);
            }
        }

        let mut keys: BTreeSet<ObservationKey> = BTreeSet::new();
        match action {
            EditorAction::SetOperation(_)
            | EditorAction::NavigateToScript(_)
            | EditorAction::NavigateToAsset(_)
            | EditorAction::SetInspectorSceneSettingsVisible(_)
            | EditorAction::SetCommandPaletteQuery(_)
            | EditorAction::SetOutputTab(_)
            | EditorAction::SetViewportMode(_)
            | EditorAction::SetGamePreviewResolution(_)
            | EditorAction::SetGamePreviewHUDEnabled(_)
            | EditorAction::SetGamePreviewFocused(_) => {
                keys.insert(ObservationKey::Workbench);
            }
            EditorAction::TickFrame(_) => mark(
                &mut keys,
                ObservationKey::FrameIndex,
                &old.timing.frame_index,
                &new.timing.frame_index,
            ),
            EditorAction::SetConnected(_) => mark(
                &mut keys,
                ObservationKey::Connected,
                &old.timing.connected,
                &new.timing.connected,
            ),
            EditorAction::SetSelectedEntity(_)
            | EditorAction::SetPrimarySelectedEntity(_)
            | EditorAction::SetSelectedEntities(_) => {
                mark(
                    &mut keys,
                    ObservationKey::SelectedEntityID,
                    &old.selection.selected_entity_id,
                    &new.selection.selected_entity_id,
                );
                mark(
                    &mut keys,
                    ObservationKey::SelectedEntityIDs,
                    &old.selection.selected_entity_ids,
                    &new.selection.selected_entity_ids,
                );
            }
            EditorAction::SetPlaybackState(_) => mark(
                &mut keys,
                ObservationKey::PlaybackState,
                &old.timing.playback_state,
                &new.timing.playback_state,
            ),
            EditorAction::SetAgentTasks(_) => mark(
                &mut keys,
                ObservationKey::AgentTasks,
                &old.assistant.agent_tasks,
                &new.assistant.agent_tasks,
            ),
            EditorAction::BeginSceneDocument => {
                keys.insert(ObservationKey::State);
            }
            EditorAction::SetContent(_) => mark(
                &mut keys,
                ObservationKey::Content,
                &old.content,
                &new.content,
            ),
            EditorAction::SetSceneRevision(_) => mark(
                &mut keys,
                ObservationKey::SceneRevision,
                &old.document.scene_revision,
                &new.document.scene_revision,
            ),
            EditorAction::MarkSceneSaved(_) | EditorAction::MarkSceneUnsaved => {
                mark(
                    &mut keys,
                    ObservationKey::LastSavedSceneRevision,
                    &old.document.last_saved_scene_revision,
                    &new.document.last_saved_scene_revision,
                );
                mark(
                    &mut keys,
                    ObservationKey::SceneRecoveryPending,
                    &old.document.scene_recovery_pending,
                    &new.document.scene_recovery_pending,
                );
            }
            EditorAction::SetSceneRecoveryPending(_) => mark(
                &mut keys,
                ObservationKey::SceneRecoveryPending,
                &old.document.scene_recovery_pending,
                &new.document.scene_recovery_pending,
            ),
            EditorAction::RequestClose(_) | EditorAction::DismissCloseRequest => mark(
                &mut keys,
                ObservationKey::PendingCloseRequest,
                &old.document.pending_close_request,
                &new.document.pending_close_request,
            ),
            EditorAction::SetWindowFocused(_) => mark(
                &mut keys,
                ObservationKey::WindowFocused,
                &old.window.focused,
                &new.window.focused,
            ),
            EditorAction::SetWindowMinimized(_) => mark(
                &mut keys,
                ObservationKey::WindowMinimized,
                &old.window.minimized,
                &new.window.minimized,
            ),
            EditorAction::SetWindowOccluded(_) => mark(
                &mut keys,
                ObservationKey::WindowOccluded,
                &old.window.occluded,
                &new.window.occluded,
            ),
            EditorAction::SetGizmoMode(_) => mark(
                &mut keys,
                ObservationKey::GizmoMode,
                &old.viewport.gizmo_mode,
                &new.viewport.gizmo_mode,
            ),
            EditorAction::SetGizmoSpace(_) => mark(
                &mut keys,
                ObservationKey::GizmoSpace,
                &old.viewport.gizmo_space,
                &new.viewport.gizmo_space,
            ),
            EditorAction::SetViewportShadingMode(_) => mark(
                &mut keys,
                ObservationKey::ViewportShadingMode,
                &old.viewport.shading_mode,
                &new.viewport.shading_mode,
            ),
            EditorAction::SetViewportShadowsEnabled(_) => mark(
                &mut keys,
                ObservationKey::ViewportShadowsEnabled,
                &old.shadows.enabled,
                &new.shadows.enabled,
            ),
            EditorAction::SetViewportGridEnabled(_) => mark(
                &mut keys,
                ObservationKey::ViewportGridEnabled,
                &old.viewport.grid_enabled,
                &new.viewport.grid_enabled,
            ),
            EditorAction::SetViewportRenderScalePercent(_) => mark(
                &mut keys,
                ObservationKey::ViewportRenderScalePercent,
                &old.viewport.render_scale_percent,
                &new.viewport.render_scale_percent,
            ),
            EditorAction::SetViewportInteractionDownscale(_) => mark(
                &mut keys,
                ObservationKey::ViewportInteractionDownscaleEnabled,
                &old.viewport.interaction_downscale_enabled,
                &new.viewport.interaction_downscale_enabled,
            ),
            EditorAction::SetViewportRealtime(_) => mark(
                &mut keys,
                ObservationKey::ViewportRealtimeEnabled,
                &old.viewport.realtime_enabled,
                &new.viewport.realtime_enabled,
            ),
            EditorAction::SetPhysicsDebugOverlayOptions(_) => mark(
                &mut keys,
                ObservationKey::PhysicsDebugOverlayOptions,
                &old.viewport.physics_debug_overlay_options,
                &new.viewport.physics_debug_overlay_options,
            ),
            EditorAction::SetPhysicsDebugOverlayScope(_) => mark(
                &mut keys,
                ObservationKey::PhysicsDebugOverlayScope,
                &old.viewport.physics_debug_overlay_scope,
                &new.viewport.physics_debug_overlay_scope,
            ),
            EditorAction::SetTranslateSnapEnabled(_) => mark(
                &mut keys,
                ObservationKey::TranslateSnapEnabled,
                &old.snapping.translate_snap_enabled,
                &new.snapping.translate_snap_enabled,
            ),
            EditorAction::SetRotateSnapEnabled(_) => mark(
                &mut keys,
                ObservationKey::RotateSnapEnabled,
                &old.snapping.rotate_snap_enabled,
                &new.snapping.rotate_snap_enabled,
            ),
            EditorAction::SetScaleSnapEnabled(_) => mark(
                &mut keys,
                ObservationKey::ScaleSnapEnabled,
                &old.snapping.scale_snap_enabled,
                &new.snapping.scale_snap_enabled,
            ),
            EditorAction::ViewportCameraChanged => mark(
                &mut keys,
                ObservationKey::ViewportCameraRevision,
                &old.viewport.camera_revision,
                &new.viewport.camera_revision,
            ),
            EditorAction::SetTranslateSnapStep(_) => mark(
                &mut keys,
                ObservationKey::TranslateSnapStep,
                &old.snapping.translate_snap_step,
                &new.snapping.translate_snap_step,
            ),
            EditorAction::SetRotateSnapStepDegrees(_) => mark(
                &mut keys,
                ObservationKey::RotateSnapStepDegrees,
                &old.snapping.rotate_snap_step_degrees,
                &new.snapping.rotate_snap_step_degrees,
            ),
            EditorAction::SetScaleSnapStep(_) => mark(
                &mut keys,
                ObservationKey::ScaleSnapStep,
                &old.snapping.scale_snap_step,
                &new.snapping.scale_snap_step,
            ),
            EditorAction::SetPrimarySelectBehavior(_) => mark(
                &mut keys,
                ObservationKey::PrimarySelectBehavior,
                &old.selection.primary_select_behavior,
                &new.selection.primary_select_behavior,
            ),
            EditorAction::SetThemeID(_) | EditorAction::ThemeCatalogChanged => mark(
                &mut keys,
                ObservationKey::Presentation,
                &old.presentation,
                &new.presentation,
            ),
            EditorAction::SetThemeMode(_) => {
                mark(
                    &mut keys,
                    ObservationKey::Presentation,
                    &old.presentation,
                    &new.presentation,
                );
                mark(
                    &mut keys,
                    ObservationKey::ThemeMode,
                    &old.theme_mode(),
                    &new.theme_mode(),
                );
                mark(
                    &mut keys,
                    ObservationKey::UIRefreshRevision,
                    &old.ui_refresh_revision(),
                    &new.ui_refresh_revision(),
                );
            }
            EditorAction::SetLanguage(_) => {
                mark(
                    &mut keys,
                    ObservationKey::Presentation,
                    &old.presentation,
                    &new.presentation,
                );
                mark(
                    &mut keys,
                    ObservationKey::Language,
                    &old.language(),
                    &new.language(),
                );
                mark(
                    &mut keys,
                    ObservationKey::UIRefreshRevision,
                    &old.ui_refresh_revision(),
                    &new.ui_refresh_revision(),
                );
            }
            EditorAction::ForceUIRefresh => {
                mark(
                    &mut keys,
                    ObservationKey::Presentation,
                    &old.presentation,
                    &new.presentation,
                );
                mark(
                    &mut keys,
                    ObservationKey::UIRefreshRevision,
                    &old.ui_refresh_revision(),
                    &new.ui_refresh_revision(),
                );
            }
            EditorAction::SetVSyncMode(_) => mark(
                &mut keys,
                ObservationKey::VSyncMode,
                &old.vsync_mode,
                &new.vsync_mode,
            ),
            EditorAction::BeginAssetDrag(_) | EditorAction::EndAssetDrag => mark(
                &mut keys,
                ObservationKey::ActiveAssetDrag,
                &old.navigation.active_asset_drag,
                &new.navigation.active_asset_drag,
            ),
            EditorAction::UpdateAssetDragCursor { .. } => {}
            EditorAction::SetInspectorSectionCollapsed { .. }
            | EditorAction::SetInspectorSectionsCollapsed { .. } => mark(
                &mut keys,
                ObservationKey::InspectorCollapsedSectionIDs,
                &old.selection.inspector_collapsed_section_ids,
                &new.selection.inspector_collapsed_section_ids,
            ),
            EditorAction::SetPendingConfirmationRequest(_) => {
                mark(
                    &mut keys,
                    ObservationKey::PendingConfirmationRequest,
                    &old.assistant.pending_confirmation_request,
                    &new.assistant.pending_confirmation_request,
                );
                mark(
                    &mut keys,
                    ObservationKey::AgentCanvas,
                    &old.assistant.agent_canvas,
                    &new.assistant.agent_canvas,
                );
            }
            EditorAction::SetAgentCanvas(_) => mark(
                &mut keys,
                ObservationKey::AgentCanvas,
                &old.assistant.agent_canvas,
                &new.assistant.agent_canvas,
            ),
            EditorAction::SetAISettings(_) => mark(
                &mut keys,
                ObservationKey::AISettings,
                &old.assistant.ai_settings,
                &new.assistant.ai_settings,
            ),
            EditorAction::SetCapabilitySettings(_) => mark(
                &mut keys,
                ObservationKey::CapabilitySettings,
                &old.assistant.capability_settings,
                &new.assistant.capability_settings,
            ),
            EditorAction::SetPluginManagementState(_) => mark(
                &mut keys,
                ObservationKey::PluginManagement,
                &old.assistant.plugin_management,
                &new.assistant.plugin_management,
            ),
            EditorAction::SetAIStatusMessage(_) => mark(
                &mut keys,
                ObservationKey::AIStatusMessage,
                &old.assistant.ai_status_message,
                &new.assistant.ai_status_message,
            ),
            EditorAction::SetAIWarnings(_) => mark(
                &mut keys,
                ObservationKey::AIWarnings,
                &old.assistant.ai_warnings,
                &new.assistant.ai_warnings,
            ),
            EditorAction::AppendChatMessage(_)
            | EditorAction::UpdateChatMessage { .. }
            | EditorAction::ClearChatHistory => {
                mark(
                    &mut keys,
                    ObservationKey::ChatMessages,
                    &old.assistant.chat_messages,
                    &new.assistant.chat_messages,
                );
                mark(
                    &mut keys,
                    ObservationKey::AgentCanvas,
                    &old.assistant.agent_canvas,
                    &new.assistant.agent_canvas,
                );
            }
            EditorAction::AppendConsoleMessage { .. }
            | EditorAction::AppendLogRecord(_)
            | EditorAction::ClearConsole => mark(
                &mut keys,
                ObservationKey::ConsoleEntries,
                &old.output.console_entries,
                &new.output.console_entries,
            ),
            EditorAction::SetCommandPaletteVisible(_) => mark(
                &mut keys,
                ObservationKey::CommandPaletteVisible,
                &old.navigation.command_palette_visible,
                &new.navigation.command_palette_visible,
            ),
            EditorAction::FrameTimingUpdated => mark(
                &mut keys,
                ObservationKey::FrameTimingRevision,
                &old.timing.frame_timing_revision,
                &new.timing.frame_timing_revision,
            ),
            EditorAction::ViewportSurfaceUpdated => mark(
                &mut keys,
                ObservationKey::ViewportSurfaceRevision,
                &old.viewport.surface_revision,
                &new.viewport.surface_revision,
            ),
            EditorAction::UpdateFrameStats(_) => {
                mark(
                    &mut keys,
                    ObservationKey::FrameStats,
                    &old.timing.frame_stats,
                    &new.timing.frame_stats,
                );
                mark(
                    &mut keys,
                    ObservationKey::FrameStatsHistory,
                    &old.timing.frame_stats_history,
                    &new.timing.frame_stats_history,
                );
            }
            EditorAction::UpdateParticleDiagnostics(_) => mark(
                &mut keys,
                ObservationKey::ParticleDiagnosticsHistory,
                &old.timing.particle_diagnostics_history,
                &new.timing.particle_diagnostics_history,
            ),
        }

        if old.should_render() != new.should_render() {
            keys.insert(ObservationKey::ShouldRender);
        }
        if !keys.is_empty() && action.invalidates_whole_state_observation() {
            keys.insert(ObservationKey::State);
        }
        keys
    }
}

impl Default for EditorStore {
    fn default() -> Self {
        Self::new()
    }
}

impl ObservableObject for EditorStore {
    fn register_observer(&self, handler: StoreObserver) -> u64 {
        let next = self.next_observer_id.get().wrapping_add(1);
        self.next_observer_id.set(next);
        self.observers.borrow_mut().insert(next, handler);
        next
    }

    fn unregister_observer(&self, token: u64) {
        self.observers.borrow_mut().remove(&token);
    }
}

impl EditorStore {
    // MARK: - Session workbench fields

    pub fn operations(&self) -> Vec<EditorOperation> {
        let value = self.storage.borrow().navigation.operations.clone();
        self.read(ObservationKey::Workbench, value)
    }

    pub fn script_navigation(&self) -> Option<EditorScriptNavigationRequest> {
        let value = self.storage.borrow().navigation.script_navigation.clone();
        self.read(ObservationKey::Workbench, value)
    }

    pub fn asset_navigation_id(&self) -> Option<String> {
        let value = self.storage.borrow().navigation.asset_navigation_id.clone();
        self.read(ObservationKey::Workbench, value)
    }

    pub fn asset_navigation_revision(&self) -> u64 {
        let value = self.storage.borrow().navigation.asset_navigation_revision;
        self.read(ObservationKey::Workbench, value)
    }

    pub fn inspector_scene_settings_visible(&self) -> bool {
        let value = self
            .storage
            .borrow()
            .selection
            .inspector_scene_settings_visible;
        self.read(ObservationKey::Workbench, value)
    }

    pub fn command_palette_query(&self) -> TextBuffer {
        let value = self
            .storage
            .borrow()
            .navigation
            .command_palette_query
            .clone();
        self.read(ObservationKey::Workbench, value)
    }

    pub fn output_tab(&self) -> EditorOutputTab {
        let value = self.storage.borrow().output.output_tab;
        self.read(ObservationKey::Workbench, value)
    }

    pub fn viewport_mode(&self) -> EditorViewportMode {
        let value = self.storage.borrow().viewport.mode;
        self.read(ObservationKey::Workbench, value)
    }

    pub fn game_preview_resolution(&self) -> EditorGamePreviewResolution {
        let value = self.storage.borrow().viewport.game_preview_resolution;
        self.read(ObservationKey::Workbench, value)
    }

    pub fn game_preview_hud_enabled(&self) -> bool {
        let value = self.storage.borrow().viewport.game_preview_hud_enabled;
        self.read(ObservationKey::Workbench, value)
    }

    pub fn game_preview_focused(&self) -> bool {
        let value = self.storage.borrow().viewport.game_preview_focused;
        self.read(ObservationKey::Workbench, value)
    }

    // MARK: - Timing and documents

    pub fn connected(&self) -> bool {
        let value = self.storage.borrow().timing.connected;
        self.read(ObservationKey::Connected, value)
    }

    pub fn selected_entity_id(&self) -> Option<u64> {
        let value = self.storage.borrow().selection.selected_entity_id;
        self.read(ObservationKey::SelectedEntityID, value)
    }

    pub fn selected_entity_ids(&self) -> BTreeSet<u64> {
        let value = self.storage.borrow().selection.selected_entity_ids.clone();
        self.read(ObservationKey::SelectedEntityIDs, value)
    }

    pub fn selected_entity_ids_count(&self) -> usize {
        let value = self.storage.borrow().selection.selected_entity_ids.len();
        self.read(ObservationKey::SelectedEntityIDs, value)
    }

    pub fn scene_revision(&self) -> u64 {
        let value = self.storage.borrow().document.scene_revision;
        self.read(ObservationKey::SceneRevision, value)
    }

    pub fn last_saved_scene_revision(&self) -> u64 {
        let value = self.storage.borrow().document.last_saved_scene_revision;
        self.read(ObservationKey::LastSavedSceneRevision, value)
    }

    pub fn scene_recovery_pending(&self) -> bool {
        let value = self.storage.borrow().document.scene_recovery_pending;
        self.read(ObservationKey::SceneRecoveryPending, value)
    }

    /// Unsaved scene edits or a recovered autosave exist.
    pub fn scene_dirty(&self) -> bool {
        self.scene_recovery_pending() || self.scene_revision() != self.last_saved_scene_revision()
    }

    pub fn pending_close_request(&self) -> Option<EditorPendingCloseRequest> {
        let value = self.storage.borrow().document.pending_close_request.clone();
        self.read(ObservationKey::PendingCloseRequest, value)
    }

    pub fn frame_index(&self) -> u64 {
        let value = self.storage.borrow().timing.frame_index;
        self.read(ObservationKey::FrameIndex, value)
    }

    pub fn frame_timing_revision(&self) -> u64 {
        let value = self.storage.borrow().timing.frame_timing_revision;
        self.read(ObservationKey::FrameTimingRevision, value)
    }

    pub fn frame_stats(&self) -> EditorFrameStats {
        let value = self.storage.borrow().timing.frame_stats.clone();
        self.read(ObservationKey::FrameStats, value)
    }

    pub fn frame_stats_history(&self) -> Vec<EditorFrameStatsHistorySample> {
        let value = self.storage.borrow().timing.frame_stats_history.clone();
        self.read(ObservationKey::FrameStatsHistory, value)
    }

    pub fn particle_diagnostics_history(&self) -> Vec<EditorParticleDiagnosticsSample> {
        let value = self
            .storage
            .borrow()
            .timing
            .particle_diagnostics_history
            .clone();
        self.read(ObservationKey::ParticleDiagnosticsHistory, value)
    }

    pub fn viewport_surface_revision(&self) -> u64 {
        let value = self.storage.borrow().viewport.surface_revision;
        self.read(ObservationKey::ViewportSurfaceRevision, value)
    }

    pub fn viewport_camera_revision(&self) -> u64 {
        let value = self.storage.borrow().viewport.camera_revision;
        self.read(ObservationKey::ViewportCameraRevision, value)
    }

    pub fn window_focused(&self) -> bool {
        let value = self.storage.borrow().window.focused;
        self.read(ObservationKey::WindowFocused, value)
    }

    pub fn window_minimized(&self) -> bool {
        let value = self.storage.borrow().window.minimized;
        self.read(ObservationKey::WindowMinimized, value)
    }

    pub fn window_occluded(&self) -> bool {
        let value = self.storage.borrow().window.occluded;
        self.read(ObservationKey::WindowOccluded, value)
    }

    pub fn should_render(&self) -> bool {
        let value = self.storage.borrow().should_render();
        self.read(ObservationKey::ShouldRender, value)
    }

    // MARK: - Assistant, console and selection

    pub fn ai_settings(&self) -> EditorAISettings {
        let value = self.storage.borrow().assistant.ai_settings.clone();
        self.read(ObservationKey::AISettings, value)
    }

    pub fn capability_settings(&self) -> EditorCapabilitySettings {
        let value = self.storage.borrow().assistant.capability_settings.clone();
        self.read(ObservationKey::CapabilitySettings, value)
    }

    pub fn plugin_management(&self) -> EditorPluginManagementState {
        let value = self.storage.borrow().assistant.plugin_management.clone();
        self.read(ObservationKey::PluginManagement, value)
    }

    pub fn ai_status_message(&self) -> Option<String> {
        let value = self.storage.borrow().assistant.ai_status_message.clone();
        self.read(ObservationKey::AIStatusMessage, value)
    }

    pub fn ai_warnings(&self) -> Vec<String> {
        let value = self.storage.borrow().assistant.ai_warnings.clone();
        self.read(ObservationKey::AIWarnings, value)
    }

    pub fn console_entries(&self) -> Vec<EditorConsoleEntry> {
        let value = self.storage.borrow().output.console_entries.clone();
        self.read(ObservationKey::ConsoleEntries, value)
    }

    pub fn latest_console_entry(&self) -> Option<EditorConsoleEntry> {
        let value = self.storage.borrow().output.console_entries.last().cloned();
        self.read(ObservationKey::ConsoleEntries, value)
    }

    pub fn playback_state(&self) -> PlaybackState {
        let value = self.storage.borrow().timing.playback_state;
        self.read(ObservationKey::PlaybackState, value)
    }

    pub fn agent_tasks(&self) -> Vec<EditorAgentTask> {
        let value = self.storage.borrow().assistant.agent_tasks.clone();
        self.read(ObservationKey::AgentTasks, value)
    }

    pub fn content(&self) -> EditorContent {
        let value = self.storage.borrow().content;
        self.read(ObservationKey::Content, value)
    }

    pub fn gizmo_mode(&self) -> EditorGizmoMode {
        let value = self.storage.borrow().viewport.gizmo_mode;
        self.read(ObservationKey::GizmoMode, value)
    }

    pub fn gizmo_space(&self) -> EditorGizmoSpace {
        let value = self.storage.borrow().viewport.gizmo_space;
        self.read(ObservationKey::GizmoSpace, value)
    }

    pub fn viewport_shading_mode(&self) -> EditorViewportShadingMode {
        let value = self.storage.borrow().viewport.shading_mode;
        self.read(ObservationKey::ViewportShadingMode, value)
    }

    pub fn viewport_shadows_enabled(&self) -> bool {
        let value = self.storage.borrow().shadows.enabled;
        self.read(ObservationKey::ViewportShadowsEnabled, value)
    }

    pub fn viewport_grid_enabled(&self) -> bool {
        let value = self.storage.borrow().viewport.grid_enabled;
        self.read(ObservationKey::ViewportGridEnabled, value)
    }

    pub fn viewport_render_scale_percent(&self) -> i64 {
        let value = self.storage.borrow().viewport.render_scale_percent;
        self.read(ObservationKey::ViewportRenderScalePercent, value)
    }

    pub fn viewport_interaction_downscale_enabled(&self) -> bool {
        let value = self.storage.borrow().viewport.interaction_downscale_enabled;
        self.read(ObservationKey::ViewportInteractionDownscaleEnabled, value)
    }

    pub fn viewport_realtime_enabled(&self) -> bool {
        let value = self.storage.borrow().viewport.realtime_enabled;
        self.read(ObservationKey::ViewportRealtimeEnabled, value)
    }

    pub fn physics_debug_overlay_options(&self) -> EditorPhysicsDebugOverlayOptions {
        let value = self.storage.borrow().viewport.physics_debug_overlay_options;
        self.read(ObservationKey::PhysicsDebugOverlayOptions, value)
    }

    pub fn physics_debug_overlay_scope(&self) -> EditorPhysicsDebugOverlayScope {
        let value = self.storage.borrow().viewport.physics_debug_overlay_scope;
        self.read(ObservationKey::PhysicsDebugOverlayScope, value)
    }

    pub fn translate_snap_enabled(&self) -> bool {
        let value = self.storage.borrow().snapping.translate_snap_enabled;
        self.read(ObservationKey::TranslateSnapEnabled, value)
    }

    pub fn rotate_snap_enabled(&self) -> bool {
        let value = self.storage.borrow().snapping.rotate_snap_enabled;
        self.read(ObservationKey::RotateSnapEnabled, value)
    }

    pub fn scale_snap_enabled(&self) -> bool {
        let value = self.storage.borrow().snapping.scale_snap_enabled;
        self.read(ObservationKey::ScaleSnapEnabled, value)
    }

    pub fn translate_snap_step(&self) -> f32 {
        let value = self.storage.borrow().snapping.translate_snap_step;
        self.read(ObservationKey::TranslateSnapStep, value)
    }

    pub fn rotate_snap_step_degrees(&self) -> f32 {
        let value = self.storage.borrow().snapping.rotate_snap_step_degrees;
        self.read(ObservationKey::RotateSnapStepDegrees, value)
    }

    pub fn scale_snap_step(&self) -> f32 {
        let value = self.storage.borrow().snapping.scale_snap_step;
        self.read(ObservationKey::ScaleSnapStep, value)
    }

    pub fn primary_select_behavior(&self) -> SelectionPrimaryModifierBehavior {
        let value = self.storage.borrow().selection.primary_select_behavior;
        self.read(ObservationKey::PrimarySelectBehavior, value)
    }

    pub fn presentation(&self) -> EditorPresentationState {
        let value = self.storage.borrow().presentation.clone();
        self.read(ObservationKey::Presentation, value)
    }

    pub fn theme_mode(&self) -> EditorThemeMode {
        let value = self.storage.borrow().theme_mode();
        self.read(ObservationKey::ThemeMode, value)
    }

    pub fn language(&self) -> EditorLanguage {
        let value = self.storage.borrow().language();
        self.read(ObservationKey::Language, value)
    }

    /// Bumped only by `forceUIRefresh`; the presentation boundary keys its
    /// view tree on it, so reading it rebuilds everything below the boundary.
    pub fn ui_refresh_revision(&self) -> u64 {
        let value = self.storage.borrow().ui_refresh_revision();
        self.read(ObservationKey::UIRefreshRevision, value)
    }

    pub fn geometry_revision(&self) -> u64 {
        self.read(
            ObservationKey::GeometryRevision,
            self.geometry_revision_value.get(),
        )
    }

    pub fn vsync_mode(&self) -> EditorVSyncMode {
        let value = self.storage.borrow().vsync_mode;
        self.read(ObservationKey::VSyncMode, value)
    }

    pub fn active_asset_drag(&self) -> Option<EditorAssetDragPayload> {
        let value = self.storage.borrow().navigation.active_asset_drag.clone();
        self.read(ObservationKey::ActiveAssetDrag, value)
    }

    pub fn inspector_collapsed_section_ids(&self) -> BTreeSet<String> {
        let value = self
            .storage
            .borrow()
            .selection
            .inspector_collapsed_section_ids
            .clone();
        self.read(ObservationKey::InspectorCollapsedSectionIDs, value)
    }

    pub fn pending_confirmation_request(&self) -> Option<ConfirmationRequestBatch> {
        let value = self
            .storage
            .borrow()
            .assistant
            .pending_confirmation_request
            .clone();
        self.read(ObservationKey::PendingConfirmationRequest, value)
    }

    pub fn command_palette_visible(&self) -> bool {
        let value = self.storage.borrow().navigation.command_palette_visible;
        self.read(ObservationKey::CommandPaletteVisible, value)
    }

    pub fn chat_messages(&self) -> Vec<AIChatMessage> {
        let value = self.storage.borrow().assistant.chat_messages.clone();
        self.read(ObservationKey::ChatMessages, value)
    }

    pub fn agent_canvas(&self) -> Option<EditorContent> {
        let value = self.storage.borrow().assistant.agent_canvas;
        self.read(ObservationKey::AgentCanvas, value)
    }
}
