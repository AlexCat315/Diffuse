//! Resident stereo clips and SDL3 playback streams.

use std::collections::HashMap;
use std::path::Path;
use std::sync::{Mutex, MutexGuard};

use cove_logging::{Level, LogEvent, LogSystem};
use cove_shell::{AudioStreamSpec, Sdl3AudioDevice, Sdl3AudioSubsystem};
use diffuse_media::{AudioFile, MediaUrl};

use crate::audio_backend::{AudioBackend, AudioVoiceID};

const CHUNK_FRAMES: usize = 2048;

struct Voice {
    stream: Sdl3AudioDevice,
    clip: String,
    loop_: bool,
    offset: usize,
    pan: f32,
    ended: bool,
}

struct State {
    clips: HashMap<String, Vec<f32>>,
    voices: HashMap<u64, Voice>,
    next_id: u64,
    bgm: Option<Voice>,
}

/// Serializes access to the resident clips and their associated SDL streams.
pub struct SDL3AudioBackend {
    state: Mutex<State>,
    _audio: Sdl3AudioSubsystem,
}

fn log_error(message: impl Into<String>) {
    LogSystem::logger("com.cove.audio").log(&LogEvent::new(Level::Error, message));
}

fn decode_clip(path: &Path) -> Result<Vec<f32>, String> {
    AudioFile::decode(&MediaUrl::from_file_path(path.to_string_lossy()))
        .map(|buffer| buffer.samples)
        .map_err(|error| error.to_string())
}

fn volume(value: f32) -> f32 {
    if value.is_finite() {
        value.max(0.0)
    } else {
        0.0
    }
}

fn pitch(value: f32) -> f32 {
    if value.is_finite() {
        value.clamp(0.01, 100.0)
    } else {
        1.0
    }
}

fn queued(stream: &Sdl3AudioDevice) -> usize {
    stream.queued_bytes() + stream.available_bytes()
}

fn feed(voice: &mut Voice, clips: &HashMap<String, Vec<f32>>) -> bool {
    let Some(samples) = clips.get(&voice.clip) else {
        return false;
    };
    let frames = samples.len() / 2;
    while !voice.ended && queued(&voice.stream) < CHUNK_FRAMES * 2 * size_of::<f32>() {
        let count = CHUNK_FRAMES.min(frames - voice.offset);
        let mut chunk = samples[voice.offset * 2..(voice.offset + count) * 2].to_vec();
        let left = if voice.pan > 0.0 {
            1.0 - voice.pan
        } else {
            1.0
        };
        let right = if voice.pan < 0.0 {
            1.0 + voice.pan
        } else {
            1.0
        };
        for frame in chunk.as_chunks_mut::<2>().0 {
            frame[0] *= left;
            frame[1] *= right;
        }
        if let Err(error) = voice.stream.put(&chunk) {
            log_error(format!("Audio stream write failed: {error}"));
            return false;
        }
        voice.offset += count;
        if voice.offset == frames {
            if voice.loop_ {
                voice.offset = 0;
            } else {
                voice.ended = true;
                if let Err(error) = voice.stream.flush() {
                    log_error(format!("Audio stream flush failed: {error}"));
                }
            }
        }
    }
    true
}

impl SDL3AudioBackend {
    pub fn new() -> Option<Self> {
        let audio = match Sdl3AudioSubsystem::new() {
            Ok(audio) => audio,
            Err(error) => {
                log_error(format!("Audio initialization failed: {error}"));
                return None;
            }
        };
        Some(Self {
            state: Mutex::new(State {
                clips: HashMap::new(),
                voices: HashMap::new(),
                next_id: 1,
                bgm: None,
            }),
            _audio: audio,
        })
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|error| error.into_inner())
    }

    fn make_voice(state: &State, clip: &str, gain: f32, rate: f32, loop_: bool) -> Option<Voice> {
        if !state.clips.contains_key(clip) {
            return None;
        }
        let mut stream = Sdl3AudioDevice::open_default(AudioStreamSpec::stereo(48_000))
            .map_err(|error| log_error(format!("Audio stream open failed: {error}")))
            .ok()?;
        if let Err(error) = stream.set_gain(volume(gain)) {
            log_error(format!("Audio gain failed: {error}"));
        }
        if let Err(error) = stream.set_frequency_ratio(pitch(rate)) {
            log_error(format!("Audio rate failed: {error}"));
        }
        let mut voice = Voice {
            stream,
            clip: clip.into(),
            loop_,
            offset: 0,
            pan: 0.0,
            ended: false,
        };
        if !feed(&mut voice, &state.clips) {
            return None;
        }
        if let Err(error) = voice.stream.resume() {
            log_error(format!("Audio stream resume failed: {error}"));
            return None;
        }
        Some(voice)
    }
}

