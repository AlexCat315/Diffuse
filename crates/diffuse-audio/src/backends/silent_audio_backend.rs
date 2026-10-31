//! `SilentAudioBackend` — an audio sink that produces no sound.

use std::collections::BTreeSet;
use std::path::Path;
use std::sync::Mutex;

use crate::audio_backend::{AudioBackend, AudioVoiceID};

/// Audio sink that produces no sound, used on platforms without a real backend.
///
/// It still reports clips as loadable (so the engine's policy code runs the same
/// path everywhere) and hands out valid, distinct voice handles that immediately
/// report inactive — gameplay logic behaves identically, just inaudibly.
pub struct SilentAudioBackend {
    state: Mutex<SilentState>,
}

struct SilentState {
    loaded: BTreeSet<String>,
    next_voice: u64,
}

impl SilentAudioBackend {
    pub fn new() -> Self {
        SilentAudioBackend {
            state: Mutex::new(SilentState {
                loaded: BTreeSet::new(),
                next_voice: 1,
            }),
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, SilentState> {
        self.state.lock().unwrap_or_else(|error| error.into_inner())
    }
}

impl Default for SilentAudioBackend {
    fn default() -> Self {
        Self::new()
    }
}

impl AudioBackend for SilentAudioBackend {
    fn load_clip(&self, name: &str, _url: &Path) -> bool {
        self.lock().loaded.insert(name.to_string());
        true
    }

    fn is_clip_loaded(&self, name: &str) -> bool {
        self.lock().loaded.contains(name)
    }

    fn unload_all_clips(&self) {
        self.stop_all();
        self.lock().loaded.clear();
    }

    fn play(&self, clip: &str, _volume: f32, _pitch: f32, _loop_: bool) -> Option<AudioVoiceID> {
        let mut state = self.lock();
        if !state.loaded.contains(clip) {
            return None;
        }
        let raw = state.next_voice;
        // `&+=` matches Swift's `&+=`: wraps instead of trapping.
        state.next_voice = state.next_voice.wrapping_add(1);
        Some(AudioVoiceID::new(raw))
    }

    fn stop(&self, _voice: AudioVoiceID) {}

    fn is_active(&self, _voice: AudioVoiceID) -> bool {
        false
    }

    fn set_volume(&self, _voice: AudioVoiceID, _volume: f32) {}

    fn play_bgm(&self, _clip: &str, _volume: f32, _loop_: bool) {}

    fn stop_bgm(&self) {}

    fn stop_all(&self) {}
}
