//! `AudioEngineTests` — Swift suite `AudioEngine`.
//!
//! Swift's suite drove a real `SceneRuntime` with a recording `MockAudioBackend`.
//! `SceneRuntime` is still being translated, so this suite drives an equivalent
//! test scene through the same [`AudioScene`] trait the engine uses. Every
//! assertion from the Swift suite is preserved.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use crate::audio_backend::{AudioBackend, AudioVoiceID};
use crate::audio_engine::{AudioEngine, AudioScene, ResolvedListener};
use diffuse_math::simd::simd_compat::Float3;
use diffuse_scene::entity_id::EntityID;
use diffuse_scene::media::audio::{AudioListener, AudioSource};

// MARK: - Recording mock backend

#[derive(Clone, Debug, PartialEq)]
struct PlayCall {
    clip: String,
    volume: f32,
    pitch: f32,
    loop_: bool,
}

#[derive(Default)]
struct MockState {
    loaded: BTreeSet<String>,
    loaded_urls: BTreeMap<String, PathBuf>,
    unload_all_clips_count: usize,
    plays: BTreeMap<AudioVoiceID, PlayCall>,
    play_order: Vec<AudioVoiceID>,
    pans: BTreeMap<AudioVoiceID, f32>,
    stopped: Vec<AudioVoiceID>,
    bgm_plays: Vec<String>,
    stop_all_count: usize,
    pump_count: usize,
    next_raw: u64,
    active: BTreeSet<AudioVoiceID>,
}

struct MockAudioBackend {
    state: Mutex<MockState>,
}

