//! Ported from `Editor/Tests/EditorCoreTests/EditorViewportRenderGateTests.swift`.

use std::collections::BTreeMap;

use diffuse_math::simd::simd_compat::{Float3, MATRIX_IDENTITY_FLOAT4X4};
use diffuse_render::core::frame::render_packet::RenderDrawableSize;
use diffuse_scene::entity_id::EntityID;
use diffuse_scene::media::animation::{JointPalette, JointPaletteMap};
use diffuse_scene::rendering::render_scene::RenderCamera;

use crate::editing::viewport::editor_viewport_frame_drive::EditorViewportFrameDrive;
use crate::editing::viewport::editor_viewport_render_gate::{
    EditorViewportRenderGate, EditorViewportRenderGateSignature,
};
use crate::state::editor_reducer::{EditorAction, EditorReducer};
use crate::state::editor_state::{EditorState, PlaybackState};

fn signature(
    revision: u64,
    eye_x: f32,
    width: u32,
    settings: u64,
    palette_count: usize,
) -> EditorViewportRenderGateSignature {
    let mut palettes = BTreeMap::new();
    for index in 0..palette_count {
        palettes.insert(
            EntityID::new(index as u32, 0),
            JointPalette::new(vec![MATRIX_IDENTITY_FLOAT4X4]),
        );
    }
    EditorViewportRenderGateSignature::new(
        revision,
        RenderCamera::new(Float3::new(eye_x, 2.0, 5.0), Float3::ZERO),
        RenderDrawableSize::new(width, 800),
        settings,
        JointPaletteMap::new(palettes),
    )
}

fn default_signature() -> EditorViewportRenderGateSignature {
    signature(1, 0.0, 1000, 0, 0)
}

fn decide(
    gate: &mut EditorViewportRenderGate,
    sig: &EditorViewportRenderGateSignature,
    force: bool,
    input: bool,
    taa: bool,
    now: f64,
) -> bool {
    gate.should_render(sig.clone(), force, input, taa, true, now)
}

/// Steps the gate through enough clean ticks to drain the post-dirty
/// convergence frames, then returns the next clean decision.
fn settled(
    gate: &mut EditorViewportRenderGate,
    sig: &EditorViewportRenderGateSignature,
    time: f64,
) -> bool {
    for _ in 0..EditorViewportRenderGate::TEMPORAL_CONVERGENCE_FRAMES {
        let _ = decide(gate, sig, false, false, false, time);
    }
    decide(gate, sig, false, false, false, time)
}

/// Hidden viewports skip even forced frames and resume with full convergence.
#[test]
fn hidden_viewport_resumes_immediately() {
    let mut gate = EditorViewportRenderGate::new();
    let sig = default_signature();
    let _ = settled(&mut gate, &sig, 0.0);
    let hidden = gate.should_render(sig.clone(), true, true, true, false, 100.0);
    assert!(!hidden);
    let exposed = gate.should_render(sig.clone(), false, false, true, true, 100.01);
    assert!(exposed);
    for frame in 1..EditorViewportRenderGate::TEMPORAL_CONVERGENCE_FRAMES {
        assert!(decide(
            &mut gate,
            &sig,
            false,
            false,
            true,
            100.01 + frame as f64 * 0.01
        ));
    }
    assert!(!decide(&mut gate, &sig, false, false, true, 100.2));
    assert!(!EditorViewportFrameDrive::wants_continuous_frames(
        true,
        PlaybackState::Playing,
        true,
        false
    ));
}

/// First tick renders, identical follow-ups settle into skipping.
#[test]
fn settles_when_clean() {
    let mut gate = EditorViewportRenderGate::new();
    let sig = default_signature();
    assert!(decide(&mut gate, &sig, false, false, false, 0.0));
    assert!(!settled(&mut gate, &sig, 0.1));
    assert!(!decide(&mut gate, &sig, false, false, false, 0.2));
}

