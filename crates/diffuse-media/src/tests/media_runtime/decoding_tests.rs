//! `MediaRuntimeTests` — Swift's `DecodingTests.swift`, re-grounded on the
//! FFmpeg 9.x command line tools that `cove-media` aligns with.
//!
//! Fixtures are the same three files the Swift target bundled: `tone.wav`,
//! `tone.m4a` and `video.mp4`. They are read from `crates/diffuse-media/fixtures`.
//! The synchronous PCM/frame readers belonged to the removed `CFFmpegBridge`;
//! their stream-level facts are now asserted through `MediaAsset::inspect`.

use crate::decoding::values::{MediaAsset, MediaError, MediaUrl};
use crate::editing::composition::{CompositionClip, CompositionVideo, MediaComposition};
use crate::editing::export::MediaExporter;
use crate::editing::tools::FFmpegTools;

/// `private func fixture(_ name: String) -> URL`.
fn fixture(name: &str) -> MediaUrl {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("fixtures")
        .join(name);
    MediaUrl::from_file_path(path.to_string_lossy().into_owned())
}

/// `pcmResamplingDrainsTailAndEnforcesResidentLimit` — the WAV fixture must
/// still be recognized as a 0.25 s audio-only asset.
#[test]
fn wav_asset_probe_reports_audio_only() {
    let asset = MediaAsset::inspect(&fixture("tone.wav")).expect("tone.wav inspects");
    assert!(asset.has_audio);
    assert!(asset.video.is_none());
    assert!((asset.duration - 0.25).abs() < 0.01);
    assert!(
        MediaAsset::inspect(&fixture("video.mp4"))
            .expect("video.mp4 inspects")
            .video
            .is_some()
    );
}

/// `compressedAudioDecodesWithoutAnExternalProcess` — compressed audio must
/// still probe as audio-only with a usable duration.
#[test]
fn compressed_audio_asset_probe_reports_stream_facts() {
    let info = MediaAsset::inspect(&fixture("tone.m4a")).expect("tone.m4a inspects");
    assert!(info.has_audio);
    assert!(info.video.is_none());
    assert!(info.duration > 0.0);
}

/// `videoFramesSeekAndResetAfterEOF` — dimensions, duration and the remote-URL
/// rejection are the parts that survive without the synchronous frame reader.
#[test]
fn video_asset_probe_reports_dimensions_and_duration() {
    let asset = MediaAsset::inspect(&fixture("video.mp4")).expect("video.mp4 inspects");
    let video = asset.video.expect("video stream present");
    assert_eq!(video.width, 16);
    assert_eq!(video.height, 16);
    assert!((asset.duration - 1.0).abs() < 0.01);
    // `try MediaAsset.inspect(URL(string: "https://example.com/video.mp4")!)`
    let remote = MediaUrl::parse("https://example.com/video.mp4").expect("URL(string:) parses");
    assert!(MediaAsset::inspect(&remote).is_err());
}

/// `authoredCompositionRoundTripsWithoutPlaybackState`
#[test]
fn authored_composition_round_trips_without_playback_state() {
    let mut document = MediaComposition::new();
    document.clips = vec![CompositionClip::new("video.mp4", 0.1, 0.4)];
    document.validate().expect("clip is valid");

    // `JSONDecoder().decode(MediaComposition.self, from: Data("{}".utf8))`
    let defaults: MediaComposition = serde_json::from_slice(b"{}").expect("empty object decodes");
    assert_eq!(defaults, MediaComposition::new());

    // `decode(MediaComposition.Video.self, from: {"width":1280})`
    let partial: CompositionVideo =
        serde_json::from_slice(br#"{"width":1280}"#).expect("partial video decodes");
    assert_eq!(partial.width, 1280);
    assert_eq!(partial.height, 1080);
    assert_eq!(partial.frames_per_second, 30);

    let data = serde_json::to_vec(&document).expect("composition encodes");
    let decoded: MediaComposition = serde_json::from_slice(&data).expect("round trip decodes");
    assert_eq!(decoded, document);
    assert!(!String::from_utf8_lossy(&data).contains("decoder"));

    document.clips[0].source = "../video.mp4".to_string();
    assert!(document.validate().is_err());
}

/// `trimsAndConcatenatesVideoWithSilentAudio`
#[test]
fn trims_and_concatenates_video_with_silent_audio() {
    let root = fixture("video.mp4").deleting_last_path_component();
    let output = MediaUrl::from_file_path(
        std::env::temp_dir()
            .join(format!("cove-media-test-{}.mp4", unique_suffix()))
            .to_string_lossy()
            .into_owned(),
    );
    struct Cleanup(MediaUrl);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            let _ = std::fs::remove_file(self.0.path());
        }
    }
    let _cleanup = Cleanup(output.clone());

    let mut composition = MediaComposition::new();
    composition.video.width = 16;
    composition.video.height = 16;
    composition.video.frames_per_second = 10;
    composition.clips = vec![
        CompositionClip::new("video.mp4", 0.1, 0.3),
        CompositionClip::new("video.mp4", 0.5, 0.3),
    ];

    let exporter = MediaExporter::new(FFmpegTools::executable().expect("FFmpeg 9.x CLI found"));
    exporter
        .export(&composition, &root, &output)
        .expect("export succeeds");

    let result = MediaAsset::inspect(&output).expect("export inspects");
    assert!(result.has_audio);
    assert!(result.video.is_some());
    assert!((result.duration - 0.6).abs() < 0.06);

    // The destination now exists, so a second export must fail.
    assert!(exporter.export(&composition, &root, &output).is_err());
}

/// A unique suffix for temporary files; the Swift test used `UUID().uuidString`.
fn unique_suffix() -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_nanos() as u64)
        .unwrap_or(0);
    format!("{nanos:X}{:X}", COUNTER.fetch_add(1, Ordering::Relaxed))
}

/// `MediaError` keeps Swift's three cases and their descriptions.
#[test]
fn media_error_cases_match_swift() {
    let invalid = MediaError::Invalid("a".to_string());
    let decoding = MediaError::Decoding("a".to_string());
    let export = MediaError::Export("a".to_string());
    assert_eq!(invalid.error_description(), "a");
    assert_eq!(decoding.error_description(), "a");
    assert_eq!(export.error_description(), "a");
    assert_ne!(invalid, decoding);
    assert_ne!(decoding, export);
}
