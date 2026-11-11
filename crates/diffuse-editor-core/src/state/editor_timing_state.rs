//! `Editor/Sources/EditorCore/State/EditorTimingState.swift`.

use serde::{Deserialize, Serialize};

use crate::state::editor_state::{
    EditorFrameStats, EditorFrameStatsHistorySample, EditorParticleDiagnosticsSample, PlaybackState,
};

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct EditorTimingState {
    pub connected: bool,
    pub playback_state: PlaybackState,
    pub frame_index: u64,
    pub frame_timing_revision: u64,
    pub frame_stats: EditorFrameStats,
    /// Session samples; the persisted file keeps only the latest frame stats.
    #[serde(skip)]
    pub frame_stats_history: Vec<EditorFrameStatsHistorySample>,
    #[serde(skip)]
    pub particle_diagnostics_history: Vec<EditorParticleDiagnosticsSample>,
}

impl EditorTimingState {
    /// Swift's `init(_ configure:)` without a configuration closure.
    pub fn new() -> Self {
        EditorTimingState::default()
    }

    /// Swift's `init(_ configure:)` with the closure applied.
    pub fn with_configure(configure: impl FnOnce(&mut EditorTimingState)) -> Self {
        let mut state = EditorTimingState::default();
        configure(&mut state);
        state
    }

    pub fn normalize(&mut self) {
        let samples = &mut self.frame_stats_history;
        if samples.len() > crate::state::editor_state::EditorState::MAX_FRAME_STATS_HISTORY_SAMPLES
        {
            let excess = samples.len()
                - crate::state::editor_state::EditorState::MAX_FRAME_STATS_HISTORY_SAMPLES;
            samples.drain(..excess);
        }
        let samples = &mut self.particle_diagnostics_history;
        if samples.len()
            > crate::state::editor_state::EditorState::MAX_PARTICLE_DIAGNOSTICS_HISTORY_SAMPLES
        {
            let excess = samples.len()
                - crate::state::editor_state::EditorState::MAX_PARTICLE_DIAGNOSTICS_HISTORY_SAMPLES;
            samples.drain(..excess);
        }
    }
}

impl Default for EditorTimingState {
    fn default() -> Self {
        EditorTimingState {
            connected: false,
            playback_state: PlaybackState::Stopped,
            frame_index: 0,
            frame_timing_revision: 0,
            frame_stats: EditorFrameStats::with_defaults(),
            frame_stats_history: Vec::new(),
            particle_diagnostics_history: Vec::new(),
        }
    }
}
