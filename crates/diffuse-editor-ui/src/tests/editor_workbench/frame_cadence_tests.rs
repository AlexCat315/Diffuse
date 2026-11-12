//! Ported from `Editor/Tests/EditorWorkbenchTests/FrameCadenceTests.swift`.

use cove_runtime::PlatformFrameRateMode;

use crate::projects::frame_cadence::EditorFrameCadence;

/// Playback and realtime previews follow display refresh, then return to idle.
#[test]
fn playback_and_previews_follow_display_refresh() {
    let mut cadence = EditorFrameCadence::new();
    assert_eq!(
        cadence.update(false, true),
        Some(PlatformFrameRateMode::EventDriven)
    );
    assert_eq!(
        cadence.update(true, true),
        Some(PlatformFrameRateMode::DisplayRefresh)
    );
    for _ in 0..60 {
        assert_eq!(cadence.update(true, true), None);
    }
    assert_eq!(
        cadence.update(false, true),
        Some(PlatformFrameRateMode::EventDriven)
    );
    assert_eq!(cadence.update(false, true), None);
}

/// Explicitly disabling VSync releases the native cadence cap.
#[test]
fn disabling_vsync_releases_the_cadence_cap() {
    let mut cadence = EditorFrameCadence::new();
    assert_eq!(
        cadence.update(true, true),
        Some(PlatformFrameRateMode::DisplayRefresh)
    );
    assert_eq!(
        cadence.update(true, false),
        Some(PlatformFrameRateMode::EventDriven)
    );
    assert_eq!(cadence.update(true, false), None);
    assert_eq!(
        cadence.update(true, true),
        Some(PlatformFrameRateMode::DisplayRefresh)
    );
}
