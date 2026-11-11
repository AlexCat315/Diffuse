//! `Editor/Sources/EditorCore/State/EditorState.swift`.
//!
//! The whole persisted editor state and the vocabulary it is built from. Each
//! nested state owns its own persistence defaults, so decoding an older file
//! keeps whatever the current defaults are for missing keys.

use cove_logging::LogRecord;
use serde::{Deserialize, Serialize};

use crate::state::assistant::editor_assistant_state::EditorAssistantState;
use crate::state::assistant::editor_output_state::EditorOutputState;
use crate::state::editor_presentation_state::EditorPresentationState;
use crate::state::editor_selection_state::EditorSelectionState;
use crate::state::editor_timing_state::EditorTimingState;
use crate::state::viewports::editor_navigation_state::EditorNavigationState;
use crate::state::viewports::editor_shadows_state::EditorShadowsState;
use crate::state::viewports::editor_snapping_state::EditorSnappingState;
use crate::state::viewports::editor_viewport_state::EditorViewportState;
use crate::state::workspace::content::EditorContent;
use crate::state::workspace::editor_document_state::EditorDocumentState;
use crate::state::workspace::editor_window_state::EditorWindowState;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PlaybackState {
    Stopped,
    Playing,
    Paused,
}

impl PlaybackState {
    pub fn can_transition(self, next: PlaybackState) -> bool {
        matches!(
            (self, next),
            (PlaybackState::Stopped, PlaybackState::Playing)
                | (PlaybackState::Playing, PlaybackState::Paused)
                | (PlaybackState::Playing, PlaybackState::Stopped)
                | (PlaybackState::Paused, PlaybackState::Playing)
                | (PlaybackState::Paused, PlaybackState::Stopped)
        )
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum EditorGizmoMode {
    None,
    BoxSelect,
    Translate,
    Rotate,
    Scale,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum EditorGizmoSpace {
    Local,
    World,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum EditorViewportShadingMode {
    /// Full PBR.
    Lit,
    /// Mesh edges drawn as an overlay over the lit surface (topology view).
    Wireframe,
    /// Material albedo with ambient occlusion, no lighting (UE "Unlit").
    Unlit,
    /// Raw base-color texture only (the albedo G-buffer).
    BaseColor,
    /// Surface normal visualized as RGB.
    Normal,
    /// Roughness channel as greyscale.
    Roughness,
    /// Metallic channel as greyscale.
    Metallic,
}

impl EditorViewportShadingMode {
    /// Swift's `CaseIterable` order.
    pub const ALL: [EditorViewportShadingMode; 7] = [
        EditorViewportShadingMode::Lit,
        EditorViewportShadingMode::Wireframe,
        EditorViewportShadingMode::Unlit,
        EditorViewportShadingMode::BaseColor,
        EditorViewportShadingMode::Normal,
        EditorViewportShadingMode::Roughness,
        EditorViewportShadingMode::Metallic,
    ];

    /// Debug-view index handed to the mesh shader (`exposure_light_count.z`).
    /// `.wireframe` shades the surface normally (lit) and overlays edges, so it
    /// maps to the same shaded path as `.lit`.
    pub fn debug_view_index(self) -> i64 {
        match self {
            EditorViewportShadingMode::Lit | EditorViewportShadingMode::Wireframe => 0,
            EditorViewportShadingMode::Unlit => 1,
            EditorViewportShadingMode::BaseColor => 2,
            EditorViewportShadingMode::Normal => 3,
            EditorViewportShadingMode::Roughness => 4,
            EditorViewportShadingMode::Metallic => 5,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum EditorViewportShadowDebugMode {
    Off,
    CascadeBands,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SelectionPrimaryModifierBehavior {
    Subtract,
    Toggle,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum EditorThemeMode {
    Dark,
    Light,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum EditorLanguage {
    System,
    English,
    SimplifiedChinese,
}

impl EditorLanguage {
    /// Swift's `CaseIterable` order.
    pub const ALL: [EditorLanguage; 3] = [
        EditorLanguage::System,
        EditorLanguage::English,
        EditorLanguage::SimplifiedChinese,
    ];

    pub fn lproj_name(self) -> Option<String> {
        match self {
            EditorLanguage::System => Some(Self::system_lproj_name()),
            EditorLanguage::English => Some("en".to_string()),
            EditorLanguage::SimplifiedChinese => Some("zh-Hans".to_string()),
        }
    }

    /// The first preferred language this editor ships a table for. Cove keeps
    /// its locale preference private, so the platform locale is read from the
    /// same environment variables Cove consults.
    fn system_lproj_name() -> String {
        let raw = std::env::var("LC_ALL")
            .ok()
            .filter(|value| !value.is_empty())
            .or_else(|| {
                std::env::var("LC_MESSAGES")
                    .ok()
                    .filter(|value| !value.is_empty())
            })
            .or_else(|| std::env::var("LANG").ok().filter(|value| !value.is_empty()))
            .unwrap_or_else(|| "en".to_string());
        for identifier in raw.split(':') {
            let language = identifier
                .split(['.', '@'])
                .next()
                .unwrap_or(identifier)
                .replace('_', "-")
                .to_lowercase();
            if language == "zh" || language.starts_with("zh-") {
                return "zh-Hans".to_string();
            }
            if language == "en" || language.starts_with("en-") {
                return "en".to_string();
            }
        }
        "en".to_string()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum EditorVSyncMode {
    Enabled,
    Disabled,
}

impl EditorVSyncMode {
    /// Swift's `CaseIterable` order.
    pub const ALL: [EditorVSyncMode; 2] = [EditorVSyncMode::Enabled, EditorVSyncMode::Disabled];

    pub fn is_enabled(self) -> bool {
        self == EditorVSyncMode::Enabled
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum EditorConsoleSeverity {
    Info,
    Warning,
    Error,
}

impl EditorConsoleSeverity {
    /// Swift's `CaseIterable` order.
    pub const ALL: [EditorConsoleSeverity; 3] = [
        EditorConsoleSeverity::Info,
        EditorConsoleSeverity::Warning,
        EditorConsoleSeverity::Error,
    ];
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EditorConsoleEntry {
    pub id: u64,
    pub severity: EditorConsoleSeverity,
    pub message: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target: Option<crate::state::workspace::editor_workbench_state::EditorIssueTarget>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next_step: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub record: Option<LogRecord>,
}

impl EditorConsoleEntry {
    /// Swift's memberwise initializer with its default arguments.
    pub fn new(id: u64, severity: EditorConsoleSeverity, message: impl Into<String>) -> Self {
        EditorConsoleEntry {
            id,
            severity,
            message: message.into(),
            detail: None,
            target: None,
            next_step: None,
            record: None,
        }
    }

    /// The `severity: .info` default spelled out.
    pub fn with_message(id: u64, message: impl Into<String>) -> Self {
        Self::new(id, EditorConsoleSeverity::Info, message)
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EditorAssetDragPayload {
    #[serde(rename = "assetID")]
    pub asset_id: String,
    pub display_name: String,
    pub kind_label: String,
    #[serde(default, serialize_with = "diffuse_kernel::codable::serialize_float")]
    pub cursor_x: f32,
    #[serde(default, serialize_with = "diffuse_kernel::codable::serialize_float")]
    pub cursor_y: f32,
}

impl EditorAssetDragPayload {
    /// Swift's memberwise initializer with its `0` cursor defaults.
    pub fn new(
        asset_id: impl Into<String>,
        display_name: impl Into<String>,
        kind_label: impl Into<String>,
    ) -> Self {
        EditorAssetDragPayload {
            asset_id: asset_id.into(),
            display_name: display_name.into(),
            kind_label: kind_label.into(),
            cursor_x: 0.0,
            cursor_y: 0.0,
        }
    }

    /// The full memberwise initializer.
    pub fn with_cursor(
        asset_id: impl Into<String>,
        display_name: impl Into<String>,
        kind_label: impl Into<String>,
        cursor_x: f32,
        cursor_y: f32,
    ) -> Self {
        EditorAssetDragPayload {
            asset_id: asset_id.into(),
            display_name: display_name.into(),
            kind_label: kind_label.into(),
            cursor_x,
            cursor_y,
        }
    }
}

/// Swift's `OptionSet` over `UInt8`; the raw bit layout is preserved.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct EditorPhysicsDebugOverlayOptions {
    pub raw_value: u8,
}

impl EditorPhysicsDebugOverlayOptions {
    pub const SHAPES: EditorPhysicsDebugOverlayOptions =
        EditorPhysicsDebugOverlayOptions { raw_value: 1 << 0 };
    pub const BOUNDS: EditorPhysicsDebugOverlayOptions =
        EditorPhysicsDebugOverlayOptions { raw_value: 1 << 1 };
    pub const CONTACTS: EditorPhysicsDebugOverlayOptions =
        EditorPhysicsDebugOverlayOptions { raw_value: 1 << 2 };
    pub const JOINTS: EditorPhysicsDebugOverlayOptions =
        EditorPhysicsDebugOverlayOptions { raw_value: 1 << 3 };
    pub const CHARACTERS: EditorPhysicsDebugOverlayOptions =
        EditorPhysicsDebugOverlayOptions { raw_value: 1 << 4 };

    pub const fn new(raw_value: u8) -> Self {
        EditorPhysicsDebugOverlayOptions { raw_value }
    }

    pub const fn all() -> EditorPhysicsDebugOverlayOptions {
        EditorPhysicsDebugOverlayOptions {
            raw_value: EditorPhysicsDebugOverlayOptions::SHAPES.raw_value
                | EditorPhysicsDebugOverlayOptions::BOUNDS.raw_value
                | EditorPhysicsDebugOverlayOptions::CONTACTS.raw_value
                | EditorPhysicsDebugOverlayOptions::JOINTS.raw_value
                | EditorPhysicsDebugOverlayOptions::CHARACTERS.raw_value,
        }
    }

    pub const fn contains(self, other: EditorPhysicsDebugOverlayOptions) -> bool {
        (self.raw_value & other.raw_value) == other.raw_value
    }

    pub const fn intersection(self, other: EditorPhysicsDebugOverlayOptions) -> Self {
        EditorPhysicsDebugOverlayOptions {
            raw_value: self.raw_value & other.raw_value,
        }
    }
}

impl Serialize for EditorPhysicsDebugOverlayOptions {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_u8(self.raw_value)
    }
}

impl<'de> Deserialize<'de> for EditorPhysicsDebugOverlayOptions {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        Ok(EditorPhysicsDebugOverlayOptions::new(u8::deserialize(
            deserializer,
        )?))
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum EditorPhysicsDebugOverlayScope {
    Selected,
    Scene,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct EditorState {
    pub selection: EditorSelectionState,
    pub document: EditorDocumentState,
    pub timing: EditorTimingState,
    /// Follows the window's active center tab; the layout persists, this does not.
    #[serde(skip, default = "default_content")]
    pub content: EditorContent,
    pub window: EditorWindowState,
    pub viewport: EditorViewportState,
    pub shadows: EditorShadowsState,
    pub snapping: EditorSnappingState,
    pub assistant: EditorAssistantState,
    pub output: EditorOutputState,
    pub navigation: EditorNavigationState,
    pub presentation: EditorPresentationState,
    pub vsync_mode: EditorVSyncMode,
}

impl EditorState {
    pub const MAX_FRAME_STATS_HISTORY_SAMPLES: usize = 240;
    pub const MAX_PARTICLE_DIAGNOSTICS_HISTORY_SAMPLES: usize = 240;

    /// Swift's `init(_ configure:)` without a configuration closure.
    pub fn new() -> Self {
        let mut state = EditorState::default();
        state.normalize();
        state
    }

    /// Swift's `init(_ configure:)` with the closure applied before normalizing.
    pub fn with_configure(configure: impl FnOnce(&mut EditorState)) -> Self {
        let mut state = EditorState::default();
        configure(&mut state);
        state.normalize();
        state
    }

    fn normalize(&mut self) {
        self.timing.normalize();
        self.viewport.normalize();
        self.shadows.normalize();
        self.snapping.normalize();
        self.output.normalize();
    }

    pub fn should_render(&self) -> bool {
        !self.window.minimized && !self.window.occluded
    }

    pub fn scene_dirty(&self) -> bool {
        self.document.scene_recovery_pending
            || self.document.scene_revision != self.document.last_saved_scene_revision
    }

    pub fn theme_mode(&self) -> EditorThemeMode {
        self.presentation.theme_mode
    }

    pub fn language(&self) -> EditorLanguage {
        self.presentation.language
    }

    pub fn ui_refresh_revision(&self) -> u64 {
        self.presentation.refresh_revision
    }

    pub fn sanitized_shadow_map_resolution(value: u32) -> u32 {
        value.clamp(128, 4096)
    }

    pub fn sanitized_max_shadowed_directional_lights(value: i64) -> i64 {
        value.clamp(0, 4)
    }

    pub fn sanitized_directional_cascade_count(value: i64) -> i64 {
        value.clamp(1, 4)
    }

    pub fn sanitized_directional_cascade_split_lambda(value: f32) -> f32 {
        value.clamp(0.0, 1.0)
    }

    pub fn sanitized_render_scale_percent(value: i64) -> i64 {
        value.clamp(25, 200)
    }

    /// Swift declared the three snapping sanitizers in an `EditorState`
    /// extension in `Editing/EditorTransformSnapping.swift`. They live here so
    /// the state layer compiles before the gizmo controller they also serve;
    /// `editor_transform_snapping.rs` must call these rather than redefine them.
    pub fn sanitized_translate_snap_step(value: f32) -> f32 {
        Self::sanitized_snap_step(value, 10_000.0, 0.5)
    }

    pub fn sanitized_rotate_snap_step(value: f32) -> f32 {
        Self::sanitized_snap_step(value, 180.0, 5.0)
    }

    pub fn sanitized_scale_snap_step(value: f32) -> f32 {
        Self::sanitized_snap_step(value, 10.0, 0.05)
    }

    fn sanitized_snap_step(value: f32, maximum: f32, fallback: f32) -> f32 {
        if !value.is_finite() || value <= 0.0 {
            return fallback;
        }
        value.clamp(0.001, maximum)
    }

    pub fn append_frame_stats_history(&mut self, stats: EditorFrameStats) {
        let sample_index = self
            .timing
            .frame_stats_history
            .last()
            .map(|sample| sample.sample_index)
            .unwrap_or(0)
            .wrapping_add(1);
        self.timing
            .frame_stats_history
            .push(EditorFrameStatsHistorySample::new(
                sample_index,
                self.timing.frame_index,
                stats,
            ));
        let samples = &mut self.timing.frame_stats_history;
        if samples.len() > Self::MAX_FRAME_STATS_HISTORY_SAMPLES {
            let excess = samples.len() - Self::MAX_FRAME_STATS_HISTORY_SAMPLES;
            samples.drain(..excess);
        }
    }

    pub fn append_particle_diagnostics_history(&mut self, sample: EditorParticleDiagnosticsSample) {
        self.timing.particle_diagnostics_history.push(sample);
        let samples = &mut self.timing.particle_diagnostics_history;
        if samples.len() > Self::MAX_PARTICLE_DIAGNOSTICS_HISTORY_SAMPLES {
            let excess = samples.len() - Self::MAX_PARTICLE_DIAGNOSTICS_HISTORY_SAMPLES;
            samples.drain(..excess);
        }
    }
}

fn default_content() -> EditorContent {
    EditorContent::Scene
}

impl Default for EditorState {
    fn default() -> Self {
        EditorState {
            selection: EditorSelectionState::default(),
            document: EditorDocumentState::default(),
            timing: EditorTimingState::default(),
            content: EditorContent::Scene,
            window: EditorWindowState::default(),
            viewport: EditorViewportState::default(),
            shadows: EditorShadowsState::default(),
            snapping: EditorSnappingState::default(),
            assistant: EditorAssistantState::default(),
            output: EditorOutputState::default(),
            navigation: EditorNavigationState::default(),
            presentation: EditorPresentationState::with_defaults(),
            vsync_mode: EditorVSyncMode::Enabled,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EditorPendingDocumentAction {
    Close,
    CloseProject,
    NewScene,
    OpenScene,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EditorPendingCloseRequest {
    pub action: EditorPendingDocumentAction,
    /// Window the OS asked to close; `None` when the whole app is quitting.
    pub window_id: Option<u32>,
    /// Scene selected by an Open dialog. Stored as a path to keep presentation
    /// state independent from any platform file-dialog type.
    pub document_path: Option<String>,
}

impl EditorPendingCloseRequest {
    /// Swift's memberwise initializer with its default arguments.
    pub fn new(action: EditorPendingDocumentAction) -> Self {
        EditorPendingCloseRequest {
            action,
            window_id: None,
            document_path: None,
        }
    }

    /// The full memberwise initializer.
    pub fn with_options(
        action: EditorPendingDocumentAction,
        window_id: Option<u32>,
        document_path: Option<String>,
    ) -> Self {
        EditorPendingCloseRequest {
            action,
            window_id,
            document_path,
        }
    }
}

impl Default for EditorPendingCloseRequest {
    fn default() -> Self {
        Self::new(EditorPendingDocumentAction::Close)
    }
}

/// Frame timing and performance statistics for the Editor viewport.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EditorFrameStats {
    /// Total wall-clock time for the last completed frame in seconds.
    #[serde(serialize_with = "diffuse_kernel::codable::serialize_double")]
    pub frame_seconds: f64,
    /// Frames per second (1 / frameSeconds), 0 if frameSeconds is 0.
    #[serde(serialize_with = "diffuse_kernel::codable::serialize_double")]
    pub fps: f64,
    /// Total frame time in milliseconds.
    #[serde(serialize_with = "diffuse_kernel::codable::serialize_double")]
    pub frame_ms: f64,

    /// Time spent processing input events this frame (seconds).
    #[serde(serialize_with = "diffuse_kernel::codable::serialize_double")]
    pub input_seconds: f64,
    /// Time spent in scene simulation this frame (seconds).
    #[serde(serialize_with = "diffuse_kernel::codable::serialize_double")]
    pub simulation_seconds: f64,
    /// Time spent preparing GPU render data this frame (seconds).
    #[serde(serialize_with = "diffuse_kernel::codable::serialize_double")]
    pub render_prepare_seconds: f64,
    /// Time spent encoding and submitting GPU commands this frame (seconds).
    #[serde(serialize_with = "diffuse_kernel::codable::serialize_double")]
    pub render_submit_seconds: f64,

    /// Time spent in GPU submit + present this frame (seconds).
    #[serde(serialize_with = "diffuse_kernel::codable::serialize_double")]
    pub gpu_present_seconds: f64,

    pub draw_call_count: i64,
    pub pass_count: i64,
    pub mesh_batch_count: i64,
    pub shadowed_light_count: i64,
    pub shadow_cascade_count: i64,
    pub shadow_map_resolution: u32,
    /// Time spent in CPU skybox encoding (nanoseconds).
    #[serde(rename = "cpuSkyboxEncodeNS")]
    pub cpu_skybox_encode_ns: u64,
    /// Time spent in CPU base pass encoding (nanoseconds).
    #[serde(rename = "cpuBaseEncodeNS")]
    pub cpu_base_encode_ns: u64,
    /// Time spent in CPU post-process encoding (nanoseconds).
    #[serde(rename = "cpuPostProcessEncodeNS")]
    pub cpu_post_process_encode_ns: u64,
}

impl EditorFrameStats {
    /// Swift's memberwise initializer with every default spelled out.
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        frame_seconds: f64,
        input_seconds: f64,
        simulation_seconds: f64,
        render_prepare_seconds: f64,
        render_submit_seconds: f64,
        gpu_present_seconds: f64,
        draw_call_count: i64,
        pass_count: i64,
        mesh_batch_count: i64,
        shadowed_light_count: i64,
        shadow_cascade_count: i64,
        shadow_map_resolution: u32,
        cpu_skybox_encode_ns: u64,
        cpu_base_encode_ns: u64,
        cpu_post_process_encode_ns: u64,
    ) -> Self {
        EditorFrameStats {
            frame_seconds,
            fps: if frame_seconds > 0.0 {
                1.0 / frame_seconds
            } else {
                0.0
            },
            frame_ms: frame_seconds * 1000.0,
            input_seconds,
            simulation_seconds,
            render_prepare_seconds,
            render_submit_seconds,
            gpu_present_seconds,
            draw_call_count,
            pass_count,
            mesh_batch_count,
            shadowed_light_count,
            shadow_cascade_count,
            shadow_map_resolution,
            cpu_skybox_encode_ns,
            cpu_base_encode_ns,
            cpu_post_process_encode_ns,
        }
    }

    /// The all-zero sample Swift's default arguments produced.
    pub fn with_defaults() -> Self {
        Self::new(0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    pub fn cpu_work_seconds(&self) -> f64 {
        self.input_seconds
            + self.simulation_seconds
            + self.render_prepare_seconds
            + self.render_submit_seconds
    }

    pub fn work_seconds(&self) -> f64 {
        self.cpu_work_seconds() + self.gpu_present_seconds
    }

    pub fn work_ms(&self) -> f64 {
        self.work_seconds() * 1000.0
    }

    pub fn pacing_gap_seconds(&self) -> f64 {
        (self.frame_seconds - self.work_seconds()).max(0.0)
    }

    pub fn pacing_gap_ms(&self) -> f64 {
        self.pacing_gap_seconds() * 1000.0
    }

    pub fn is_frame_pacing_dominated(&self) -> bool {
        if self.work_seconds() <= 0.0 {
            return self.frame_seconds > 0.05;
        }
        self.pacing_gap_seconds() > self.work_seconds().max(1.0 / 60.0)
    }

    pub fn work_fps(&self) -> f64 {
        if self.work_seconds() > 0.0 {
            1.0 / self.work_seconds()
        } else {
            0.0
        }
    }
}

impl Default for EditorFrameStats {
    fn default() -> Self {
        Self::with_defaults()
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EditorFrameStatsHistorySample {
    pub sample_index: u64,
    pub frame_index: u64,
    pub stats: EditorFrameStats,
}

impl EditorFrameStatsHistorySample {
    pub fn new(sample_index: u64, frame_index: u64, stats: EditorFrameStats) -> Self {
        EditorFrameStatsHistorySample {
            sample_index,
            frame_index,
            stats,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EditorParticleDiagnosticsSample {
    pub sample_index: u64,
    pub frame_index: u64,
    #[serde(serialize_with = "diffuse_kernel::codable::serialize_float")]
    pub simulated_delta_time: f32,
    pub emitter_count: i64,
    pub active_emitter_count: i64,
    pub live_particle_count: i64,
    pub live_particle_limit: i64,
    pub requested_spawn_count: i64,
    pub spawned_particle_count: i64,
    pub dropped_spawn_count: i64,
    pub capacity_limited_spawn_count: i64,
    pub spawn_budget_limited_count: i64,
    pub spawn_budget_consumed_count: i64,
    pub spawn_budget_limit: i64,
    pub event_requested_spawn_count: i64,
    pub event_dropped_spawn_count: i64,
    pub dropped_readback_event_count: i64,
    pub cpu_render_instance_count: i64,
    pub gpu_render_instance_count: i64,
    pub cpu_batch_count: i64,
    pub gpu_batch_count: i64,
    pub gpu_simulation_particle_count: i64,
    pub gpu_workgroup_count: i64,
    pub gpu_sort_item_count: i64,
    pub gpu_sort_padded_item_count: i64,
}

impl EditorParticleDiagnosticsSample {
    /// Swift's memberwise initializer; every count is clamped to `>= 0`.
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        sample_index: u64,
        frame_index: u64,
        simulated_delta_time: f32,
        emitter_count: i64,
        active_emitter_count: i64,
        live_particle_count: i64,
        live_particle_limit: i64,
        requested_spawn_count: i64,
        spawned_particle_count: i64,
        dropped_spawn_count: i64,
        capacity_limited_spawn_count: i64,
        spawn_budget_limited_count: i64,
        spawn_budget_consumed_count: i64,
        spawn_budget_limit: i64,
        event_requested_spawn_count: i64,
        event_dropped_spawn_count: i64,
        dropped_readback_event_count: i64,
        cpu_render_instance_count: i64,
        gpu_render_instance_count: i64,
        cpu_batch_count: i64,
        gpu_batch_count: i64,
        gpu_simulation_particle_count: i64,
        gpu_workgroup_count: i64,
        gpu_sort_item_count: i64,
        gpu_sort_padded_item_count: i64,
    ) -> Self {
        EditorParticleDiagnosticsSample {
            sample_index,
            frame_index,
            simulated_delta_time,
            emitter_count: emitter_count.max(0),
            active_emitter_count: active_emitter_count.max(0),
            live_particle_count: live_particle_count.max(0),
            live_particle_limit: live_particle_limit.max(0),
            requested_spawn_count: requested_spawn_count.max(0),
            spawned_particle_count: spawned_particle_count.max(0),
            dropped_spawn_count: dropped_spawn_count.max(0),
            capacity_limited_spawn_count: capacity_limited_spawn_count.max(0),
            spawn_budget_limited_count: spawn_budget_limited_count.max(0),
            spawn_budget_consumed_count: spawn_budget_consumed_count.max(0),
            spawn_budget_limit: spawn_budget_limit.max(0),
            event_requested_spawn_count: event_requested_spawn_count.max(0),
            event_dropped_spawn_count: event_dropped_spawn_count.max(0),
            dropped_readback_event_count: dropped_readback_event_count.max(0),
            cpu_render_instance_count: cpu_render_instance_count.max(0),
            gpu_render_instance_count: gpu_render_instance_count.max(0),
            cpu_batch_count: cpu_batch_count.max(0),
            gpu_batch_count: gpu_batch_count.max(0),
            gpu_simulation_particle_count: gpu_simulation_particle_count.max(0),
            gpu_workgroup_count: gpu_workgroup_count.max(0),
            gpu_sort_item_count: gpu_sort_item_count.max(0),
            gpu_sort_padded_item_count: gpu_sort_padded_item_count.max(0),
        }
    }
}
