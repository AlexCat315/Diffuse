//! Translation of `Engine/Sources/AudioRuntime/Playback/MediaPlayer.swift`.
//!
//! Swift's `actor MediaPlayer` becomes a struct whose state sits behind a
//! `Mutex` (MIGRATION.md §5.5); `async` entry points become synchronous
//! blocking functions. `Task.checkCancellation()` becomes an `AtomicBool`
//! cancellation token (`cove_media::CancellationToken` wraps `Arc<AtomicBool>`),
//! and `ContinuousClock` becomes [`std::time::Instant`].
//!
//! The 8.1.3 decode stack (`VideoReader`/`AudioReader`/`PCMBuffer`/
//! `VideoFrame`) was removed in batch 85 (MIGRATION.md §8,
//! `Docs/rust-migration-files.json`: `readers.rs` is `removed`). Generic demux
//! and decode now come from `cove-media`'s [`MediaDecoder`], and frames are
//! [`cove_media::VideoFrame`]. Playback errors stay in the Diffuse domain via
//! [`diffuse_media::MediaError`].

use std::ffi::{c_int, c_void};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use cove_media::{
    AudioFormat, CancellationToken, DecoderOptions, MediaDecoder, MediaSource, MediaTime,
    VideoFrame,
};
use diffuse_media::{MediaAsset, MediaError, MediaUrl};

/// Streams video and audio without retaining the whole movie.
///
/// Cancelling through [`MediaPlayer::cancel`] stops playback and releases
/// decoder/device state, the counterpart of cancelling Swift's calling task.
pub struct MediaPlayer {
    /// `Task.checkCancellation()` → an `AtomicBool`-backed token.
    cancelled: CancellationToken,
    /// `actor` isolation → owned state behind a `Mutex` (MIGRATION.md §5.5).
    state: Mutex<()>,
}

impl MediaPlayer {
    /// `public init()`.
    pub fn new() -> Self {
        MediaPlayer {
            cancelled: CancellationToken::default(),
            state: Mutex::new(()),
        }
    }

    /// `Task.cancel()` — sets the token that `check_cancellation` reads.
    pub fn cancel(&self) {
        self.cancelled.cancel();
    }

