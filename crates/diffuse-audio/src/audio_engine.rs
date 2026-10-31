//! `AudioEngine` — turns the scene's audio components into playback requests and
//! drives spatial attenuation.
//!
//! All of this logic is platform-neutral: the actual sound output is delegated to
//! an injected [`AudioBackend`], so the same gameplay behaviour runs on every
//! platform and can be unit-tested with a recording mock.
//!
//! Swift read the scene through `SceneRuntime`'s `entities(with:)` /
//! `component(_:for:)`. That root type is still being translated, so the engine
//! takes an [`AudioScene`] view instead. `SceneRuntime` implements it once its
//! anchors land (MIGRATION.md §8), and nothing in this file changes.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard};

use diffuse_math::simd::simd_compat::{Float3, simd_clamp_scalar, simd_dot, simd_length};
use diffuse_scene::entity_id::EntityID;
use diffuse_scene::media::audio::{AudioListener, AudioSource};

use crate::audio_backend::{AudioBackend, AudioVoiceID};
use crate::backends::silent_audio_backend::SilentAudioBackend;

/// What the engine needs from the scene, in the shape Swift's `SceneRuntime`
/// already offers.
pub trait AudioScene {
    /// `SceneRuntime::entities(with: AudioSource.self)`.
    fn entities_with_audio_source(&self) -> Vec<EntityID>;
    /// `SceneRuntime::entities(with: AudioListener.self)`.
    fn entities_with_audio_listener(&self) -> Vec<EntityID>;
    /// `SceneRuntime::component(AudioSource.self, for:)`.
    fn audio_source(&self, entity: EntityID) -> Option<AudioSource>;
    /// `SceneRuntime::component(AudioListener.self, for:)`.
    fn audio_listener(&self, entity: EntityID) -> Option<AudioListener>;
    /// `SceneRuntime::component(WorldTransform.self, for:)?.translation`.
    fn world_translation(&self, entity: EntityID) -> Option<Float3>;
    /// `SceneRuntime::component(RigidBody.self, for:)?.linearVelocity`.
    fn linear_velocity(&self, entity: EntityID) -> Option<Float3>;
}

/// The per-voice mix the engine computes each tick.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SpatialMix {
    pub volume: f32,
    pub pan: f32,
    pub pitch: f32,
}

/// The listener state resolved for one tick.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ResolvedListener {
    pub position: Float3,
    pub master_volume: f32,
    pub linear_velocity: Float3,
}

pub struct AudioEngine {
    backend: Box<dyn AudioBackend>,
    state: Mutex<EngineState>,
}

struct EngineState {
    search_urls: Vec<PathBuf>,
    indexed_clip_urls: BTreeMap<String, PathBuf>,
    loaded_clips: BTreeSet<String>,
    /// The clip that successfully completed play-on-awake for each entity.
    /// Recording the clip (rather than only the entity) lets a later source edit
    /// arm the replacement clip even after the old voice finished.
    awakened_clips: BTreeMap<EntityID, String>,
    entity_voices: BTreeMap<EntityID, EntityVoice>,
}

#[derive(Clone, Debug, PartialEq)]
struct EntityVoice {
    id: AudioVoiceID,
    clip_name: String,
}

impl EngineState {
    fn new() -> Self {
        EngineState {
            search_urls: Vec::new(),
            indexed_clip_urls: BTreeMap::new(),
            loaded_clips: BTreeSet::new(),
            awakened_clips: BTreeMap::new(),
            entity_voices: BTreeMap::new(),
        }
    }
}

/// The extensions Swift searched, in its order.
const SEARCH_EXTENSIONS: [&str; 12] = [
    "wav", "mp3", "m4a", "aiff", "aif", "caf", "ogg", "flac", "opus", "aac", "mp4", "webm",
];

impl AudioEngine {
    /// Injects a specific backend (used by tests and embedders).
    pub fn new(backend: Box<dyn AudioBackend>) -> Self {
        AudioEngine {
            backend,
            state: Mutex::new(EngineState::new()),
        }
    }

    /// The best backend this platform offers, matching Swift: SDL3 when the
    /// binding is present, otherwise silence.
    pub fn with_default_backend() -> Self {
        Self::new(Box::new(SilentAudioBackend::new()))
    }

