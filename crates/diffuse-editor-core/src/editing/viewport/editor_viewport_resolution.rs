//! `Editor/Sources/EditorCore/Editing/Viewport/EditorViewportResolution.swift`.

use diffuse_render::core::frame::render_packet::RenderDrawableSize;

use crate::state::editor_state::EditorState;

/// Maps the viewport's presentation size (physical pixels of the on-screen
/// quad) to the engine's render resolution: presentation × renderScale ×
/// optional interaction downscale. Pure math, kept separate for tests.
pub struct EditorViewportResolution;

impl EditorViewportResolution {
    pub const MAX_DIMENSION: u32 = 16_384;
    /// Extra factor applied while a camera / gizmo drag is active and the
    /// interaction-downscale toggle is on.
    pub const INTERACTION_FACTOR: f32 = 0.5;

    pub fn effective_size(
        presentation: RenderDrawableSize,
        render_scale_percent: i64,
        interaction_downscale_active: bool,
    ) -> RenderDrawableSize {
        let mut scale =
            EditorState::sanitized_render_scale_percent(render_scale_percent) as f32 / 100.0;
        if interaction_downscale_active {
            scale *= Self::INTERACTION_FACTOR;
        }
        RenderDrawableSize::new(
            Self::scaled(presentation.width, scale),
            Self::scaled(presentation.height, scale),
        )
    }

    fn scaled(value: u32, scale: f32) -> u32 {
        let raw = (value as f32 * scale).round();
        if raw < 1.0 {
            return 1;
        }
        (raw as u32).min(Self::MAX_DIMENSION)
    }
}
