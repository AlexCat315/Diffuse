//! Transient history/cache state committed with a submitted frame.
//!
//! Ported from
//! `Engine/Sources/RenderBackend/Core/RenderTemporalState.swift`.

use crate::core::frame::render_packet::{RenderDrawableSize, RenderPacket};
use crate::core::mesh::opaque_scene_fingerprint::OpaqueSceneFingerprint;
use crate::core::render_settings::RenderSettings;

/// The resource epochs a frame depends on. Authored settings remain whole
/// values; resource epochs also detect failed resizes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RenderFrameResourceVersion {
    pub mesh_revision: Option<u64>,
    pub post_revision: u64,
    pub used_size: RenderDrawableSize,
}

impl RenderFrameResourceVersion {
    pub fn new(
        mesh_revision: Option<u64>,
        post_revision: u64,
        used_size: RenderDrawableSize,
    ) -> Self {
        RenderFrameResourceVersion {
            mesh_revision,
            post_revision,
            used_size,
        }
    }
}

/// Transient history/cache state commits with a submitted frame. Authored
/// settings remain whole values; resource epochs also detect failed resizes.
#[derive(Clone, Debug, PartialEq)]
pub struct RenderTemporalState {
    settings: Option<RenderSettings>,
    settings_generation: u64,
    fingerprint: Option<i64>,
    resources: Option<RenderFrameResourceVersion>,
    stable_frames: i64,
    pub history_valid: bool,
    pub snapshot_valid: bool,
    moving: bool,
    cache_hit: bool,
}

impl RenderTemporalState {
    /// `static let taaWarmupFrames = 6`.
    pub const TAA_WARMUP_FRAMES: i64 = 6;

    pub fn new() -> Self {
        RenderTemporalState {
            settings: None,
            settings_generation: 0,
            fingerprint: None,
            resources: None,
            stable_frames: 0,
            history_valid: false,
            snapshot_valid: false,
            moving: true,
            cache_hit: false,
        }
    }

    pub fn moving(&self) -> bool {
        self.moving
    }

    pub fn cache_hit(&self) -> bool {
        self.cache_hit
    }

    pub fn settings_generation(&self) -> u64 {
        self.settings_generation
    }

    /// `mutating func prepare(packet:resources:hdr:)`.
    pub fn prepare(
        &mut self,
        packet: &RenderPacket,
        resources: RenderFrameResourceVersion,
        hdr: bool,
    ) {
        if self.settings.as_ref() != Some(&packet.render_settings) {
            // Swift compares `settings?.viewport.gridEnabled` — an `Optional`,
            // so a first frame with no stored settings always invalidates
            // history (nil != false).
            let previous_grid_enabled = self
                .settings
                .as_ref()
                .map(|settings| settings.viewport.grid_enabled);
            if previous_grid_enabled != Some(packet.render_settings.viewport.grid_enabled) {
                self.history_valid = false;
            }
            self.settings = Some(packet.render_settings);
            self.settings_generation = self.settings_generation.wrapping_add(1);
        }
        if !packet.render_settings.post_processing.taa {
            self.history_valid = false;
        }
        let resource_change = self.resources != Some(resources);
        if resource_change {
            self.history_valid = false;
        }
        let next = OpaqueSceneFingerprint::make(packet, self.settings_generation);
        self.moving = self.fingerprint != Some(next) || resource_change;
        self.stable_frames = if self.moving {
            0
        } else {
            self.stable_frames + 1
        };
        if self.moving {
            self.snapshot_valid = false;
        }
        self.cache_hit = hdr && self.snapshot_valid && !self.moving;
        self.fingerprint = Some(next);
        self.resources = Some(resources);
    }

    /// `func canCapture(settings:)`.
    pub fn can_capture(&self, settings: &RenderSettings) -> bool {
        let warmup = if settings.post_processing.taa {
            Self::TAA_WARMUP_FRAMES
        } else {
            0
        };
        self.stable_frames >= warmup && (!settings.post_processing.ssr || !self.moving)
    }
}

impl Default for RenderTemporalState {
    fn default() -> Self {
        Self::new()
    }
}