impl MockAudioBackend {
    fn new() -> Self {
        MockAudioBackend {
            state: Mutex::new(MockState {
                next_raw: 1,
                ..Default::default()
            }),
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, MockState> {
        self.state.lock().unwrap_or_else(|error| error.into_inner())
    }

    fn play_count(&self) -> usize {
        self.lock().plays.len()
    }

    fn pump_count(&self) -> usize {
        self.lock().pump_count
    }

    fn stop_all_count(&self) -> usize {
        self.lock().stop_all_count
    }

    fn unload_all_clips_count(&self) -> usize {
        self.lock().unload_all_clips_count
    }

    fn play_order_len(&self) -> usize {
        self.lock().play_order.len()
    }

    fn last_voice(&self) -> Option<AudioVoiceID> {
        self.lock().play_order.last().copied()
    }

    fn last_play(&self) -> Option<PlayCall> {
        let state = self.lock();
        state
            .play_order
            .last()
            .and_then(|voice| state.plays.get(voice).cloned())
    }

    fn loaded_url_of(&self, name: &str) -> Option<PathBuf> {
        self.lock().loaded_urls.get(name).cloned()
    }

    /// Simulates a voice that finished on its own.
    fn finish(&self, voice: AudioVoiceID) {
        self.lock().active.remove(&voice);
    }
}

impl AudioBackend for MockAudioBackend {
    fn load_clip(&self, name: &str, url: &Path) -> bool {
        let mut state = self.lock();
        if state.loaded.contains(name) {
            return true;
        }
        state.loaded.insert(name.to_string());
        state
            .loaded_urls
            .insert(name.to_string(), url.to_path_buf());
        true
    }

    fn is_clip_loaded(&self, name: &str) -> bool {
        self.lock().loaded.contains(name)
    }

    fn unload_all_clips(&self) {
        self.stop_all();
        let mut state = self.lock();
        state.unload_all_clips_count += 1;
        state.loaded.clear();
        state.loaded_urls.clear();
    }

    fn play(&self, clip: &str, volume: f32, pitch: f32, loop_: bool) -> Option<AudioVoiceID> {
        let mut state = self.lock();
        let voice = AudioVoiceID::new(state.next_raw);
        state.next_raw = state.next_raw.wrapping_add(1);
        state.plays.insert(
            voice,
            PlayCall {
                clip: clip.to_string(),
                volume,
                pitch,
                loop_,
            },
        );
        state.play_order.push(voice);
        state.active.insert(voice);
        Some(voice)
    }

    fn stop(&self, voice: AudioVoiceID) {
        let mut state = self.lock();
        state.stopped.push(voice);
        state.active.remove(&voice);
    }

    fn is_active(&self, voice: AudioVoiceID) -> bool {
        self.lock().active.contains(&voice)
    }

    fn set_volume(&self, voice: AudioVoiceID, volume: f32) {
        if let Some(call) = self.lock().plays.get_mut(&voice) {
            call.volume = volume;
        }
    }

    fn set_pan(&self, voice: AudioVoiceID, pan: f32) {
        self.lock().pans.insert(voice, pan);
    }

    fn set_pitch(&self, voice: AudioVoiceID, pitch: f32) {
        if let Some(call) = self.lock().plays.get_mut(&voice) {
            call.pitch = pitch;
        }
    }

    fn play_bgm(&self, clip: &str, _volume: f32, _loop_: bool) {
        self.lock().bgm_plays.push(clip.to_string());
    }

    fn stop_bgm(&self) {}

    fn stop_all(&self) {
        let mut state = self.lock();
        state.stop_all_count += 1;
        state.active.clear();
    }

    fn pump(&self) {
        self.lock().pump_count += 1;
    }
}

// MARK: - Test scene

#[derive(Default)]
struct TestScene {
    entities: Vec<EntityID>,
    sources: BTreeMap<EntityID, AudioSource>,
    listeners: BTreeMap<EntityID, AudioListener>,
    translations: BTreeMap<EntityID, Float3>,
    velocities: BTreeMap<EntityID, Float3>,
}

impl TestScene {
    fn new() -> Self {
        TestScene::default()
    }

    fn create_entity(&mut self) -> EntityID {
        let entity = EntityID::new(self.entities.len() as u32, 0);
        self.entities.push(entity);
        entity
    }

    fn set_source(&mut self, entity: EntityID, source: AudioSource) {
        if source.clip_name.is_empty() {
            self.sources.remove(&entity);
        } else {
            self.sources.insert(entity, source);
        }
    }

    fn set_listener(&mut self, entity: EntityID, listener: AudioListener) {
        self.listeners.insert(entity, listener);
    }

    fn set_translation(&mut self, entity: EntityID, translation: Float3) {
        self.translations.insert(entity, translation);
    }

    fn set_velocity(&mut self, entity: EntityID, velocity: Float3) {
        self.velocities.insert(entity, velocity);
    }
}

impl AudioScene for TestScene {
    fn entities_with_audio_source(&self) -> Vec<EntityID> {
        self.sources.keys().copied().collect()
    }

    fn entities_with_audio_listener(&self) -> Vec<EntityID> {
        self.listeners.keys().copied().collect()
    }

    fn audio_source(&self, entity: EntityID) -> Option<AudioSource> {
        self.sources.get(&entity).cloned()
    }

    fn audio_listener(&self, entity: EntityID) -> Option<AudioListener> {
        self.listeners.get(&entity).cloned()
    }

    fn world_translation(&self, entity: EntityID) -> Option<Float3> {
        self.translations.get(&entity).copied()
    }

    fn linear_velocity(&self, entity: EntityID) -> Option<Float3> {
        self.velocities.get(&entity).copied()
    }
}

// MARK: - Helpers

/// Creates real (empty) clip files so the engine's on-disk search succeeds; the
/// mock backend then "loads" them without touching a decoder.
fn make_clip_dir(names: &[&str]) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("cove-audio-tests-{}", unique_suffix()));
    std::fs::create_dir_all(&dir).expect("clip dir");
    for name in names {
        std::fs::write(dir.join(format!("{name}.wav")), b"").expect("clip file");
    }
    dir
}

fn unique_suffix() -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or(0);
    format!("{nanos}-{}", NEXT.fetch_add(1, Ordering::Relaxed))
}

fn source(clip: &str) -> AudioSource {
    AudioSource {
        clip_name: clip.to_string(),
        ..AudioSource::default()
    }
}

fn flat_source(clip: &str, volume: f32) -> AudioSource {
    AudioSource {
        clip_name: clip.to_string(),
        volume,
        play_on_awake: true,
        spatial_blend: 0.0,
        ..AudioSource::default()
    }
}

// MARK: - Tests

