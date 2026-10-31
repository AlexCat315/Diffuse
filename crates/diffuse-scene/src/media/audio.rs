//! Audio components authored on scene entities.

use diffuse_math::simd::simd_compat::simd_clamp_scalar;

use crate::entity_id::RuntimeComponent;

/// Component that drives audio playback on an entity.
#[derive(Clone, Debug, PartialEq)]
pub struct AudioSource {
    /// Name of the audio clip asset (filename without extension, e.g. "footstep").
    pub clip_name: String,
    pub volume: f32,
    pub pitch: f32,
    pub loop_: bool,
    /// Start playing automatically when the scene enters play mode.
    pub play_on_awake: bool,
    /// Spatial blend: 0 = fully 2D, 1 = fully 3D positional audio.
    pub spatial_blend: f32,
}

impl AudioSource {
    pub fn new(
        clip_name: impl Into<String>,
        volume: f32,
        pitch: f32,
        loop_: bool,
        play_on_awake: bool,
        spatial_blend: f32,
    ) -> Self {
        AudioSource {
            clip_name: clip_name.into(),
            volume,
            pitch,
            loop_,
            play_on_awake,
            spatial_blend,
        }
    }
}

impl Default for AudioSource {
    fn default() -> Self {
        AudioSource {
            clip_name: String::new(),
            volume: 1.0,
            pitch: 1.0,
            loop_: false,
            play_on_awake: true,
            spatial_blend: 1.0,
        }
    }
}

impl RuntimeComponent for AudioSource {}

/// Marks an entity as the audio listener for spatial audio.
/// Typically placed on the main camera entity. The audio system uses the
/// listener's world position for distance-based attenuation.
///
/// If no entity has this component, the listener defaults to world origin.
#[derive(Clone, Debug, PartialEq)]
pub struct AudioListener {
    /// Optional per-listener volume multiplier (0…1).
    pub master_volume: f32,
}

impl AudioListener {
    pub fn new(master_volume: f32) -> Self {
        AudioListener {
            master_volume: simd_clamp_scalar(master_volume, 0.0, 1.0),
        }
    }
}

impl Default for AudioListener {
    fn default() -> Self {
        AudioListener { master_volume: 1.0 }
    }
}

impl RuntimeComponent for AudioListener {}
