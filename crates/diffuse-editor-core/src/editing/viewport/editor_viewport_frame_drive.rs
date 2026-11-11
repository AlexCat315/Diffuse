//! `Editor/Sources/EditorCore/Editing/Viewport/EditorViewportFrameDrive.swift`.

use crate::state::editor_state::PlaybackState;

pub struct EditorViewportFrameDrive;

impl EditorViewportFrameDrive {
    pub fn wants_continuous_frames(
        viewport_realtime_enabled: bool,
        playback_state: PlaybackState,
        continuous_viewport_interaction_active: bool,
        is_presentation_active: bool,
    ) -> bool {
        is_presentation_active
            && (viewport_realtime_enabled
                || playback_state == PlaybackState::Playing
                || continuous_viewport_interaction_active)
    }

    /// Swift's `isPresentationActive: Bool = true` default.
    pub fn wants_continuous_frames_default(
        viewport_realtime_enabled: bool,
        playback_state: PlaybackState,
        continuous_viewport_interaction_active: bool,
    ) -> bool {
        Self::wants_continuous_frames(
            viewport_realtime_enabled,
            playback_state,
            continuous_viewport_interaction_active,
            true,
        )
    }
}