// "playOnAwake triggers exactly one voice and not again next tick"
#[test]
fn play_on_awake_once() {
    let dir = make_clip_dir(&["beep"]);
    let mock = MockAudioBackend::new();
    let engine = AudioEngine::new(Box::new(mock));
    engine.add_search_url(&dir);

    let mut scene = TestScene::new();
    let entity = scene.create_entity();
    scene.set_source(entity, flat_source("beep", 1.0));

    engine.tick(&scene, Float3::ZERO);
    assert!(engine.backend().is_clip_loaded("beep"));

    engine.tick(&scene, Float3::ZERO);
    // The second tick must not retrigger: exactly one voice exists overall.
    assert!(engine.backend().is_active(AudioVoiceID::new(1)));
}

// "a source that disappears stops its voice"
#[test]
fn stale_voice_stopped() {
    let dir = make_clip_dir(&["beep"]);
    let engine = AudioEngine::new(Box::new(MockAudioBackend::new()));
    engine.add_search_url(&dir);

    let mut scene = TestScene::new();
    let entity = scene.create_entity();
    scene.set_source(entity, flat_source("beep", 1.0));
    engine.tick(&scene, Float3::ZERO);

    // Clearing the clip name removes the entity as an active source.
    scene.set_source(entity, source(""));
    engine.tick(&scene, Float3::ZERO);

    // The voice is gone: nothing is active, and the backend was told to stop it.
    assert!(!engine.backend().is_active(AudioVoiceID::new(1)));
}

// "spatial sources attenuate with listener distance"
#[test]
fn spatial_attenuation() {
    let dir = make_clip_dir(&["beep"]);
    let engine = AudioEngine::new(Box::new(MockAudioBackend::new()));
    engine.add_search_url(&dir);

    let mut scene = TestScene::new();
    let listener = scene.create_entity();
    scene.set_listener(listener, AudioListener::default());
    scene.set_translation(listener, Float3::ZERO);

    let source_entity = scene.create_entity();
    scene.set_source(
        source_entity,
        AudioSource {
            clip_name: "beep".to_string(),
            volume: 1.0,
            play_on_awake: true,
            spatial_blend: 1.0,
            ..AudioSource::default()
        },
    );
    // Half of the 50-unit falloff range.
    scene.set_translation(source_entity, Float3::new(25.0, 0.0, 0.0));

    let mix = crate::audio_engine::spatial_mix(
        &scene.audio_source(source_entity).expect("source"),
        &scene,
        source_entity,
        ResolvedListener {
            position: Float3::ZERO,
            master_volume: 1.0,
            linear_velocity: Float3::ZERO,
        },
    );
    assert!(
        (mix.volume - 0.5).abs() < 0.01,
        "expected ~0.5 at half falloff, got {}",
        mix.volume
    );
}

// "2D sources ignore distance"
#[test]
fn flat_source_not_attenuated() {
    let dir = make_clip_dir(&["beep"]);
    let engine = AudioEngine::new(Box::new(MockAudioBackend::new()));
    engine.add_search_url(&dir);

    let mut scene = TestScene::new();
    let source_entity = scene.create_entity();
    scene.set_source(source_entity, flat_source("beep", 0.8));
    scene.set_translation(source_entity, Float3::new(1000.0, 0.0, 0.0));

    let mix = crate::audio_engine::spatial_mix(
        &scene.audio_source(source_entity).expect("source"),
        &scene,
        source_entity,
        ResolvedListener {
            position: Float3::ZERO,
            master_volume: 1.0,
            linear_velocity: Float3::ZERO,
        },
    );
    assert_eq!(mix.volume, 0.8);
    assert_eq!(mix.pan, 0.0);
}