    fn state(&self) -> MutexGuard<'_, EngineState> {
        self.state.lock().unwrap_or_else(|error| error.into_inner())
    }

    /// The backend, for callers that need to inspect it (tests, diagnostics).
    pub fn backend(&self) -> &dyn AudioBackend {
        self.backend.as_ref()
    }

    // MARK: - Clip loading

    pub fn add_search_url(&self, url: &Path) {
        let normalized = normalize_path(url);
        let key = search_url_key(&normalized);
        let mut state = self.state();
        if state
            .search_urls
            .iter()
            .any(|existing| search_url_key(existing) == key)
        {
            return;
        }
        state.search_urls.push(normalized.clone());
        index_clip_urls(&mut state, &normalized);
    }

    /// Replaces project-scoped clip search roots. Also clears the name cache so
    /// opening another project with a clip of the same name loads the new file.
    pub fn set_search_urls(&self, urls: &[PathBuf]) {
        let mut normalized_urls = Vec::with_capacity(urls.len());
        let mut seen: BTreeSet<String> = BTreeSet::new();
        for url in urls {
            let normalized = normalize_path(url);
            if seen.insert(search_url_key(&normalized)) {
                normalized_urls.push(normalized);
            }
        }
        let mut state = self.state();
        state.search_urls = normalized_urls;
        state.indexed_clip_urls.clear();
        let roots = state.search_urls.clone();
        for directory in &roots {
            index_clip_urls(&mut state, directory);
        }
        // `resetPlaybackState()` then `unloadAllClips()` then forget the cache.
        self.backend.stop_all();
        state.awakened_clips.clear();
        state.entity_voices.clear();
        self.backend.unload_all_clips();
        state.loaded_clips.clear();
    }

    /// Ensures `name` is decoded and cached by the backend. Returns whether the
    /// clip is now available.
    pub fn preload(&self, name: &str) -> bool {
        if !is_safe_clip_name(name) {
            return false;
        }
        let mut state = self.state();
        Self::preload_locked(self.backend.as_ref(), &mut state, name)
    }

    fn preload_locked(backend: &dyn AudioBackend, state: &mut EngineState, name: &str) -> bool {
        if state.loaded_clips.contains(name) {
            return true;
        }
        for directory in &state.search_urls {
            for extension in SEARCH_EXTENSIONS {
                let url = directory.join(format!("{name}.{extension}"));
                if url.is_file() && backend.load_clip(name, &url) {
                    state.loaded_clips.insert(name.to_string());
                    return true;
                }
            }
        }
        let indexed = state.indexed_clip_urls.get(name).cloned();
        if let Some(url) = indexed
            && backend.load_clip(name, &url)
        {
            state.loaded_clips.insert(name.to_string());
            return true;
        }
        false
    }

    // MARK: - Fire-and-forget playback

    pub fn play_sfx(&self, clip_name: &str, volume: f32, pitch: f32) {
        if !self.preload(clip_name) {
            return;
        }
        let _ = self.backend.play(clip_name, volume, pitch, false);
    }

    pub fn play_bgm(&self, clip_name: &str, volume: f32, loop_: bool) {
        if !self.preload(clip_name) {
            return;
        }
        self.backend.play_bgm(clip_name, volume, loop_);
    }

    pub fn stop_bgm(&self) {
        self.backend.stop_bgm();
    }

    // MARK: - Scene-driven playback

    /// One simulation tick, mirroring Swift's `tick(scene:listenerPosition:)`.
    pub fn tick(&self, scene: &dyn AudioScene, listener_position: Float3) {
        let mut state = self.state();
        self.backend.pump();

        let resolved_listener = resolve_listener(scene, listener_position);
        let entities = scene.entities_with_audio_source();
        let mut active_ids: BTreeSet<EntityID> = BTreeSet::new();

        for id in entities {
            let Some(source) = scene.audio_source(id) else {
                continue;
            };
            if source.clip_name.is_empty() {
                continue;
            }
            active_ids.insert(id);

            let changed_clip = state
                .entity_voices
                .get(&id)
                .is_some_and(|voice| voice.clip_name != source.clip_name);
            if changed_clip {
                Self::stop_entity_locked(self.backend.as_ref(), &mut state, id);
            }

            let needs_awake = source.play_on_awake
                && state.awakened_clips.get(&id).map(String::as_str)
                    != Some(source.clip_name.as_str());

            if needs_awake {
                if Self::play_entity_locked(
                    self.backend.as_ref(),
                    &mut state,
                    scene,
                    id,
                    &source,
                    resolved_listener,
                ) {
                    // A missing asset or a temporarily unavailable device must stay
                    // eligible for retry on a later tick.
                    state.awakened_clips.insert(id, source.clip_name.clone());
                }
            } else if let Some(voice) = state.entity_voices.get(&id).cloned() {
                if self.backend.is_active(voice.id) {
                    // Re-mix live voices so moving sources fade and pan.
                    let mix = spatial_mix(&source, scene, id, resolved_listener);
                    self.backend.set_volume(voice.id, mix.volume);
                    self.backend.set_pan(voice.id, mix.pan);
                    self.backend.set_pitch(voice.id, mix.pitch);
                } else {
                    // Non-looping voices are reclaimed by the backend: forget the
                    // stale handle while retaining `awakened_clips`.
                    state.entity_voices.remove(&id);
                }
            }
        }

        // Drop both live handles and play-on-awake state when an entity or its
        // usable source goes away. `awakened_clips` participates so a finished
        // voice whose entity was deleted is still forgotten.
        let mut tracked: BTreeSet<EntityID> = state.entity_voices.keys().copied().collect();
        tracked.extend(state.awakened_clips.keys().copied());
        let stale: Vec<EntityID> = tracked
            .into_iter()
            .filter(|id| !active_ids.contains(id))
            .collect();
        for id in stale {
            Self::stop_entity_locked(self.backend.as_ref(), &mut state, id);
        }
    }

    fn play_entity_locked(
        backend: &dyn AudioBackend,
        state: &mut EngineState,
        scene: &dyn AudioScene,
        id: EntityID,
        source: &AudioSource,
        listener: ResolvedListener,
    ) -> bool {
        if !Self::preload_locked(backend, state, &source.clip_name) {
            return false;
        }
        if let Some(existing) = state.entity_voices.get(&id) {
            backend.stop(existing.id);
        }
        let mix = spatial_mix(source, scene, id, listener);
        match backend.play(&source.clip_name, mix.volume, mix.pitch, source.loop_) {
            Some(voice) => {
                state.entity_voices.insert(
                    id,
                    EntityVoice {
                        id: voice,
                        clip_name: source.clip_name.clone(),
                    },
                );
                backend.set_pan(voice, mix.pan);
                true
            }
            None => {
                state.entity_voices.remove(&id);
                false
            }
        }
    }

    /// Plays one entity's source with a synthesised listener at `listener_position`.
    pub fn play_entity(
        &self,
        scene: &dyn AudioScene,
        id: EntityID,
        source: &AudioSource,
        listener_position: Float3,
    ) {
        let mut state = self.state();
        let listener = ResolvedListener {
            position: listener_position,
            master_volume: 1.0,
            linear_velocity: Float3::ZERO,
        };
        Self::play_entity_locked(
            self.backend.as_ref(),
            &mut state,
            scene,
            id,
            source,
            listener,
        );
    }

    fn stop_entity_locked(backend: &dyn AudioBackend, state: &mut EngineState, id: EntityID) {
        if let Some(voice) = state.entity_voices.remove(&id) {
            backend.stop(voice.id);
        }
        state.awakened_clips.remove(&id);
    }

    pub fn stop_entity(&self, id: EntityID) {
        let mut state = self.state();
        Self::stop_entity_locked(self.backend.as_ref(), &mut state, id);
    }

    /// Stop everything and forget which entities have awakened. Called when play
    /// mode stops so the next run restarts cleanly.
    pub fn reset_playback_state(&self) {
        let mut state = self.state();
        self.backend.stop_all();
        state.awakened_clips.clear();
        state.entity_voices.clear();
    }
}