impl AudioBackend for SDL3AudioBackend {
    fn load_clip(&self, name: &str, url: &Path) -> bool {
        let mut state = self.lock();
        if state.clips.contains_key(name) {
            return true;
        }
        match decode_clip(url) {
            Ok(samples) => {
                state.clips.insert(name.into(), samples);
                true
            }
            Err(error) => {
                log_error(format!(
                    "Audio decoding failed ({}): {error}",
                    url.display()
                ));
                false
            }
        }
    }
    fn is_clip_loaded(&self, name: &str) -> bool {
        self.lock().clips.contains_key(name)
    }
    fn unload_all_clips(&self) {
        let mut state = self.lock();
        state.voices.clear();
        state.bgm = None;
        state.clips.clear();
    }
    fn play(&self, clip: &str, gain: f32, rate: f32, loop_: bool) -> Option<AudioVoiceID> {
        let mut state = self.lock();
        let voice = Self::make_voice(&state, clip, gain, rate, loop_)?;
        let id = state.next_id;
        state.next_id = state.next_id.wrapping_add(1);
        state.voices.insert(id, voice);
        Some(AudioVoiceID::new(id))
    }
    fn stop(&self, voice: AudioVoiceID) {
        self.lock().voices.remove(&voice.raw);
    }
    fn is_active(&self, voice: AudioVoiceID) -> bool {
        self.lock()
            .voices
            .get(&voice.raw)
            .is_some_and(|value| !value.ended || queued(&value.stream) > 0)
    }
    fn set_volume(&self, voice: AudioVoiceID, gain: f32) {
        if let Some(value) = self.lock().voices.get_mut(&voice.raw)
            && let Err(error) = value.stream.set_gain(volume(gain))
        {
            log_error(format!("Audio gain failed: {error}"));
        }
    }
    fn set_pitch(&self, voice: AudioVoiceID, rate: f32) {
        if let Some(value) = self.lock().voices.get_mut(&voice.raw)
            && let Err(error) = value.stream.set_frequency_ratio(pitch(rate))
        {
            log_error(format!("Audio rate failed: {error}"));
        }
    }
    fn set_pan(&self, voice: AudioVoiceID, pan: f32) {
        if let Some(value) = self.lock().voices.get_mut(&voice.raw) {
            value.pan = if pan.is_finite() {
                pan.clamp(-1.0, 1.0)
            } else {
                0.0
            };
        }
    }
    fn pump(&self) {
        let mut state = self.lock();
        let State {
            clips, voices, bgm, ..
        } = &mut *state;
        voices.retain(|_, voice| feed(voice, clips) && (!voice.ended || queued(&voice.stream) > 0));
        if bgm
            .as_mut()
            .is_some_and(|voice| !feed(voice, clips) || (voice.ended && queued(&voice.stream) == 0))
        {
            *bgm = None;
        }
    }
    fn play_bgm(&self, clip: &str, gain: f32, loop_: bool) {
        let mut state = self.lock();
        state.bgm = None;
        state.bgm = Self::make_voice(&state, clip, gain, 1.0, loop_);
    }
    fn stop_bgm(&self) {
        self.lock().bgm = None;
    }
    fn stop_all(&self) {
        let mut state = self.lock();
        state.voices.clear();
        state.bgm = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> std::path::PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../diffuse-media/fixtures/tone.wav")
    }

    #[test]
    fn decodes_resident_stereo_and_rejects_missing_files() {
        let samples = decode_clip(&fixture()).expect("decode fixture");
        assert!(!samples.is_empty());
        assert_eq!(samples.len() % 2, 0);
        assert!(decode_clip(&fixture().with_file_name("missing.wav")).is_err());
    }

    #[test]
    fn voices_and_music_use_the_live_device() {
        let Some(backend) = SDL3AudioBackend::new() else {
            return;
        };
        if Sdl3AudioDevice::open_default(AudioStreamSpec::stereo(48_000)).is_err() {
            return;
        }
        assert!(backend.load_clip("tone", &fixture()));
        assert!(backend.load_clip("tone", Path::new("missing.wav")));
        assert!(backend.is_clip_loaded("tone"));
        assert!(backend.play("missing", 1.0, 1.0, false).is_none());
        let voice = backend.play("tone", 1.0, 1.0, true).expect("play");
        assert!(backend.is_active(voice));
        backend.set_volume(voice, 0.5);
        backend.set_pitch(voice, 1.25);
        backend.set_pan(voice, -1.0);
        backend.pump();
        assert!(backend.is_active(voice));
        backend.play_bgm("tone", 0.5, true);
        assert!(backend.lock().bgm.is_some());
        backend.stop(voice);
        assert!(!backend.is_active(voice));
        backend.unload_all_clips();
        assert!(!backend.is_clip_loaded("tone"));
        assert!(backend.lock().bgm.is_none());

        let engine = crate::audio_engine::AudioEngine::with_default_backend();
        assert!(engine.backend().load_clip("tone", &fixture()));
        let default_voice = engine
            .backend()
            .play("tone", 1.0, 1.0, true)
            .expect("default backend plays");
        assert!(engine.backend().is_active(default_voice));
        engine.backend().stop_all();
    }
}