// "spatial sources pan from listener-relative position and update while moving"
#[test]
fn spatial_panning_updates() {
    let listener = ResolvedListener {
        position: Float3::ZERO,
        master_volume: 1.0,
        linear_velocity: Float3::ZERO,
    };
    let mut scene = TestScene::new();
    let source_entity = scene.create_entity();
    scene.set_source(
        source_entity,
        AudioSource {
            clip_name: "beep".to_string(),
            play_on_awake: true,
            spatial_blend: 1.0,
            ..AudioSource::default()
        },
    );

    scene.set_translation(source_entity, Float3::new(10.0, 0.0, 0.0));
    let right = crate::audio_engine::spatial_mix(
        &scene.audio_source(source_entity).expect("source"),
        &scene,
        source_entity,
        listener,
    );
    assert!((right.pan - 1.0).abs() < 0.001);

    scene.set_translation(source_entity, Float3::new(-10.0, 0.0, 0.0));
    let left = crate::audio_engine::spatial_mix(
        &scene.audio_source(source_entity).expect("source"),
        &scene,
        source_entity,
        listener,
    );
    assert!((left.pan + 1.0).abs() < 0.001);
}

// "spatial sources apply Doppler pitch from rigid body velocity"
#[test]
fn spatial_doppler_pitch_updates() {
    let listener = ResolvedListener {
        position: Float3::ZERO,
        master_volume: 1.0,
        linear_velocity: Float3::ZERO,
    };
    let mut scene = TestScene::new();
    let source_entity = scene.create_entity();
    scene.set_source(
        source_entity,
        AudioSource {
            clip_name: "beep".to_string(),
            pitch: 1.0,
            play_on_awake: true,
            spatial_blend: 1.0,
            ..AudioSource::default()
        },
    );
    scene.set_translation(source_entity, Float3::new(10.0, 0.0, 0.0));

    // Moving toward the listener raises pitch.
    scene.set_velocity(source_entity, Float3::new(-100.0, 0.0, 0.0));
    let approaching = crate::audio_engine::spatial_mix(
        &scene.audio_source(source_entity).expect("source"),
        &scene,
        source_entity,
        listener,
    );
    assert!(
        approaching.pitch > 1.3,
        "expected raised pitch, got {}",
        approaching.pitch
    );

    // Moving away lowers it.
    scene.set_velocity(source_entity, Float3::new(100.0, 0.0, 0.0));
    let receding = crate::audio_engine::spatial_mix(
        &scene.audio_source(source_entity).expect("source"),
        &scene,
        source_entity,
        listener,
    );
    assert!(
        receding.pitch < 0.8,
        "expected lowered pitch, got {}",
        receding.pitch
    );
}

// "listener master volume scales scene playback"
#[test]
fn listener_master_volume_scales_playback() {
    let listener = ResolvedListener {
        position: Float3::ZERO,
        master_volume: 0.25,
        linear_velocity: Float3::ZERO,
    };
    let mut scene = TestScene::new();
    let source_entity = scene.create_entity();
    scene.set_source(source_entity, flat_source("beep", 0.8));

    let mix = crate::audio_engine::spatial_mix(
        &scene.audio_source(source_entity).expect("source"),
        &scene,
        source_entity,
        listener,
    );
    assert!((mix.volume - 0.2).abs() < 0.001);
}

// "resetPlaybackState stops everything and re-arms play-on-awake"
#[test]
fn reset_re_arms() {
    let dir = make_clip_dir(&["beep"]);
    let mock = std::sync::Arc::new(MockAudioBackend::new());
    struct Shared(std::sync::Arc<MockAudioBackend>);
    impl AudioBackend for Shared {
        fn load_clip(&self, name: &str, url: &Path) -> bool {
            self.0.load_clip(name, url)
        }
        fn is_clip_loaded(&self, name: &str) -> bool {
            self.0.is_clip_loaded(name)
        }
        fn unload_all_clips(&self) {
            self.0.unload_all_clips()
        }
        fn play(&self, clip: &str, volume: f32, pitch: f32, loop_: bool) -> Option<AudioVoiceID> {
            self.0.play(clip, volume, pitch, loop_)
        }
        fn stop(&self, voice: AudioVoiceID) {
            self.0.stop(voice)
        }
        fn is_active(&self, voice: AudioVoiceID) -> bool {
            self.0.is_active(voice)
        }
        fn set_volume(&self, voice: AudioVoiceID, volume: f32) {
            self.0.set_volume(voice, volume)
        }
        fn set_pan(&self, voice: AudioVoiceID, pan: f32) {
            self.0.set_pan(voice, pan)
        }
        fn set_pitch(&self, voice: AudioVoiceID, pitch: f32) {
            self.0.set_pitch(voice, pitch)
        }
        fn play_bgm(&self, clip: &str, volume: f32, loop_: bool) {
            self.0.play_bgm(clip, volume, loop_)
        }
        fn stop_bgm(&self) {
            self.0.stop_bgm()
        }
        fn stop_all(&self) {
            self.0.stop_all()
        }
        fn pump(&self) {
            self.0.pump()
        }
    }

    let engine = AudioEngine::new(Box::new(Shared(mock.clone())));
    engine.add_search_url(&dir);

    let mut scene = TestScene::new();
    let entity = scene.create_entity();
    scene.set_source(entity, flat_source("beep", 1.0));

    engine.tick(&scene, Float3::ZERO);
    assert_eq!(mock.play_count(), 1);
    assert_eq!(mock.pump_count(), 1);

    engine.reset_playback_state();
    assert_eq!(mock.stop_all_count(), 1);

    engine.tick(&scene, Float3::ZERO);
    assert_eq!(
        mock.play_count(),
        2,
        "after reset the source should awaken again"
    );
}