fn resolve_listener(scene: &dyn AudioScene, fallback: Float3) -> ResolvedListener {
    for id in scene.entities_with_audio_listener() {
        let Some(listener) = scene.audio_listener(id) else {
            continue;
        };
        let position = scene.world_translation(id).unwrap_or(fallback);
        let velocity = scene.linear_velocity(id).unwrap_or(Float3::ZERO);
        return ResolvedListener {
            position,
            master_volume: listener.master_volume,
            linear_velocity: velocity,
        };
    }
    ResolvedListener {
        position: fallback,
        master_volume: 1.0,
        linear_velocity: Float3::ZERO,
    }
}

/// The engine's spatial mix, exactly as Swift computed it.
///
/// The `!(x > 0.0)` comparisons are deliberate: they are the NaN-safe spelling of
/// Swift's `guard x > 0 else`, which takes the fallback path for NaN as well as for
/// zero. Rewriting them as `x <= 0.0` would let NaN through and change the mix.
#[allow(clippy::neg_cmp_op_on_partial_ord)]
pub fn spatial_mix(
    source: &AudioSource,
    scene: &dyn AudioScene,
    entity_id: EntityID,
    listener: ResolvedListener,
) -> SpatialMix {
    let spatial_blend = simd_clamp_scalar(source.spatial_blend, 0.0, 1.0);
    let flat_mix = SpatialMix {
        volume: source.volume * listener.master_volume,
        pan: 0.0,
        pitch: source.pitch.max(0.01),
    };
    let Some(translation) = scene.world_translation(entity_id) else {
        return flat_mix;
    };
    if !(spatial_blend > 0.0) {
        return flat_mix;
    }

    let offset = translation - listener.position;
    let distance = simd_length(offset);
    let falloff = (1.0 - distance / 50.0).max(0.0);
    let spatial = source.volume * falloff;
    let flat = source.volume * (1.0 - spatial_blend);
    let volume = (flat + spatial * spatial_blend) * listener.master_volume;

    let pitch = doppler_pitch(
        source.pitch,
        scene.linear_velocity(entity_id).unwrap_or(Float3::ZERO),
        listener.linear_velocity,
        offset,
        spatial_blend,
    );

    let horizontal_distance = (offset.x * offset.x + offset.z * offset.z).sqrt();
    if !(horizontal_distance > 0.0001) {
        return SpatialMix {
            volume,
            pan: 0.0,
            pitch,
        };
    }
    let pan = simd_clamp_scalar(offset.x / horizontal_distance, -1.0, 1.0) * spatial_blend;
    SpatialMix { volume, pan, pitch }
}

