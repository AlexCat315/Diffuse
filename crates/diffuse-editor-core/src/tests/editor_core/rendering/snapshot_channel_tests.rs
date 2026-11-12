//! Ported from `Editor/Tests/EditorCoreTests/Rendering/SnapshotChannelTests.swift`.

use std::sync::Arc;

use cove_ui_compose::scene_core::{
    DrawList, DrawListAtlasDirty, DrawListSnapshot, GlyphAtlasFormat, color_glyph_atlas_id,
};

use crate::rendering::hud::snapshots::InGameDrawListSource;

struct Lease;

fn frame(dirty: Option<DrawListAtlasDirty>, width: u32) -> DrawListSnapshot {
    let mut snapshot =
        DrawListSnapshot::new(Vec::new(), Vec::new(), Vec::new(), [width as f32, 480.0]);
    snapshot.atlas_updates = dirty.into_iter().collect();
    snapshot
}

fn body_frame(width: u32) -> DrawListSnapshot {
    frame(None, width)
}

fn patch(value: u8, x: u32, texture: u32) -> DrawListAtlasDirty {
    DrawListAtlasDirty::new(
        vec![value],
        x,
        0,
        1,
        1,
        2,
        2,
        texture,
        GlyphAtlasFormat::Alpha,
    )
}

fn color_patch(value: u8, x: u32) -> DrawListAtlasDirty {
    DrawListAtlasDirty::new(
        vec![value, 20, 30, 255],
        x,
        0,
        1,
        1,
        2,
        2,
        color_glyph_atlas_id(1),
        GlyphAtlasFormat::Color,
    )
}

/// Latest frame and consumed snapshots own resources independently.
#[test]
fn snapshot_ownership() {
    let source = InGameDrawListSource::new();
    let mut list = DrawList::default();
    let owner = Arc::new(Lease);
    let observed = Arc::downgrade(&owner);
    list.resources.retain(owner.clone());
    drop(owner);
    let mut published = frame(None, 640);
    published.resources = list.resources.clone();
    source.publish(published);
    list.resources.reset();
    let mut consumed = source.consume().expect("consumed");
    source.publish(body_frame(640));
    assert!(observed.upgrade().is_some());
    let mut restored = DrawList::default();
    restored
        .load(
            consumed.vertices.clone(),
            consumed.indices.clone(),
            consumed.batches.clone(),
            consumed.resources.clone(),
        )
        .expect("restore");
    consumed.resources.reset();
    assert!(observed.upgrade().is_some());
    restored.resources.reset();
    assert!(observed.upgrade().is_none());
}

/// Skipped frames retain all glyph patches while geometry uses the newest frame.
#[test]
fn skipped_frames() {
    let source = InGameDrawListSource::new();
    source.publish(frame(Some(patch(100, 0, 1)), 640));
    source.publish(frame(Some(patch(200, 1, 1)), 640));
    source.publish(body_frame(800));
    let consumed = source.consume().expect("consumed");
    assert_eq!(consumed.logical_size[0], 800.0);
    assert_eq!(consumed.atlas_updates[0].pixels, [100, 200, 0, 0]);
    assert_eq!(consumed.atlas_updates[0].region_width, 2);
    assert!(
        source
            .consume()
            .expect("second consume")
            .atlas_updates
            .is_empty()
    );
    source.publish(frame(Some(patch(150, 0, 1)), 640));
    assert_eq!(
        source.consume().expect("third consume").atlas_updates[0].pixels,
        [150, 200, 0, 0]
    );
}

/// A replacement atlas clears pixels from the previous texture.
#[test]
fn replacement() {
    let source = InGameDrawListSource::new();
    source.publish(frame(Some(patch(100, 0, 1)), 640));
    source.publish(frame(Some(patch(200, 1, 2)), 640));
    assert_eq!(
        source.consume().expect("replacement").atlas_updates[0].pixels,
        [0, 200, 0, 0]
    );
    source.publish(frame(Some(patch(5, u32::MAX, 1)), 640));
    assert!(source.consume().expect("invalid").atlas_updates.is_empty());
}

/// Alpha and RGBA planes accumulate independently across skipped frames.
#[test]
fn paired_planes() {
    let source = InGameDrawListSource::new();
    source.publish(frame(Some(patch(100, 0, 1)), 640));
    source.publish(frame(Some(color_patch(50, 0)), 640));
    source.publish(frame(Some(color_patch(80, 1)), 640));
    source.publish(body_frame(900));
    let snapshot = source.consume().expect("snapshot");
    assert_eq!(snapshot.logical_size[0], 900.0);
    let formats: Vec<GlyphAtlasFormat> = snapshot
        .atlas_updates
        .iter()
        .map(|update| update.format)
        .collect();
    assert_eq!(formats, [GlyphAtlasFormat::Alpha, GlyphAtlasFormat::Color]);
    assert_eq!(snapshot.atlas_updates[0].pixels, [100, 0, 0, 0]);
    assert_eq!(
        snapshot.atlas_updates[1].pixels,
        [50, 20, 30, 255, 80, 20, 30, 255, 0, 0, 0, 0, 0, 0, 0, 0]
    );
    assert!(
        source
            .consume()
            .expect("second consume")
            .atlas_updates
            .is_empty()
    );
    source.publish(frame(Some(patch(5, 1, 2)), 640));
    assert_eq!(
        source.consume().expect("third consume").atlas_updates[0].pixels,
        [0, 5, 0, 0]
    );
    source.publish(frame(Some(color_patch(70, 1)), 640));
    assert_eq!(
        &source.consume().expect("fourth consume").atlas_updates[0].pixels[..8],
        [50, 20, 30, 255, 70, 20, 30, 255]
    );
}

/// Malformed RGBA patches and oversized allocations preserve the retained plane.
#[test]
fn invalid_color_patch() {
    let source = InGameDrawListSource::new();
    source.publish(frame(Some(color_patch(50, 0)), 640));
    let mut invalid = color_patch(80, 1);
    invalid.pixels.pop();
    source.publish(frame(Some(invalid), 640));
    assert_eq!(
        &source.consume().expect("malformed").atlas_updates[0].pixels[..8],
        [50, 20, 30, 255, 0, 0, 0, 0]
    );
    let mut oversized = color_patch(80, 1);
    oversized.texture_width = u32::MAX;
    oversized.texture_height = u32::MAX;
    source.publish(frame(Some(oversized), 640));
    assert!(
        source
            .consume()
            .expect("oversized")
            .atlas_updates
            .is_empty()
    );
}