// "missing clip files never reach the backend"
#[test]
fn missing_clip_not_loaded() {
    let engine = AudioEngine::new(Box::new(MockAudioBackend::new()));
    engine.add_search_url(
        &std::env::temp_dir().join(format!("cove-audio-nonexistent-{}", unique_suffix())),
    );

    assert!(!engine.preload("ghost"));
    let mut scene = TestScene::new();
    let entity = scene.create_entity();
    scene.set_source(
        entity,
        AudioSource {
            clip_name: "ghost".to_string(),
            play_on_awake: true,
            ..AudioSource::default()
        },
    );
    engine.tick(&scene, Float3::ZERO);
    assert!(!engine.backend().is_clip_loaded("ghost"));
}

// "supports aif clips and rejects clip names that escape search roots"
#[test]
fn portable_clip_lookup_stays_within_search_root() {
    let parent = std::env::temp_dir().join(format!("cove-audio-paths-{}", unique_suffix()));
    let clips = parent.join("clips");
    std::fs::create_dir_all(&clips).expect("clips dir");
    std::fs::write(clips.join("theme.AIF"), b"").expect("theme");
    std::fs::write(parent.join("outside.wav"), b"").expect("outside");

    let mock = MockAudioBackend::new();
    let engine = AudioEngine::new(Box::new(mock));
    engine.add_search_url(&clips);

    assert!(engine.preload("theme"));
    assert!(!engine.preload("../outside"));

    let _ = std::fs::remove_dir_all(&parent);
}

// "play-on-awake retries when a missing clip becomes available"
#[test]
fn play_on_awake_retries_after_missing_clip_appears() {
    let dir = make_clip_dir(&[]);
    let engine = AudioEngine::new(Box::new(MockAudioBackend::new()));
    engine.add_search_url(&dir);

    let mut scene = TestScene::new();
    let entity = scene.create_entity();
    scene.set_source(entity, flat_source("late", 1.0));

    engine.tick(&scene, Float3::ZERO);
    assert!(!engine.backend().is_clip_loaded("late"));

    std::fs::write(dir.join("late.wav"), b"").expect("late clip");
    engine.tick(&scene, Float3::ZERO);
    assert!(engine.backend().is_clip_loaded("late"));

    let _ = std::fs::remove_dir_all(&dir);
}

// "changing an audio source clip replaces its live voice"
#[test]
fn changing_clip_replaces_live_voice() {
    let dir = make_clip_dir(&["first", "second"]);
    let engine = AudioEngine::new(Box::new(MockAudioBackend::new()));
    engine.add_search_url(&dir);

    let mut scene = TestScene::new();
    let entity = scene.create_entity();
    scene.set_source(entity, flat_source("first", 1.0));
    engine.tick(&scene, Float3::ZERO);
    assert!(engine.backend().is_clip_loaded("first"));

    scene.set_source(entity, flat_source("second", 1.0));
    engine.tick(&scene, Float3::ZERO);

    assert!(engine.backend().is_clip_loaded("second"));
    // The first voice was stopped when the clip changed.
    assert!(!engine.backend().is_active(AudioVoiceID::new(1)));
    assert!(engine.backend().is_active(AudioVoiceID::new(2)));

    let _ = std::fs::remove_dir_all(&dir);
}