    /// `public func play(url:from:duration:onVideo:) async throws`.
    ///
    /// `onVideo: @Sendable (VideoFrame) async -> Void` becomes a synchronous
    /// `Arc<dyn Fn(VideoFrame) + Send + Sync>` (MIGRATION.md §5.5).
    pub fn play(
        &self,
        url: &MediaUrl,
        start: f64,
        duration: Option<f64>,
        on_video: Arc<dyn Fn(VideoFrame) + Send + Sync>,
    ) -> Result<(), MediaError> {
        // One call at a time, matching the actor's isolation.
        let _guard = self.state.lock().unwrap_or_else(|error| error.into_inner());

        // `guard start.isFinite, start >= 0, duration == nil ||
        //  (duration!.isFinite && duration! > 0)`.
        if !start.is_finite()
            || start < 0.0
            || duration.is_some_and(|value| !value.is_finite() || value <= 0.0)
        {
            return Err(MediaError::Invalid(
                "Playback range must be finite and positive".to_string(),
            ));
        }

        let asset = MediaAsset::inspect(url)?;
        let end = asset
            .duration
            .min(start + duration.unwrap_or(asset.duration));
        // `guard asset.video != nil, start < end`. Comparing `partial_cmp`
        // against `Less` keeps Swift's `guard` NaN behaviour (a NaN comparison
        // is false) without clippy's negated-comparison lint.
        if asset.video.is_none() || start.partial_cmp(&end) != Some(std::cmp::Ordering::Less) {
            return Err(MediaError::Invalid(
                "Playback requires a video stream and a valid range".to_string(),
            ));
        }

        // Swift opens two independent decoders: `VideoReader(url:)` and
        // `AudioReader(url:)`. Each `MediaDecoder::open` owns its own FFmpeg
        // handles, so video and audio keep independent decoder state.
        let mut video =
            MediaDecoder::open(MediaSource::file(url.path()), DecoderOptions::video_only())
                .map_err(media_error)?;
        video
            .seek(MediaTime::from_seconds(start).map_err(media_error)?)
            .map_err(media_error)?;

        let mut audio = if asset.has_audio {
            Some(
                MediaDecoder::open(
                    MediaSource::file(url.path()),
                    DecoderOptions {
                        video: false,
                        audio: true,
                        video_size: None,
                        // Swift's `PCMBuffer` is interleaved native Float32
                        // stereo at 48 kHz: 2 channels × 4 bytes = 8 bytes/frame.
                        audio_format: Some(AudioFormat {
                            sample_rate: 48000,
                            channels: 2,
                        }),
                    },
                )
                .map_err(media_error)?,
            )
        } else {
            None
        };
        if let Some(audio) = audio.as_mut() {
            audio
                .seek(MediaTime::from_seconds(start).map_err(media_error)?)
                .map_err(media_error)?;
        }
        let sink = if audio.is_some() {
            Some(PlaybackAudioSink::new()?)
        } else {
            None
        };
        let mut audio_ended = audio.is_none();
        let mut submitted: f64 = 0.0;
        let mut frame = video.next_video().map_err(media_error)?;
        // `ContinuousClock` → `Instant`; `began` is the clock instant at which
        // playback actually started (after the first audio queue fill).
        let mut began: Option<Instant> = None;

        loop {
            // `try Task.checkCancellation()`.
            self.check_cancellation()?;

            // `if let audio, let sink, !audioEnded` then the 0.2 s queue loop.
            if !audio_ended && let (Some(audio), Some(sink)) = (&mut audio, &sink) {
                while sink.queued_seconds() < 0.2 && !audio_ended {
                    if let Some(buffer) = audio.next_audio().map_err(media_error)? {
                        // `max(0, Int(((end - start) - submitted) * 48000))`.
                        // A float→usize cast saturates negatives to zero,
                        // which is Swift's `max(0, Int(...))` clamp here.
                        let remaining_frames =
                            (((end - start) - submitted) * 48000.0).max(0.0) as usize;
                        let frames = buffer.frames().min(remaining_frames);
                        // `buffer.samples.prefix(frames * 8)`: 8 bytes per
                        // frame (2 × f32), native-endian like Swift's Data.
                        let bytes: Vec<u8> = buffer.samples[..frames * 2]
                            .iter()
                            .flat_map(|sample| sample.to_ne_bytes())
                            .collect();
                        sink.write(&bytes)?;
                        submitted += frames as f64 / 48000.0;
                        if frames < buffer.frames() || remaining_frames == 0 {
                            audio_ended = true;
                            sink.flush();
                        }
                    } else {
                        audio_ended = true;
                        sink.flush();
                    }
                }
            }

            // `if began == nil { try sink?.resume(); began = clock.now }`.
            if began.is_none() {
                if let Some(sink) = &sink {
                    sink.resume()?;
                }
                began = Some(Instant::now());
            }
            // `began!.duration(to: clock.now).components` → elapsed seconds.
            // `as_secs_f64` is `seconds + subsec_nanos / 1e9`, matching Swift's
            // `Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18`
            // at `Duration`'s nanosecond precision.
            let wall_time = began
                .expect("began is set before the elapsed read")
                .elapsed()
                .as_secs_f64();
            // After a shorter audio track ends, the movie continues on its clock.
            let played = match &sink {
                Some(sink) if !audio_ended || sink.queued_seconds() > 0.0 => {
                    (submitted - sink.queued_seconds()).max(0.0)
                }
                _ => wall_time,
            };
            let position = start + played;

            // Deliver every frame that belongs to the requested range before
            // stopping: a slow decode must not drop the range's remaining
            // frames just because wall time crossed the end.
            while let Some(pending) = frame.take() {
                let time = frame_time(&pending);
                if time < end && time <= position + 0.005 {
                    self.check_cancellation()?;
                    on_video(pending);
                    frame = video.next_video().map_err(media_error)?;
                } else {
                    // Not due yet (or past the range): keep it for the next tick.
                    frame = Some(pending);
                    break;
                }
            }
            if position >= end {
                break;
            }
            // `try await clock.sleep(for: .milliseconds(5))`.
            std::thread::sleep(Duration::from_millis(5));
        }
        Ok(())
    }

    /// One-frame read for previews. Swift's `Media.swift` called
    /// `VideoReader(url:).frame(at:)`, which `Readers.swift` implemented as
    /// `decoder.seek(to: seconds)` then `decoder.video()` — seek to the
    /// requested time and take the first frame. `MediaDecoder`'s `frame_at`
    /// is exactly that pair; it is spelled out here to keep the
    /// seek-then-first-frame semantics explicit rather than re-derived.
    ///
    /// Returns `Option<VideoFrame>` because reaching the end (or a position
    /// past the last frame) yields no frame.
    pub fn frame_at(&self, url: &MediaUrl, at: f64) -> Result<Option<VideoFrame>, MediaError> {
        let _guard = self.state.lock().unwrap_or_else(|error| error.into_inner());
        // `VideoReader(url:)` → `FileDecoder(url:)` rejected non-file URLs
        // (`Decoder.swift`'s `guard url.isFileURL`).
        if !url.is_file_url() {
            return Err(MediaError::Invalid(
                "Media decoding requires a local file".to_string(),
            ));
        }
        let mut decoder =
            MediaDecoder::open(MediaSource::file(url.path()), DecoderOptions::video_only())
                .map_err(media_error)?;
        // `MediaTime::from_seconds` enforces the finite/nonnegative seek
        // precondition that Swift's `FileDecoder.seek(to:)` guarded.
        let position = MediaTime::from_seconds(at).map_err(media_error)?;
        decoder.seek(position).map_err(media_error)?;
        decoder.next_video().map_err(media_error)
    }

