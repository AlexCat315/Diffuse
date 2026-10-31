//! `AudioVoiceID` and the platform-specific sound-output sink behind
//! `AudioEngine`.

use std::path::Path;

/// Opaque handle to a single playing voice owned by an [`AudioBackend`].
///
/// The high bits encode the backend's voice slot and the low bits a generation
/// counter, so a handle held after its slot was recycled is rejected rather than
/// silently controlling whatever now occupies the slot.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct AudioVoiceID {
    pub raw: u64,
}

impl AudioVoiceID {
    #[inline]
    pub const fn new(raw: u64) -> Self {
        AudioVoiceID { raw }
    }
}

/// The platform-specific sound-output sink behind `AudioEngine`.
///
/// `AudioEngine` owns every piece of gameplay policy — entity tracking, spatial
/// attenuation, play-on-awake, clip search paths. A backend only has to load
/// clips and turn playback requests into audible sound. Splitting the two keeps
/// the engine's audio *logic* identical on every platform; only the final output
/// path is swapped. It also makes the logic unit-testable against a recording
/// mock.
pub trait AudioBackend: Send + Sync {
    /// Load and cache the clip at `url` under `name`. Returns `true` once the clip
    /// is available for playback (including when it was already loaded).
    fn load_clip(&self, name: &str, url: &Path) -> bool;

    /// Whether a clip with `name` is loaded and ready.
    fn is_clip_loaded(&self, name: &str) -> bool;

    /// Release every decoded clip cached by the backend. Implementations must stop
    /// voices that reference clip storage before freeing that storage. Called when
    /// the active project's audio search roots change.
    fn unload_all_clips(&self) {
        self.stop_all();
    }

    /// Start a tracked voice for an already-loaded clip. Returns `None` if the clip
    /// is missing or no voice could be allocated.
    fn play(&self, clip: &str, volume: f32, pitch: f32, loop_: bool) -> Option<AudioVoiceID>;

    /// Stop and release a voice. A stale or already-stopped handle is ignored.
    fn stop(&self, voice: AudioVoiceID);

    /// Whether the voice is still producing sound. A stale handle returns `false`.
    fn is_active(&self, voice: AudioVoiceID) -> bool;

    /// Update a live voice's gain.
    fn set_volume(&self, voice: AudioVoiceID, volume: f32);

    /// Update the stereo pan of a live voice. `-1` is fully left, `0` centred and
    /// `1` fully right. Backends without a pan-capable mixer may ignore it.
    fn set_pan(&self, voice: AudioVoiceID, pan: f32) {
        let _ = (voice, pan);
    }

    /// Update playback rate for a live voice. Used by scene-space Doppler.
    fn set_pitch(&self, voice: AudioVoiceID, pitch: f32) {
        let _ = (voice, pitch);
    }

    /// Dedicated single background-music channel (independent of the voice pool).
    fn play_bgm(&self, clip: &str, volume: f32, loop_: bool);

    fn stop_bgm(&self);

    /// Stop every voice and the background-music channel (play-mode reset).
    fn stop_all(&self);

    /// Advance backend bookkeeping once per frame: refeed looping voices and
    /// reclaim voices that have finished.
    fn pump(&self) {}
}
