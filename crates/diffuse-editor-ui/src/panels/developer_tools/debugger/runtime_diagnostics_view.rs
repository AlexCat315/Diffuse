//! Translation of
//! Editor/Sources/EditorUI/Panels/DeveloperTools/Debugger/RuntimeDiagnosticsView.swift.

use cove_ui_compose::modifiers::layout::{LayoutFrameExt, PaddingExt};
use cove_ui_compose::scene_core::{Align, FlexDirection, Justify, Wrap};
use cove_ui_compose::{
    AnyView, BoxView, Column, FrameDimension, HorizontalAlignment, Scope, ScrollAxis, ScrollView,
    TupleView, View,
};
use diffuse_editor_core::diagnostics::formatting::{format_fps, format_ms, format_ns};
use diffuse_editor_core::state::editor_state::{EditorFrameStats, PlaybackState};
use diffuse_editor_core::state::editor_store::EditorStore;
use diffuse_render::core::render_stats::RenderFrameStats;

use crate::localization::localized;
use crate::panels::developer_tools::shared::developer_stat_components::{StatGroup, StatRow};

pub struct RuntimeDiagnosticsView {
    pub store: EditorStore,
    pub timing_revision: u64,
    pub frame_stats: EditorFrameStats,
    pub render_stats: RenderFrameStats,
}

impl RuntimeDiagnosticsView {
    pub fn new(
        store: EditorStore,
        timing_revision: u64,
        frame_stats: EditorFrameStats,
        render_stats: RenderFrameStats,
    ) -> Self {
        RuntimeDiagnosticsView {
            store,
            timing_revision,
            frame_stats,
            render_stats,
        }
    }
}

impl View for RuntimeDiagnosticsView {
    fn body(&self, _scope: &Scope) -> AnyView {
        let store = &self.store;
        let stats = &self.frame_stats;
        let render = &self.render_stats;

        let editor = group(
            localized("Editor"),
            vec![
                row(
                    localized("Status"),
                    if store.connected() {
                        localized("Connected")
                    } else {
                        localized("Offline")
                    },
                ),
                row(localized("Revision"), store.scene_revision().to_string()),
                row(localized("Frame Index"), store.frame_index().to_string()),
                row(
                    localized("Timing Sample"),
                    format!("#{}", self.timing_revision),
                ),
            ],
        );
        let performance = group(
            localized("Performance"),
            vec![
                row(localized("Frame Work"), format_ms(stats.work_ms())),
                row(localized("Observed FPS"), format_fps(stats.fps)),
                row(
                    localized("CPU Total"),
                    format_ms(stats.cpu_work_seconds() * 1000.0),
                ),
                row(
                    localized("GPU / Present"),
                    format_ms(stats.gpu_present_seconds * 1000.0),
                ),
                row(localized("Pacing Gap"), format_ms(stats.pacing_gap_ms())),
            ],
        );
        let rendering = group(
            localized("Render"),
            vec![
                row(localized("Draw Calls"), render.draw_call_count.to_string()),
                row(localized("Passes"), render.pass_count.to_string()),
                row(
                    localized("Mesh Batches"),
                    render.mesh_batch_count.to_string(),
                ),
                row(localized("CPU Encode"), format_ns(render.cpu_encode_ns)),
            ],
        );
        let viewport = group(
            localized("Viewport"),
            vec![
                row(
                    localized("Realtime"),
                    on_off(store.viewport_realtime_enabled()),
                ),
                row(
                    localized("Render Scale"),
                    format!("{}%", store.viewport_render_scale_percent()),
                ),
                row(
                    localized("Shading"),
                    localized(&capitalize_first(store.viewport_shading_mode().raw_value())),
                ),
                row(
                    localized("Shadows"),
                    on_off(store.viewport_shadows_enabled()),
                ),
            ],
        );
        let selection = group(
            localized("Selection"),
            vec![
                row(
                    localized("Primary"),
                    store
                        .selected_entity_id()
                        .map(|entity| entity.to_string())
                        .unwrap_or_else(|| "--".to_string()),
                ),
                row(
                    localized("Count"),
                    store.selected_entity_ids().len().to_string(),
                ),
                row(
                    localized("Playback"),
                    localized(playback_state_label(store.playback_state())),
                ),
            ],
        );

        let content = AnyView::new(
            AnyView::new(BoxView::new(
                FlexDirection::Row,
                Align::Stretch,
                Justify::FlexStart,
                Wrap::Wrap,
                8.0,
                AnyView::new(TupleView::new(vec![
                    editor,
                    performance,
                    rendering,
                    viewport,
                    selection,
                ])),
            ))
            .frame(
                Some(FrameDimension::Percent(100.0)),
                None,
                Some(0.0),
                None,
                None,
                None,
            )
            .padding_edges(12.0, 10.0),
        );
        AnyView::new(ScrollView::new(ScrollAxis::Vertical, content))
    }
}

fn group(title: String, rows: Vec<AnyView>) -> AnyView {
    AnyView::new(
        StatGroup::new(
            title,
            Column::new(
                HorizontalAlignment::Leading,
                0.0,
                AnyView::new(TupleView::new(rows)),
            ),
        )
        .frame(None, None, Some(200.0), None, Some(280.0), None),
    )
}

fn row(label: String, value: String) -> AnyView {
    AnyView::new(StatRow::new(label, value))
}

fn on_off(enabled: bool) -> String {
    if enabled {
        localized("On")
    } else {
        localized("Off")
    }
}

fn playback_state_label(state: PlaybackState) -> &'static str {
    match state {
        PlaybackState::Stopped => "Stopped",
        PlaybackState::Playing => "Playing",
        PlaybackState::Paused => "Paused",
    }
}

/// Swift's `String(describing: enum).capitalized` uppercases the first letter of
/// the raw case name (`baseColor` → `Basecolor`).
fn capitalize_first(value: &str) -> String {
    let mut characters = value.chars();
    match characters.next() {
        Some(first) => first.to_uppercase().collect::<String>() + characters.as_str(),
        None => String::new(),
    }
}