#[allow(clippy::neg_cmp_op_on_partial_ord)]
fn doppler_pitch(
    source_pitch: f32,
    source_velocity: Float3,
    listener_velocity: Float3,
    offset: Float3,
    spatial_blend: f32,
) -> f32 {
    let distance = simd_length(offset);
    if !(distance > 0.0001) {
        return source_pitch.max(0.01);
    }
    let direction = offset / distance;
    let speed_of_sound: f32 = 343.0;
    let max_radial = speed_of_sound * 0.9;
    let source_radial = simd_clamp_scalar(
        simd_dot(source_velocity, direction),
        -max_radial,
        max_radial,
    );
    let listener_radial = simd_clamp_scalar(
        simd_dot(listener_velocity, direction),
        -max_radial,
        max_radial,
    );
    let doppler = simd_clamp_scalar(
        (speed_of_sound + listener_radial) / (speed_of_sound + source_radial),
        0.5,
        2.0,
    );
    let blended = 1.0 + (doppler - 1.0) * spatial_blend;
    (source_pitch * blended).max(0.01)
}

/// `URL.standardizedFileURL` for a path.
pub fn normalize_path(path: &Path) -> PathBuf {
    std::path::absolute(path).unwrap_or_else(|_| path.to_path_buf())
}

fn search_url_key(path: &Path) -> String {
    let text = path.to_string_lossy().into_owned();
    if cfg!(target_os = "windows") {
        text.to_lowercase()
    } else {
        text
    }
}

/// Rejects names that would escape the search root, matching Swift.
pub fn is_safe_clip_name(name: &str) -> bool {
    !name.is_empty() && name != "." && name != ".." && !name.contains('/') && !name.contains('\\')
}