    /// `Task.checkCancellation()` → check the `AtomicBool` token.
    fn check_cancellation(&self) -> Result<(), MediaError> {
        self.cancelled.check().map_err(media_error)
    }
}

impl Default for MediaPlayer {
    fn default() -> Self {
        Self::new()
    }
}

/// Swift's `VideoFrame.time: Double` is `cove_media`'s `pts:
/// Option<MediaTime>` (integer nanoseconds). A frame without a timestamp is
/// treated as time zero, matching the decoder's default `time` value.
fn frame_time(frame: &VideoFrame) -> f64 {
    frame.pts.map_or(0.0, MediaTime::seconds)
}

/// `MediaError.decoding` is the Diffuse domain for a source that could not be
/// opened, probed, seeked or decoded; `cove-media` reports all of those as
/// its own `MediaError`, whose message is preserved verbatim.
fn media_error(error: cove_media::MediaError) -> MediaError {
    MediaError::Decoding(error.message)
}

/// `private final class PlaybackAudioSink` — the one SDL3-specific part of
/// playback. Swift kept `private import CSDL3`; the Rust equivalent keeps the
/// declarations in this private module so no other file can name an SDL symbol.
/// The symbols come from the SDL3 static library linked by `cove-shell`'s
/// build script (see `.migration/cove-gaps.md` G7: no public `cove_shell`
/// audio-device surface exists yet).
mod sdl {
    use std::ffi::{c_int, c_void};

    /// `SDL_AudioSpec` (`format: SDL_AudioFormat`, `channels`, `freq`). A C
    /// enum is `int`-sized; using `u32` gives the same field offsets and size
    /// whether the vendored SDL3 declares `SDL_AudioFormat` as 16 or 32 bits.
    #[repr(C)]
    #[derive(Clone, Copy, Default)]
    pub struct SDL_AudioSpec {
        pub format: u32,
        pub channels: c_int,
        pub freq: c_int,
    }

    /// Opaque `SdlAudioStream *`.
    pub enum SdlAudioStream {}

    /// `COVE_SDL_INIT_AUDIO` = `SDL_INIT_AUDIO`.
    pub const SDL_INIT_AUDIO: u32 = 0x0000_0010;
    /// `COVE_SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK`.
    pub const SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK: u32 = 0xFFFF_FFFF;
    /// `SDL_AUDIO_F32` is byte-order dependent (`SDL_AUDIO_F32LE`/`BE`).
    #[cfg(target_endian = "little")]
    pub const SDL_AUDIO_F32: u32 = 0x8120;
    #[cfg(target_endian = "big")]
    pub const SDL_AUDIO_F32: u32 = 0x9120;

    // SAFETY: every declaration below is a direct SDL3 C API (SDL_init.h,
    // SDL_audio.h); pointers are validated by the caller before use and the
    // SDL3 library is linked into the binary by `cove-shell`.
    unsafe extern "C" {
        pub fn SDL_InitSubSystem(flags: u32) -> bool;
        pub fn SDL_QuitSubSystem(flags: u32);
        pub fn SDL_OpenAudioDeviceStream(
            devid: u32,
            spec: *const SDL_AudioSpec,
            callback: Option<unsafe extern "C" fn()>,
            userdata: *mut c_void,
        ) -> *mut SdlAudioStream;
        pub fn SDL_GetAudioStreamDevice(stream: *mut SdlAudioStream) -> u32;
        pub fn SDL_GetAudioDeviceFormat(
            devid: u32,
            spec: *mut SDL_AudioSpec,
            sample_frames: *mut c_int,
        ) -> bool;
        pub fn SDL_GetAudioStreamQueued(stream: *mut SdlAudioStream) -> c_int;
        pub fn SDL_GetAudioStreamAvailable(stream: *mut SdlAudioStream) -> c_int;
        pub fn SDL_PutAudioStreamData(
            stream: *mut SdlAudioStream,
            buf: *const c_void,
            len: c_int,
        ) -> bool;
        pub fn SDL_FlushAudioStream(stream: *mut SdlAudioStream) -> bool;
        pub fn SDL_ResumeAudioStreamDevice(stream: *mut SdlAudioStream) -> bool;
        pub fn SDL_DestroyAudioStream(stream: *mut SdlAudioStream);
    }
}

/// `private final class PlaybackAudioSink`.
struct PlaybackAudioSink {
    stream: *mut sdl::SdlAudioStream,
    output_bytes_per_second: f64,
}

