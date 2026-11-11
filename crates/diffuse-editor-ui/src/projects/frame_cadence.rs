//! Translation of Editor/Sources/EditorUI/Projects/FrameCadence.swift.

use cove_runtime::PlatformFrameRateMode;

/// Active viewports follow display callbacks when VSync is enabled. Idle
/// workspaces return to event-driven updates; uncapped mode stays explicit.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct EditorFrameCadence {
    applied: Option<PlatformFrameRateMode>,
}

impl EditorFrameCadence {
    pub fn new() -> Self {
        EditorFrameCadence::default()
    }

    pub fn update(
        &mut self,
        continuous: bool,
        vsync_enabled: bool,
    ) -> Option<PlatformFrameRateMode> {
        let next = if continuous && vsync_enabled {
            PlatformFrameRateMode::DisplayRefresh
        } else {
            PlatformFrameRateMode::EventDriven
        };
        if self.applied == Some(next) {
            return None;
        }
        self.applied = Some(next);
        Some(next)
    }
}
