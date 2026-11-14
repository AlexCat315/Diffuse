//! Playback range and cancellation, translated from MediaPlaybackTests.swift.

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use crate::playback::media_player::MediaPlayer;
use diffuse_media::{MediaError, MediaUrl};

#[test]
fn video_playback_respects_range_and_cancellation() {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../diffuse-media/fixtures/video.mp4");
    let url = MediaUrl::from_file_path(path.to_string_lossy().into_owned());
    let times = Arc::new(Mutex::new(Vec::new()));
    let observed = times.clone();
    let start = Instant::now();
    MediaPlayer::new()
        .play(
            &url,
            0.2,
            Some(0.2),
            Arc::new(move |frame| {
                observed
                    .lock()
                    .expect("frame list")
                    .push(frame.pts.map_or(0.0, |time| time.seconds()));
            }),
        )
        .expect("play selected range");
    let times = times.lock().expect("frame list");
    assert_eq!(times.len(), 2);
    for (actual, expected) in times.iter().zip([0.2, 0.3]) {
        assert!((actual - expected).abs() < 0.000001);
    }
    assert!(start.elapsed() >= Duration::from_millis(180));
    drop(times);

    let player = Arc::new(MediaPlayer::new());
    let worker_player = player.clone();
    let worker = std::thread::spawn(move || worker_player.play(&url, 0.0, None, Arc::new(|_| {})));
    std::thread::sleep(Duration::from_millis(30));
    player.cancel();
    assert_eq!(
        worker.join().expect("playback thread"),
        Err(MediaError::Cancelled)
    );
}