impl PlaybackAudioSink {
    /// `init() throws`.
    fn new() -> Result<Self, MediaError> {
        // SAFETY: `SDL_INIT_AUDIO` is a valid subsystem flag; the returned
        // boolean is checked before any other SDL call.
        let initialized = unsafe { sdl::SDL_InitSubSystem(sdl::SDL_INIT_AUDIO) };
        if !initialized {
            return Err(MediaError::Decoding(
                "Audio device initialization failed".to_string(),
            ));
        }
        let spec = sdl::SDL_AudioSpec {
            format: sdl::SDL_AUDIO_F32,
            channels: 2,
            freq: 48000,
        };
        // SAFETY: `spec` is a fully initialized SDL_AudioSpec; a null callback
        // and userdata open a stream the caller feeds with SDL_PutAudioStreamData.
        let stream = unsafe {
            sdl::SDL_OpenAudioDeviceStream(
                sdl::SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK,
                &spec,
                None,
                std::ptr::null_mut(),
            )
        };
        if stream.is_null() {
            // SAFETY: the audio subsystem was initialized above and no stream
            // was opened, so quitting here balances that initialization.
            unsafe { sdl::SDL_QuitSubSystem(sdl::SDL_INIT_AUDIO) };
            return Err(MediaError::Decoding(
                "Audio output device is unavailable".to_string(),
            ));
        }
        let mut output = sdl::SDL_AudioSpec::default();
        // SAFETY: `output` is a writable SDL_AudioSpec and the sample-frame
        // out-parameter may be null. Swift ignores the boolean result.
        let _ = unsafe {
            sdl::SDL_GetAudioDeviceFormat(
                sdl::SDL_GetAudioStreamDevice(stream),
                &mut output,
                std::ptr::null_mut(),
            )
        };
        // `Double(max(1, output.freq)) * Double(max(1, output.channels)) *
        //  Double(max(1, Int(output.format.rawValue & 0xFF) / 8))`.
        let bytes_per_sample = ((output.format & 0xFF) / 8).max(1);
        let output_bytes_per_second = (output.freq.max(1) as f64)
            * (output.channels.max(1) as f64)
            * (bytes_per_sample as f64);
        Ok(PlaybackAudioSink {
            stream,
            output_bytes_per_second,
        })
    }

    /// `var queuedSeconds: Double`.
    fn queued_seconds(&self) -> f64 {
        // SAFETY: `stream` is the live stream opened in `new`, owned by this
        // sink until `Drop`; both calls only query its state.
        let (queued, available) = unsafe {
            (
                sdl::SDL_GetAudioStreamQueued(self.stream),
                sdl::SDL_GetAudioStreamAvailable(self.stream),
            )
        };
        // `Double(max(0, queued)) / (48000 * 8) +
        //  Double(max(0, available)) / outputBytesPerSecond`.
        (queued.max(0) as f64) / (48000.0 * 8.0)
            + (available.max(0) as f64) / self.output_bytes_per_second
    }

    /// `func write(_ samples: Data) throws`.
    fn write(&self, samples: &[u8]) -> Result<(), MediaError> {
        // SAFETY: `samples` is a valid byte slice for the duration of the call;
        // SDL copies exactly `len` bytes from its base address.
        let accepted = unsafe {
            sdl::SDL_PutAudioStreamData(
                self.stream,
                samples.as_ptr().cast::<c_void>(),
                samples.len() as c_int,
            )
        };
        if !accepted {
            return Err(MediaError::Decoding(
                "Audio stream rejected decoded samples".to_string(),
            ));
        }
        Ok(())
    }

    /// `func flush()` — Swift ignores the result.
    fn flush(&self) {
        // SAFETY: `stream` is the live stream opened in `new`.
        let _ = unsafe { sdl::SDL_FlushAudioStream(self.stream) };
    }

    /// `func resume() throws`.
    fn resume(&self) -> Result<(), MediaError> {
        // SAFETY: `stream` was opened in `new` in a paused state.
        let resumed = unsafe { sdl::SDL_ResumeAudioStreamDevice(self.stream) };
        if !resumed {
            return Err(MediaError::Decoding(
                "Audio device failed to resume".to_string(),
            ));
        }
        Ok(())
    }
}

impl Drop for PlaybackAudioSink {
    /// `deinit { SDL_DestroyAudioStream(stream); SDL_QuitSubSystem(...) }`.
    fn drop(&mut self) {
        // SAFETY: `stream` was opened in `new` and is destroyed exactly once
        // here; the audio subsystem initialized there is quit once here.
        unsafe {
            sdl::SDL_DestroyAudioStream(self.stream);
            sdl::SDL_QuitSubSystem(sdl::SDL_INIT_AUDIO);
        }
    }
}
