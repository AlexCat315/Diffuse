//! Translation of Editor/Sources/EditorCore/Rendering/HUD/Snapshots.swift.
//!
//! Thread-safe channel for passing a rendered `DrawListSnapshot` from the
//! main-thread ViewGraph pipeline to the render-thread `DrawListRenderer`.
//!
//! The main thread calls `publish` after each tick; the render thread calls
//! `consume` inside `record_in_game_ui`. The render thread always sees the most
//! recent published snapshot (last-write-wins — no queuing needed for an
//! overlay that refreshes every frame).

use std::sync::Mutex;

use cove_ui_compose::scene_core::GlyphAtlasFormat;
use cove_ui_compose::scene_core::scene::{DrawListAtlasDirty, DrawListSnapshot};

#[derive(Default)]
struct SourceState {
    latest: Option<DrawListSnapshot>,
    /// Swift keys these dictionaries on `GlyphAtlasFormat`, which is not `Ord`
    /// in Rust; the pairs keep insertion order with replace-on-insert.
    planes: Vec<(GlyphAtlasFormat, DrawListAtlasDirty)>,
    dirty_planes: Vec<GlyphAtlasFormat>,
}

pub struct InGameDrawListSource {
    state: Mutex<SourceState>,
}

impl Default for InGameDrawListSource {
    fn default() -> Self {
        Self::new()
    }
}

impl InGameDrawListSource {
    pub fn new() -> Self {
        InGameDrawListSource {
            state: Mutex::new(SourceState::default()),
        }
    }

    fn state(&self) -> std::sync::MutexGuard<'_, SourceState> {
        self.state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    pub fn publish(&self, snapshot: DrawListSnapshot) {
        let mut state = self.state();
        for update in &snapshot.atlas_updates {
            merge(&mut state, update);
        }
        state.latest = Some(snapshot);
    }

    pub fn consume(&self) -> Option<DrawListSnapshot> {
        let mut state = self.state();
        let mut snapshot = state.latest.clone()?;
        snapshot.atlas_updates = [GlyphAtlasFormat::Alpha, GlyphAtlasFormat::Color]
            .into_iter()
            .filter(|format| state.dirty_planes.contains(format))
            .filter_map(|format| {
                state
                    .planes
                    .iter()
                    .find(|(plane, _)| *plane == format)
                    .map(|(_, update)| update.clone())
            })
            .collect();
        state.dirty_planes.clear();
        Some(snapshot)
    }
}

/// Each plane retains the complete texture, including patches from frames
/// skipped during GPU startup. Geometry still uses the latest frame.
fn merge(state: &mut SourceState, update: &DrawListAtlasDirty) {
    let stride = update.format.bytes_per_pixel() as u64;
    let texture_width = u64::from(update.texture_width);
    let texture_height = u64::from(update.texture_height);
    if update.texture_id == 0
        || update.texture_width == 0
        || update.texture_height == 0
        || update.texture_width > 16_384
        || update.texture_height > 16_384
        || texture_width * texture_height * stride > 64 * 1024 * 1024
        || update.region_width == 0
        || update.region_height == 0
        || u64::from(update.region_x) + u64::from(update.region_width) > texture_width
        || u64::from(update.region_y) + u64::from(update.region_height) > texture_height
        || update.pixels.len() as u64
            != u64::from(update.region_width) * u64::from(update.region_height) * stride
    {
        return;
    }
    let position = state
        .planes
        .iter()
        .position(|(format, _)| *format == update.format);
    let mut merged = position.map(|index| state.planes.remove(index).1);
    let same_texture = merged.as_ref().is_some_and(|plane| {
        plane.texture_id == update.texture_id
            && plane.texture_width == update.texture_width
            && plane.texture_height == update.texture_height
    });
    if !same_texture {
        merged = Some(DrawListAtlasDirty::new(
            vec![
                0;
                update.texture_width as usize * update.texture_height as usize * stride as usize
            ],
            0,
            0,
            update.texture_width,
            update.texture_height,
            update.texture_width,
            update.texture_height,
            update.texture_id,
            update.format,
        ));
    }
    let Some(mut plane) = merged else {
        return;
    };
    let stride = stride as usize;
    let row_bytes = update.region_width as usize * stride;
    for row in 0..update.region_height as usize {
        let src = row * row_bytes;
        let dst = ((row + update.region_y as usize) * update.texture_width as usize
            + update.region_x as usize)
            * stride;
        plane.pixels[dst..dst + row_bytes].copy_from_slice(&update.pixels[src..src + row_bytes]);
    }
    state.planes.push((update.format, plane));
    if !state.dirty_planes.contains(&update.format) {
        state.dirty_planes.push(update.format);
    }
}