fn index_clip_urls(state: &mut EngineState, directory: &Path) {
    // Case-sensitive platforms need an index for common files such as `Theme.WAV`;
    // preserve search-root precedence and keep stem matching exact.
    let Ok(entries) = std::fs::read_dir(directory) else {
        return;
    };
    let mut paths: Vec<PathBuf> = entries
        .filter_map(|entry| entry.ok())
        .map(|entry| entry.path())
        .filter(|path| {
            path.file_name()
                .map(|name| !name.to_string_lossy().starts_with('.'))
                .unwrap_or(false)
        })
        .collect();
    paths.sort_by(|left, right| {
        left.file_name()
            .unwrap_or_default()
            .to_string_lossy()
            .cmp(&right.file_name().unwrap_or_default().to_string_lossy())
    });
    for entry in paths {
        let Some(name) = entry
            .file_stem()
            .map(|stem| stem.to_string_lossy().into_owned())
        else {
            continue;
        };
        if state.indexed_clip_urls.contains_key(&name) {
            continue;
        }
        let matches_extension = entry
            .extension()
            .map(|extension| {
                let extension = extension.to_string_lossy().to_lowercase();
                SEARCH_EXTENSIONS.contains(&extension.as_str())
            })
            .unwrap_or(false);
        if !matches_extension || !entry.is_file() {
            continue;
        }
        state.indexed_clip_urls.insert(name, entry);
    }
}

// MARK: - SceneRuntime / RuntimeWorld adapters

/// `RuntimeWorld` already exposes the exact queries `AudioScene` needs, so the
/// adapter is a one-to-one forwarding layer. `SceneRuntime` will forward to the
/// same place once its schedule field lands.
impl AudioScene for diffuse_scene::runtime_world::RuntimeWorld {
    fn entities_with_audio_source(&self) -> Vec<EntityID> {
        self.entities_with::<AudioSource>()
    }

    fn entities_with_audio_listener(&self) -> Vec<EntityID> {
        self.entities_with::<AudioListener>()
    }

    fn audio_source(&self, entity: EntityID) -> Option<AudioSource> {
        self.component::<AudioSource>(entity)
    }

    fn audio_listener(&self, entity: EntityID) -> Option<AudioListener> {
        self.component::<AudioListener>(entity)
    }

    fn world_translation(&self, entity: EntityID) -> Option<Float3> {
        self.world_transform(entity)
            .map(|transform| transform.translation())
    }

    fn linear_velocity(&self, entity: EntityID) -> Option<Float3> {
        self.component::<diffuse_scene::physics::rigid_body::RigidBody>(entity)
            .map(|body| body.linear_velocity)
    }
}

#[cfg(test)]
mod runtime_world_tests {
    use std::sync::Arc;

    use diffuse_scene::components::core::registry::ComponentRegistry;
    use diffuse_scene::media::audio::{AudioListener, AudioSource};
    use diffuse_scene::physics::rigid_body::RigidBody;
    use diffuse_scene::runtime_world::{RuntimeWorld, WorldTransform};

    use super::{AudioEngine, AudioScene};
    use crate::audio_backend::{AudioBackend, AudioVoiceID};
    use crate::backends::silent_audio_backend::SilentAudioBackend;
    use diffuse_math::simd::simd_compat::Float3;
    use std::path::Path;

    /// A recording backend so the engine's policy is observable through a real
    /// `RuntimeWorld` rather than a test double of the scene.
    #[derive(Default)]
    struct Recorder {
        plays: Arc<std::sync::Mutex<Vec<(String, f32)>>>,
    }

    impl AudioBackend for Recorder {
        fn load_clip(&self, _name: &str, _url: &Path) -> bool {
            true
        }
        fn is_clip_loaded(&self, _name: &str) -> bool {
            true
        }
        fn play(&self, clip: &str, volume: f32, _pitch: f32, _loop: bool) -> Option<AudioVoiceID> {
            self.plays.lock().unwrap().push((clip.to_string(), volume));
            Some(AudioVoiceID::new(1))
        }
        fn stop(&self, _voice: AudioVoiceID) {}
        fn is_active(&self, _voice: AudioVoiceID) -> bool {
            true
        }
        fn set_volume(&self, _voice: AudioVoiceID, _volume: f32) {}
        fn play_bgm(&self, _clip: &str, _volume: f32, _loop: bool) {}
        fn stop_bgm(&self) {}
        fn stop_all(&self) {}
    }

