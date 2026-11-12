//! Ported from `Editor/Tests/EditorCoreTests/EditorViewportResolutionTests.swift`.

use diffuse_render::core::frame::render_packet::RenderDrawableSize;

use crate::editing::viewport::editor_viewport_input_controller::{
    ActiveInteraction, CameraDrag, EditorViewportInputController,
};
use crate::editing::viewport::editor_viewport_resolution::EditorViewportResolution;
use crate::state::editor_reducer::{EditorAction, EditorReducer};
use crate::state::editor_state::EditorState;
use diffuse_kernel::input_event::{KeyModifiers, MouseButton};

fn size(width: u32, height: u32) -> RenderDrawableSize {
    RenderDrawableSize::new(width, height)
}

/// Native scale passes the presentation size through.
#[test]
fn native_scale_is_identity() {
    assert_eq!(
        EditorViewportResolution::effective_size(size(2800, 1600), 100, false),
        size(2800, 1600)
    );
}

/// Render scale percent shrinks and supersamples with rounding.
#[test]
fn percent_scales() {
    assert_eq!(
        EditorViewportResolution::effective_size(size(2801, 1601), 50, false),
        size(1401, 801)
    );
    assert_eq!(
        EditorViewportResolution::effective_size(size(1400, 800), 200, false),
        size(2800, 1600)
    );
}

/// Interaction downscale stacks an extra halving on top of the scale.
#[test]
fn interaction_factor_stacks() {
    assert_eq!(
        EditorViewportResolution::effective_size(size(2800, 1600), 100, true),
        size(1400, 800)
    );
    assert_eq!(
        EditorViewportResolution::effective_size(size(2800, 1600), 50, true),
        size(700, 400)
    );
}

/// Effective size never collapses below one pixel and sanitizes the percent.
#[test]
fn clamps_and_sanitizes() {
    assert_eq!(
        EditorViewportResolution::effective_size(size(1, 1), 25, true),
        size(1, 1)
    );
    // Out-of-range percents clamp to the sanitized bounds (25–200).
    assert_eq!(
        EditorViewportResolution::effective_size(size(1000, 1000), 5, false),
        size(250, 250)
    );
    assert_eq!(
        EditorViewportResolution::effective_size(size(1000, 1000), 9999, false),
        size(2000, 2000)
    );
}

/// Reducer sanitizes the render scale percent and toggles downscale.
#[test]
fn reducer_handles_render_scale_actions() {
    let mut state = EditorState::default();
    assert_eq!(state.viewport.render_scale_percent, 100);
    assert!(!state.viewport.interaction_downscale_enabled);

    EditorReducer::reduce(&mut state, EditorAction::SetViewportRenderScalePercent(75));
    assert_eq!(state.viewport.render_scale_percent, 75);

    EditorReducer::reduce(
        &mut state,
        EditorAction::SetViewportRenderScalePercent(9999),
    );
    assert_eq!(state.viewport.render_scale_percent, 200);

    EditorReducer::reduce(&mut state, EditorAction::SetViewportRenderScalePercent(1));
    assert_eq!(state.viewport.render_scale_percent, 25);

    EditorReducer::reduce(
        &mut state,
        EditorAction::SetViewportInteractionDownscale(true),
    );
    assert!(state.viewport.interaction_downscale_enabled);
}

/// Render scale settings survive a state codable round trip.
#[test]
fn render_scale_settings_round_trip() {
    let mut state = EditorState::default();
    EditorReducer::reduce(&mut state, EditorAction::SetViewportRenderScalePercent(50));
    EditorReducer::reduce(
        &mut state,
        EditorAction::SetViewportInteractionDownscale(true),
    );

    let data = serde_json::to_vec(&state).expect("encode");
    let decoded: EditorState = serde_json::from_slice(&data).expect("decode");
    assert_eq!(decoded.viewport.render_scale_percent, 50);
    assert!(decoded.viewport.interaction_downscale_enabled);
}

/// Camera and gizmo drags count as continuous scene interaction, clicks do not.
#[test]
fn continuous_interaction_classification() {
    let controller = EditorViewportInputController::shared();
    controller.reset();

    controller.begin(
        ActiveInteraction::Camera {
            drag: CameraDrag::Orbit,
            button: MouseButton::Left,
        },
        (0.0, 0.0),
        KeyModifiers::default(),
    );
    assert!(controller.is_continuous_scene_interaction_active());
    controller.set_pressed_scancodes(std::collections::BTreeSet::from([26]));
    assert!(!controller.has_freelook_movement_input());

    controller.begin(
        ActiveInteraction::Gizmo {
            button: MouseButton::Left,
        },
        (0.0, 0.0),
        KeyModifiers::default(),
    );
    assert!(controller.is_continuous_scene_interaction_active());

    controller.begin(
        ActiveInteraction::Camera {
            drag: CameraDrag::Freelook,
            button: MouseButton::Right,
        },
        (0.0, 0.0),
        KeyModifiers::default(),
    );
    assert!(controller.is_continuous_scene_interaction_active());
    assert!(controller.has_freelook_movement_input());
    controller.set_pressed_scancodes(std::collections::BTreeSet::from([44]));
    assert!(!controller.has_freelook_movement_input());

    controller.begin(
        ActiveInteraction::PendingClick {
            button: MouseButton::Left,
        },
        (0.0, 0.0),
        KeyModifiers::default(),
    );
    assert!(!controller.is_continuous_scene_interaction_active());

    controller.begin(
        ActiveInteraction::Marquee {
            button: MouseButton::Left,
        },
        (0.0, 0.0),
        KeyModifiers::default(),
    );
    assert!(!controller.is_continuous_scene_interaction_active());

    controller.end_pointer_session(true);
    assert!(!controller.is_continuous_scene_interaction_active());
    controller.reset();
}