// "removing a finished source re-arms play-on-awake"
#[test]
fn removing_finished_source_rearms_play_on_awake() {
    let dir = make_clip_dir(&["beep"]);
    let mock = std::sync::Arc::new(MockAudioBackend::new());
    struct Shared(std::sync::Arc<MockAudioBackend>);
    impl AudioBackend for Shared {
        fn load_clip(&self, name: &str, url: &Path) -> bool {
            self.0.load_clip(name, url)
        }
        fn is_clip_loaded(&self, name: &str) -> bool {
            self.0.is_clip_loaded(name)
        }
        fn unload_all_clips(&self) {
            self.0.unload_all_clips()
        }
        fn play(&self, clip: &str, volume: f32, pitch: f32, loop_: bool) -> Option<AudioVoiceID> {
            self.0.play(clip, volume, pitch, loop_)
        }
        fn stop(&self, voice: AudioVoiceID) {
            self.0.stop(voice)
        }
        fn is_active(&self, voice: AudioVoiceID) -> bool {
            self.0.is_active(voice)
        }
        fn set_volume(&self, voice: AudioVoiceID, volume: f32) {
            self.0.set_volume(voice, volume)
        }
        fn set_pan(&self, voice: AudioVoiceID, pan: f32) {
            self.0.set_pan(voice, pan)
        }
        fn set_pitch(&self, voice: AudioVoiceID, pitch: f32) {
            self.0.set_pitch(voice, pitch)
        }
        fn play_bgm(&self, clip: &str, volume: f32, loop_: bool) {
            self.0.play_bgm(clip, volume, loop_)
        }
        fn stop_bgm(&self) {
            self.0.stop_bgm()
        }
        fn stop_all(&self) {
            self.0.stop_all()
        }
        fn pump(&self) {
            self.0.pump()
        }
    }

    let engine = AudioEngine::new(Box::new(Shared(mock.clone())));
    engine.add_search_url(&dir);

    let mut scene = TestScene::new();
    let entity = scene.create_entity();
    let beep = flat_source("beep", 1.0);
    scene.set_source(entity, beep.clone());
    engine.tick(&scene, Float3::ZERO);

    let first_voice = mock.last_voice().expect("first voice");
    mock.finish(first_voice);
    engine.tick(&scene, Float3::ZERO);

    scene.set_source(entity, source(""));
    engine.tick(&scene, Float3::ZERO);
    scene.set_source(entity, beep);
    engine.tick(&scene, Float3::ZERO);

    assert_eq!(mock.play_order_len(), 2);
    assert_eq!(
        mock.last_play().map(|call| call.clip),
        Some("beep".to_string())
    );

    let _ = std::fs::remove_dir_all(&dir);
}