/// Each packet input change re-renders: revision, camera, size, settings, palettes.
#[test]
fn packet_input_changes_dirty() {
    let mut gate = EditorViewportRenderGate::new();
    let _ = settled(&mut gate, &default_signature(), 0.0);

    for changed in [
        signature(2, 0.0, 1000, 0, 0),
        signature(2, 1.0, 1000, 0, 0),
        signature(2, 1.0, 1400, 0, 0),
        signature(2, 1.0, 1400, 1, 0),
        signature(2, 1.0, 1400, 1, 1),
    ] {
        assert!(decide(&mut gate, &changed, false, false, false, 0.1));
        assert!(!settled(&mut gate, &changed, 0.1));
    }
}

/// Convergence renders a couple of frames after the last change, more with TAA.
#[test]
fn convergence_frames() {
    let mut gate = EditorViewportRenderGate::new();
    let sig = default_signature();
    assert!(decide(&mut gate, &sig, false, false, false, 0.0));
    // CONVERGENCE_FRAMES = 2: the dirty frame plus one extra.
    assert!(decide(&mut gate, &sig, false, false, false, 0.01));
    assert!(!decide(&mut gate, &sig, false, false, false, 0.02));

    let mut taa_gate = EditorViewportRenderGate::new();
    assert!(decide(&mut taa_gate, &sig, false, false, true, 0.0));
    let mut rendered_after_dirty = 0;
    for tick in 0..(EditorViewportRenderGate::TEMPORAL_CONVERGENCE_FRAMES + 4) {
        if decide(
            &mut taa_gate,
            &sig,
            false,
            false,
            true,
            0.01 + tick as f64 * 0.01,
        ) {
            rendered_after_dirty += 1;
        }
    }
    assert_eq!(
        rendered_after_dirty,
        EditorViewportRenderGate::TEMPORAL_CONVERGENCE_FRAMES - 1
    );
}

/// Realtime / playing force and viewport input keep rendering.
#[test]
fn forces_keep_rendering() {
    let mut gate = EditorViewportRenderGate::new();
    let sig = default_signature();
    let _ = settled(&mut gate, &sig, 0.0);
    assert!(decide(&mut gate, &sig, true, false, false, 0.1));
    assert!(decide(&mut gate, &sig, true, false, false, 0.2));

    let mut input_gate = EditorViewportRenderGate::new();
    let _ = settled(&mut input_gate, &sig, 0.0);
    assert!(decide(&mut input_gate, &sig, false, true, false, 0.1));
}

/// Frame drive treats camera and gizmo drags as continuous work.
#[test]
fn frame_drive_includes_continuous_viewport_interaction() {
    assert!(EditorViewportFrameDrive::wants_continuous_frames(
        false,
        PlaybackState::Stopped,
        true,
        true
    ));
    assert!(!EditorViewportFrameDrive::wants_continuous_frames(
        false,
        PlaybackState::Stopped,
        false,
        true
    ));
    assert!(EditorViewportFrameDrive::wants_continuous_frames(
        true,
        PlaybackState::Stopped,
        false,
        true
    ));
    assert!(EditorViewportFrameDrive::wants_continuous_frames(
        false,
        PlaybackState::Playing,
        false,
        true
    ));
    assert!(!EditorViewportFrameDrive::wants_continuous_frames(
        false,
        PlaybackState::Paused,
        false,
        true
    ));
}

/// Heartbeat forces a frame after the interval even when clean.
#[test]
fn heartbeat_forces_frame() {
    let mut gate = EditorViewportRenderGate::new();
    let sig = default_signature();
    let _ = settled(&mut gate, &sig, 0.0);
    assert!(!decide(&mut gate, &sig, false, false, false, 0.5));
    assert!(decide(
        &mut gate,
        &sig,
        false,
        false,
        false,
        EditorViewportRenderGate::HEARTBEAT_INTERVAL + 0.01
    ));
}

/// Realtime toggle reducer and codable round trip.
#[test]
fn realtime_state_plumbing() {
    let mut state = EditorState::default();
    assert!(!state.viewport.realtime_enabled);
    EditorReducer::reduce(&mut state, EditorAction::SetViewportRealtime(true));
    assert!(state.viewport.realtime_enabled);

    let data = serde_json::to_vec(&state).expect("encode");
    let decoded: EditorState = serde_json::from_slice(&data).expect("decode");
    assert!(decoded.viewport.realtime_enabled);
}