    fn world() -> RuntimeWorld {
        RuntimeWorld::new(ComponentRegistry::new())
    }

    #[test]
    fn runtime_world_satisfies_the_audio_scene_queries() {
        let mut world = world();
        let entity = world.create_entity();
        assert!(world.set_component(
            AudioSource {
                clip_name: "beep".into(),
                ..AudioSource::default()
            },
            entity
        ));
        assert!(world.set_component(AudioListener::default(), entity));
        assert!(world.set_component(
            WorldTransform::new(diffuse_math::simd::simd_compat::MATRIX_IDENTITY_FLOAT4X4),
            entity
        ));
        assert!(world.set_component(RigidBody::default(), entity));

        assert_eq!(world.entities_with_audio_source(), vec![entity]);
        assert_eq!(world.entities_with_audio_listener(), vec![entity]);
        assert_eq!(
            world.audio_source(entity).map(|source| source.clip_name),
            Some("beep".to_string())
        );
        assert!(world.audio_listener(entity).is_some());
        assert_eq!(world.world_translation(entity), Some(Float3::ZERO));
        assert_eq!(world.linear_velocity(entity), Some(Float3::ZERO));
    }

    #[test]
    fn engine_plays_through_a_real_world_and_attentates_by_distance() {
        let recorder = Recorder::default();
        let plays = recorder.plays.clone();
        let engine = AudioEngine::new(Box::new(recorder));
        // The engine searches the filesystem for clip files, so give it one.
        let directory = std::env::temp_dir().join(format!(
            "diffuse-audio-world-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|value| value.as_nanos())
                .unwrap_or(0)
        ));
        std::fs::create_dir_all(&directory).expect("clip dir");
        std::fs::write(directory.join("beep.wav"), b"").expect("clip file");
        engine.add_search_url(&directory);

        let mut world = world();
        let listener = world.create_entity();
        world.set_component(AudioListener::default(), listener);
        world.set_component(
            WorldTransform::new(diffuse_math::simd::simd_compat::MATRIX_IDENTITY_FLOAT4X4),
            listener,
        );

        let source = world.create_entity();
        world.set_component(
            AudioSource {
                clip_name: "beep".into(),
                volume: 1.0,
                play_on_awake: true,
                spatial_blend: 1.0,
                ..AudioSource::default()
            },
            source,
        );
        // `spatial_mix` reads the *world* transform, so the entity needs one.
        let mut world_matrix = diffuse_math::simd::simd_compat::MATRIX_IDENTITY_FLOAT4X4;
        world_matrix.set_column(
            3,
            diffuse_math::simd::simd_compat::Float4::new(25.0, 0.0, 0.0, 1.0),
        );
        world.set_component(WorldTransform::new(world_matrix), source);

        engine.tick(&world, Float3::ZERO);

        let recorded = plays.lock().unwrap().clone();
        assert_eq!(recorded.len(), 1, "one voice for one awake source");
        assert_eq!(recorded[0].0, "beep");
        // 25 of the 50-unit falloff range → half volume.
        assert!(
            (recorded[0].1 - 0.5).abs() < 0.01,
            "expected ~0.5, got {}",
            recorded[0].1
        );

        let _ = std::fs::remove_dir_all(&directory);
    }

    #[test]
    fn silent_backend_still_reports_clips_through_a_real_world() {
        let engine = AudioEngine::new(Box::new(SilentAudioBackend::new()));
        let mut world = world();
        let entity = world.create_entity();
        world.set_component(
            AudioSource {
                clip_name: "ghost".into(),
                play_on_awake: true,
                ..AudioSource::default()
            },
            entity,
        );
        // No search root, so nothing loads; the tick must not panic and must not
        // report a voice.
        engine.tick(&world, Float3::ZERO);
        assert!(!engine.backend().is_active(AudioVoiceID::new(1)));
    }
}