// "changing project search roots reloads same-named clips"
#[test]
fn changing_search_roots_reloads_same_named_clips() {
    let first_project = make_clip_dir(&["shared"]);
    let second_project = make_clip_dir(&["shared"]);
    let mock = std::sync::Arc::new(MockAudioBackend::new());
    struct Shared(std::sync::Arc<MockAudioBackend>);
    impl AudioBackend for Shared {
        fn load_clip(&self, name: &str, url: &Path) -> bool {
            self.0.load_clip(name, url)
        }
        fn is_clip_loaded(&self, name: &str) -> bool {
            self.0.is_clip_loaded(name)
        }
        fn unload_all_clips(&self) {
            self.0.unload_all_clips()
        }
        fn play(&self, clip: &str, volume: f32, pitch: f32, loop_: bool) -> Option<AudioVoiceID> {
            self.0.play(clip, volume, pitch, loop_)
        }
        fn stop(&self, voice: AudioVoiceID) {
            self.0.stop(voice)
        }
        fn is_active(&self, voice: AudioVoiceID) -> bool {
            self.0.is_active(voice)
        }
        fn set_volume(&self, voice: AudioVoiceID, volume: f32) {
            self.0.set_volume(voice, volume)
        }
        fn set_pan(&self, voice: AudioVoiceID, pan: f32) {
            self.0.set_pan(voice, pan)
        }
        fn set_pitch(&self, voice: AudioVoiceID, pitch: f32) {
            self.0.set_pitch(voice, pitch)
        }
        fn play_bgm(&self, clip: &str, volume: f32, loop_: bool) {
            self.0.play_bgm(clip, volume, loop_)
        }
        fn stop_bgm(&self) {
            self.0.stop_bgm()
        }
        fn stop_all(&self) {
            self.0.stop_all()
        }
        fn pump(&self) {
            self.0.pump()
        }
    }

    let engine = AudioEngine::new(Box::new(Shared(mock.clone())));

    engine.set_search_urls(std::slice::from_ref(&first_project));
    assert!(engine.preload("shared"));
    assert_eq!(
        mock.loaded_url_of("shared"),
        Some(first_project.join("shared.wav"))
    );
    let unload_count = mock.unload_all_clips_count();

    engine.set_search_urls(std::slice::from_ref(&second_project));
    assert_eq!(mock.unload_all_clips_count(), unload_count + 1);
    assert!(!engine.backend().is_clip_loaded("shared"));
    assert!(engine.preload("shared"));
    assert_eq!(
        mock.loaded_url_of("shared"),
        Some(second_project.join("shared.wav"))
    );

    let _ = std::fs::remove_dir_all(&first_project);
    let _ = std::fs::remove_dir_all(&second_project);
}

// "project reload and playback operations are serialized across threads"
#[test]
fn concurrent_operations_are_serialized() {
    let directory = make_clip_dir(&["shared"]);
    let mock = std::sync::Arc::new(MockAudioBackend::new());
    struct Shared(std::sync::Arc<MockAudioBackend>);
    impl AudioBackend for Shared {
        fn load_clip(&self, name: &str, url: &Path) -> bool {
            self.0.load_clip(name, url)
        }
        fn is_clip_loaded(&self, name: &str) -> bool {
            self.0.is_clip_loaded(name)
        }
        fn unload_all_clips(&self) {
            self.0.unload_all_clips()
        }
        fn play(&self, clip: &str, volume: f32, pitch: f32, loop_: bool) -> Option<AudioVoiceID> {
            self.0.play(clip, volume, pitch, loop_)
        }
        fn stop(&self, voice: AudioVoiceID) {
            self.0.stop(voice)
        }
        fn is_active(&self, voice: AudioVoiceID) -> bool {
            self.0.is_active(voice)
        }
        fn set_volume(&self, voice: AudioVoiceID, volume: f32) {
            self.0.set_volume(voice, volume)
        }
        fn set_pan(&self, voice: AudioVoiceID, pan: f32) {
            self.0.set_pan(voice, pan)
        }
        fn set_pitch(&self, voice: AudioVoiceID, pitch: f32) {
            self.0.set_pitch(voice, pitch)
        }
        fn play_bgm(&self, clip: &str, volume: f32, loop_: bool) {
            self.0.play_bgm(clip, volume, loop_)
        }
        fn stop_bgm(&self) {
            self.0.stop_bgm()
        }
        fn stop_all(&self) {
            self.0.stop_all()
        }
        fn pump(&self) {
            self.0.pump()
        }
    }

    let engine = std::sync::Arc::new(AudioEngine::new(Box::new(Shared(mock.clone()))));
    std::thread::scope(|threads| {
        for index in 0..80 {
            let engine = engine.clone();
            let directory = directory.clone();
            threads.spawn(move || match index % 4 {
                0 => engine.set_search_urls(&[directory]),
                1 => {
                    engine.preload("shared");
                }
                2 => engine.play_sfx("shared", 1.0, 1.0),
                _ => engine.reset_playback_state(),
            });
        }
    });

    engine.set_search_urls(std::slice::from_ref(&directory));
    assert!(engine.preload("shared"));
    assert_eq!(
        mock.loaded_url_of("shared"),
        Some(directory.join("shared.wav"))
    );

    let _ = std::fs::remove_dir_all(&directory);
}
